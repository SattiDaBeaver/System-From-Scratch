# tests/asm_programs/test_diff_trap.asm
# ECALL/EBREAK/MRET coverage for the differential harness (tb_diff.sv) --
# same shape as test_trap.asm's mtvec_setup/ecall/ebreak/trap_handler
# round trip, but ends in the standard self-loop rather than a register
# snapshot. Correctness is judged by comparing regfile + CSR state
# (mepc/mcause included) against the golden single-cycle model, not
# fixed expected values -- this is what actually exercises the pipelined
# core's EX-stage flush/redirect timing (2-stage squash reach) against a
# reference that has none of that latency.
#
# mtvec_setup's offset to trap_handler is a hand-verified literal (see
# test_trap.asm's identical comment) -- this test flow only assembles
# (no linker pass), so far-symbol relocations (`la`) and label-difference
# immediates aren't usable here.

.section .text
.globl _start
_start:
    jal   x1, mtvec_setup
    jal   x0, main

mtvec_setup:
    auipc x2, 0
    addi  x2, x2, 0x38           # mtvec_setup + 0x38 = trap_handler (verified below)
    csrrw x0, mtvec, x2
    jalr  x0, x1, 0

main:
    addi  x3, x0, 0              # marker: set to 1 only if ecall resumes correctly
ecall_point:
    ecall
    addi  x3, x0, 1

    csrrs x4, mcause, x0         # x4 = mcause after ecall (expect 11)

    addi  x5, x0, 0              # marker: set to 1 only if ebreak resumes correctly
ebreak_point:
    ebreak
    addi  x5, x0, 1

    csrrs x6, mcause, x0         # x6 = mcause after ebreak (expect 3)

    addi x7, x0, 1               # success marker

loop:
    jal x0, loop

trap_handler:
    csrrs x14, mepc, x0
    addi  x15, x14, 4
    csrrw x0, mepc, x15
    mret
