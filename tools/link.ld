ENTRY(_start)

SECTIONS {
    . = 0x00000000;
    .text : {
        *(.text*)
    }

    .rodata : {
        *(.rodata*)
    }

    . = 0x00010000;
    .data : {
        *(.data*)
    }

    .bss : {
        . = ALIGN(4);
        _bss_start = .;
        *(.bss*)
        *(COMMON);
        . = ALIGN(4);
        _bss_end = .;
    }

    __stack_top = 0x0001FFFF;
}
