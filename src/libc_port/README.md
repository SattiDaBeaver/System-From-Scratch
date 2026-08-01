# src/libc_port

Bare-metal C runtime support for compiling programs with
`riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -mno-div` and linking
against newlib, for upload via `tools/uart_loader.py` + `bootloader.asm`.

## Why `-mno-div`

The CPU (`src/riscv_core/riscv_core.sv` / `riscv_core_single_cycle.sv`)
implements the M-extension's multiply instructions (MUL/MULH/MULHSU/MULHU)
but not divide/remainder -- an undecoded `div`/`rem` opcode currently
falls into a silent `default: ;` case (no trap, no result, just nothing
happening). `-mno-div` makes GCC lower `/` and `%` to calls into libgcc's
software division routines (`__divsi3`, `__modsi3`, `__udivsi3`,
`__umodsi3`) instead of emitting the hardware opcode, so integer division
in C code is safe on this hardware today.

## Memory map recap (see `docs/01_architecture.md` for the full map)

- `0x00000000`-`0x00000FFF`: bootloader
- `0x00001000`-`0x00003FFF`: program + heap + stack (this is where
  `link.ld` places everything -- 12KB)
- `0x10000000`/`0x10000004`/`0x10000008`: UART TX/RX/status

## Files

- `crt0.S` -- `_start`: sets `sp`, zeroes `.bss`, calls `main`, then
  `_exit` on return. Entry point the bootloader jumps to at `0x1000`.
- `link.ld` -- places everything in the 12KB program region, defines
  `_bss_start`/`_bss_end` (for `crt0.S`) and `end`/`_end` (for `_sbrk`'s
  heap cursor).
- `syscalls.c` -- newlib syscall stubs. `_write` is the interesting one:
  it drives the same UART TX register/status-bit protocol
  `bootloader.asm`'s `uart_tx_byte` implements by hand, so `printf` output
  appears on the same UART used for program upload. `_sbrk` bumps a heap
  cursor starting at `end`. Everything else (`_close`/`_fstat`/`_isatty`/
  `_lseek`/`_read`/`_exit`) is a stub matching newlib's own
  bare-metal-port conventions -- there's no filesystem or OS underneath.

## Usage

Not built standalone -- see `src/apps/Makefile`, which compiles
`crt0.S`+`syscalls.c` alongside each program's `.c` file.
