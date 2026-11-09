/* link.ld - riscv-arch-test layout for this CPU
 *
 *   ROM 0x0000_0000 - 0x0000_7FFF  code, then the initial image of .data
 *   RAM 0x0001_0000 - 0x0001_7FFF  .data (test inputs, signature)
 *
 * RVMODEL_BOOT (model_test.h) copies the image into RAM.
 */
OUTPUT_ARCH(riscv)
ENTRY(rvtest_entry_point)

SECTIONS {
    . = 0x00000000;
    .text : {
        *(.text.init)
        *(.text*)
        . = ALIGN(4);
    }
    .rodata : {
        *(.rodata*)
        . = ALIGN(4);
    }
    _data_lma = .;

    . = 0x00010000;
    .data : AT(_data_lma) {
        _data_start = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _data_end = .;
    }
    .bss : {
        *(.bss*)
        *(.sbss*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.comment)
        *(.riscv.attributes)
    }

    ASSERT(_data_lma + (_data_end - _data_start) <= 0x8000,
           "code + data image does not fit in the 32 KB ROM")
    ASSERT(. <= 0x18000, "data does not fit in the 32 KB RAM")
}
