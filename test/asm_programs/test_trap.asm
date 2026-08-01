# tests/asm_programs/test_trap.asm
# Exercises ECALL/EBREAK trap entry and MRET trap exit on the single-cycle
# core. mtvec points at a shared handler that advances mepc past the
# faulting instruction, then mret's back. Correctness is checked via
# mcause (trap-entry decode) and via each marker register only becoming 1
# if control correctly resumed just past the ecall/ebreak (trap-exit/MRET
# + mepc handling). Verifying mepc's exact captured address isn't done
# here -- this test flow only assembles (no linker pass), so label
# arithmetic (`la`, `sym1 - sym2`) can't be resolved; resumption behavior
# already exercises mepc end-to-end.
# Pass condition: x2,x8,x9,x13 == 1 (checked via diff+sltiu, see
# test_csr.asm for the idiom this mirrors), x30 == 1.

.section .text
.globl _start
_start:
    jal   x1, mtvec_setup
    jal   x0, main

mtvec_setup:
    # trap_handler's address, computed as a literal pc-relative offset
    # (assembler resolves jal targets locally, no linker needed) rather
    # than via `la` (needs linker relocation, unavailable in this flow).
    auipc x2, 0
    addi  x2, x2, 0x48           # mtvec_setup + 0x48 = trap_handler (verified below)
    csrrw x0, mtvec, x2
    jalr  x0, x1, 0

main:
    addi  x2, x0, 0              # marker: set to 1 only if ecall resumes correctly
ecall_point:
    ecall
    addi  x2, x0, 1

    csrrs x8, mcause, x0
    xori  x8, x8, 11
    sltiu x8, x8, 1              # x8 = 1 iff mcause == 11 (ECALL from M-mode)

    addi  x9, x0, 0              # marker: set to 1 only if ebreak resumes correctly
ebreak_point:
    ebreak
    addi  x9, x0, 1

    csrrs x13, mcause, x0
    xori  x13, x13, 3
    sltiu x13, x13, 1            # x13 = 1 iff mcause == 3 (breakpoint)

    # Success
    addi x30, x0, 1

loop:
    jal x0, loop

trap_handler:
    csrrs x14, mepc, x0
    addi  x15, x14, 4
    csrrw x0, mepc, x15
    mret
