# src/libc_port/crt0.S
# Startup stub for C programs built with -nostartfiles -- the bootloader's
# UART upload protocol always jumps to 0x1000 after a successful transfer
# (see bootloader.asm), so this is what runs first there. Sets up sp,
# zeroes .bss (newlib's malloc/globals assume zero-initialized statics),
# calls main, then falls into _exit on return.
#
# Register conventions: matches bootloader.asm (x1=ra, x2=sp).

.section .text
.globl _start
_start:
    li   sp, 0x00003FF0        # stack top, just under BRAM end (0x4000)

    la   t0, _bss_start
    la   t1, _bss_end
bss_clear:
    bge  t0, t1, bss_done
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    bss_clear
bss_done:

    call main                    # main's return value (a0) becomes exit's status
    call exit                    # exit() flushes stdio (_fwalk/__sflush_r)
                                 # before calling _exit -- calling _exit
                                 # directly here skipped that flush, so
                                 # buffered printf output never reached
                                 # _write/UART
