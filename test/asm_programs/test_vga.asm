.section .text
.globl _start
# Draws a vertical-stripe pattern (0xAAAAAAAA per word) into every row of
# the VGA draw buffer, single-buffer mode (default DOUBLE_BUF_EN=0) so it's
# visible on the real display immediately with no SWAP needed.
_start:
    li   x1, 0x20001000    # VGA draw buffer base (logical draw address)
    li   x2, 0xAAAAAAAA    # alternating-bit pattern -> vertical stripes
    li   x3, 600           # BUF_WORDS
    li   x4, 0             # word index
fill_loop:
    sw   x2, 0(x1)
    addi x1, x1, 4
    addi x4, x4, 1
    blt  x4, x3, fill_loop
loop:
    j    loop
