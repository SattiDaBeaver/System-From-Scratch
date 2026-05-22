# tests/utils.py

import subprocess
import struct
import os
from cocotb.triggers import RisingEdge


# *****************************
#  Clock
# *****************************

async def generate_clock(dut, half_period_ns=5):
    """10ns clock by default (100MHz)"""
    from cocotb.triggers import Timer
    while True:
        dut.clk.value = 0
        await Timer(half_period_ns, units="ns")
        dut.clk.value = 1
        await Timer(half_period_ns, units="ns")


# *****************************
#  Reset
# *****************************

async def reset(dut, cycles=5):
    dut.rst.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0


# *****************************
#  Run
# *****************************

async def run_cycles(dut, n):
    for _ in range(n):
        await RisingEdge(dut.clk)


# *****************************
#  Memory
# *****************************

def load_imem(dut, words):
    """Load a list of 32-bit integers into instruction memory"""
    for i, word in enumerate(words):
        dut.imem[i].value = word


def load_dmem(dut, words, start=0):
    """Load a list of 32-bit integers into data memory from start index"""
    for i, word in enumerate(words):
        dut.dmem[start + i].value = word


def read_reg(dut, reg):
    """Read a register from the internal regfile"""
    return dut.u_core.regfile[reg].value.integer


# *****************************
#  Assembler
# *****************************

ASM_DIR = os.path.join(os.path.dirname(__file__), "asm_programs")

def assemble(filename):
    """
    Assemble a .asm file and return a list of 32-bit instruction words.
    filename: just the name, e.g. "add_test.asm"
    """
    src  = os.path.join(ASM_DIR, filename)
    obj  = "/tmp/rv_test.o"
    binary = "/tmp/rv_test.bin"

    # Assemble
    subprocess.run([
        "riscv64-unknown-elf-as",
        "-march=rv32i", "-mabi=ilp32",
        src, "-o", obj
    ], check=True)

    # Strip to raw binary
    subprocess.run([
        "riscv64-unknown-elf-objcopy",
        "-O", "binary", obj, binary
    ], check=True)

    # Read and pack into 32-bit words
    with open(binary, "rb") as f:
        raw = f.read()

    # Pad to word boundary
    while len(raw) % 4 != 0:
        raw += b'\x00'

    words = list(struct.unpack(f"<{len(raw)//4}I", raw))
    return words