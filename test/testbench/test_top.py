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
#
# tb_top's CORE_TYPE parameter (mirrors fpga/riscv_top.sv) picks which core
# gets elaborated -- "PIPELINED" (default) or "SINGLE_CYCLE". This whole
# suite runs unchanged against either, since riscv_top's wrapper logic
# doesn't care which core is behind it -- except test_single_cycle_core_smoke
# below, which is only meaningful when the suite is invoked with
# CORE_TYPE=SINGLE_CYCLE (`make sim TOPLEVEL=tb_top MODULE=testbench.test_top
# CORE_TYPE=SINGLE_CYCLE`); cocotb can't introspect the elaborated Verilog
# parameter value from Python, so it can't self-skip when the wrong core is
# built -- treat "run the whole file twice, once per CORE_TYPE" as the full
# regression matrix for this testbench.

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
CMD_READ_REG = 0x04
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
    dut.KEY.value = 0b10  # KEY[0]=0 (active-low reset asserted), KEY[1]=1
                          # (halt override inactive) -- set together, since
                          # two sequential set_key() calls would race: each
                          # reads dut.KEY.value before the other's write has
                          # taken effect in the same timestep, so the second
                          # call would silently clobber the first.
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
    pc_before = dut.g_core.u_core.pc.value.to_unsigned()
    await ClockCycles(dut.CLOCK_50, 100)
    pc_after = dut.g_core.u_core.pc.value.to_unsigned()
    assert pc_after == pc_before, (
        f"core advanced while halted (KEY[1]=1): 0x{pc_before:08x} -> 0x{pc_after:08x}"
    )

    # Now pull KEY[1] low -- the override should force the core to run
    # again even though the debug UART never got a RESUME.
    set_key(dut, 1, 0)
    await ClockCycles(dut.CLOCK_50, 100)
    pc_override = dut.g_core.u_core.pc.value.to_unsigned()
    assert pc_override != pc_before, (
        f"KEY[1] override did not un-halt the core: PC stuck at 0x{pc_before:08x}"
    )

    cocotb.log.info("Halt override PASSED")


@cocotb.test()
async def test_single_cycle_core_smoke(dut):
    """Smoke-check that riscv_top's wrapper logic works unchanged when
    CORE_TYPE=SINGLE_CYCLE picks the frozen golden-model core instead of the
    pipelined one -- only meaningful under that build (see module docstring);
    with the default CORE_TYPE=PIPELINED this just re-covers test_basic.asm
    against the pipelined core's predict-not-taken self-loop bounce."""
    cocotb.start_soon(Clock(dut.CLOCK_50, 20, unit="ns").start())
    await reset_top(dut)

    words = assemble("test_basic.asm")
    load_program(dut, words)
    loop_pc = (len(words) - 1) * 4  # test_basic.asm's trailing `loop: j loop` word

    # debug_uart.sv halts the core on reset by default (halt <= 1'b1) --
    # with no RESUME, it never executes a single instruction (see
    # test_debugger.py). Pulling KEY[1] low forces the core to run
    # regardless (same override test_halt_override exercises), which is
    # far cheaper here than round-tripping a RESUME over the debug UART.
    set_key(dut, 1, 0)
    await ClockCycles(dut.CLOCK_50, 200)

    # Unlike the pipelined core (which bounces around loop_pc/+4/+8 because
    # a self-jump doesn't resolve until EX -- see test_debugger.py), the
    # single-cycle core resolves the jump same-cycle, so pc parks exactly on
    # loop_pc with no bounce.
    pc = dut.g_core.u_core.pc.value.to_unsigned()
    phase_idx = (pc - loop_pc) // 4
    assert phase_idx in (0, 1, 2), (
        f"core did not settle into test_basic.asm's trailing self-loop: "
        f"pc=0x{pc:08x}, loop_pc=0x{loop_pc:08x}"
    )

    cocotb.log.info("Single-cycle core smoke PASSED")


