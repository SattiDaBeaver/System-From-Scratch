# src/apps/Makefile
#
# Compile/link/upload flow for C programs targeting the RV32IM core.
# `make` (default) builds only; `make upload` sends an already-built
# .bin over the bootloader's program UART; `make flash` does both. See
# ../libc_port/README.md for the runtime this links against.
#
# Two independent upload paths, matching two independent linker scripts:
#   - upload/flash    -- program UART (tools/uart_loader.py), talks to
#                         bootloader.asm already running at 0x0000, which
#                         jumps to 0x1000 after transfer. Uses link.ld
#                         (ORIGIN=0x1000). Needs the bootloader image
#                         loaded first (see src/bootloader/build.sh).
#   - dbg-upload/dbg-flash -- debug UART (tools/reg_debugger.py load),
#                         writes straight into imem starting at 0x0000
#                         and resumes pc from there -- no bootloader
#                         involved. Uses link_dbg.ld (ORIGIN=0x0000).
# A .elf built with one linker script will NOT run correctly loaded via
# the other path's upload target -- PROG_BUILD below keeps their .elf/.bin
# outputs in separate build/ subdirs so `make dbg-flash` after `make flash`
# (or vice versa) can't silently upload a stale wrong-origin binary.
#
# Usage:
#   source ../../test/env.sh   # PATH to riscv64-unknown-elf-gcc
#   make PROG=hello
#   make PROG=hello flash PORT=/dev/ttyUSB0
#   make PROG=hello dbg-flash DBG_PORT=/dev/ttyUSB1

CC        = riscv64-unknown-elf-gcc
OBJCOPY   = riscv64-unknown-elf-objcopy
LIBC_PORT = ../libc_port

# newlib-nano (-specs=nano.specs, -lc_nano) instead of full newlib --
# full libc.a's printf pulls in float-formatting support that alone
# overflows the 12KB program region; nano trims that out.
#
# -march=rv32i (NOT rv32im): the core has MUL/MULH* but no DIV/REM (see
# docs/04_pipeline_plan.md), and the toolchain has no "M extension minus
# DIV" multilib -- GCC's rv32im/ilp32 multilib assumes the *whole* M
# extension is real hardware, so its prebuilt libc.a/libgcc.a use raw
# mul/div/rem opcodes directly (e.g. newlib's _printf_i digit-conversion
# loop uses divu/remu straight from source, not through a libgcc call --
# -mno-div only affects code WE compile fresh, not prebuilt library
# objects). Since this core silently no-ops on div/rem (unrecognized
# opcode falls into a default: ; case), every printf %d came out as 0.
# Dropping to rv32i/ilp32 makes GCC treat mul/div/rem alike: both compiled
# fresh and inside the prebuilt libc.a/libgcc.a, they're plain function
# calls into libgcc's software routines, matching what this hardware can
# actually execute. Costs hardware MUL performance for now -- acceptable
# per docs/00_manifesto.md (no perf work in v1).
CFLAGS  = -march=rv32i -mabi=ilp32 -O2 -ffreestanding -Wall \
          -specs=nano.specs -I$(LIBC_PORT)
LDFLAGS      = -nostartfiles -T$(LIBC_PORT)/link.ld
DBG_LDFLAGS  = -nostartfiles -T$(LIBC_PORT)/link_dbg.ld

PROG      ?= hello
SRC        = $(PROG).c
BUILD      = build/$(PROG)
DBG_BUILD  = build/$(PROG)_dbg
PORT      ?= /dev/ttyUSB0
DBG_PORT  ?= /dev/ttyUSB0
DBG       = ../../tools/reg_debugger.py

.PHONY: all upload flash dbg-build dbg-upload dbg-flash clean

all: $(BUILD).bin

$(BUILD).elf: $(SRC) $(LIBC_PORT)/crt0.S $(LIBC_PORT)/syscalls.c $(LIBC_PORT)/link.ld
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) $(LIBC_PORT)/crt0.S $(LIBC_PORT)/syscalls.c $(SRC) \
	    -lc_nano -lgcc -lnosys -o $@

$(BUILD).bin: $(BUILD).elf
	$(OBJCOPY) -O binary $< $@

upload: $(BUILD).bin
	python3 ../../tools/uart_loader.py $< --port $(PORT)

flash: all upload

# ── Debugger-direct path (no bootloader) ──
dbg-build: $(DBG_BUILD).bin

$(DBG_BUILD).elf: $(SRC) $(LIBC_PORT)/crt0.S $(LIBC_PORT)/syscalls.c $(LIBC_PORT)/link_dbg.ld
	@mkdir -p build
	$(CC) $(CFLAGS) $(DBG_LDFLAGS) $(LIBC_PORT)/crt0.S $(LIBC_PORT)/syscalls.c $(SRC) \
	    -lc_nano -lgcc -lnosys -o $@

$(DBG_BUILD).bin: $(DBG_BUILD).elf
	$(OBJCOPY) -O binary $< $@

# load leaves the core halted at pc=0x0000 (the WRITE_MEMs don't touch
# pc), so a resume after load is what actually starts the program --
# --resume does both in one debug-UART round trip.
dbg-upload: $(DBG_BUILD).bin
	python3 $(DBG) --port $(DBG_PORT) load $< --resume

dbg-flash: dbg-build dbg-upload

clean:
	rm -rf build
