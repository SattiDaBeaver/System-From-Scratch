# tests/asm_programs/test_diff_mul.asm
# RV32M differential test: exercises all 4 multiply variants (MUL, MULH,
# MULHSU, MULHU), diffed against the golden single-cycle model via
# diff_test_mul (regfile + dmem), rather than checked against hand-derived
# expected values directly.

.section .text
.globl _start
_start:
    # MUL, positive * positive
    addi x1, x0, 6
    addi x2, x0, 7
    mul  x5, x1, x2

    # MUL, negative * negative
    addi x1, x0, -3
    addi x2, x0, -4
    mul  x6, x1, x2

    # MULH, signed * signed, overflows into upper word
    lui  x1, 0x80000
    lui  x2, 0x80000
    mulh x7, x1, x2

    # MULHSU, signed rs1 * unsigned rs2
    addi x1, x0, -1
    addi x2, x0, -1
    mulhsu x8, x1, x2

    # MULHU, unsigned * unsigned, overflows into upper word
    addi x1, x0, -1
    addi x2, x0, -1
    mulhu x9, x1, x2

    # Store a couple of results to dmem too, to exercise the dmem diff window
    sw x5, 0(x0)
    sw x7, 4(x0)

loop:
    jal x0, loop
