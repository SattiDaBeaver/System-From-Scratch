# test/testbench/test_top.py
#
# Exercises fpga/riscv_top.sv's own wrapper logic via tb_top.sv (dp_ram
# swapped for the behavioral dp_ram_model -- see its header comment) --
# things the core-only testbenches (tb_core.sv/tb_soc.sv) can't cover:
#   - the CLOCK_50 -> clk divider actually produces half-rate clk
#   - SW[0] muxes the single external serial pin (ext_rx/ext_tx) between
#     the program UART and the debug UART
#   - KEY[1] acts as a manual override that always un-halts the core,
#     regardless of what the debug UART's HALT command says

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import assemble

# tb_top's internal clk = CLOCK_50 / 2, and CLK_PER_BIT (baud divider) is
# hardwired for 25MHz operation -- so one UART bit period is 217 clk
# cycles = 434 CLOCK_50 cycles.
CLK_PER_BIT_EXT = 434

CMD_HALT     = 0x01
CMD_RESUME   = 0x02
CMD_STEP     = 0x03
CMD_READ_PC  = 0x05


def load_program(dut, words):
    for i, w in enumerate(words):
        dut.u_bram.mem[i].value = w


def set_key(dut, idx, bit):
    """KEY is a packed [1:0] vector -- cocotb v2 can't index into a packed
    vector directly, so read-modify-write the whole thing instead."""
    cur = int(dut.KEY.value)
    if bit:
        cur |= (1 << idx)
    else:
        cur &= ~(1 << idx)
    dut.KEY.value = cur


async def reset_top(dut, cycles=10):
    set_key(dut, 0, 0)  # active-low reset asserted
    set_key(dut, 1, 1)  # halt override inactive (core allowed to run)
    dut.SW.value = 0
    dut.ext_rx.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.CLOCK_50)
    set_key(dut, 0, 1)
    await RisingEdge(dut.CLOCK_50)  # let reset release settle before sampling


async def dbg_send_byte(dut, byte, clk_per_bit=CLK_PER_BIT_EXT):
    """Drive one 8N1 byte onto ext_rx (LSB first), CLOCK_50-relative."""
    dut.ext_rx.value = 0  # start bit
    await ClockCycles(dut.CLOCK_50, clk_per_bit)
    for i in range(8):
        dut.ext_rx.value = (byte >> i) & 1
        await ClockCycles(dut.CLOCK_50, clk_per_bit)
    dut.ext_rx.value = 1  # stop bit
    await ClockCycles(dut.CLOCK_50, clk_per_bit)


async def dbg_recv_byte(dut, clk_per_bit=CLK_PER_BIT_EXT):
    await FallingEdge(dut.ext_tx)
    await ClockCycles(dut.CLOCK_50, clk_per_bit + clk_per_bit // 2)
    value = 0
    for i in range(8):
        value |= (int(dut.ext_tx.value) << i)
        await ClockCycles(dut.CLOCK_50, clk_per_bit)
    return value


async def dbg_recv_word(dut, clk_per_bit=CLK_PER_BIT_EXT):
    b = [await dbg_recv_byte(dut, clk_per_bit) for _ in range(4)]
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)


@cocotb.test()
async def test_clock_divider(dut):
    """clk should toggle once every 2 CLOCK_50 edges (CLOCK_50 / 2)."""
    cocotb.start_soon(Clock(dut.CLOCK_50, 20, unit="ns").start())
    await reset_top(dut)

    # Sample clk on consecutive CLOCK_50 rising edges -- it should flip
    # every single edge (a /2 toggle divider), never staying level for two.
    prev = int(dut.clk.value)
    toggles = 0
    for _ in range(8):
        await RisingEdge(dut.CLOCK_50)
        cur = int(dut.clk.value)
        if cur != prev:
            toggles += 1
        prev = cur

    assert toggles == 8, f"clk did not toggle every CLOCK_50 edge: {toggles}/8"
    cocotb.log.info("Clock divider PASSED")


@cocotb.test()
async def test_uart_mux(dut):
    """SW[0] should route ext_rx/ext_tx to the program UART when low, and
    to the debug UART when high -- never both at once."""
    cocotb.start_soon(Clock(dut.CLOCK_50, 20, unit="ns").start())
    await reset_top(dut)

    words = assemble("test_basic.asm")
    load_program(dut, words)

    # SW[0] = 0 -> program UART selected: ext_rx should feed uart_rx, and
    # dbg_rx should be tied idle-high (unreachable from the pin).
    dut.SW.value = 0
    await ClockCycles(dut.CLOCK_50, 4)
    dut.ext_rx.value = 0
    await ClockCycles(dut.CLOCK_50, 4)
    assert int(dut.uart_rx.value) == 0, "SW[0]=0: ext_rx should reach uart_rx"
    assert int(dut.dbg_rx.value) == 1, "SW[0]=0: dbg_rx should stay idle-high"
    dut.ext_rx.value = 1

    # SW[0] = 1 -> debug UART selected: ext_rx should feed dbg_rx, and
    # uart_rx should be tied idle-high instead.
    dut.SW.value = 1
    await ClockCycles(dut.CLOCK_50, 4)
    dut.ext_rx.value = 0
    await ClockCycles(dut.CLOCK_50, 4)
    assert int(dut.dbg_rx.value) == 0, "SW[0]=1: ext_rx should reach dbg_rx"
    assert int(dut.uart_rx.value) == 1, "SW[0]=1: uart_rx should stay idle-high"
    dut.ext_rx.value = 1

    cocotb.log.info("UART mux PASSED")


@cocotb.test()
async def test_halt_override(dut):
    """KEY[1] should force the core to run regardless of what the debug
    UART's halt output says -- a manual escape hatch so the operator never
    needs to send RESUME over the wire to get the core moving again."""
    cocotb.start_soon(Clock(dut.CLOCK_50, 20, unit="ns").start())
    await reset_top(dut)

    words = assemble("test_basic.asm")
    load_program(dut, words)

    dut.SW.value = 1  # route ext_rx/ext_tx to the debug UART
    await ClockCycles(dut.CLOCK_50, 4)

    # HALT over the debug UART -- with KEY[1]=1 (override inactive), the
    # core should actually stop.
    await dbg_send_byte(dut, CMD_HALT)
    await ClockCycles(dut.CLOCK_50, 10)
    pc_before = dut.u_core.pc.value.to_unsigned()
    await ClockCycles(dut.CLOCK_50, 100)
    pc_after = dut.u_core.pc.value.to_unsigned()
    assert pc_after == pc_before, (
        f"core advanced while halted (KEY[1]=1): 0x{pc_before:08x} -> 0x{pc_after:08x}"
    )

    # Now pull KEY[1] low -- the override should force the core to run
    # again even though the debug UART never got a RESUME.
    set_key(dut, 1, 0)
    await ClockCycles(dut.CLOCK_50, 100)
    pc_override = dut.u_core.pc.value.to_unsigned()
    assert pc_override != pc_before, (
        f"KEY[1] override did not un-halt the core: PC stuck at 0x{pc_before:08x}"
    )

    cocotb.log.info("Halt override PASSED")