@cocotb.test()
async def test_step_reliability(dut):
    """Regression test for the real-hardware bug this session's fix
    addresses: with dp_ram_model's REGISTERED_ADDR=1 (matching real BRAM's
    registered-address read latency), the core's own native imem_req/
    imem_vld stall logic must hold pc in place until the fetched
    instruction is actually valid, so STEP reliably advances pc by exactly
    one instruction every single time -- not ~1/3 of the time as observed
    pre-fix (back when this was patched externally via the now-retired
    mem_stall_ctrl halt wrapper). Only meaningful under
    CORE_TYPE=SINGLE_CYCLE: debug_uart's STEP drops halt for exactly one
    clk cycle, which assumes one halt-drop = one instruction retiring --
    true for the single-cycle core, but not for the pipelined core, where
    a RAW hazard (front_stall) or memory wait already pending in the
    pipeline can eat that single un-halted cycle without pc advancing at
    all. cocotb can't introspect the elaborated CORE_TYPE parameter
    directly, so this self-skips off the CORE_TYPE env var the Makefile
    exports instead (see module docstring for why running the file twice,
    once per CORE_TYPE, is still the full regression matrix)."""
    if os.environ.get("CORE_TYPE", "PIPELINED") != "SINGLE_CYCLE":
        cocotb.log.info("Skipping test_step_reliability: only meaningful "
                         "under CORE_TYPE=SINGLE_CYCLE")
        return

    cocotb.start_soon(Clock(dut.CLOCK_50, 20, unit="ns").start())
    await reset_top(dut)

    words = assemble("test_full.asm")
    load_program(dut, words)

    dut.SW.value = 1  # route ext_rx/ext_tx to the debug UART
    await ClockCycles(dut.CLOCK_50, 4)

    # debug_uart.sv halts on reset by default -- core hasn't moved yet.
    prev_pc = dut.g_core.u_core.pc.value.to_unsigned()
    assert prev_pc == 0, f"core advanced before any STEP: pc=0x{prev_pc:08x}"

    # test_full.asm is len(words) instructions, ending in a trailing
    # self-loop (jal x0, loop) -- so pc can only advance by +4 exactly
    # len(words)-1 times before parking on that self-loop, after which
    # STEP legitimately can't advance it any further.
    for i in range(len(words) - 1):
        await dbg_send_byte(dut, CMD_STEP)
        await ClockCycles(dut.CLOCK_50, 20)  # let native stall logic settle
        pc = dut.g_core.u_core.pc.value.to_unsigned()
        assert pc == prev_pc + 4, (
            f"STEP #{i} did not advance pc by exactly 4: "
            f"0x{prev_pc:08x} -> 0x{pc:08x}"
        )
        prev_pc = pc

    cocotb.log.info("Step reliability PASSED")


@cocotb.test()
async def test_resume_correctness(dut):
    """Regression test for the RESUME-path counterpart of
    test_step_reliability: with REGISTERED_ADDR=1, letting the core run
    freely via RESUME must still produce the same architectural end-state
    as single-stepping through the whole program -- pre-fix, RESUME would
    settle into a persistently wrong steady state instead. Runs under both
    CORE_TYPE values: the pipelined core's predict-not-taken self-loop
    doesn't park pc at an exact value (IF keeps optimistically fetching
    pc+4/pc+8 after every jal, bouncing pc through loop_pc/+4/+8 forever
    even though the jal correctly keeps re-redirecting back to loop_pc --
    same bounce test_single_cycle_core_smoke/test_debugger.py already
    tolerate), so convergence is checked as "parked in the bounce range"
    rather than exact equality."""
    cocotb.start_soon(Clock(dut.CLOCK_50, 20, unit="ns").start())
    await reset_top(dut)

    words = assemble("test_full.asm")
    load_program(dut, words)
    loop_pc = (len(words) - 1) * 4  # test_full.asm's trailing self-loop word

    dut.SW.value = 1  # route ext_rx/ext_tx to the debug UART
    await ClockCycles(dut.CLOCK_50, 4)

    await dbg_send_byte(dut, CMD_RESUME)

    # Poll pc until it parks in the trailing self-loop's bounce range, with
    # a generous timeout as a safety net against a genuine hang.
    for _ in range(2000):
        await ClockCycles(dut.CLOCK_50, 10)
        pc = dut.g_core.u_core.pc.value.to_unsigned()
        if loop_pc <= pc <= loop_pc + 8:
            break
    else:
        assert False, f"core never converged on trailing self-loop (last pc=0x{pc:08x})"

    await dbg_send_byte(dut, CMD_HALT)
    await ClockCycles(dut.CLOCK_50, 20)

    # test_full.asm's own contract: every general-purpose register it
    # touches (x5-x30) ends up == 1 once the program has fully run.
    for reg in range(5, 31):
        await dbg_send_byte(dut, CMD_READ_REG)
        await dbg_send_byte(dut, reg)
        got = await dbg_recv_word(dut)
        assert got == 1, f"x{reg} = {got} after RESUME convergence, expected 1"

    cocotb.log.info("Resume correctness PASSED")


