# tests/testbench/test_debugger.py
#
# Bit-bangs the debug UART protocol against tb_soc's dbg_rx/dbg_tx pins
# (same 115200 baud / clk_per_bit=434 config as fpga/riscv_top.sv) and
# cross-checks every value read back over the wire against read_reg()/
# dut.u_core.pc, the trusted direct-signal path already used elsewhere
# in this test suite.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import reset, run_cycles, load_imem, read_reg, assemble

CLK_PER_BIT = 434  # matches tb_soc's hardcoded debug_uart clk_per_bit

CMD_HALT     = 0x01
CMD_RESUME   = 0x02
CMD_STEP     = 0x03
CMD_READ_REG = 0x04
CMD_READ_PC  = 0x05
CMD_READ_ALL = 0x06


async def dbg_send_byte(dut, byte, clk_per_bit=CLK_PER_BIT):
    """Drive one 8N1 byte onto dbg_rx (LSB first)."""
    dut.dbg_rx.value = 0  # start bit
    await ClockCycles(dut.clk, clk_per_bit)
    for i in range(8):
        dut.dbg_rx.value = (byte >> i) & 1
        await ClockCycles(dut.clk, clk_per_bit)
    dut.dbg_rx.value = 1  # stop bit
    await ClockCycles(dut.clk, clk_per_bit)


async def dbg_recv_byte(dut, clk_per_bit=CLK_PER_BIT):
    """Sample one 8N1 byte off dbg_tx (LSB first)."""
    await FallingEdge(dut.dbg_tx)          # start bit begins
    await ClockCycles(dut.clk, clk_per_bit + clk_per_bit // 2)  # mid of bit0
    value = 0
    for i in range(8):
        value |= (int(dut.dbg_tx.value) << i)
        await ClockCycles(dut.clk, clk_per_bit)
    return value


async def dbg_recv_word(dut, clk_per_bit=CLK_PER_BIT):
    """4 little-endian bytes -> unsigned 32-bit int."""
    b = [await dbg_recv_byte(dut, clk_per_bit) for _ in range(4)]
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)


@cocotb.test()
async def test_halt_step_resume(dut):
    """Halt the core, single-step it, read regs/PC over the debug UART,
    and verify every value matches the direct-signal ground truth."""

    dut.dbg_rx.value = 1  # idle high

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    words = assemble("test_basic.asm")
    load_imem(dut, words)
    loop_pc = (len(words) - 1) * 4  # test_basic.asm's trailing `loop: j loop` word

    await reset(dut)

    # debug_uart.sv halts the core by default on reset (halt <= 1'b1) with
    # no override in tb_soc (unlike fpga/riscv_top.sv's KEY[1]) -- so the
    # core never executes a single instruction until RESUME is sent. Send
    # it first, then let x1-x4 compute and the core settle into its
    # trailing `loop: j loop`.
    await dbg_send_byte(dut, CMD_RESUME)
    await run_cycles(dut, 20)

    # ── HALT ──────────────────────────────────────────
    await dbg_send_byte(dut, CMD_HALT)
    await run_cycles(dut, 5)

    pc_before_halt = dut.u_core.pc.value.to_unsigned()
    await run_cycles(dut, 50)
    pc_after_wait = dut.u_core.pc.value.to_unsigned()
    assert pc_after_wait == pc_before_halt, (
        f"PC advanced while halted: 0x{pc_before_halt:08x} -> 0x{pc_after_wait:08x}"
    )

    # ── READ_REG x1..x4 over UART, compare to read_reg() ──
    for reg in range(1, 5):
        await dbg_send_byte(dut, CMD_READ_REG)
        await dbg_send_byte(dut, reg)
        got = await dbg_recv_word(dut)
        want = read_reg(dut, reg)
        assert got == want, f"x{reg} over debug UART = {got}, direct read = {want}"

    # ── READ_PC over UART, compare to dut.u_core.pc ──
    await dbg_send_byte(dut, CMD_READ_PC)
    pc_reported = await dbg_recv_word(dut)
    assert pc_reported == pc_before_halt, (
        f"READ_PC = 0x{pc_reported:08x}, expected 0x{pc_before_halt:08x}"
    )

    # ── STEP three times ──
    # Sending one command byte over the debug UART takes ~10 * clk_per_bit
    # core cycles -- far longer than this 4-instruction program takes to
    # run, so by the time HALT actually lands, the core is already parked
    # on `loop: j loop` (pc_before_halt is somewhere in that self-loop).
    #
    # On the pipelined core (docs/04_pipeline_plan.md), STEP only frees
    # `halt` for exactly one clk cycle (debug_uart.sv's STEP_ASSERT ->
    # STEP_DEASSERT) -- one pipeline-register update, not one full
    # instruction's worth of latency. A self-jump doesn't resolve until it
    # reaches EX (2 register stages after fetch), so pc walks through the
    # same predict-not-taken period-3 bounce the differential harness's
    # await_pc_convergence() already relies on elsewhere: each STEP
    # advances pc from whichever of {loop_pc, loop_pc+4, loop_pc+8} it's
    # currently on to the next phase in that fixed cycle, wrapping back
    # to loop_pc after loop_pc+8.
    phase_idx = (pc_before_halt - loop_pc) // 4
    assert phase_idx in (0, 1, 2), f"pc_before_halt 0x{pc_before_halt:08x} not in self-loop bounce"
    step_pattern = [loop_pc + ((phase_idx + i) % 3) * 4 for i in range(1, 4)]
    for expected_pc in step_pattern:
        await dbg_send_byte(dut, CMD_STEP)
        await run_cycles(dut, 3)

        await dbg_send_byte(dut, CMD_READ_PC)
        pc_reported = await dbg_recv_word(dut)
        assert pc_reported == expected_pc, (
            f"after STEP, READ_PC = 0x{pc_reported:08x}, expected 0x{expected_pc:08x}"
        )
        direct_pc = dut.u_core.pc.value.to_unsigned()
        assert direct_pc == expected_pc, (
            f"direct pc read = 0x{direct_pc:08x}, expected 0x{expected_pc:08x}"
        )

    # ── RESUME — core should run freely again ──
    await dbg_send_byte(dut, CMD_RESUME)
    await run_cycles(dut, 20)
    # Running freely, pc is somewhere in the same period-3 loop bounce --
    # not necessarily back at pc_before_halt exactly (depends which of
    # the 3 phases 20 more cycles landed on).
    resumed_pc = dut.u_core.pc.value.to_unsigned()
    bounce = [loop_pc, loop_pc + 4, loop_pc + 8]
    assert resumed_pc in bounce, (
        f"core did not resume into the expected self-loop bounce: "
        f"pc = 0x{resumed_pc:08x}, expected one of {[hex(p) for p in bounce]}"
    )

    cocotb.log.info("Debug UART halt/step/read/resume cycle PASSED")
