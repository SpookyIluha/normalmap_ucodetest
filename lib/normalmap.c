#include <stdio.h>
#include <malloc.h>
#include <string.h>
#include <stdint.h>

#include <libdragon.h>

typedef struct rgba32_t
{
  unsigned char r;
  unsigned char g;
  unsigned char b;
  unsigned char a;
} RGBA32;

typedef struct uba64_t { unsigned char value[8]; } uba64_t;

typedef struct norm16pak_t
{
  uba64_t x;
  uba64_t y;
} NORM16PAK;

typedef unsigned short RGBA16;

/// @brief Calculate the reflections on an 32-bit unfiltered environment map using an equal sized normal map
/// @param normalmap Pointer to the raw 32-bit standard normal map texture
/// @param envmap Pointer to the raw 32-bit unfiltered environment map texture of equal size
/// @param destmap Pointer to the raw 32-bit texture to store the result onto
/// @param size A power of 2 size of the square textures (e.g 4 -> 16 pixels, 5 -> 32 pixels etc.)
/// @param shitfx Shift the environment texture x amount of pixels with wrapping before reflecting
/// @param shifty Shift the environment texture y amount of pixels with wrapping before reflecting
/// @param strength Power of 2 strength of the normal map in pixels (e.g 4 -> reflections can deviate up to 16 pixels, 5 -> 32 pixels etc.)
void normalmap_reflect_opt32(RGBA32* normalmap, RGBA32* envmap, RGBA32* destmap, int size, int shiftx, int shifty, int strength){
  int pixelsize = 1<<size;
  strength = 8 - strength; shiftx += (1<<16); shifty += (1<<16);
  
  for(int i = 0; i < pixelsize; i++){
    for(int j = 0; j < pixelsize; j++, normalmap++, destmap++){
      
      int n_shiftx = (normalmap->r - 128) >> strength;
      int n_shifty = (normalmap->g - 128) >> strength;
      
      int x = (j + shiftx + n_shiftx) % pixelsize;
      int y = ((i + shifty - n_shifty) % pixelsize) << size;

      *destmap = envmap[x + y];
    }
  }
}

/// @brief Calculate the reflections on an 16-bit unfiltered environment map using an equal sized normal map
/// @param normalmap Pointer to the raw 32-bit standard normal map texture
/// @param envmap Pointer to the raw 16-bit unfiltered environment map texture of equal size
/// @param destmap Pointer to the raw 16-bit texture to store the result onto
/// @param size A power of 2 size of the square textures (e.g 4 -> 16 pixels, 5 -> 32 pixels etc.)
/// @param shitfx Shift the environment texture x amount of pixels with wrapping before reflecting
/// @param shifty Shift the environment texture y amount of pixels with wrapping before reflecting
/// @param strength Power of 2 strength of the normal map in pixels (e.g 4 -> reflections can deviate up to 16 pixels, 5 -> 32 pixels etc.)
void normalmap_reflect_opt16(RGBA32* normalmap, RGBA16* envmap, RGBA16* destmap, int size, int shiftx, int shifty, int strength){
  int pixelsize = 1<<size;
  strength = 8 - strength; shiftx += (1<<16); shifty += (1<<16);
  
  for(int i = 0; i < pixelsize; i++){
    for(int j = 0; j < pixelsize; j++, normalmap++, destmap++){
      
      int n_shiftx = (normalmap->r - 128) >> strength;
      int n_shifty = (normalmap->g - 128) >> strength;
      
      int x = (j + shiftx + n_shiftx) % pixelsize;
      int y = ((i + shifty - n_shifty) % pixelsize) << size;

      *destmap = envmap[x + y];
    }
  }
}

/// @brief Calculate the reflections on an 32-bit prefiltered (magnified) environment map using a normal map 
///
///(Slower than using unfiltered version and takes more memory but the reflections are smoother)
/// @param normalmap Pointer to the raw 32-bit standard normal map texture
/// @param envmap Pointer to the raw 32-bit prefiltered environment map texture of magnified size
/// @param destmap Pointer to the raw 32-bit texture to store the result onto of equal size to the normal map
/// @param size A power of 2 size of the square normalmap and dest textures (e.g 4 -> 16 pixels, 5 -> 32 pixels etc.)
/// @param shitfx Shift the magnified environment texture x amount of pixels with wrapping before reflecting
/// @param shifty Shift the magnified environment texture y amount of pixels with wrapping before reflecting
/// @param strength Power of 2 strength of the normal map in pixels (e.g 4 -> reflections can deviate up to 16 pixels, 5 -> 32 pixels etc.)
void normalmap_reflect_filt32(RGBA32* normalmap, RGBA32* envmap, RGBA32* destmap, int size, int filterfactor, int shiftx, int shifty, int strength){
  int pixelsize = 1<<size<<filterfactor;
  int pixelfactor = 1<<filterfactor;
  strength = 8 - strength; shiftx += (1<<16); shifty += (1<<16);
  
  for(int i = 0; i < pixelsize; i+=pixelfactor){
    for(int j = 0; j < pixelsize; j+=pixelfactor, normalmap++, destmap++){
      
      int n_shiftx = (normalmap->r - 128) >> strength;
      int n_shifty = (normalmap->g - 128) >> strength;
      
      int x = (j + shiftx - n_shiftx) % pixelsize;
      int y = ((i + shifty - n_shifty) % pixelsize) << size << filterfactor;

      *destmap = envmap[x + y];
    }
  }
}

/// @brief Calculate the reflections on an 16-bit prefiltered (magnified) environment map using a normal map 
///
///(Slower than using unfiltered version and takes more memory but the reflections are smoother)
/// @param normalmap Pointer to the raw 32-bit standard normal map texture
/// @param envmap Pointer to the raw 16-bit prefiltered environment map texture of magnified size
/// @param destmap Pointer to the raw 16-bit texture to store the result onto of equal size to the normal map
/// @param size A power of 2 size of the square normalmap and dest textures (e.g 4 -> 16 pixels, 5 -> 32 pixels etc.)
/// @param shitfx Shift the magnified environment texture x amount of pixels with wrapping before reflecting
/// @param shifty Shift the magnified environment texture y amount of pixels with wrapping before reflecting
/// @param strength Power of 2 strength of the normal map in pixels (e.g 4 -> reflections can deviate up to 16 pixels, 5 -> 32 pixels etc.)
void normalmap_reflect_filt16(RGBA32* normalmap, RGBA16* envmap, RGBA16* destmap, int size, int filterfactor, int shiftx, int shifty, int strength){
  int pixelsize = 1<<size<<filterfactor;
  int pixelfactor = 1<<filterfactor;
  strength = 8 - strength; shiftx += (1<<16); shifty += (1<<16);
  
  for(int i = 0; i < pixelsize; i+=pixelfactor){
    for(int j = 0; j < pixelsize; j+=pixelfactor, normalmap++, destmap++){
      
      int n_shiftx = (normalmap->r - 128) >> strength;
      int n_shifty = (normalmap->g - 128) >> strength;
      
      int x = (j + shiftx - n_shiftx) % pixelsize;
      int y = ((i + shifty - n_shifty) % pixelsize) << size << filterfactor;

      *destmap = envmap[x + y];
    }
  }
}