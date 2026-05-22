# tests/testbench/test_basic.py

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import reset, run_cycles, load_imem, read_reg, assemble


@cocotb.test()
async def test_addi_add(dut):
    """Test basic addi and add instructions"""

    # Start clock
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Load program
    words = assemble("test_basic.asm")

    # Debug Prints  
    print(f"Program ({len(words)} words):")
    for i, w in enumerate(words):
        print(f"  [{i}] 0x{w:08x}")
    # End Debug Prints
    
    load_imem(dut, words)

    # Reset
    await reset(dut)

    # Run enough cycles for 4 instructions + some margin
    await run_cycles(dut, 20)

    # Debug Prints  
    # Print first few instructions fetched
    for i in range(8):
        print(f"imem[{i}] = {dut.imem[i].value}")

    print(f"pc        = {dut.u_core.pc.value}")
    print(f"instr     = {dut.u_core.instr.value}")
    print(f"is_addi   = {dut.u_core.is_addi.value}")
    print(f"wr_en     = {dut.u_core.wr_en.value}")
    print(f"rd        = {dut.u_core.rd.value}")
    print(f"wr_data   = {dut.u_core.wr_data.value}")

    # End Debug Prints

    # Check results
    assert read_reg(dut, 1) == 5,  f"x1 expected 5,  got {read_reg(dut, 1)}"
    assert read_reg(dut, 2) == 10, f"x2 expected 10, got {read_reg(dut, 2)}"
    assert read_reg(dut, 3) == 15, f"x3 expected 15, got {read_reg(dut, 3)}"
    assert read_reg(dut, 4) == 7,  f"x4 expected 7,  got {read_reg(dut, 4)}"

    cocotb.log.info("test_addi_add PASSED")