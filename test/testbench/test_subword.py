# tests/testbench/test_subword.py
#
# Byte/halfword load-store coverage (LB/LH/LBU/LHU/SB/SH) for the
# single-cycle core's new dmem_byteena interface. Mirrors test_full.py's
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
    """Load and run the sub-word access test program"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    words = assemble("test_subword.asm")
    load_imem(dut, words)

    await reset(dut)
    # riscv_core_single_cycle.sv has no pipeline stages, so pc settles
    # into a period-1 self-loop (unlike the pipelined core's period-3).
    await await_pc_convergence(dut, dut.pc_dbg, period=1)

    for reg in range(5, 11):
        _reg_values[reg] = read_reg(dut, reg)
    _reg_values[30] = read_reg(dut, 30)

    cocotb.log.info("Program run complete, register snapshot taken")


@cocotb.test()
async def check_lb(dut):
    assert _reg_values.get(5) == 1, f"LB (positive byte): x5 = {_reg_values.get(5)}"

@cocotb.test()
async def check_lb_sign_extend(dut):
    assert _reg_values.get(6) == 1, f"LB (sign-extend): x6 = {_reg_values.get(6)}"

@cocotb.test()
async def check_lbu_zero_extend(dut):
    assert _reg_values.get(7) == 1, f"LBU (zero-extend): x7 = {_reg_values.get(7)}"

@cocotb.test()
async def check_lh_sign_extend(dut):
    assert _reg_values.get(8) == 1, f"LH (sign-extend): x8 = {_reg_values.get(8)}"

@cocotb.test()
async def check_lhu_zero_extend(dut):
    assert _reg_values.get(9) == 1, f"LHU (zero-extend): x9 = {_reg_values.get(9)}"

@cocotb.test()
async def check_byte_isolation(dut):
    assert _reg_values.get(10) == 1, f"byte isolation (dmem_byteena masking): x10 = {_reg_values.get(10)}"

@cocotb.test()
async def check_success(dut):
    assert _reg_values.get(30) == 1, f"x30 = {_reg_values.get(30)}, program did not reach success"
