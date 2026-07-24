#!/bin/bash
# fpga/programs/test_full/build.sh
#
# Regenerates test_full.mif from test/asm_programs/test_full.asm -- the
# same program the test/testbench/test_full.py cocotb suite runs (27/27
# checks). Load the .mif directly into the imem BRAM in Quartus to run
# it standalone on hardware, with no bootloader involved.
#
# Uses the RISC-V toolchain and python3 already set up in test/env.sh
# (venv python3 + pre-existing SiFive binutils) -- no system installs.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/../../.."
ASM="$ROOT/test/asm_programs/test_full.asm"
BIN2MIF="$ROOT/src/bootloader/bin2mif.py"

# shellcheck disable=SC1091
. "$ROOT/test/env.sh"

riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 "$ASM" -o "$DIR/test_full.o"
riscv64-unknown-elf-objcopy -O binary "$DIR/test_full.o" "$DIR/test_full.bin"
python3 "$BIN2MIF" "$DIR/test_full.bin" "$DIR/test_full.mif"

echo "Done — $DIR/test_full.mif"
