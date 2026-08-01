/* src/libc_port/link_dbg.ld
 * Variant of link.ld for programs loaded directly via the debug UART
 * (tools/reg_debugger.py load), bypassing the bootloader entirely --
 * reg_debugger.py's WRITE_MEM writes start at imem base (0x0000) and
 * `resume`/`step` continue from wherever pc already sits after reset,
 * which is 0x0000, not the bootloader's fixed 0x1000 jump target. So
 * programs meant for this path must be linked to run from 0x0000, not
 * 0x1000 like link.ld's bootloader-relative programs.
 *
 * Whole 16KB BRAM (0x0000-0x3FFF) is usable here since there's no
 * bootloader occupying the low end of the region.
 */

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00004000
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
