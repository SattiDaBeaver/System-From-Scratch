#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

riscv64-unknown-elf-as -march=rv32i -mabi=ilp32 $DIR/bootloader.asm -o $DIR/bootloader.o
riscv64-unknown-elf-ld -m elf32lriscv -T $DIR/bootloader.ld -o $DIR/bootloader.elf $DIR/bootloader.o
riscv64-unknown-elf-objcopy -O binary $DIR/bootloader.elf $DIR/bootloader.bin
riscv64-unknown-elf-objcopy -O ihex   $DIR/bootloader.elf $DIR/bootloader.hex
python3 $DIR/bin2mif.py $DIR/bootloader.bin $DIR/bootloader.mif
cp $DIR/bootloader.mif /mnt/c/Github/System-From-Scratch/fpga/bootloader.mif

echo "Done — bootloader.mif ready for Quartus"