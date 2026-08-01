# tests/testbench/test_trap.py
#
# ECALL/EBREAK/MRET trap entry & exit coverage for the single-cycle core.
# Mirrors test_csr.py's run-once-then-check-registers pattern.

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
    """Load and run the trap test program"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    words = assemble("test_trap.asm")
    load_imem(dut, words)

    await reset(dut)
    # riscv_core_single_cycle.sv has no pipeline stages, so pc settles
    # into a period-1 self-loop (unlike the pipelined core's period-3).
    await await_pc_convergence(dut, dut.pc_dbg, period=1)

    for reg in [2, 8, 9, 13, 30]:
        _reg_values[reg] = read_reg(dut, reg)

    cocotb.log.info("Program run complete, register snapshot taken")


@cocotb.test()
async def check_ecall_resumed(dut):
    assert _reg_values.get(2) == 1, f"ecall did not resume past itself: x2 = {_reg_values.get(2)}"

@cocotb.test()
async def check_ecall_mcause(dut):
    assert _reg_values.get(8) == 1, f"mcause != 11 after ecall: x8 = {_reg_values.get(8)}"

@cocotb.test()
async def check_ebreak_resumed(dut):
    assert _reg_values.get(9) == 1, f"ebreak did not resume past itself: x9 = {_reg_values.get(9)}"

@cocotb.test()
async def check_ebreak_mcause(dut):
    assert _reg_values.get(13) == 1, f"mcause != 3 after ebreak: x13 = {_reg_values.get(13)}"

@cocotb.test()
async def check_success(dut):
    assert _reg_values.get(30) == 1, f"x30 = {_reg_values.get(30)}, program did not reach success"
