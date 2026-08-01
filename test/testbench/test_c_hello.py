# test/testbench/test_c_hello.py
#
# End-to-end smoke test for the new C toolchain (src/libc_port + src/apps):
# loads hello.bin (built via src/apps/Makefile) into BRAM at its actual
# load address (0x1000, past the 4KB bootloader region -- mirrors how the
# real bootloader jumps there after a UART upload, except here we place
# the program directly instead of running the upload handshake), lets the
# core run free (KEY[1] override, same pattern test_top.py's
# test_single_cycle_core_smoke uses), and decodes the program UART's TX
# byte stream to confirm hello.c's printf output actually appears --
# catching any crt0.S/link.ld mistake in simulation before a hardware
# round-trip.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import struct
import os

CLK_PER_BIT_EXT = 434  # same as test_top.py -- 25MHz internal clk, 115200 baud, CLOCK_50-relative

HELLO_BIN = os.path.join(os.path.dirname(__file__), "..", "..", "src", "apps", "build", "hello.bin")
LOAD_WORD_ADDR = 0x1000 // 4  # program load address per src/libc_port/link.ld
JAL_X0_0x1000 = 0x0000106f  # `jal x0, 0x1000` -- pc resets to 0 (see riscv_core.sv),
# and on real hardware the bootloader living at 0x0 is what jumps to 0x1000 after a
# UART upload; the test skips that upload step, so it must place this jump itself.


def set_key(dut, idx, bit):
    cur = int(dut.KEY.value)
    if bit:
        cur |= (1 << idx)
    else:
        cur &= ~(1 << idx)
    dut.KEY.value = cur


async def reset_top(dut, cycles=10):
    dut.KEY.value = 0b10
    dut.SW.value = 0
    dut.ext_rx.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.CLOCK_50)
    set_key(dut, 0, 1)
    await RisingEdge(dut.CLOCK_50)


async def recv_uart_bytes(dut, n_bytes, clk_per_bit=CLK_PER_BIT_EXT, timeout_ns=20_000_000):
    """Passively sample ext_tx (program UART TX, SW[0]=0) and decode 8N1
    bytes as they arrive, without assuming any particular idle framing --
    polls for a falling edge (start bit) each time, same shape as
    test_top.py's dbg_recv_byte. Each byte wait is capped at timeout_ns
    simulated time so a wiring/mux mistake or a program that never reaches
    printf fails the test with a clear timeout instead of spinning the
    simulator forever."""
    from cocotb.triggers import FallingEdge, with_timeout, SimTimeoutError
    out = bytearray()
    for _ in range(n_bytes):
        try:
            await with_timeout(FallingEdge(dut.ext_tx), timeout_ns, "ns")
        except SimTimeoutError:
            break
        await ClockCycles(dut.CLOCK_50, clk_per_bit + clk_per_bit // 2)
        value = 0
        for i in range(8):
            value |= (int(dut.ext_tx.value) << i)
            await ClockCycles(dut.CLOCK_50, clk_per_bit)
        out.append(value)
    return bytes(out)


@cocotb.test()
async def test_hello_c_prints(dut):
    """Load hello.bin at 0x1000, run free, confirm its printf output
    (via _write -> UART TX) shows up on the program UART."""
    assert os.path.exists(HELLO_BIN), (
        f"{HELLO_BIN} not found -- build it first: "
        f"cd src/apps && source ../../test/env.sh && make PROG=hello"
    )

    cocotb.start_soon(Clock(dut.CLOCK_50, 20, unit="ns").start())
    await reset_top(dut)

    with open(HELLO_BIN, "rb") as f:
        raw = f.read()
    while len(raw) % 4:
        raw += b"\x00"
    words = struct.unpack(f"<{len(raw)//4}I", raw)
    for i, w in enumerate(words):
        dut.u_bram.mem[LOAD_WORD_ADDR + i].value = w

    # pc resets to 0x0 (see riscv_core.sv) with nothing placed there --
    # jump straight to the loaded program, mimicking what the bootloader
    # would do after a real UART upload.
    dut.u_bram.mem[0].value = JAL_X0_0x1000

    # KEY[1]=0 forces the core to run regardless of debug_uart's
    # halt-on-reset default (same override test_halt_override exercises).
    set_key(dut, 1, 0)

    # hello.c prints 3 lines totalling under 60 bytes -- give generous
    # margin for setup/malloc/loop overhead before bytes start arriving.
    data = await recv_uart_bytes(dut, 60)

    text = data.decode("ascii", errors="replace")
    cocotb.log.info(f"UART TX captured: {text!r}")

    assert "hello from RV32IM" in text, f"missing greeting: {text!r}"
    assert "17 / 5 = 3" in text, f"division result wrong/missing: {text!r}"
    assert "17 % 5 = 2" in text, f"modulo result wrong/missing: {text!r}"
    assert "squares: 0 1 4 9" in text, f"malloc/free round-trip wrong/missing: {text!r}"

    cocotb.log.info("hello.c end-to-end PASSED")
