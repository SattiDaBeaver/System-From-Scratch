.section .text
.globl _start

# Milestone-4 test program: RAW-hazard stall detection (stall-only v1, no
# forwarding). Every case below has an instruction immediately (0-gap)
# followed by another instruction reading the register it just wrote --
# the exact case that must stall in ID until the write commits, per
# docs/04_pipeline_plan.md Sec.3. Covers dependency distance 0 (very next
# instruction), a chain of several back-to-back dependent instructions
# (rs1 AND rs2 both hazards), a branch depending on the immediately
# preceding compare operands, and a load-use hazard (sw immediately
# followed by lw of the same address, then an add reading the loaded
# value right away) -- milestone 5 has its own dedicated load-use test,
# but exercising it here too costs nothing and catches an obvious break
# early.
_start:
    addi x1, x0, 5
    addi x2, x1, 10        # RAW on x1, distance 0 -- must stall

    add  x3, x1, x2        # RAW on x1 (distance 2, already resolved) and x2 (distance 0)
    add  x4, x3, x3        # RAW on x3, distance 0, used twice (rs1==rs2)

    addi x5, x0, 1
    addi x6, x0, 1
    beq  x5, x6, taken      # RAW on x5 and x6, both distance 0 -- must stall before branch resolves
    addi x7, x0, 99          # skipped -- must NOT execute if branch is correct
taken:
    addi x8, x0, 8

    addi x9,  x0, 4          # dmem word address
    addi x10, x0, 42         # value to store
    sw   x10, 0(x9)          # RAW on x9 and x10, both distance 0
    lw   x11, 0(x9)          # RAW on x9 (distance 1) -- load-use setup
    add  x12, x11, x11       # RAW on x11 (the loaded value), distance 0 -- load-use hazard

loop:
    j loop
