#!/bin/bash
# fpga/programs/test_vga/build.sh
#
# Standalone hardware image of test/asm_programs/test_vga.asm -- fills the
# VGA draw buffer with a vertical-stripe pattern in single-buffer mode, for
# a quick visual smoke test of vga_framebuffer.sv on real hardware. Load
# test_vga.mif directly into the imem BRAM in Quartus, no bootloader.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/../../.."
ASM="$ROOT/test/asm_programs/test_vga.asm"
BIN2MIF="$ROOT/src/bootloader/bin2mif.py"

. "$ROOT/test/env.sh"

riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 "$ASM" -o "$DIR/test_vga.o"
riscv64-unknown-elf-objcopy -O binary "$DIR/test_vga.o" "$DIR/test_vga.bin"
python3 "$BIN2MIF" "$DIR/test_vga.bin" "$DIR/test_vga.mif"

echo "Done — $DIR/test_vga.mif"
