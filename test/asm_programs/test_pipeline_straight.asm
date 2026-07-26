.section .text
.globl _start

# Milestone-2 test program: pipeline registers only, no hazard handling yet.
# Every instruction writes a distinct destination register and reads only
# x0 or immediates -- no instruction depends on a value produced by any
# preceding instruction still in flight, so a naive straight-through
# pipeline (no stall/forwarding) must still get this right.
_start:
    addi x1,  x0, 1
    addi x2,  x0, 2
    addi x3,  x0, 3
    addi x4,  x0, 4
    addi x5,  x0, 5
    addi x6,  x0, 6
    addi x7,  x0, 7
    addi x8,  x0, 8
    addi x9,  x0, 9
    addi x10, x0, 10
    addi x11, x0, -1
    addi x12, x0, -2
    lui  x13, 0x1
    lui  x14, 0x2
    ori  x15, x0, 0xf
    andi x16, x0, 0x0
    xori x17, x0, -1
    slli x18, x0, 3
    srli x19, x0, 3
    srai x20, x0, 3
loop:
    j loop
