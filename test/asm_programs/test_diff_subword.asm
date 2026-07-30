# tests/asm_programs/test_diff_subword.asm
# Sub-word access (LB/LH/LBU/LHU/SB/SH) coverage for the differential
# harness (tb_diff.sv) -- same instruction sequence as test_subword.asm,
# but ends in the standard self-loop that await_pc_convergence expects,
# rather than a register snapshot. Correctness is judged by comparing
# regfile + dmem against the golden single-cycle model, not fixed
# expected values.

.section .text
.globl _start
_start:
    addi x1, x0, 0x100      # base address (word-aligned)

    addi x3, x0, 0x7F
    sb   x3, 0(x1)
    lb   x5, 0(x1)

    addi x3, x0, -1
    sb   x3, 1(x1)
    lb   x6, 1(x1)

    lbu  x7, 1(x1)

    addi x3, x0, -1
    sh   x3, 2(x1)
    lh   x8, 2(x1)

    lhu  x9, 2(x1)

    lw   x10, 0(x1)

loop:
    jal x0, loop
