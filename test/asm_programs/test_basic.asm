# tests/asm_programs/add_test.asm
# Expected results:
# x1 = 5
# x2 = 10
# x3 = 15  (x1 + x2)
# x4 = 7   (x1 + 2)

.section .text
.globl _start
_start:
    addi x1, x0, 5       # x1 = 5
    addi x2, x0, 10      # x2 = 10
    add  x3, x1, x2      # x3 = 15
    addi x4, x1, 2       # x4 = 7

loop:
    j loop                # spin forever
