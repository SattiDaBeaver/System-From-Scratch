# fpga/programs/test_full/

Standalone hardware image of `test/asm_programs/test_full.asm` -- the same
RV32I instruction-coverage program exercised by the `test_full` cocotb suite
(`test/testbench/test_full.py`, 27/27 checks passing in simulation).

Load `test_full.mif` directly into the `imem` BRAM in Quartus to run it on
the FPGA with no bootloader involved -- useful as known-good starting
firmware while the bootloader (software + planned hardware/debug version)
is still being worked on.

## What the program does

Exercises every RV32I instruction the core implements: ANDI, ORI, ADDI,
SLLI, SRLI, AND, OR, XOR, ADD, SUB, SLL, SRL, SLTU, SLTIU, LUI, SRAI, SLT,
SLTI, SRA, AUIPC, JAL, JALR, SW/LW. Each instruction's result is XORed
against its expected value so a correct result leaves a register at 1.

Register map after it runs (see `check_*` in `test_full.py` for the exact
expected values):
- x5-x27: one register per instruction under test, each should equal 1
  (correct) or a nonzero XOR remainder (wrong result to investigate)
- x28, x29: padding, always 1
- x30: overall success flag, set to 1 only if execution reached the end
- Ends in an infinite `jal x0, loop` -- watch the register file/LEDs (or
  attach the debug UART) to see it settled at x30=1 rather than reset.

## Rebuilding

```
./build.sh
```

Uses the RISC-V assembler/binutils and python3 already available via
`test/env.sh` (pre-existing toolchain + project venv -- no system installs).
Produces `test_full.o`, `test_full.bin`, and `test_full.mif`.
