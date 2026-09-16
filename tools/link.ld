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

    /* Scratch RAM is 0x0001_0000 - 0x0001_FFFF, so the stack starts one word
       past the top and grows down. This MUST stay 16-byte aligned: the CPU's
       data_memory ignores addr[1:0] on word accesses, so a misaligned sp
       silently corrupts every stack slot instead of trapping. */
    __stack_top = 0x00020000;
}
