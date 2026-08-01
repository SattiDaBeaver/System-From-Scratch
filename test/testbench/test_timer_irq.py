# tests/testbench/test_timer_irq.py
#
# End-to-end timer-interrupt coverage: src/peripherals/timer.sv fires,
# riscv_core.sv's irq_taken redirects to mtvec, mcause decodes to the
# machine-timer-interrupt encoding, the handler runs, and mret resumes.
#
# tb_top.sv has no clk/rst ports of its own (clk is CLOCK_50/2, rst is
# ~KEY[0] -- both internal wires derived combinationally), so this mirrors
# test_top.py's CLOCK_50/KEY/SW-driven style, not test_trap.py's
# clk/rst-port style. Only meaningful against TOPLEVEL=tb_top
# CORE_TYPE=PIPELINED -- see test_timer_irq.asm's header comment for why.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import assemble

_reg_values = {}


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
    dut.KEY.value = 0b10  # KEY[0]=0 (active-low reset asserted), KEY[1]=1
                          # (halt override inactive) -- set together, since
                          # two sequential set_key() calls would race.
    dut.SW.value = 0
    dut.ext_rx.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.CLOCK_50)
    set_key(dut, 0, 1)
    await RisingEdge(dut.CLOCK_50)


@cocotb.test()
async def run_program(dut):
    """Load and run the timer-interrupt test program."""
    cocotb.start_soon(Clock(dut.CLOCK_50, 20, unit="ns").start())
    await reset_top(dut)

    words = assemble("test_timer_irq.asm")
    load_program(dut, words)

    # debug_uart.sv halts the core on reset by default -- pull KEY[1] low
    # to force the core to run regardless (same override test_top.py's
    # test_halt_override/test_single_cycle_core_smoke exercise).
    set_key(dut, 1, 0)

    # Timer RELOAD=20 (see test_timer_irq.asm) plus setup instructions plus
    # handler execution -- generous margin for the pipelined core's stalls.
    await ClockCycles(dut.CLOCK_50, 2000)

    for reg in [8, 30]:
        _reg_values[reg] = dut.g_core.u_core.regfile[reg].value.integer

    cocotb.log.info(f"Program run complete: x8={_reg_values[8]:#x} x30={_reg_values[30]:#x} pc={dut.pc_dbg.value.integer:#x}")


@cocotb.test()
async def check_timer_mcause(dut):
    assert _reg_values.get(8) == 1, (
        f"mcause != 0x80000007 after timer interrupt: x8 = {_reg_values.get(8)}"
    )


@cocotb.test()
async def check_handler_completed(dut):
    assert _reg_values.get(30) == 1, (
        f"x30 = {_reg_values.get(30)}, handler did not run to completion"
    )
