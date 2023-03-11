###################################################################
#
# Example RSPQ overlay that does pixel processing on the RSP.
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

    # The BSS segment holds all uniniitialized memory buffers
    # Notice that the contents of this variable is *random* (not zero).
    # RSP code should never expect these to be zero-initialized.
    .bss

    .balign 8    # Buffers accessed via DMA must be 8-byte aligned

NRM_BUF:    .dcb.b  128*4+8     # normalmap image buffer (+ 8 bytes to handle misalignment of RDRAM pointer)
DST_BUF:    .dcb.b  128*2       # destmap image buffer
ENV_BUF:    .dcb.b  2048        # envmap image buffer

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
    #define i_val     t2
    #define j_val     t3
    #define n_shiftX   t4
    #define n_shiftY   t5
    #define X_val     t6
    #define Y_val     t7


BlendCmd_NormalMapReflect:

    li  t0, 1
    andi size, 65535
    sllv pixelsize, t0, size     #   int pixelsize = 1<<size; (eg. 32 pixel width and height image)
    sllv totalsize, pixelsize, size     #   int totalsize = pixelsize<<size; (eg. 32*32 total pixels in image)
    li  t0, 8
    sub t1, t0, strength
    move strength, t1           #   strength = 8 - strength;
    andi strength, 65535
    li  t0, 65535
    #add shiftx, shiftx, t0      #   shiftx += (1<<16); 
    #add shifty, shifty, t0      #   shifty += (1<<16);


    # Fetch envmap buffer into DMEM. Notice that we use to async version
    # of DMAIn here as we don't need to wait for the DMA to complete, we
    # can just continue.
    lw s0, %lo(ENV_SRC_RDRAM)
    li s4, %lo(ENV_BUF)
    li t0, 2048
    jal DMAInAsync
    addi t0, -1

    li i_val, 0 # store i for the pixel loop
    li j_val, 0 # store j for the pixel loop
    add pixelsize, -1
buffer_loop:
    # Fetch normalmap buffer into DMEM. This is a sync version that will
    # wait for this (and the previous!) DMA to complete.
    # NOTE: the RDRAM pointer might be misaligned (RSP DMA requires 8-byte alignment).
    # DMAIn will automatically adjust the pointer to the previous 8-byte boundary, but
    # we need to fetch 8 bytes more to make sure the correct pixels are fetched.
    lw s0, %lo(NRM_SRC_RDRAM)
    li s4, %lo(NRM_BUF)
    li t0, 512
    jal DMAIn
    addi t0, +8-1


    li pixelcount, 128 # store buffer length in pixels for the pixel loop
    lw nrm_buf, %lo(NRM_BUF)
    lw dest_buf, %lo(DST_BUF)

pixel_loop:

    # t0 - pixel buffer counter         # s1 - pixelsize
    # t1 - NRM_BUF                      # s2 - totalsize
    # t2 - i                            # s3 - DST_BUF
    # t3 - j
    # a0 - size 
    # a1 - shiftx  
    # a2 - shifty
    # a3 - strength

    addi nrm_buf, 1
    li n_shiftX, 0
    lb n_shiftX, (nrm_buf)   #      int n_shiftX = normalmap->r;
    addi nrm_buf, 1
    li n_shiftY, 0
    lb n_shiftY, (nrm_buf)   #      int n_shiftX = normalmap->g;
    addi n_shiftX, -128   
    addi n_shiftY, -128
    srlv n_shiftX, n_shiftX, strength    #      int n_shiftX = (normalmap->r - 128) >> strength;
    srlv n_shiftY, n_shiftY, strength    #      int n_shiftY = (normalmap->g - 128) >> strength;

    move X_val, i_val
    add X_val, shiftx
    add X_val, n_shiftX
    and X_val, pixelsize    #      int x = (j + shiftx + n_shiftX) % pixelsize;

    move Y_val, j_val
    add Y_val, shiftx
    add Y_val, n_shiftX
    and Y_val, pixelsize
    sllv  Y_val, Y_val, size    #      int y = ((i + shifty - n_shiftY) % pixelsize) << size;

    lw  n_shiftY, %lo(ENV_BUF)
    add n_shiftY, n_shiftY, X_val
    add n_shiftY, n_shiftY, Y_val # envmap[x + y];
    lh  n_shiftX, (n_shiftY)
    sh  n_shiftX, (dest_buf)  # *destmap = envmap[x + y];

    addi nrm_buf, 2
    addi dest_buf, 2 # normalmap++, destmap++
    addi j_val, 1 # j++
    beq  j_val, pixelsize, end_pixel_loop # if(j == pixelsize) i++
    nop
    li   j_val, 0
    addi i_val, 1 # i++

end_pixel_loop:
    # 1 pixel done, check if we're done
    addi pixelcount, -1
    bgtz pixelcount, pixel_loop
    nop
    
    # Now DMA back into RDRAM
    lw s0, %lo(DST_SRC_RDRAM)
    li s4, %lo(DST_BUF)
    li t0, 256
    jal DMAOut
    addi t0, +8-1

    # Increment pointer of the source image by the buffer amount. Next loop,
    # we'll fetch the next buffer.
    lw t4, %lo(DST_SRC_RDRAM)
    addi t4, 256
    sw t4, %lo(DST_SRC_RDRAM)

    lw t4, %lo(NRM_SRC_RDRAM)
    addi t4, 512
    sw t4, %lo(NRM_SRC_RDRAM)
    addi totalsize, -128 # subtract buffer length in pixels for the buffer loop
    bgtz totalsize, buffer_loop
    nop
    # Done! Go back to main loop
    # NOTE: we can't do "jr ra" here as "ra" was discarded by the previous DMA function calls.
    # Jumping to RSPQ_Loop is the standard way to finish an overlay command, in these cases.
    j RSPQ_Loop 
    nop

    .endfunc
