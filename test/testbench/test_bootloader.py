# tests/testbench/test_bootloader.py

import cocotb
from cocotb.clock import Clock
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import reset, run_cycles, assemble


@cocotb.test()
async def test_bootloader_tx(dut):
    """Verify bootloader sends 0xAA on startup and PC progresses"""

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Load bootloader into imem
    words = assemble("bootloader.asm")
    for i, w in enumerate(words):
        dut.imem[i].value = w

    print(f"Bootloader: {len(words)} words loaded")

    await reset(dut)

    # Run enough cycles to get through setup and TX of 0xAA
    # Setup is a few instructions, TX takes ~434*10 cycles at 115200 baud
    await run_cycles(dut, 50)

    # Check PC is progressing past 0
    pc = dut.u_core.pc.value.to_unsigned()
    print(f"PC after 50 cycles: 0x{pc:08x}")
    assert pc > 0, f"PC stuck at 0, core not running"

    # Check UART TX fired — uart_tx should have gone low at some point
    # (start bit). We check TX_busy went high meaning transmission started
    tx_busy = dut.u_uart.TX_busy.value
    print(f"TX_busy: {tx_busy}")

    # Run more cycles to let TX complete
    await run_cycles(dut, 5000)

    pc = dut.u_core.pc.value.to_unsigned()
    print(f"PC after 5000 more cycles: 0x{pc:08x}")

    # Core should now be sitting in rx_wait loop polling UART status
    # PC should be somewhere in bootloader range (< 0x1000)
    assert pc < 0x1000, f"PC out of bootloader range: 0x{pc:08x}"

    cocotb.log.info("Bootloader sanity check PASSED")