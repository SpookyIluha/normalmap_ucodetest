#include <stdio.h>
#include <malloc.h>
#include <string.h>
#include <stdint.h>

#include <libdragon.h>
#include "rsp_blend_constants.h"
#include "lib/normalmap.c"

static sprite_t *tiles_sprite;
static sprite_t *normal_sprite;
static surface_t dest_surface;
static surface_t normal_pack_surf;
static rspq_block_t *tiles_block;
rdpq_font_t *fnt1;

int shiftx = 0;
int shifty = 0;
int usec = 0;
int mode = 1;


static uint32_t ovl_id;
static void rsp_blend_vector_assert_handler(rsp_snapshot_t *state, uint16_t code);

enum {
    // Overlay commands. This must match the command table in the RSP code
    RSP_BLEND_VECTOR_CMD_NORMALMAP_SET_SOURCES  = 0x0,
    RSP_BLEND_VECTOR_CMD_NORMALMAP_REFLECT     = 0x1
};

// Overlay definition
DEFINE_RSP_UCODE(rsp_blend_vector, .assert_handler = rsp_blend_vector_assert_handler);

void rsp_blend_vector_init(void) {
    // Initialize if rspq (if it isn't already). It's best practice to let all overlays
    // always call rspq_init(), so that they can be themselves initialized in any order
    // by the user.
    rspq_init();
    ovl_id = rspq_overlay_register(&rsp_blend_vector);
}

void rsp_blend_vector_assert_handler(rsp_snapshot_t *state, uint16_t code) {
    switch (code) {
    case ASSERT_INVALID_WIDTH:
        printf("Invalid surface width (%ld)\nMust be multiple of 8 and less than 640\n",
            state->gpr[8]); // read current width from t0 (reg #8): we know it's there at assert point
        return;
    }
}


void rsp_blend_vector_normalmap_set_sources(NORM16PAK* normalmap, RGBA16* envmap, RGBA16* destmap) {
    rspq_write(ovl_id, RSP_BLEND_VECTOR_CMD_NORMALMAP_SET_SOURCES, PhysicalAddr(normalmap),PhysicalAddr(envmap),PhysicalAddr(destmap));
}

void rsp_blend_vector_normalmap_reflect(int size, int shiftx, int shifty, int strength) {
    rspq_write(ovl_id, RSP_BLEND_VECTOR_CMD_NORMALMAP_REFLECT, size, shiftx, shifty, strength);
}


/// @brief Calculate the reflections on an 16-bit unfiltered environment map using an equal sized normal map
/// @param normalmap Pointer to the raw 32-bit standard normal map texture
/// @param envmap Pointer to the raw 16-bit unfiltered environment map texture of equal size
/// @param destmap Pointer to the raw 16-bit texture to store the result onto
/// @param size A power of 2 size of the square textures (e.g 4 -> 16 pixels, 5 -> 32 pixels etc.)
/// @param shitfx Shift the environment texture x amount of pixels with wrapping before reflecting
/// @param shifty Shift the environment texture y amount of pixels with wrapping before reflecting
/// @param strength Power of 2 strength of the normal map in pixels (e.g 4 -> reflections can deviate up to 16 pixels, 5 -> 32 pixels etc.)
void normalmap_reflect_rspq16(NORM16PAK* normalmap, RGBA16* envmap, RGBA16* destmap, int size, int shiftx, int shifty, int strength){
  strength = 8 - strength; shiftx += (1<<16); shifty = (1<<16) - shifty;
  rsp_blend_vector_normalmap_set_sources(normalmap, envmap, destmap);
  rsp_blend_vector_normalmap_reflect(size, shiftx, shifty, strength);
}


/// @brief Split the R/G channels into 8byte interleaved planes for the RSP implementation format. Can be called just once per image loading from a file. Output format is RRRRRRRRGGGGGGGG.
/// @param normalmap Pointer to the raw 32-bit standard normal map texture
/// @param output Pointer to the raw 16-bit texture to store the result onto
/// @param size A power of 2 size of the square textures (e.g 4 -> 16 pixels, 5 -> 32 pixels etc.)

void normalmap_packimage(RGBA32* normalmap, NORM16PAK* output, int size){
    int totalsize = 2<<size<<size;     int sizeplane = sizeof(uba64_t);
    int8_t* outX = (int8_t*)output;
    int8_t* outY = (int8_t*)output + sizeplane;
    
    for(int i = 0; i < totalsize / sizeplane; i++, outX+=sizeplane, outY+=sizeplane){
        for(int  j = 0; j < sizeplane; j++, normalmap++, outX++, outY++){
            *outX = normalmap->r - 128;
            *outY = normalmap->g - 128;
        }
    }
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
    //rdpq_debug_log_msg("tiles");

        rdpq_font_begin(RGBA32(0xFF, 0xFF, 0xFF, 0xFF));
        rdpq_font_position(40, 60);
        rdpq_font_printf(fnt1, "%ld usec", usec);
        rdpq_font_end();

    rdpq_detach_show();
}

int main(void)
{
	debug_init_isviewer();
	debug_init_usblog();
    display_init(RESOLUTION_320x240, DEPTH_16_BPP, 3, GAMMA_NONE, ANTIALIAS_RESAMPLE);

    controller_init();
    timer_init(); 
    dfs_init(DFS_DEFAULT_LOCATION);
    rdpq_init();
    rsp_init();
    rsp_blend_vector_init();  // init our custom overlay

    tiles_sprite = sprite_load("rom:/env_spec1.sprite");
    normal_sprite = sprite_load("rom:/normal.sprite");
    fnt1 = rdpq_font_load("rom:/Ac437_Tandy2K_G.font64");

    surface_t normal_surf = sprite_get_pixels(normal_sprite);
    surface_t tiles_surf = sprite_get_pixels(tiles_sprite);
    normal_pack_surf = surface_alloc(FMT_I8, 64,32);
    dest_surface = surface_alloc(FMT_RGBA16, 32,32);

    normalmap_packimage((RGBA32*)normal_surf.buffer, (NORM16PAK*)normal_pack_surf.buffer, 5);

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
        rspq_wait(); // finish whatever is pending
        long long t0 = timer_ticks();
        //for(int i = 0; i < mode; i++)
            normalmap_reflect_rspq16((NORM16PAK*)normal_pack_surf.buffer, (RGBA16*)tiles_surf.buffer, (RGBA16*)dest_surface.buffer, 5, shiftx, shifty, mode);

        // Wait until RSP+RDP are idle. This is normally not required, but we force it here
        // to measure the exact frame computation time.
        rspq_wait();
        long long t1 = timer_ticks();
        usec = TIMER_MICROS_LL(t1-t0);

        render(cur_frame);

        controller_scan(); 
        struct controller_data contheld = get_keys_pressed();
        struct controller_data conttrigger = get_keys_down();
        
        if (contheld.c[0].C_up) shifty++; 
        if (contheld.c[0].C_down) shifty--;
        if (contheld.c[0].C_left) shiftx++; 
        if (contheld.c[0].C_right) shiftx--;
        if (conttrigger.c[0].Z) mode++;
        mode = mode % 16;

        cur_frame++;
    }

}
