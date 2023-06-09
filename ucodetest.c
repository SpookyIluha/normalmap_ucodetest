#include <stdio.h>
#include <malloc.h>
#include <string.h>
#include <stdint.h>

#include <libdragon.h>
#include "rsp_blend_constants.h"

static sprite_t *tiles_sprite;
static sprite_t *normal_sprite;
static surface_t dest_surface;
static rspq_block_t *tiles_block;
rdpq_font_t *fnt1;

int shiftx = 0;
int shifty = 0;
int usec = 0;



static uint32_t ovl_id;
static void rsp_blend_assert_handler(rsp_snapshot_t *state, uint16_t code);

enum {
    // Overlay commands. This must match the command table in the RSP code
    RSP_BLEND_CMD_NORMALMAP_SET_SOURCES  = 0x0,
    RSP_BLEND_CMD_NORMALMAP_REFLECT     = 0x1,
};

// Overlay definition
DEFINE_RSP_UCODE(rsp_blend, .assert_handler = rsp_blend_assert_handler);

void rsp_blend_init(void) {
    // Initialize if rspq (if it isn't already). It's best practice to let all overlays
    // always call rspq_init(), so that they can be themselves initialized in any order
    // by the user.
    rspq_init();
    ovl_id = rspq_overlay_register(&rsp_blend);
}

void rsp_blend_assert_handler(rsp_snapshot_t *state, uint16_t code) {
    switch (code) {
    case ASSERT_INVALID_WIDTH:
        printf("Invalid surface width (%ld)\nMust be multiple of 8 and less than 640\n",
            state->gpr[8]); // read current width from t0 (reg #8): we know it's there at assert point
        return;
    }
}

typedef struct rgba32_t
{
  unsigned char r;
  unsigned char g;
  unsigned char b;
  unsigned char a;
} RGBA32;

typedef unsigned short RGBA16;

void rsp_blend_normalmap_set_sources(RGBA32* normalmap, RGBA16* envmap, RGBA16* destmap) {
    rspq_write(ovl_id, RSP_BLEND_CMD_NORMALMAP_SET_SOURCES, PhysicalAddr(normalmap),PhysicalAddr(envmap),PhysicalAddr(destmap));
}

void rsp_blend_normalmap_reflect(int size, int shiftx, int shifty, int strength) {
    rspq_write(ovl_id, RSP_BLEND_CMD_NORMALMAP_REFLECT, size, shiftx, shifty, strength);
}


/// @brief Calculate the reflections on an 16-bit unfiltered environment map using an equal sized normal map
/// @param normalmap Pointer to the raw 32-bit standard normal map texture
/// @param envmap Pointer to the raw 16-bit unfiltered environment map texture of equal size
/// @param destmap Pointer to the raw 16-bit texture to store the result onto
/// @param size A power of 2 size of the square textures (e.g 4 -> 16 pixels, 5 -> 32 pixels etc.)
/// @param shitfx Shift the environment texture x amount of pixels with wrapping before reflecting
/// @param shifty Shift the environment texture y amount of pixels with wrapping before reflecting
/// @param strength Power of 2 strength of the normal map in pixels (e.g 4 -> reflections can deviate up to 16 pixels, 5 -> 32 pixels etc.)
void normalmap_reflect_rspq16(RGBA32* normalmap, RGBA16* envmap, RGBA16* destmap, int size, int shiftx, int shifty, int strength){
  rsp_blend_normalmap_set_sources(normalmap, envmap, destmap);
  rsp_blend_normalmap_reflect(size, shiftx, shifty, strength);
}

void render(int cur_frame)
{
    surface_t *disp;
    RSP_WAIT_LOOP(200) {
        if ((disp = display_lock())) {
            break;
        }
    }   

    // Attach and clear the screen
    rdpq_attach_clear(disp, NULL);
    rspq_block_run(tiles_block);
    // Draw the tile background, by playing back the compiled block.
    // This is using copy mode by default, but notice how it can switch
    // to standard mode (aka "1 cycle" in RDP terminology) in a completely
    // transparent way. Even if the block is compiled, the RSP commands within it
    // will adapt its commands to the current render mode, Try uncommenting
    // the line below to see.
    rdpq_debug_log_msg("tiles");

        rdpq_font_begin(RGBA32(0xFF, 0x00, 0x00, 0xFF));
        rdpq_font_position(10, 20);
        rdpq_font_printf(fnt1, "%ld usec", usec);
        rdpq_font_end();

    rdpq_detach_show();
}

int main(void)
{
    display_init(RESOLUTION_320x240, DEPTH_16_BPP, 3, GAMMA_NONE, ANTIALIAS_RESAMPLE);

    controller_init();
    timer_init(); 
    dfs_init(DFS_DEFAULT_LOCATION);
    rdpq_init();
    rsp_init();
    rsp_blend_init();  // init our custom overlay

    tiles_sprite = sprite_load("rom:/env_spec1.sprite");
    normal_sprite = sprite_load("rom:/normal.sprite");
    fnt1 = rdpq_font_load("rom:/Ac437_Tandy2K_G.font64");

    surface_t normal_surf = sprite_get_pixels(normal_sprite);
    surface_t tiles_surf = sprite_get_pixels(tiles_sprite);
    dest_surface = surface_alloc(FMT_RGBA16, 32,32);
    for(int i = 0; i < 32*32; i++){
        ((RGBA16*)dest_surface.buffer)[i] = 0;
    }

    
    uint32_t display_width = display_get_width();
    uint32_t display_height = display_get_height();
    uint32_t tile_width = 32;
    uint32_t tile_height = 32;

    // Create a block for the background, so that we can replay it later.
    rspq_block_begin();
    rdpq_set_mode_standard();
    for (uint32_t ty = 0; ty < display_height; ty += tile_height)
    {
        for (uint32_t tx = 0; tx < display_width; tx += tile_width)
        {
            // Load a random tile among the 4 available in the texture,
            // and draw it as a rectangle.
            // Notice that this code is agnostic to both the texture format
            // and the render mode (standard vs copy), it will work either way.
            rdpq_tex_load(TILE0, &dest_surface, 0);
            rdpq_texture_rectangle(TILE0, tx, ty, tx+32, ty+32, 0, 0);
        }
    }

    tiles_block = rspq_block_end();


    int cur_frame = 0;
    while (1)
    {
        long long t0 = timer_ticks();
        normalmap_reflect_rspq16((RGBA32*)normal_surf.buffer, (RGBA16*)tiles_surf.buffer, (RGBA16*)dest_surface.buffer, 5, shiftx, shifty, 5);
        long long t1 = timer_ticks();
        usec = TICKS_DISTANCE(t0, t1) / (TICKS_PER_SECOND / 1000 / 1000 );
        render(cur_frame);

        controller_scan();
        struct controller_data contheld = get_keys_pressed();
        
        if (contheld.c[0].C_up) shifty++;
        if (contheld.c[0].C_down) shifty--;
        if (contheld.c[0].C_left) shiftx++;
        if (contheld.c[0].C_right) shiftx--;

        cur_frame++;
    }
}
