# =============================================================================
# loop55.S - sum 1..10 into x1 (= 55), then halt
# =============================================================================
# fpga_top lights led[1] when debug_x1 (= x1) reaches 55, and tb_fpga_top /
# tb_branch check the same thing, so the result must land in x1 specifically.
# loop55.c cannot be used for this: at -O2 the accumulator is dead code and
# gcc deletes the whole loop, and nothing pins the result to x1 anyway.
# Hand-written assembly is therefore the source of truth for loop55.hex.
# =============================================================================

    .section .text
    .globl _start

_start:
    addi  x1, x0, 0         # sum   = 0
    addi  x2, x0, 1         # i     = 1
    addi  x3, x0, 11        # limit = 11
loop:
    add   x1, x1, x2        # sum  += i
    addi  x2, x2, 1         # i++
    blt   x2, x3, loop      # while (i < 11)
    nop                     # x1 = 55, x2 = 11