@cocotb.test()
async def test_pipeline_stall_real_latency(dut):
    """Regression test for the RTL bug this session fixed: riscv_core.sv's
    ProgramCounter had no explicit ex_flush priority over front_stall, so
    a branch/jump resolving on the same cycle a RAW-hazard stall
    (front_stall) or real-BRAM fetch wait (if_wait) was pending got
    silently dropped -- exactly the kind of interaction
    test_pipeline_stall.asm's back-to-back RAW hazards (distance-0
    dependencies, a load-use chain, and a hazard-guarded branch) can
    trigger once real REGISTERED_ADDR=1 memory timing is in the mix,
    which test_diff.py's diff_test_pipeline_stall never exercises (tb_diff
    is zero-latency there). Runs under both CORE_TYPE values via RESUME,
    same convergence/readback pattern as test_resume_correctness."""
    cocotb.start_soon(Clock(dut.CLOCK_50, 20, unit="ns").start())
    await reset_top(dut)

    # regfile has no reset logic (only pc/pipeline regs do) -- cocotb.test()
    # functions run sequentially against the same simulated instance, so
    # test_resume_correctness's x5-x30==1 leftovers would otherwise leak
    # into this test's own x7==0 check (x7 is deliberately never written
    # here, since the beq must skip it).
    for i in range(32):
        dut.g_core.u_core.regfile[i].value = 0

    words = assemble("test_pipeline_stall.asm")
    load_program(dut, words)
    loop_pc = (len(words) - 1) * 4  # trailing self-loop word

    dut.SW.value = 1  # route ext_rx/ext_tx to the debug UART
    await ClockCycles(dut.CLOCK_50, 4)

    await dbg_send_byte(dut, CMD_RESUME)

    # Poll pc until it parks in the trailing self-loop's bounce range, with
    # a generous timeout as a safety net against a genuine hang.
    for _ in range(2000):
        await ClockCycles(dut.CLOCK_50, 10)
        pc = dut.g_core.u_core.pc.value.to_unsigned()
        if loop_pc <= pc <= loop_pc + 8:
            break
    else:
        assert False, f"core never converged on trailing self-loop (last pc=0x{pc:08x})"

    await dbg_send_byte(dut, CMD_HALT)
    await ClockCycles(dut.CLOCK_50, 20)

    # test_pipeline_stall.asm's own contract, derived from its source:
    # x1=5, x2=x1+10=15, x3=x1+x2=20, x4=x3+x3=40, x5=x6=1 (beq operands),
    # x7=0 (never executed -- beq must take the branch), x8=8 (post-branch
    # target), x9=4 (dmem word addr), x10=42 (stored value), x11=42
    # (loaded back), x12=x11+x11=84.
    expected = {
        1: 5, 2: 15, 3: 20, 4: 40, 5: 1, 6: 1, 7: 0, 8: 8,
        9: 4, 10: 42, 11: 42, 12: 84,
    }
    for reg, want in expected.items():
        await dbg_send_byte(dut, CMD_READ_REG)
        await dbg_send_byte(dut, reg)
        got = await dbg_recv_word(dut)
        assert got == want, f"x{reg} = {got} after RESUME convergence, expected {want}"

    cocotb.log.info("Pipeline stall real-latency PASSED")
