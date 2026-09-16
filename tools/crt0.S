    .section .text
    .globl _start
    .type _start, @function

_start:
    # Set up the stack pointer.
    la sp, __stack_top

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
