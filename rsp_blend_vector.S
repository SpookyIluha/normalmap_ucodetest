###################################################################
#
# Example RSPQ overlay that does pixel processing on the RSP with vector support.
#
###################################################################

# All rspq overlays must include rspq_queue.inc
#include <rsp_queue.inc>

# This is an internal header to share some constants between the C code and the assembly.
#include "rsp_blend_constants.h"

    .set noreorder
    .set at

    .data

# Standard RSPQ command table. This defines the entrypoints that can be called from C.
# In this case, we define two commands. The number "8" refers to the number of bytes the
# commands is made of. Currently, rspq only allow commands to be specified in multipe of
# 32-bit words, so this nunber is always expected to be a multiple of 4.
#
# The commands are:
#   * BlendCmd_NormalMapSetSources: this is used to configure the rspq overlay with the pointer to
#     source textures to reflect
#   * BlendCmd_NormalMapReflect: this is used to reflect the previously configured source textures into
#     the destination texture.
#
RSPQ_BeginOverlayHeader
    RSPQ_DefineCommand BlendCmd_NormalMapSetSources,    12  # 0x0
    RSPQ_DefineCommand BlendCmd_NormalMapReflect,       16  # 0x1
RSPQ_EndOverlayHeader

# Standard RSPQ DMEM state. This block must contain all variables that must save
# their value *between* calls to the overlay, that is between different commands.
# In general, anytime the overlay is swapped out and then back in, the data segment
# is restored ot its initial value. The only exception is this saved state, which is
# saved into RDRAM and then restored in DMEM anytime the overlay is swapped.
RSPQ_BeginSavedState

NRM_SRC_RDRAM: .long  0     # Pointer to the normalmap image in RDRAM
ENV_SRC_RDRAM: .long  0     # Pointer to the envmap image in RDRAM
DST_SRC_RDRAM: .long  0     # Pointer to the destmap image in RDRAM

RSPQ_EndSavedState

    .balign 16
VCONST:     .half 0x1F << 10    # 5-bit mask in bits 14..10
            .half 0             # Padding
            .half 0
            .half 0
            .half 0
            .half 0
            .half 0
            .half 0

VINDEX:     .byte 0             # index array from 0 to 7
            .byte 1             
            .byte 2
            .byte 3
            .byte 4
            .byte 5
            .byte 6
            .byte 7

    # The BSS segment holds all uniniitialized memory buffers
    # Notice that the contents of this variable is *random* (not zero).
    # RSP code should never expect these to be zero-initialized.
    .bss

    .balign 16    # Buffers accessed via DMA must be 8-byte aligned

#define BUFFER_PIXELS 256
#define BUFFER_ENV_SIZ 2048
#define NORM16_BYTES 2
#define RGBA16_BYTES 2
#define PX_PER_VECTOR 8

NRM_BUF:    .dcb.b  BUFFER_PIXELS*NORM16_BYTES+8     # normalmap image buffer (+ 8 bytes to handle misalignment of RDRAM pointer)
DST_BUF:    .dcb.b  BUFFER_PIXELS*RGBA16_BYTES       # destmap image buffer
ENV_BUF:    .dcb.b  BUFFER_ENV_SIZ                   # envmap image buffer

    .text


    #######################################
    # BlendCmd_NormalMapSetSources
    #
    # Set source images pointers
    #
    # Input:
    #   a0 = pointer to normalmap image in RDRAM
    #   a1 = pointer to envmap image in RDRAM
    #   a2 = pointer to destmap image in RDRAM
    #
    #######################################
    .func BlendCmd_NormalMapSetSources
