# tests/asm_programs/test_mul.asm
# Exercises all 4 RV32M multiply instructions (MUL, MULH, MULHSU, MULHU)
# on the single-cycle core, including a negative*negative case and cases
# that overflow into the upper 32-bit word.
# Pass condition: x5-x9 == 1 (checked via xor+sltiu, see test_csr.asm for
# the idiom this mirrors), x30 == 1.

.section .text
.globl _start
_start:
    # Check x5: MUL, positive * positive, no overflow. 6 * 7 = 42
    addi x1, x0, 6
    addi x2, x0, 7
    mul  x5, x1, x2
    xori x5, x5, 42
    sltiu x5, x5, 1

    # Check x6: MUL, negative * negative = positive. -3 * -4 = 12
    addi x1, x0, -3
    addi x2, x0, -4
    mul  x6, x1, x2
    xori x6, x6, 12
    sltiu x6, x6, 1

    # Check x7: MULH, signed * signed, overflows into upper word.
    # 0x80000000 * 0x80000000 (both -2147483648 signed) = 2^62,
    # upper 32 bits = 0x40000000.
    lui  x1, 0x80000
    lui  x2, 0x80000
    mulh x7, x1, x2
    lui  x3, 0x40000
    xor  x7, x7, x3
    sltiu x7, x7, 1

    # Check x8: MULHSU, signed rs1 * unsigned rs2.
    # rs1 = -1 (signed), rs2 = 0xFFFFFFFF (unsigned) -> product = -4294967295,
    # upper 32 bits (two's complement 64-bit) = 0xFFFFFFFF.
    addi x1, x0, -1
    addi x2, x0, -1
    mulhsu x8, x1, x2
    addi x4, x0, -1
    xor  x8, x8, x4
    sltiu x8, x8, 1

    # Check x9: MULHU, unsigned * unsigned, overflows into upper word.
    # 0xFFFFFFFF * 0xFFFFFFFF -> upper 32 bits = 0xFFFFFFFE.
    addi x1, x0, -1
    addi x2, x0, -1
    mulhu x9, x1, x2
    addi x11, x0, -2
    xor  x9, x9, x11
    sltiu x9, x9, 1

    # Success
    addi x30, x0, 1

loop:
    jal x0, loop
