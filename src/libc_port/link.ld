/* src/libc_port/link.ld
 * Program load address 0x1000 matches the bootloader's fixed jump target
 * (bootloader.asm always jumps to 0x1000 after a successful UART upload).
 * Usable BRAM ends at 0x4000 (16KB dual-port BRAM, see docs/01_architecture.md).
 * _bss_start/_bss_end feed crt0.S's zero loop; end/_end feed newlib's
 * _sbrk heap cursor in syscalls.c.
 */

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00001000, LENGTH = 0x00003000
}

SECTIONS
{
    .text : {
        *(.text*)
    } > RAM

    .rodata : {
        *(.rodata*)
    } > RAM

    .data : {
        *(.data*)
    } > RAM

    .bss : {
        _bss_start = .;
        *(.bss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    . = ALIGN(4);
    end = .;
    _end = .;
}