BlendCmd_NormalMapSetSources:
    sw a0, %lo(NRM_SRC_RDRAM)   # Save normalmap pointer
    sw a1, %lo(ENV_SRC_RDRAM)   # Save envmap pointer
    sw a2, %lo(DST_SRC_RDRAM)   # Save destmap pointer
    j RSPQ_Loop 
    nop
    .endfunc


    #######################################
    # BlendCmd_NormalMapReflect
    #
    # Set source image pointer and size
    #
    # Input:
    # a0 = size A power of 2 size of the square textures (e.g 4 -> 16 pixels, 5 -> 32 pixels etc.)
    # a1 = shitfx Shift the environment texture x amount of pixels with wrapping before reflecting
    # a2 = shifty Shift the environment texture y amount of pixels with wrapping before reflecting
    # a3 = strength Power of 2 strength of the normal map in pixels (e.g 4 -> reflections can deviate up to 16 pixels, 5 -> 32 pixels etc.)
    #

    # C alternative:
    # void normalmap_reflect_opt16(RGBA32* normalmap, RGBA16* envmap, RGBA16* destmap, int size, int shiftx, int shifty, int strength){
    #  int pixelsize = 1<<size;
    #  strength = 8 - strength; shiftx += (1<<16); shifty += (1<<16);
    #  
    #  for(int i = 0; i < pixelsize; i++){
    #    for(int j = 0; j < pixelsize; j++, normalmap++, destmap++){
    #      
    #      int n_shiftX = (normalmap->r - 128) >> strength;
    #      int n_shiftY = (normalmap->g - 128) >> strength;
    #      
    #      int x = (j + shiftx + n_shiftX) % pixelsize;
    #      int y = ((i + shifty - n_shiftY) % pixelsize) << size;
    #
    #      *destmap = envmap[x + y];
    #    }
    #  }
    # }
    #######################################
    .func BlendCmd_NormalMapReflect
    
    # Register allocation: define aliases for readability

    #define pixelsize s1
    #define totalsize s2
    #define dest_buf  s3
    #define size      a0
    #define shiftx    a1
    #define shifty    a2
    #define strength  a3

    #define pixelcount t0
    #define nrm_buf    t1

    #define n_shiftX   $v01
    #define n_shiftY   $v02
    #define X_val      $v03
    #define Y_val      $v04
    #define Vshiftx    $v05
    #define Vshifty    $v06
    #define vindex     $v08
    #define vaddress     $v09
    #define vresult     $v10

BlendCmd_NormalMapReflect:

    li  t0, 1
    sllv pixelsize, t0, size     #   int pixelsize = 1<<size; (eg. 32 pixel width and height image)
    sllv totalsize, pixelsize, size     #   int totalsize = pixelsize<<size; (eg. 32*32 total pixels in image)
    
    #   this line of code is done beforehand on cpu when issuing the command
    #    #  strength = 8 - strength; shiftx += (1<<16); shifty += (1<<16);

    # Fetch envmap buffer into DMEM. Notice that we use to async version
    # of DMAIn here as we don't need to wait for the DMA to complete, we
    # can just continue.
    lw s0, %lo(ENV_SRC_RDRAM)
    li s4, %lo(ENV_BUF)
    li t0, BUFFER_ENV_SIZ
    jal DMAInAsync
    addi t0, -1

    la t0, %lo(VINDEX)
    luv vindex,  0,t0 # store indices for the pixel loop
    vsra  vindex, vindex, 7
    add pixelsize, -1

    li t0, %lo(ENV_BUF)
    mtc2 t0, vaddress.e0

buffer_loop:
    # Fetch normalmap buffer into DMEM. This is a sync version that will
    # wait for this (and the previous!) DMA to complete.
    # NOTE: the RDRAM pointer might be misaligned (RSP DMA requires 8-byte alignment).
    # DMAIn will automatically adjust the pointer to the previous 8-byte boundary, but
    # we need to fetch 8 bytes more to make sure the correct pixels are fetched.
    lw s0, %lo(NRM_SRC_RDRAM)
    li s4, %lo(NRM_BUF)
    li t0, BUFFER_PIXELS*NORM16_BYTES
    jal DMAIn
    addi t0, +8-1


    li pixelcount, BUFFER_PIXELS # store buffer length in pixels for the pixel loop
    la nrm_buf, %lo(NRM_BUF)
    la dest_buf, %lo(DST_BUF)

