# tests/asm_programs/test_timer_irq.asm
# Exercises the new timer peripheral (src/peripherals/timer.sv) and the
# pipelined core's timer-interrupt-taking support end to end: mtvec setup,
# timer RELOAD/CTRL programming, mie.MTIE/mstatus.MIE enable, a tight
# self-loop waiting to be interrupted, and a handler that checks mcause,
# disables the timer (so it fires exactly once), and mret's back.
#
# Only meaningful against TOPLEVEL=tb_top CORE_TYPE=PIPELINED -- the timer
# peripheral only exists in the SoC-level address decoder (not tb_core's
# bare-core wrapper), and only riscv_core.sv (pipelined) has the timer_irq
# port / irq_taken logic wired up at all.
#
# Unlike test_trap.asm's handler, this one does NOT advance mepc past the
# interrupted instruction -- an interrupt doesn't "complete" the instruction
# it lands on, so mret simply retries the spin loop's own self-jump. The
# handler instead disables the timer (CTRL.EN=0) so it can't fire again,
# letting pc settle permanently back into the spin self-loop afterward.
#
# Pass condition: x8 == 1 (mcause decoded to the machine-timer-interrupt
# encoding, 0x80000007), x30 == 1 (handler ran all the way to mret).

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
    addi  x2, x2, 0x38           # mtvec_setup + 0x38 = trap_handler (verified below)
    csrrw x0, mtvec, x2
    jalr  x0, x1, 0

main:
    addi  x4, x0, 20             # timer RELOAD value (cycles)
    lui   x3, 0x30000            # x3 = 0x30000000, timer peripheral base
    sw    x4, 0(x3)              # RELOAD = 20
    addi  x5, x0, 1
    sw    x5, 4(x3)              # CTRL.EN = 1

    addi  x6, x0, 0x80
    csrrs x0, mie, x6             # set MTIE (bit 7)

    addi  x7, x0, 0x8
    csrrs x0, mstatus, x7         # set MIE (bit 3)

spin:
    jal   x0, spin

trap_handler:
    csrrs x8, mcause, x0
    lui   x9, 0x80000
    addi  x9, x9, 7
    xor   x8, x8, x9
    sltiu x8, x8, 1              # x8 = 1 iff mcause == 0x80000007

    sw    x5, 8(x3)              # STATUS: write-1-to-clear the pending bit
    sw    x0, 4(x3)              # CTRL.EN = 0 -- disable timer, fire only once

    addi  x30, x0, 1             # success marker

    mret
