# tests/testbench/test_mul.py
#
# RV32M multiply instruction coverage (MUL/MULH/MULHSU/MULHU) for the
# single-cycle core's new multiply logic. Mirrors test_csr.py's
# run-once-then-check-registers pattern.

import cocotb
from cocotb.clock import Clock
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import reset, load_imem, read_reg, assemble, await_pc_convergence

# Store DUT state after running so individual tests can check it
_reg_values = {}

@cocotb.test()
async def run_program(dut):
    """Load and run the multiply test program"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    words = assemble("test_mul.asm")
    load_imem(dut, words)

    await reset(dut)
    # riscv_core_single_cycle.sv has no pipeline stages, so pc settles
    # into a period-1 self-loop (unlike the pipelined core's period-3).
    await await_pc_convergence(dut, dut.pc_dbg, period=1)

    for reg in range(5, 10):
        _reg_values[reg] = read_reg(dut, reg)
    _reg_values[30] = read_reg(dut, 30)

    cocotb.log.info("Program run complete, register snapshot taken")


@cocotb.test()
async def check_mul_positive(dut):
    assert _reg_values.get(5) == 1, f"MUL 6*7: x5 = {_reg_values.get(5)}"

@cocotb.test()
async def check_mul_negative(dut):
    assert _reg_values.get(6) == 1, f"MUL -3*-4: x6 = {_reg_values.get(6)}"

@cocotb.test()
async def check_mulh(dut):
    assert _reg_values.get(7) == 1, f"MULH overflow: x7 = {_reg_values.get(7)}"

@cocotb.test()
async def check_mulhsu(dut):
    assert _reg_values.get(8) == 1, f"MULHSU signed*unsigned: x8 = {_reg_values.get(8)}"

@cocotb.test()
async def check_mulhu(dut):
    assert _reg_values.get(9) == 1, f"MULHU unsigned overflow: x9 = {_reg_values.get(9)}"

@cocotb.test()
async def check_success(dut):
    assert _reg_values.get(30) == 1, f"x30 = {_reg_values.get(30)}, program did not reach success"