pixel_loop:

    # t0 - pixel buffer counter         # s1 - pixelsize
    # t1 - NRM_BUF                      # s2 - totalsize
    # a0 - size                         # s3 - DST_BUF
    # a1 - shiftx  
    # a2 - shifty
    # a3 - strength

    # v1 - n_shiftX
    # v2 - n_shiftY
    # v3 - X_val
    # v4 - Y_val
    # v5 - Vshiftx
    # v6 - Vshifty
    # v8 - vindex

    #luv   n_shiftX, 0,nrm_buf  #      int n_shiftX = normalmap->x;
    #luv   n_shiftY, 8,nrm_buf  #      int n_shiftY = normalmap->y;
    #vsra  n_shiftX, n_shiftX, 7
    #vsra  n_shiftY, n_shiftY, 7

    #vsubc n_shiftX, K128
    #vsubc n_shiftY, K128

    #vsra  n_shiftX, n_shiftX, 4   #      int n_shiftX = (normalmap->x - 128) >> strength;
    #vsra  n_shiftY, n_shiftY, 4   #      int n_shiftY = (normalmap->y - 128) >> strength;

    #vor   X_val, vindex, vzero
    #vadd  X_val, Vshiftx
    #vadd  X_val, n_shiftX
    #vand  X_val, K32       #      int x = (count + shiftx + n_shiftX) % pixelsize;

    #vor   Y_val, vindex, vzero
    #vsrl  Y_val, Y_val, 5
    #vsub  Y_val, Vshifty   #      this line is either sub or add depends on whether you use DirectX/OpenGL normal maps respectively
    #vadd  Y_val, n_shiftY
    #vand  Y_val, K32
    #vsll  Y_val, Y_val, 5   #      int y = (((count >> size) + shifty - n_shiftY) % pixelsize) << size;

    #vadd n_shiftX, X_val, Y_val # x+y
    vadd n_shiftX, vindex, vzero # x+y
    vsll n_shiftX, n_shiftX, 1 # (x+y)*2


    vadd n_shiftX, vaddress.e0 # pre-add the address to all values

    mfc2 t4, n_shiftX.e0
    mfc2 t5, n_shiftX.e1
    mfc2 t6, n_shiftX.e2
    mfc2 t7, n_shiftX.e3
    mfc2 t8, n_shiftX.e4
    mfc2 t9, n_shiftX.e5
    mfc2 s6, n_shiftX.e6
    mfc2 s7, n_shiftX.e7

    lsv vresult.e0, 0,t4 # *destmap = envmap[x + y];
    lsv vresult.e1, 0,t5 # *destmap = envmap[x + y];
    lsv vresult.e2, 0,t6 # *destmap = envmap[x + y];
    lsv vresult.e3, 0,t7 # *destmap = envmap[x + y];
    lsv vresult.e4, 0,t8 # *destmap = envmap[x + y];
    lsv vresult.e5, 0,t9 # *destmap = envmap[x + y];
    lsv vresult.e6, 0,s6 # *destmap = envmap[x + y];
    lsv vresult.e7, 0,t7 # *destmap = envmap[x + y];

    sqv vresult, 0,dest_buf

    addi nrm_buf,  NORM16_BYTES*PX_PER_VECTOR
    addi dest_buf, RGBA16_BYTES*PX_PER_VECTOR # normalmap++, destmap++
    vadd vindex, K8

end_pixel_loop:
    # 8 pixels done, check if we're done
    addi pixelcount, -PX_PER_VECTOR
    bgtz pixelcount, pixel_loop
    
    # Now DMA back into RDRAM
    lw s0, %lo(DST_SRC_RDRAM)
    li s4, %lo(DST_BUF)
    li t0, BUFFER_PIXELS*RGBA16_BYTES
    jal DMAOut
    addi t0, +8-1

    # Increment pointer of the source image by the buffer amount. Next loop,
    # we'll fetch the next buffer.
    lw t4, %lo(DST_SRC_RDRAM)
    addi t4, BUFFER_PIXELS*RGBA16_BYTES
    sw t4, %lo(DST_SRC_RDRAM)

    lw t4, %lo(NRM_SRC_RDRAM)
    addi t4, BUFFER_PIXELS*NORM16_BYTES
    sw t4, %lo(NRM_SRC_RDRAM)
    addi totalsize, -BUFFER_PIXELS # subtract buffer length in pixels for the buffer loop
    bgtz totalsize, buffer_loop
    nop


    # Done! Go back to main loop
    # NOTE: we can't do "jr ra" here as "ra" was discarded by the previous DMA function calls.
    # Jumping to RSPQ_Loop is the standard way to finish an overlay command, in these cases.
    j RSPQ_Loop 
    nop

    .endfunc