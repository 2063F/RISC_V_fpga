/* =============================================================================
 * link.ld - Linker script for the RV32IM soft CPU
 * =============================================================================
 * Memory map implemented by the hardware:
 *   ROM (instruction_memory) 0x0000_0000 - 0x0000_7FFF   32 KB, loaded from *.hex
 *   RAM (data_memory)        0x0001_0000 - 0x0001_FFFF   64 KB, zero at power-up
 *
 * Only the ROM is initialised by the bitstream, so .data lives in RAM (VMA) but
 * its initial image is stored in ROM right behind .rodata (LMA). crt0.S copies
 * it across before calling main.
 * ========================================================================== */

ENTRY(_start)

__rom_start = 0x00000000;
__rom_end   = 0x00008000;
__ram_start = 0x00010000;
__ram_end   = 0x00020000;

SECTIONS {
    . = __rom_start;

    .text : {
        *(.text*)
        . = ALIGN(4);
    }

    .rodata : {
        *(.rodata*)
        *(.srodata*)
        . = ALIGN(4);
    }

    /* Load address of the .data image inside the ROM. */
    _data_lma = .;

    . = __ram_start;

    .data : AT(_data_lma) {
        _data_start = .;
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
    ASSERT(_bss_end <= __ram_end,
           "ERROR: .data + .bss do not fit in the 64 KB RAM")
}
