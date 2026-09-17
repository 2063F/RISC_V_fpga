    .section .text
    .globl _start
    .type _start, @function

_start:
    # Set up the stack pointer.
    la sp, __stack_top

    # Copy the .data image from ROM (LMA) into RAM (VMA). Only the ROM is
    # initialised by the bitstream, so without this every global with a
    # non-zero initialiser would read back as whatever RAM powered up with.
    la t0, _data_lma
    la t1, _data_start
    la t2, _data_end
1:
    bgeu t1, t2, 2f
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b
2:

    # Zero out the .bss section.
    la t0, _bss_start
    la t1, _bss_end
1:
    bgeu t0, t1, 2f
    sw x0, 0(t0)
    addi t0, t0, 4
    j 1b
2:

    # Run the C entry point.
    call main

    # If main returns, halt in a tight loop.
1:
    jal x0, 1b

    .size _start, . - _start
