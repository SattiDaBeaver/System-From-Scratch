# Web-based hardware debugger

A local browser dashboard for the FPGA debug UART protocol
(`src/peripherals/debug_uart.sv`). Lets you halt/resume/step the core,
watch registers/PC update live, read memory, and flash a compiled
`.bin`/`.mif` program to it -- all from a browser tab instead of the
`reg_debugger_shell.py` text REPL.

Architecture: browsers can't open a serial port, so this is a 3-tier
setup -- browser (vanilla HTML/JS) <-WebSocket-> this Flask process
<-pyserial-> FPGA debug UART. `server.py` is a thin translation layer;
all protocol knowledge lives in `tools/reg_debugger.py`'s `RegDebugger`,
reused here unmodified.

**Local by default.** The server binds `127.0.0.1` unless you pass
`--host 0.0.0.0`, in which case it's reachable from other machines on
your network (e.g. a work laptop) at this host's IP -- same as any other
locally-run dashboard. There's no authentication on top of this, so only
do that on a network you trust; anyone who can reach it can halt/resume
the core, write memory, and flash a new program.

## Install

Inside the repo's activated `.venv` (per project convention, no system-wide
installs on this host):

```bash
source .venv/bin/activate
pip install -r tools/webdbg/requirements.txt
```

## Run

Against real hardware:

```bash
python tools/webdbg/server.py --port /dev/ttyUSB1
```

No hardware needed (logs sent/received bytes instead of opening a serial
port):

```bash
python tools/webdbg/server.py --dry-run
```

Then open http://127.0.0.1:5000 in a browser. Use `--http-port` to change
the local port, `--baud`/`--timeout` to override the serial settings
(defaults match `reg_debugger.py`'s `BAUD_RATE`/`TIMEOUT`). Add
`--host 0.0.0.0` to reach it from another machine on your network at
this host's IP instead of just localhost.

The connection panel's baud field (default 115200, matching
`debug_uart.sv`'s hardcoded `clk_per_bit`) overrides `--baud` per
connection -- no need to restart the server to change it. The manual
port field accepts either a Windows COM port (e.g. `COM3`) or a Linux
device path (e.g. `/dev/ttyUSB1`).

## Usage notes

- **Connection panel**: the server no longer has to hard-connect to one
  port at startup. `--port`/`--dry-run` on the command line still connect
  immediately (useful for a fixed dev setup), but you can also start the
  server with neither and pick a port from the browser instead: "Scan
  ports" lists what pyserial detects (`serial.tools.list_ports`), or type
  a device path manually, then hit Connect. Disconnect drops the serial
  connection without killing the server, and you can reconnect to a
  different port afterward -- useful if you're swapping between multiple
  boards on the same machine.
- The register table and PC update live while the core is resumed
  (polled at 10Hz -- `debug_uart.sv` has no way to push state
  unsolicited, so this is polling dressed up as streaming, not true
  hardware push). Each row shows one register (name/ABI name, hex, uint,
  int, ascii); toggle the "ABI names" checkbox to switch the name column
  between `x0`-style and ABI names (`zero`, `ra`, `sp`, ...).
- Registers that changed since the last poll briefly flash highlighted.
- The light/dark toggle (top-right) persists across reloads via
  `localStorage`.
- The memory panel (read) and flash panel (write/upload) only make sense
  while the core is halted, same restriction the wire protocol itself
  already enforces on hardware.
- **CSR panel**: "Read CSRs" pulls `mstatus`/`mie`/`mtvec`/`mscratch`/
  `mepc`/`mcause`/`mtval`/`mip` over the debug UART's `READ_CSR` command
  and fills the table (hex only -- these are bitfields, not general
  data). This is an explicit-pull button, not polled like the register
  table, since it's 8 extra serial round-trips at 115200 baud each click.
  Unlike memory/flash, CSR reads are *not* halt-gated -- the core can be
  running when you read them.
- **MMIO panel**: "Read MMIO" pulls the UART (`UART_TX`/`UART_RX`/
  `UART_STATUS`) and Timer (`TIMER_RELOAD`/`TIMER_CTRL`/`TIMER_STATUS`)
  registers over the debug UART's `READ_MMIO` command, same explicit-pull
  pattern as CSRs. This *is* halt-gated like memory reads. It's read-only
  peek -- no MMIO write support, since poking live UART/timer registers
  over the debug side-channel while a program depends on them has real
  side effects, unlike BRAM peek/poke which only touches program state.
  Reading `UART_RX`/`UART_STATUS` can itself perturb pending UART state
  (e.g. consume a byte the running program was about to read) -- treat
  this panel as a diagnostic snapshot, not a side-effect-free peek.
- **VGA reference table**: address-only reference (`VGA_CTRL`,
  `VGA_STATUS`, the draw buffer, and the debug-peek buffer), not a live
  read like the MMIO panel above it. VGA is deliberately excluded from
  the debug UART's `READ_MMIO`/`READ_MEM` muxes (`vga_sel` in
  `fpga/riscv_top.sv` is only ever derived from the live core's
  `dmem_addr`, never from `dbg_mmio_addr`/`dbg_mem_addr` -- see the
  comment block at `riscv_top.sv:166-170`), so there's no debug-side-
  channel command that can actually read these values on hardware; this
  table exists purely so code targeting VGA has the addresses on hand
  while writing it.
- Flash uploads a `.bin` or `.mif` file via the browser's File API,
  base64-encodes it client-side, and sends it over the WebSocket, where
  the server decodes it and calls `RegDebugger.load_program` -- the same
  WRITE_MEM-based path `reg_debugger.py load` / `--resume` already use.
- **Assembly IDE panel**: write RV32IM assembly directly in the browser,
  hit "Assemble" to run it through `riscv64-unknown-elf-{as,ld,objcopy,objdump}`
  server-side and show the resulting disassembly, or "Assemble + Flash"
  to also upload it over the debug UART and (optionally) resume --
  exactly the same `RegDebugger.load_program()` path the Flash panel
  above uses, just skipping the "build it externally, drag in a `.bin`"
  step. Links against `src/libc_port/link_dbg.ld` (`ORIGIN = 0x00000000`,
  no bootloader) -- there's no `crt0.S`/libc here, so your `.s` file is
  raw assembly responsible for its own setup and an infinite loop at the
  end, same convention as `test/asm_programs/*.asm`. "Assemble" alone
  works even while disconnected (no hardware touched); "Assemble +
  Flash" requires a connected port and, like the Flash panel, only makes
  sense while halted. Assembler/linker errors come back as readable
  stderr text in the log panel (`build_error`), not a stack trace.
  **Requires `riscv64-unknown-elf-{as,ld,objcopy,objdump}` on
  `server.py`'s own `PATH`** -- source `test/env.sh` (or otherwise add
  `/pkg/qct/software/sifive/gcc/centos/8.3.0/bin`) *before* starting
  `server.py`, since webdbg is normally launched outside `test/`'s
  sourcing dance and won't have the toolchain on `PATH` otherwise.
