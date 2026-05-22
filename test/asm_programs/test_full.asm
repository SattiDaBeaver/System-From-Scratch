# tests/asm_programs/test_full.asm
# Tests every RV32I instruction
# Pass condition: x5-x29 == 0, x30 == 1 (checked via XOR pattern)
# Final pass: x30 = 1

.section .text
.globl _start
_start:
    # Operand setup
    addi x1, x0, 21        # x1 = 21  (10101 in binary)
    addi x2, x0, 7         # x2 = 7   (111 in binary)
    addi x3, x0, -4        # x3 = -4  (111111111100 in binary)

    # ANDI
    andi x5, x1, 0b1011100
    xori x5, x5, 0b10101

    andi  x5,  x1, 0b1011100
    xori  x5,  x5, 0b10101

    # ORI
    ori   x6,  x1, 0b1011100
    xori  x6,  x6, 0b1011100

    # ADDI
    addi  x7,  x1, 7
    xori  x7,  x7, 0b11101

    # SLLI
    slli  x8,  x1, 6
    xori  x8,  x8, 0b10101000001

    # SRLI
    srli  x9,  x1, 2
    xori  x9,  x9, 0b100

    # AND
    and   x10, x1, x2
    xori  x10, x10, 0b100

    # OR
    or    x11, x1, x2
    xori  x11, x11, 0b10110

    # XOR
    xor   x12, x1, x2
    xori  x12, x12, 0b10011

    # ADD
    add   x13, x1, x2
    xori  x13, x13, 0b11101

    # SUB
    sub   x14, x1, x2
    xori  x14, x14, 0b1111

    # SLL
    sll   x15, x2, x2
    xori  x15, x15, 0b1110000001

    # SRL
    srl   x16, x1, x2
    xori  x16, x16, 1

    # SLTU
    sltu  x17, x2, x1
    xori  x17, x17, 0

    # SLTIU
    sltiu x18, x2, 21
    xori  x18, x18, 0

    # LUI
    lui   x19, 0
    xori  x19, x19, 1

    # SRAI
    srai  x20, x3, 1
    xori  x20, x20, -1

    # SLT
    slt   x21, x3, x1
    xori  x21, x21, 0

    # SLTI
    slti  x22, x3, 1
    xori  x22, x22, 0

    # SRA
    sra   x23, x1, x2
    xori  x23, x23, 1

    # AUIPC
    auipc x4,  4
    srli  x24, x4, 7
    xori  x24, x24, 0b10000000

    # JAL
    jal   x25, 1f          # x25 = PC+4
1:  auipc x4,  0           # x4  = PC
    xor   x25, x25, x4
    xori  x25, x25, 1

    # JALR
    jalr  x26, x4, 16
    sub   x26, x26, x4
    addi  x26, x26, -15

    # SW + LW
    sw    x1,  1(x2)       # mem[x2+1] = x1
    lw    x27, 1(x2)       # x27 = mem[x2+1]
    xori  x27, x27, 0b10100

    # Pad remaining
    addi  x28, x0, 1
    addi  x29, x0, 1

    # Success
    addi  x30, x0, 1

loop:
    jal   x0, loop