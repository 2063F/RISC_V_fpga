    .section .text
    .globl _start
    .type _start, @function

_start:
    # Every hart starts here. Only hart 0 sets up memory and runs main; the
    # others start later, once hart 0 lets them run (see src/cpu_top.v).
    # csrr t0, mhartid - spelled out so this file also assembles with
    # -march=rv32im, which has no Zicsr.
    .word 0xF14022F3
    bnez t0, _secondary

    # Set up the stack pointer.
    la sp, __stack_top

    # Copy the .data image from ROM (LMA) into RAM (VMA). Only the ROM is
    # initialised by the bitstream, so without this every global with a
    # non-zero initialiser would read back as whatever RAM powered up with.
    # With tools/link_mp.ld the image holds .rodata as well.
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

    # Any other hart: memory is already set up by hart 0 by the time it gets
    # here. Its stack sits mhartid * __hart_stack_size bytes below hart 0's
    # (the size must keep sp 16-byte aligned), and it runs
    # hart_main(mhartid).
_secondary:
    la   sp, __stack_top
    la   t1, __hart_stack_size
    mul  t1, t1, t0
    sub  sp, sp, t1
    mv   a0, t0
    call hart_main
1:
    jal x0, 1b

    .size _start, . - _start

    # Programs that never start another hart need no hart_main of their own.
    .weak hart_main
    .type hart_main, @function
hart_main:
1:
    jal x0, 1b
    .size hart_main, . - hart_main
