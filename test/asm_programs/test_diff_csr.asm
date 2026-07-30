# tests/asm_programs/test_diff_csr.asm
# Zicsr coverage (CSRRW/S/C, CSRRWI/SI/CI) for the differential harness
# (tb_diff.sv) -- same instruction sequence as test_csr.asm, but ends in
# the standard self-loop that await_pc_convergence expects, rather than
# a register snapshot. Correctness is judged by comparing regfile + dmem
# + CSR state against the golden single-cycle model, not fixed expected
# values.

.section .text
.globl _start
_start:
    csrrwi x0, mscratch, 5      # mscratch = 5 (rd=x0, discarded)
    addi   x1, x0, 0x123
    csrrw  x5, mscratch, x1     # x5 = old mscratch (5), mscratch = 0x123

    csrrwi x6, mscratch, 7      # x6 = old mscratch (0x123), mscratch = 7

    addi   x2, x0, 0xF0
    csrrw  x0, mtvec, x2        # mtvec = 0xF0
    addi   x3, x0, 0x0F
    csrrs  x7, mtvec, x3        # x7 = old mtvec (0xF0), mtvec = 0xFF

    csrrsi x8, mtvec, 0x10      # x8 = old mtvec (0xFF), mtvec = 0xFF

    addi   x4, x0, -1
    csrrw  x0, mepc, x4         # mepc = 0xFFFFFFFF
    addi   x11, x0, 0xFF
    csrrc  x9, mepc, x11        # x9 = old mepc (0xFFFFFFFF), mepc = 0xFFFFFF00

    addi   x12, x0, -1
    csrrw  x0, mie, x12         # mie = 0xFFFFFFFF
    csrrci x10, mie, 0x1F       # x10 = old mie (0xFFFFFFFF), mie = 0xFFFFFFE0

loop:
    jal x0, loop
