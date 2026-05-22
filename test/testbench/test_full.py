# tests/testbench/test_full.py

import cocotb
from cocotb.clock import Clock
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import reset, run_cycles, load_imem, read_reg, assemble

# Store DUT state after running so individual tests can check it
_reg_values = {}

@cocotb.test()
async def run_program(dut):
    """Load and run the full RV32I test program"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    words = assemble("test_full.asm")
    load_imem(dut, words)

    await reset(dut)
    await run_cycles(dut, 100)

    # Snapshot all registers
    for reg in range(5, 31):
        _reg_values[reg] = read_reg(dut, reg)

    # Print registers x0-x4
    for reg in range(0, 5):
        print(f"x{reg}: {read_reg(dut, reg)}")

    cocotb.log.info("Program run complete, register snapshot taken")


@cocotb.test()
async def check_andi(dut):
    assert _reg_values.get(5) == 1, f"ANDI: x5 = {_reg_values.get(5)}"

@cocotb.test()
async def check_ori(dut):
    assert _reg_values.get(6) == 1, f"ORI: x6 = {_reg_values.get(6)}"

@cocotb.test()
async def check_addi(dut):
    assert _reg_values.get(7) == 1, f"ADDI: x7 = {_reg_values.get(7)}"

@cocotb.test()
async def check_slli(dut):
    assert _reg_values.get(8) == 1, f"SLLI: x8 = {_reg_values.get(8)}"

@cocotb.test()
async def check_srli(dut):
    assert _reg_values.get(9) == 1, f"SRLI: x9 = {_reg_values.get(9)}"

@cocotb.test()
async def check_and(dut):
    assert _reg_values.get(10) == 1, f"AND: x10 = {_reg_values.get(10)}"

@cocotb.test()
async def check_or(dut):
    assert _reg_values.get(11) == 1, f"OR: x11 = {_reg_values.get(11)}"

@cocotb.test()
async def check_xor(dut):
    assert _reg_values.get(12) == 1, f"XOR: x12 = {_reg_values.get(12)}"

@cocotb.test()
async def check_add(dut):
    assert _reg_values.get(13) == 1, f"ADD: x13 = {_reg_values.get(13)}"

@cocotb.test()
async def check_sub(dut):
    assert _reg_values.get(14) == 1, f"SUB: x14 = {_reg_values.get(14)}"

@cocotb.test()
async def check_sll(dut):
    assert _reg_values.get(15) == 1, f"SLL: x15 = {_reg_values.get(15)}"

@cocotb.test()
async def check_srl(dut):
    assert _reg_values.get(16) == 1, f"SRL: x16 = {_reg_values.get(16)}"

@cocotb.test()
async def check_sltu(dut):
    assert _reg_values.get(17) == 1, f"SLTU: x17 = {_reg_values.get(17)}"

@cocotb.test()
async def check_sltiu(dut):
    assert _reg_values.get(18) == 1, f"SLTIU: x18 = {_reg_values.get(18)}"

@cocotb.test()
async def check_lui(dut):
    assert _reg_values.get(19) == 1, f"LUI: x19 = {_reg_values.get(19)}"

@cocotb.test()
async def check_srai(dut):
    assert _reg_values.get(20) == 1, f"SRAI: x20 = {_reg_values.get(20)}"

@cocotb.test()
async def check_slt(dut):
    assert _reg_values.get(21) == 1, f"SLT: x21 = {_reg_values.get(21)}"

@cocotb.test()
async def check_slti(dut):
    assert _reg_values.get(22) == 1, f"SLTI: x22 = {_reg_values.get(22)}"

@cocotb.test()
async def check_sra(dut):
    assert _reg_values.get(23) == 1, f"SRA: x23 = {_reg_values.get(23)}"

@cocotb.test()
async def check_auipc(dut):
    assert _reg_values.get(24) == 1, f"AUIPC: x24 = {_reg_values.get(24)}"

@cocotb.test()
async def check_jal(dut):
    assert _reg_values.get(25) == 1, f"JAL: x25 = {_reg_values.get(25)}"

@cocotb.test()
async def check_jalr(dut):
    assert _reg_values.get(26) == 1, f"JALR: x26 = {_reg_values.get(26)}"

@cocotb.test()
async def check_sw_lw(dut):
    assert _reg_values.get(27) == 1, f"SW/LW: x27 = {_reg_values.get(27)}"

@cocotb.test()
async def check_x28(dut):
    assert _reg_values.get(28) == 1, f"x28 = {_reg_values.get(28)}"

@cocotb.test()
async def check_x29(dut):
    assert _reg_values.get(29) == 1, f"x29 = {_reg_values.get(29)}"

@cocotb.test()
async def check_success(dut):
    assert _reg_values.get(30) == 1, f"x30 = {_reg_values.get(30)}, program did not reach success"