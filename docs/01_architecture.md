# High-level:

## Word size

## Endianness
- Little Endian

## Memory Map

| Base Address | End Address  | Size | Description          |
|--------------|--------------|------|----------------------|
| `0x00000000` | `0x00003FFF` | 16KB | DP BRAM (boot + program) |
| `0x10000000` | `0x10000000` | 4B   | UART TX data         |
| `0x10000004` | `0x10000004` | 4B   | UART RX data         |
| `0x10000008` | `0x10000008` | 4B   | UART status (bit 0 = TX_busy, bit 1 = RX_done) |
| `0x20000000` | `0x20000000` | 4B   | VGA_CTRL (bit0 = DOUBLE_BUF_EN, bit1 = SWAP) |
| `0x20000004` | `0x20000004` | 4B   | VGA_STATUS, read-only (bit0 = SWAP_PENDING) |
| `0x20001000` | `0x20001FFF` | 4KB page (2400B used) | VGA draw buffer -- fixed logical address, remapped internally by `vga_framebuffer.sv` to whichever physical buffer software should be drawing into (the scanned-out buffer in single-buffer mode, the back buffer in double-buffer mode) |
| `0x20002000` | `0x20002FFF` | 4KB page (2400B used) | VGA debug-peek buffer -- fixed logical address, always maps to the physical buffer NOT currently mapped at the draw address; lets `reg_debugger.py` READ_MEM inspect the other buffer regardless of mode |

### VGA framebuffer (`src/peripherals/vga_framebuffer.sv`)

160x120, 1bpp (monochrome), two physical buffers (double-buffer capable,
~2.4KB each / ~4.8KB total -- negligible against MAX10 10M50's ~200KB
M9K budget). Row-major, row stride 5 words (20B): pixel `(x,y)` -> word
`y*5 + x/32`, bit `x%32`. Self-contained module -- owns both physical
buffers, the draw/debug-peek address remapping, and VGA timing/scanout
internally; the top level only wires a slice of the dmem bus in (same
pattern as `uart_sel`/`debug_uart` today) plus `CLOCK_50`/hsync/vsync/rgb
out, no muxing logic lives in `riscv_top.sv` itself -- designed to be a
drop-in for other CPU-driven-VGA projects, not SoC-specific.

- **Single-buffer mode** (`DOUBLE_BUF_EN=0`): writes to the draw address
  hit the buffer currently being scanned out directly -- real-time,
  visible immediately, tearing possible. Useful for testing/quick
  iteration without waiting on a swap.
- **Double-buffer mode** (`DOUBLE_BUF_EN=1`): writes to the draw address
  hit the back buffer only. Writing `SWAP=1` requests a swap; the actual
  front/back flip is applied on the vsync edge that starts the next
  frame (never mid-scanout, so the swap itself can't tear), at which
  point `SWAP_PENDING` clears. Software's draw loop: draw into the back
  buffer, write `SWAP=1`, poll `SWAP_PENDING` until it clears, repeat.
- A `SWAP` write in single-buffer mode is a no-op (nothing to swap, not
  an error) -- lets software leave a `SWAP=1` write in place when
  toggling `DOUBLE_BUF_EN` without needing to special-case it.


## Register count

## Address space layout

## Interrupt model

## Target clock frequency