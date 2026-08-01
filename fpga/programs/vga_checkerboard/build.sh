#!/bin/bash
# fpga/programs/vga_checkerboard/build.sh
#
# Standalone hardware image of test/asm_programs/vga_checkerboard.asm --
# fills the VGA draw buffer with an 8x8-block checkerboard in single-buffer
# mode. Load vga_checkerboard.mif directly into the imem BRAM in Quartus
# (no bootloader), or `python3 tools/reg_debugger.py load
# vga_checkerboard.bin` to push it over the debug UART instead.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/../../.."
ASM="$ROOT/test/asm_programs/vga_checkerboard.asm"
BIN2MIF="$ROOT/src/bootloader/bin2mif.py"

. "$ROOT/test/env.sh"

riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 "$ASM" -o "$DIR/vga_checkerboard.o"
riscv64-unknown-elf-objcopy -O binary "$DIR/vga_checkerboard.o" "$DIR/vga_checkerboard.bin"
python3 "$BIN2MIF" "$DIR/vga_checkerboard.bin" "$DIR/vga_checkerboard.mif"

echo "Done — $DIR/vga_checkerboard.mif"
