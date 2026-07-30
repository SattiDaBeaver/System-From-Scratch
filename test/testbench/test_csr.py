# tests/testbench/test_csr.py
#
# Zicsr instruction coverage (CSRRW/S/C, CSRRWI/SI/CI) for the
# single-cycle core's new CSR read-modify-write logic. Mirrors
# test_subword.py's run-once-then-check-registers pattern.

import cocotb
from cocotb.clock import Clock
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import reset, load_imem, read_reg, read_csr, assemble, await_pc_convergence

# Store DUT state after running so individual tests can check it
_reg_values = {}
_csr_values = {}

@cocotb.test()
async def run_program(dut):
    """Load and run the CSR test program"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    words = assemble("test_csr.asm")
    load_imem(dut, words)

    await reset(dut)
    # riscv_core_single_cycle.sv has no pipeline stages, so pc settles
    # into a period-1 self-loop (unlike the pipelined core's period-3).
    await await_pc_convergence(dut, dut.pc_dbg, period=1)

    for reg in range(5, 13):
        _reg_values[reg] = read_reg(dut, reg)
    _reg_values[30] = read_reg(dut, 30)
    for name in ("mscratch", "mtvec", "mepc", "mie"):
        _csr_values[name] = read_csr(dut, name)

    cocotb.log.info("Program run complete, register/CSR snapshot taken")


@cocotb.test()
async def check_csrrw_old_value(dut):
    assert _reg_values.get(5) == 1, f"CSRRW (old value read): x5 = {_reg_values.get(5)}"

@cocotb.test()
async def check_csrrwi_roundtrip(dut):
    assert _reg_values.get(6) == 1, f"CSRRWI round-trip: x6 = {_reg_values.get(6)}"

@cocotb.test()
async def check_csrrs(dut):
    assert _reg_values.get(7) == 1, f"CSRRS (set bits, register): x7 = {_reg_values.get(7)}"

@cocotb.test()
async def check_csrrsi(dut):
    assert _reg_values.get(8) == 1, f"CSRRSI (set bits, immediate): x8 = {_reg_values.get(8)}"

@cocotb.test()
async def check_csrrc(dut):
    assert _reg_values.get(9) == 1, f"CSRRC (clear bits, register): x9 = {_reg_values.get(9)}"

@cocotb.test()
async def check_csrrci(dut):
    assert _reg_values.get(10) == 1, f"CSRRCI (clear bits, immediate): x10 = {_reg_values.get(10)}"

@cocotb.test()
async def check_final_csr_state(dut):
    assert _csr_values.get("mtvec") == 0xFF, f"mtvec = {_csr_values.get('mtvec'):#x}"
    assert _csr_values.get("mepc") == 0xFFFFFF00, f"mepc = {_csr_values.get('mepc'):#x}"
    assert _csr_values.get("mie") == 0xFFFFFFE0, f"mie = {_csr_values.get('mie'):#x}"
    assert _csr_values.get("mscratch") == 7, f"mscratch = {_csr_values.get('mscratch'):#x}"

@cocotb.test()
async def check_success(dut):
    assert _reg_values.get(30) == 1, f"x30 = {_reg_values.get(30)}, program did not reach success"
