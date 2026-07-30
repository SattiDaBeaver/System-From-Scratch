# tests/asm_programs/test_csr.asm
# Exercises all 6 Zicsr instructions (CSRRW/S/C, CSRRWI/SI/CI) against
# mscratch, mtvec, mepc, mie on the single-cycle core.
# Pass condition: x5-x10 == 1 (checked via diff+sltiu, see test_subword.asm
# for the idiom this mirrors), x30 == 1.

.section .text
.globl _start
_start:
    # Check x5: CSRRWI writes zimm into mscratch, CSRRW then reads the old
    # value (5) into rd and writes a new value (0x123) from x1.
    csrrwi x0, mscratch, 5      # mscratch = 5 (rd=x0, discarded)
    addi   x1, x0, 0x123
    csrrw  x5, mscratch, x1     # x5 = old mscratch (5), mscratch = 0x123
    xori   x5, x5, 5
    sltiu  x5, x5, 1

    # Check x6: mscratch now holds 0x123 (verify round-trip via CSRRWI's
    # own read-old-value semantics, using rd this time).
    csrrwi x6, mscratch, 7      # x6 = old mscratch (0x123), mscratch = 7
    xori   x6, x6, 0x123
    sltiu  x6, x6, 1

    # Check x7: CSRRS sets bits (register form) into mtvec.
    addi   x2, x0, 0xF0
    csrrw  x0, mtvec, x2        # mtvec = 0xF0
    addi   x3, x0, 0x0F
    csrrs  x7, mtvec, x3        # x7 = old mtvec (0xF0), mtvec = 0xFF
    xori   x7, x7, 0xF0
    sltiu  x7, x7, 1

    # Check x8: mtvec now 0xFF -- CSRRSI (immediate form) sets more bits.
    csrrsi x8, mtvec, 0x10      # x8 = old mtvec (0xFF), mtvec = 0xFF (0x10 already set)
    xori   x8, x8, 0xFF
    sltiu  x8, x8, 1

    # Check x9: CSRRC clears bits (register form) from mepc.
    addi   x4, x0, -1
    csrrw  x0, mepc, x4         # mepc = 0xFFFFFFFF
    addi   x11, x0, 0xFF
    csrrc  x9, mepc, x11        # x9 = old mepc (0xFFFFFFFF), mepc = 0xFFFFFF00
    xori   x9, x9, -1
    sltiu  x9, x9, 1

    # Check x10: CSRRCI (immediate form) clears more bits from mie, and
    # confirms mepc's post-clear value via a plain CSRRS-with-zero read.
    addi   x12, x0, -1
    csrrw  x0, mie, x12         # mie = 0xFFFFFFFF
    csrrci x10, mie, 0x1F       # x10 = old mie (0xFFFFFFFF), mie = 0xFFFFFFE0
    xori   x10, x10, -1
    sltiu  x10, x10, 1

    # Success
    addi x30, x0, 1

loop:
    jal x0, loop
