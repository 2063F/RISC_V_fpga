/* =============================================================================
 * link_mp.ld - Linker script for programs that start the second hart
 * =============================================================================
 * Same as link.ld, except that .rodata lives in RAM: once hart 1 runs, the
 * ROM's second port fetches its instructions and data loads from the ROM read
 * as 0 (see src/cpu_top.v). crt0.S copies .rodata into RAM together with .data,
 * before main runs and so before hart 1 can be started.
 *
 * Memory map implemented by the hardware:
 *   ROM (instruction_memory) 0x0000_0000 - 0x0000_7FFF   32 KB, loaded from *.hex
 *   RAM (data_memory)        0x0001_0000 - 0x0001_7FFF   32 KB, zero at power-up
 *
 * Only the ROM is initialised by the bitstream, so .rodata and .data live in
 * RAM (VMA) but their initial image is stored in ROM right behind .text (LMA).
 * crt0.S copies it across before calling main.
 *
 * Hart 0's stack starts at the top of RAM; hart h's starts h * __hart_stack_size
 * bytes below it.
 * ========================================================================== */

ENTRY(_start)

__rom_start = 0x00000000;
__rom_end   = 0x00008000;
__ram_start = 0x00010000;
__ram_end   = 0x00018000;

/* Stack size of each hart other than 0 (crt0.S). Only used by programs that
   start a second hart; override with -Wl,--defsym=__hart_stack_size=... */
PROVIDE(__hart_stack_size = 0x1000);

SECTIONS {
    . = __rom_start;

    .text : {
        *(.text*)
        . = ALIGN(4);
    }

    /* Load address of the .data (+ .rodata) image inside the ROM. */
    _data_lma = .;

    . = __ram_start;

    .data : AT(_data_lma) {
        _data_start = .;
        *(.rodata*)
        *(.srodata*)
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _data_end = .;
    }

    .bss : {
        . = ALIGN(4);
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        *(.scommon)
        . = ALIGN(4);
        _bss_end = .;
    }

    /* Left alone by crt0.S, so it survives a reset (S1) as long as the board
       stays powered. Contents are garbage at power-up - validate before use. */
    .noinit (NOLOAD) : {
        . = ALIGN(4);
        *(.noinit*)
        . = ALIGN(4);
        _noinit_end = .;
    }

    /* The stack starts one word past the top of RAM and grows down. This MUST
       stay 16-byte aligned: the CPU's data_memory ignores addr[1:0] on word
       accesses, so a misaligned sp silently corrupts every stack slot instead
       of trapping. */
    __stack_top = __ram_end;

    /DISCARD/ : {
        *(.comment)
        *(.riscv.attributes)
    }

    ASSERT(_data_lma + (_data_end - _data_start) <= __rom_end,
           "ERROR: .text + .rodata + .data image does not fit in the 32 KB ROM")
    ASSERT(_noinit_end <= __ram_end - 2 * __hart_stack_size,
           "ERROR: .rodata + .data + .bss leave no room for two hart stacks in the 32 KB RAM")
}
