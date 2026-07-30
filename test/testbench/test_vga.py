# test/testbench/test_vga.py
#
# Dedicated unit tests for src/peripherals/vga_framebuffer.sv, driven
# directly through tb_vga.sv's pass-through wrapper (no core/riscv_top in
# the loop) -- covers what test_top.py can't reach easily: draw/peek
# buffer addressing per DOUBLE_BUF_EN mode, SWAP/SWAP_PENDING request/
# apply/clear timing (specifically that a swap only lands at frame_start,
# never mid-scanout), and hsync/vsync pulse generation.
#
# vga_framebuffer now runs its `clk` input at full (un-divided) rate --
# dut.clk here stands in for clk50 -- with an internal CLK_DIV=2 pixel-rate
# enable gating the H/V timing counters (see vga_framebuffer.sv). So any
# cycle count expressed in terms of h_count/v_count/frame timing must be
# scaled by CLK_DIV clk edges per pixel-timing advance.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from utils import reset, run_cycles

CTRL_ADDR   = 0x0000
STATUS_ADDR = 0x0004
DRAW_BASE   = 0x1000
PEEK_BASE   = 0x2000
CLK_DIV     = 2  # must match vga_framebuffer's CLK_DIV default


async def clear_buffers(dut):
    """vga_framebuffer's rst only clears mode/swap state, not buffer
    contents (by design -- a real display shouldn't need re-clearing on
    every reset) -- so cocotb.test() functions sharing this simulated
    instance must explicitly zero both physical buffers themselves,
    otherwise a later test's peek/draw read can silently observe a
    previous test's leftover write instead of catching a real bug.
    Buffers now live inside dp_ram_sync_read submodule instances rather
    than raw arrays directly on vga_framebuffer."""
    for i in range(600):
        dut.u_vga.u_buf0.mem[i].value = 0
        dut.u_vga.u_buf1.mem[i].value = 0


async def write(dut, addr, data):
    dut.addr.value = addr
    dut.wdata.value = data
    dut.sel.value = 1
    dut.we.value = 1
    dut.re.value = 0
    await RisingEdge(dut.clk)
    dut.we.value = 0
    dut.sel.value = 0


async def read(dut, addr):
    """Reads take 3 clk edges from here, not the 2 the RTL's own latency
    (1 for dp_ram_sync_read's registered dout, 1 for the outer sel_d/re_d
    decode-delay register) would suggest. The extra edge is a cocotb/
    Verilator deposit-timing quirk confirmed by probing sel_d/re_d
    directly: a .value write made right after a RisingEdge callback (no
    intervening delta) isn't seen by an always_ff register at the very
    next posedge -- it only becomes visible starting the edge after that
    -- even though combinational logic (e.g. is_draw_write) driven off
    the same live signal DOES see it immediately. write() escapes this
    because it only relies on that combinational path, never a registered
    decode of its own inputs."""
    dut.addr.value = addr
    dut.sel.value = 1
    dut.re.value = 1
    dut.we.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    val = int(dut.rdata.value)
    dut.re.value = 0
    dut.sel.value = 0
    return val


@cocotb.test()
async def test_single_buffer_draw_is_visible_immediately(dut):
    """Single-buffer mode (default, DOUBLE_BUF_EN=0): a draw-address write
    should land in the same physical buffer the peek address currently
    reads back as the OTHER buffer -- i.e. draw and peek never alias."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await clear_buffers(dut)

    await write(dut, DRAW_BASE + 0, 0xDEADBEEF)
    got_draw = await read(dut, DRAW_BASE + 0)
    got_peek = await read(dut, PEEK_BASE + 0)
    assert got_draw == 0xDEADBEEF, f"draw readback mismatch: 0x{got_draw:08x}"
    assert got_peek != 0xDEADBEEF, "peek buffer aliased the draw write in single-buffer mode"


@cocotb.test()
async def test_double_buffer_draw_hits_back_buffer_only(dut):
    """Double-buffer mode: draws must go to the back buffer (peek address),
    never the buffer currently scanned out -- so a draw is invisible on the
    draw address's own peek mirror until a swap actually happens."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await clear_buffers(dut)

    await write(dut, CTRL_ADDR, 0b01)  # DOUBLE_BUF_EN=1
    await write(dut, DRAW_BASE + 4, 0xCAFEBABE)

    got_draw = await read(dut, DRAW_BASE + 4)
    got_peek = await read(dut, PEEK_BASE + 4)
    assert got_draw == 0xCAFEBABE, f"draw readback mismatch: 0x{got_draw:08x}"
    assert got_peek != 0xCAFEBABE, "back-buffer draw leaked into the peek(front)-buffer read"


