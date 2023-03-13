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
    .balign 16    # Buffers accessed via DMA must be 8-byte aligned
NRM_BUF:    .dcb.b  BUFFER_PIXELS*NORM16_BYTES       # normalmap image buffer (+ 8 bytes to handle misalignment of RDRAM pointer)
    .balign 16    # Buffers accessed via DMA must be 8-byte aligned
DST_BUF:    .dcb.b  BUFFER_PIXELS*RGBA16_BYTES       # destmap image buffer
    .balign 16    # Buffers accessed via DMA must be 8-byte aligned
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
    
    #define vstall

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
    #define rowcount   s5

    #define n_shiftX   $v01
    #define n_shiftY   $v02
    #define X_val      $v03
    #define Y_val      $v04
    #define Vshiftx    $v05
    #define Vshifty    $v06
    #define vindex     $v08
    #define vaddress   $v09
    #define vresult    $v10
    #define values     $v11
    #define kpixelsize $v11.e0
    #define ksize      $v11.e1
    #define ksize2     $v11.e5
    #define kshiftx    $v11.e2
    #define kshifty    $v11.e3
    #define kstrength  $v11.e4
    #define vcalcindex   $v12
    #define vcalcoffset  $v13
    #define vcalcaddress $v14
    #define X_val2     $v15
    #define Y_val2     $v16
    #define Y_val3     $v17
    #define vindexY    $v18

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
    vor vaddress, vzero, vaddress.e0

    li t0, 1<<16>>7
    srav strength, t0, strength
    mtc2 strength, kstrength

    li t0, 1<<16
    srav t0, t0, size
    mtc2 t0, ksize

    li t0, 1
    sllv t0, t0, size
    mtc2 t0, ksize2

    mtc2 pixelsize, kpixelsize
    mtc2 shiftx, kshiftx
    mtc2 shifty, kshifty
    vand vindexY, vindexY, vzero
    add pixelsize, 1
    vadd  vindex,  vindex, kshiftx
    vadd  vindexY, vindexY,kshifty

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

    li pixelcount, BUFFER_PIXELS # store buffer length in pixels for the buffer loop
    la nrm_buf, %lo(NRM_BUF)
    la dest_buf, %lo(DST_BUF)

row_loop:
    move rowcount, pixelsize # store row length in pixels for the row loop
pixel_loop:

    lpv   n_shiftX, 0,nrm_buf  #       int n_shiftX = normalmap->x; 
    lpv   n_shiftY, 8,nrm_buf  #       int n_shiftY = normalmap->y;
    vmudm n_shiftX, kstrength   #      int n_shiftX = (normalmap->x - 128) >> strength;
    vmudm n_shiftY, kstrength   #      int n_shiftY = (normalmap->y - 128) >> strength;
    vstall
    vstall

    vadd  X_val, vindex,  n_shiftX
    vsub  Y_val, vindexY, n_shiftY   #      this line is either add or sub depends on whether you use DirectX/OpenGL normal maps respectively
    vstall
    vstall
    vand  X_val2, X_val, kpixelsize       #      int x = (index_x + shiftx + n_shiftX) % pixelsize;
    vstall
    vand  Y_val2, Y_val  kpixelsize
    vmudn Y_val3, Y_val2, ksize2   #      int y = ((index_y + shifty - n_shiftY) % pixelsize) << size;
    vstall
    vstall

    vmudn vcalcoffset, X_val2, K2 # use MAC to calculate the address into envmap after normal mapping
    vmadn vcalcoffset, Y_val3, K2 # (x+y)*2
    vmadn vcalcaddress, vaddress, K1 # pre-add the address to all values

    mfc2 t4, vcalcaddress.e0
    mfc2 t5, vcalcaddress.e1
    mfc2 t6, vcalcaddress.e2
    mfc2 t7, vcalcaddress.e3
    mfc2 t8, vcalcaddress.e4
    mfc2 t9, vcalcaddress.e5
    mfc2 s6, vcalcaddress.e6
    mfc2 s7, vcalcaddress.e7

    lsv vresult.e0, 0,t4 # *destmap = envmap[x + y];
    lsv vresult.e1, 0,t5 # *destmap = envmap[x + y];
    lsv vresult.e2, 0,t6 # *destmap = envmap[x + y];
    lsv vresult.e3, 0,t7 # *destmap = envmap[x + y];
    lsv vresult.e4, 0,t8 # *destmap = envmap[x + y];
    lsv vresult.e5, 0,t9 # *destmap = envmap[x + y];
    lsv vresult.e6, 0,s6 # *destmap = envmap[x + y];
    lsv vresult.e7, 0,s7 # *destmap = envmap[x + y];

end_pixel_loop:

    vadd vindex, K8
    addi nrm_buf,  NORM16_BYTES*PX_PER_VECTOR
    addi dest_buf, RGBA16_BYTES*PX_PER_VECTOR # normalmap++, destmap++, index++
    addi rowcount, -PX_PER_VECTOR
    
    bgtz rowcount, pixel_loop     # 8 pixels done, check if we're done with the row
    sqv vresult, -RGBA16_BYTES*PX_PER_VECTOR,dest_buf

end_row_loop:
    vadd vindexY, K1
    # 1 row done, check if we're done with the buffer
    sub  pixelcount, pixelsize
    bgtz pixelcount, row_loop
end_buffer_loop:

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
