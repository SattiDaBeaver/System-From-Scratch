.section .text
.globl _start
# Draws an 8x8-block checkerboard into the VGA draw buffer, single-buffer
# mode (default DOUBLE_BUF_EN=0, visible immediately, no SWAP needed).
#
# Why no per-pixel loop: each buffer word covers 32 horizontal pixels,
# which is an exact multiple of the 8-pixel block size (32/8 = 4 blocks
# per word) -- so a word's checkerboard bit pattern only depends on which
# row-block it's in, never on which of the 5 words-per-row it is. That
# collapses the whole thing to "pick one of two masks per row, stamp it
# into all 5 words of that row" -- no per-pixel/per-bit work, and no
# multiply/divide (the core has no DIV/REM -- see docs/04_pipeline_plan.md
# -- and this avoids needing one).
#
# Mask derivation (bit i of a word = pixel x = word*32+i, i in 0..31):
#   block(i) = i >> 3   -> 0,0,0,0,0,0,0,0, 1,1,1,1,1,1,1,1, 2,..., 3,...
#   block_parity(i) = block(i) & 1  -> 0 for i in [0,8), 1 for [8,16),
#                                       0 for [16,24), 1 for [24,32)
#   bit_set = block_parity(i) XOR row_parity
# so MASK_ROW_EVEN (row_parity=0) sets exactly the block_parity=1 bits:
#   0xFF00FF00 (bits 8-15 and 24-31)
# and MASK_ROW_ODD is its complement: 0x00FF00FF
_start:
    li   x1, 0x20001000    # VGA draw buffer base (logical draw address)
    li   x2, 0              # row = 0 .. 119
    li   x9, 120            # row count (loop bound)
    li   x8, 5              # words per row (loop bound)
row_loop:
    srli x3, x2, 3          # row_block = row / 8
    andi x3, x3, 1          # row_parity = row_block & 1
    li   x4, 0xFF00FF00     # mask for row_parity == 0
    beqz x3, mask_ready
    li   x4, 0x00FF00FF     # mask for row_parity == 1
mask_ready:
    slli x5, x2, 2          # row*4
    add  x5, x5, x2         # row*5  (words per row)
    slli x5, x5, 2          # -> byte offset (*4 bytes/word)
    add  x6, x1, x5         # x6 = row base address
    li   x7, 0              # word_in_row = 0
word_loop:
    sw   x4, 0(x6)
    addi x6, x6, 4
    addi x7, x7, 1
    blt  x7, x8, word_loop
    addi x2, x2, 1
    blt  x2, x9, row_loop
loop:
    j    loop