@cocotb.test()
async def test_swap_applies_only_at_frame_start(dut):
    """SWAP must not take effect mid-scanout -- SWAP_PENDING should stay set
    for the remainder of the current frame and only clear (with front/back
    swapped) once frame_start (h_count==0 && v_count==0) is reached."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await clear_buffers(dut)

    await write(dut, CTRL_ADDR, 0b01)          # DOUBLE_BUF_EN=1
    await write(dut, DRAW_BASE + 0, 0x11111111)  # draw into back buffer
    await write(dut, CTRL_ADDR, 0b11)          # SWAP=1 request

    pending = await read(dut, STATUS_ADDR)
    assert pending & 1, "SWAP_PENDING did not set immediately after SWAP request"

    # Drive many cycles without ever reaching frame_start (H_COUNT_MAX=800,
    # V_COUNT_MAX=525 -- 700 *pixel-timing* advances guarantees staying
    # inside the same frame since the design starts post-reset at
    # h_count=v_count=0 and this many won't wrap V_COUNT_MAX*H_COUNT_MAX.
    # Each pixel-timing advance takes CLK_DIV clk edges, since h_count/
    # v_count only advance on pixel_en, not every clk edge.
    await run_cycles(dut, 700 * CLK_DIV)
    pending_mid = await read(dut, STATUS_ADDR)
    assert pending_mid & 1, "SWAP applied before frame_start (tearing risk)"

    # draw address should still read back the pre-swap back-buffer write
    # unchanged -- confirms nothing corrupted the back buffer while the
    # swap sits pending. (peek always maps to the OTHER buffer than draw,
    # so it reads the still-unswapped front buffer here, not this value --
    # checked separately below, after the swap actually lands.)
    still_pending_draw = await read(dut, DRAW_BASE + 0)
    assert still_pending_draw == 0x11111111, "back buffer contents changed before swap applied"

    # Run past a full frame (800*525 pixel-timing advances, each taking
    # CLK_DIV clk edges) so frame_start fires.
    await run_cycles(dut, 800 * 525 * CLK_DIV)
    pending_after = await read(dut, STATUS_ADDR)
    assert not (pending_after & 1), "SWAP_PENDING never cleared after a full frame"

    # Now the just-swapped-in front buffer should be readable via the draw
    # address's *peek* side (peek is always "the other buffer" from draw,
    # and front/back roles just flipped).
    swapped_visible = await read(dut, PEEK_BASE + 0)
    assert swapped_visible == 0x11111111, "swapped buffer contents not visible after frame_start"


@cocotb.test()
async def test_swap_noop_in_single_buffer_mode(dut):
    """A SWAP write while DOUBLE_BUF_EN=0 must be a no-op, not an error --
    SWAP_PENDING should never latch since there's no back buffer to bring
    forward."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await clear_buffers(dut)

    await write(dut, CTRL_ADDR, 0b10)  # DOUBLE_BUF_EN=0, SWAP=1
    pending = await read(dut, STATUS_ADDR)
    assert not (pending & 1), "SWAP_PENDING latched despite single-buffer mode"


@cocotb.test()
async def test_hsync_vsync_pulse_widths(dut):
    """hsync/vsync are active-low; hsync should be low for the first 96
    h_count cycles of each line, vsync low for the first 2 lines of each
    frame -- matches the module's own front/back-porch constants. h_count
    only advances once every CLK_DIV clk edges (pixel_en-gated), so the
    clk-edge window covering 96 h_count values is 96*CLK_DIV clk edges."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await clear_buffers(dut)

    low_count = 0
    for _ in range(96 * CLK_DIV):
        await RisingEdge(dut.clk)
        if int(dut.hsync.value) == 0:
            low_count += 1
    assert low_count == 96 * CLK_DIV, f"hsync low for {low_count}/{96 * CLK_DIV} expected cycles"

    # pixel_en is itself a registered divider output, so h_count's very
    # first advance after reset lags by one extra clk edge before the
    # steady CLK_DIV-cycle period kicks in -- give hsync's rise up to 2
    # extra edges of slack to account for that fixed startup latency.
    rose = False
    for _ in range(CLK_DIV):
        await RisingEdge(dut.clk)
        if int(dut.hsync.value) == 1:
            rose = True
            break
    assert rose, "hsync did not rise after the sync pulse window"

    assert int(dut.vsync.value) == 0, "vsync should still be low within the first 2 lines"
