.section .text
.globl _start

# Milestone-5 test program: dedicated load-use hazard verification.
# docs/04_pipeline_plan.md Sec.3/Sec.7 milestone 5 claims the generic
# RAW-stall mechanism added in milestone 4 already covers load-use with
# no special case (a load's result isn't available until mem_wb, same as
# any ALU result) -- this program exists to confirm that claim rather
# than assume it, with load-use as the star of the show instead of one
# case buried in a bigger mix (test_pipeline_stall.asm already covers one
# load-use instance incidentally). Covers: immediate lw-then-use (rd as
# rs1), lw-then-use as rs2, lw feeding both rs1 and rs2 of the same
# instruction, and back-to-back loads where the second load's own address
# depends on the first load's result.
_start:
    addi x1, x0, 4          # dmem word address 4
    addi x2, x0, 77
    sw   x2, 0(x1)
    lw   x3, 0(x1)           # load
    add  x4, x3, x0          # immediate use as rs1 -- must stall

    addi x5, x0, 8           # dmem word address 8
    addi x6, x0, 55
    sw   x6, 0(x5)
    lw   x7, 0(x5)           # load
    sub  x8, x0, x7          # immediate use as rs2 -- must stall

    addi x9, x0, 12          # dmem word address 12
    addi x10, x0, 9
    sw   x10, 0(x9)
    lw   x11, 0(x9)           # load
    add  x12, x11, x11        # loaded value used as both rs1 and rs2 -- must stall

    addi x13, x0, 0          # dmem word address 0 -- holds a word we'll set up as a pointer
    addi x14, x0, 16          # target address for the pointer to point at
    sw   x14, 0(x13)          # dmem[0] = 16
    addi x15, x0, 33
    sw   x15, 16(x0)          # dmem[16/4=4]... use word offset directly below instead
    lw   x16, 0(x13)          # x16 = dmem[word 0] = 16 (a byte address)
    lw   x17, 0(x16)          # second load's address (x16) depends on first load's result -- must stall

loop:
    j loop
