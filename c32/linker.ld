/* There is no executable loader: boot.asm copies raw bytes to 0x10000. The
 * linker's addresses must therefore agree exactly with that physical location. */
OUTPUT_FORMAT(elf32-i386)
OUTPUT_ARCH(i386)
ENTRY(stage2_start)

SECTIONS
{
    . = 0x10000;

    /* Must be first because boot.asm jumps to the first loaded byte. */
    .start : { KEEP(*(.start)) }
    .text  : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data : { *(.data .data.*) }

    /* NOBITS saves floppy space; entry.asm explicitly zeros this range. */
    __bss_start = .;
    .bss (NOLOAD) : {
        *(.bss .bss.*)
        *(COMMON)
    }
    __bss_end = .;

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame)
        *(.note*)
    }
}
