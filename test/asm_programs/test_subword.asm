# tests/asm_programs/test_subword.asm
# Exercises byte/halfword loads and stores (LB/LH/LBU/LHU/SB/SH) on the
# single-cycle core's new byte-enable-masked memory interface.
# Pass condition: x5-x10 == 1 (checked via diff+sltiu, see below), x30 == 1.
#
# Each check computes `diff = actual XOR expected` then `sltiu rd, diff, 1`
# -- diff is 0 iff actual == expected, and sltiu of 0 against 1 (unsigned)
# is 1, so rd == 1 iff the check passed. This avoids test_full.asm's
# XOR-immediate-picked-to-equal-1 idiom, which only works when the
# expected value is known in advance and small; here some expected values
# (0xFFFF) don't fit a 12-bit immediate, so register-form xor is used.

.section .text
.globl _start
_start:
    addi x1, x0, 0x100      # base address (word-aligned)

    # Check x5: SB (positive byte, 0x7F) + LB reads it back unchanged
    addi x3, x0, 0x7F
    sb   x3, 0(x1)
    lb   x5, 0(x1)
    xori x5, x5, 0x7F
    sltiu x5, x5, 1

    # Check x6: SB (byte pattern 0xFF) + LB sign-extends to -1
    addi x3, x0, -1
    sb   x3, 1(x1)
    lb   x6, 1(x1)
    xori x6, x6, -1
    sltiu x6, x6, 1

    # Check x7: LBU zero-extends the same byte written above (0xFF -> 255)
    lbu  x7, 1(x1)
    xori x7, x7, 0xFF
    sltiu x7, x7, 1

    # Check x8: SH (halfword pattern 0xFFFF) + LH sign-extends to -1
    addi x3, x0, -1
    sh   x3, 2(x1)
    lh   x8, 2(x1)
    xori x8, x8, -1
    sltiu x8, x8, 1

    # Check x9: LHU zero-extends the same halfword written above
    lhu  x9, 2(x1)
    addi x4, x0, -1
    srli x4, x4, 16         # x4 = 0x0000FFFF
    xor  x9, x9, x4
    sltiu x9, x9, 1

    # Check x10: byte isolation -- confirms SB/SH only wrote their own
    # bytes via dmem_byteena, not the whole word. Word at x1 should now
    # read back as 0xFFFFFF7F: byte0=0x7F (check x5's SB),
    # byte1=0xFF (check x6's SB), bytes2/3=0xFF/0xFF (check x8's SH).
    lw   x10, 0(x1)
    xori x10, x10, -129     # 0xFFFFFF7F as a signed 32-bit value == -129
    sltiu x10, x10, 1

    # Success
    addi x30, x0, 1

loop:
    jal x0, loop
