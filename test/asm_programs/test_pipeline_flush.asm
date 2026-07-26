.section .text
.globl _start

# Milestone-3 test program: isolates flush-on-taken-jump/branch from
# RAW-hazard behavior (which milestone 4 covers separately). Every
# instruction writes a distinct register and reads only x0/immediates --
# same no-dependency discipline as test_pipeline_straight.asm. Operand
# setup for each branch/jalr is followed by 3 filler instructions before
# it's read, clearing the 5-stage no-forwarding RAW hazard window so it
# can't corrupt the branch decision and confound this test's actual
# target: flush behavior on jal, jalr, and both branch directions. Every
# post-jump/branch instruction that should be squashed writes a
# recognizable sentinel (99) to a register no other instruction touches.
_start:
    addi x1, x0, 1
    addi x2, x0, 2

    jal  x3, fwd            # x3 = PC+4 (link), jumps over x4's addi
    addi x4, x0, 99          # skipped -- must NOT execute if flush works
fwd:
    addi x5, x0, 5

jalr_base:
    auipc x6, 0               # x6 = address of this instruction
    addi  x21, x0, 21          # filler (breaks x6 RAW hazard window)
    addi  x22, x0, 22          # filler
    addi  x25, x0, 25          # filler
    jalr  x7, x6, 28          # x7 = PC+4 (link), jump to x6+28 (= jalr_target)
    addi  x8, x0, 99          # skipped -- must NOT execute if flush works
    addi  x9, x0, 99          # skipped -- must NOT execute if flush works
jalr_target:
    addi x10, x0, 10

    addi x11, x0, 0
    addi x17, x0, 17          # filler (breaks x11 RAW hazard window)
    addi x18, x0, 18          # filler
    addi x23, x0, 23          # filler
    beq  x11, x0, taken       # always taken
    addi x12, x0, 99          # skipped -- must NOT execute if flush works
taken:
    addi x13, x0, 13

    addi x14, x0, 1
    addi x19, x0, 19          # filler (breaks x14 RAW hazard window)
    addi x20, x0, 20          # filler
    addi x24, x0, 24          # filler
    bne  x14, x0, nottaken    # always taken (1 != 0)
    addi x15, x0, 99          # skipped -- must NOT execute if flush works
nottaken:
    addi x16, x0, 16

loop:
    j loop
