# test/testbench/test_uart.py
#
# Exercises uart.sv directly (tb_uart's TX looped back into RX) with cocotb.
# Unlike the other test modules here, this one never calls assemble() /
# needs the RISC-V cross-toolchain -- useful for verifying just the UART
# peripheral when riscv64-unknown-elf-as isn't available.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import reset, run_cycles

CLK_PER_BIT = 4  # small divider -> fast test, exact value doesn't matter for loopback


async def tx_byte(dut, byte):
    dut.TX_dataIn.value = byte
    dut.TX_en.value = 1
    await RisingEdge(dut.clk)
    dut.TX_en.value = 0


@cocotb.test()
async def test_uart_loopback(dut):
    """Send bytes through UART_TX, looped back into UART_RX, and check they
    arrive unmodified."""

    dut.clk_per_bit.value = CLK_PER_BIT
    dut.TX_dataIn.value = 0
    dut.TX_en.value = 0

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    for byte in (0x00, 0xA5, 0xFF, 0x3C):
        await tx_byte(dut, byte)

        # Wait for TX to finish, then for RX to finish shortly after
        # (loopback path is combinational, so RX tracks TX bit-for-bit).
        timeout = 0
        while not dut.RX_done.value:
            await RisingEdge(dut.clk)
            timeout += 1
            assert timeout < 2000, f"RX_done never asserted for byte 0x{byte:02x}"

        got = dut.RX_dataOut.value.integer
        assert got == byte, f"loopback mismatch: sent 0x{byte:02x}, got 0x{got:02x}"
        assert dut.RX_parityError.value == 0, f"unexpected parity error for byte 0x{byte:02x}"

        await run_cycles(dut, 5)

    cocotb.log.info("UART loopback test PASSED")
