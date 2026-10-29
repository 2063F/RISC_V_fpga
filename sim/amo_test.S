# =============================================================================
# amo_test.S - Self-checking test for the A extension on one hart
# =============================================================================
# Run by sim/tb_amo.v. Covers every AMO*.W (result in rd and in memory,
# including the signed/unsigned edge cases of MIN/MAX), rd = x0, forwarding
# into the address and out of the result, and the LR.W/SC.W reservation rules
# that one hart can observe. Misaligned and reserved encodings are in
# trap_test.S; the two-hart cases are in examples/multicore_demo.c.
#
# Register conventions (as in trap_test.S):
#   s0 = checks passed    s1 = checks failed
#   s2 = number of the current check
#   s3 = number of the first failing check (0 = none)
#   gp = 0xD0E once everything has run (the testbench waits for it)
#
# Nothing here should trap; mtvec stays 0, so a trap restarts the program and
# the testbench times out.
#
# Rebuild:
#   riscv64-unknown-elf-gcc -march=rv32ima -mabi=ilp32 -nostdlib \
#     -T tools/link.ld sim/amo_test.S -o sim/amo_test.elf
#   riscv64-unknown-elf-objcopy -O binary sim/amo_test.elf sim/amo_test.bin
#   python tools/bin2hex.py sim/amo_test.bin > sim/amo_test.hex
# =============================================================================

# Compare two registers and count the result.
.macro EXPECT a, b
    addi s2, s2, 1
    beq  \a, \b, 1f
    addi s1, s1, 1
    bnez s3, 2f
    mv   s3, s2
    j    2f
1:  addi s0, s0, 1
2:
.endm

# Compare a register with a constant (clobbers t0).
.macro EXPECTI a, imm
    li   t0, \imm
    EXPECT \a, t0
.endm

# Compare the word at 0(a0) with a constant (clobbers t0, t1).
.macro EXPECT_MEM imm
    lw   t1, 0(a0)
    EXPECTI t1, \imm
.endm

    .section .text
    .globl _start
_start:
    li   s0, 0
    li   s1, 0
    li   s2, 0
    li   s3, 0
    li   a0, 0x10200

# -----------------------------------------------------------------------------
# 1. AMOs: rd gets the old word, memory the new one
# -----------------------------------------------------------------------------
    li   a1, 100
    sw   a1, 0(a0)
    li   a2, 5
    amoadd.w a1, a2, (a0)
    EXPECTI a1, 100
    EXPECT_MEM 105

    li   a2, 0x1234
    amoswap.w a1, a2, (a0)
    EXPECTI a1, 105
    EXPECT_MEM 0x1234

    li   a2, 0xFF00
    amoxor.w a1, a2, (a0)
    EXPECTI a1, 0x1234
    EXPECT_MEM 0xED34

    li   a2, 0x0F0F
    amoand.w a1, a2, (a0)
    EXPECTI a1, 0xED34
    EXPECT_MEM 0x0D04

    li   a2, 0xF000
    amoor.w a1, a2, (a0)
    EXPECTI a1, 0x0D04
    EXPECT_MEM 0xFD04

    # Signed MIN / MAX around zero
    li   a1, -5
    sw   a1, 0(a0)
    li   a2, 3
    amomin.w a1, a2, (a0)
    EXPECTI a1, -5
    EXPECT_MEM -5
    amomax.w a1, a2, (a0)
    EXPECTI a1, -5
    EXPECT_MEM 3
    li   a2, -7
    amomin.w a1, a2, (a0)
    EXPECTI a1, 3
    EXPECT_MEM -7
    li   a2, 0x7FFFFFFF
    amomax.w a1, a2, (a0)
    EXPECT_MEM 0x7FFFFFFF

    # Unsigned MIN / MAX: 0xFFFFFFF0 is large, not negative
    li   a1, 0xFFFFFFF0
    sw   a1, 0(a0)
    li   a2, 5
    amomaxu.w a1, a2, (a0)
    EXPECTI a1, 0xFFFFFFF0
    EXPECT_MEM 0xFFFFFFF0
    amominu.w a1, a2, (a0)
    EXPECTI a1, 0xFFFFFFF0
    EXPECT_MEM 5
    li   a2, 0x80000000
    amomaxu.w a1, a2, (a0)
    EXPECTI a1, 5
    EXPECT_MEM 0x80000000
    li   a2, 0x7FFFFFFF
    amominu.w a1, a2, (a0)
    EXPECT_MEM 0x7FFFFFFF

    # Signed again on the same bit patterns: 0x80000000 is the smallest
    li   a2, 0x80000000
    amomin.w a1, a2, (a0)
    EXPECT_MEM 0x80000000
    li   a2, -1
    amomax.w a1, a2, (a0)
    EXPECTI a1, 0x80000000
    EXPECT_MEM -1

# -----------------------------------------------------------------------------
# 2. rd = x0, forwarding, back-to-back
# -----------------------------------------------------------------------------
    li   a1, 10
    sw   a1, 0(a0)
    li   a2, 7
    amoadd.w x0, a2, (a0)           # result discarded, memory still updated
    EXPECT_MEM 17
    EXPECTI zero, 0

    li   a1, 40
    sw   a1, 4(a0)
    addi a3, a0, 4                  # address forwarded from the previous instruction
    amoadd.w a1, a2, (a3)
    addi a4, a1, 1                  # result forwarded to the next instruction
    EXPECTI a4, 41
    lw   t1, 4(a0)
    EXPECTI t1, 47

    li   a2, 1
    amoadd.w a1, a2, (a0)
    amoadd.w a1, a2, (a0)
    amoadd.w a1, a2, (a0)
    EXPECTI a1, 19
    lw   a4, 0(a0)                  # a plain load right after sees the new word
    EXPECTI a4, 20

    # Byte stores into an AMO'd word, and the AMO sees them
    li   a1, 0x11223344
    sw   a1, 0(a0)
    li   a2, 0xAA
    sb   a2, 1(a0)
    li   a2, 0
    amoor.w a1, a2, (a0)
    EXPECTI a1, 0x1122AA44

# -----------------------------------------------------------------------------
# 3. LR / SC
# -----------------------------------------------------------------------------
    li   a1, 0x55
    sw   a1, 0(a0)
    lr.w a1, (a0)
    EXPECTI a1, 0x55
    li   a2, 0x66
    sc.w a4, a2, (a0)
    EXPECTI a4, 0                   # stored
    EXPECT_MEM 0x66

    li   a2, 0x77
    sc.w a4, a2, (a0)               # the reservation went with the last SC
    EXPECTI a4, 1
    EXPECT_MEM 0x66

    # SC to another word than the LR fails, and still ends the reservation
    lr.w a1, (a0)
    addi a3, a0, 4
    sc.w a4, a2, (a3)
    EXPECTI a4, 1
    lw   t1, 4(a0)
    EXPECTI t1, 47
    sc.w a4, a2, (a0)
    EXPECTI a4, 1
    EXPECT_MEM 0x66

    # The latest LR is the one that counts
    addi a3, a0, 8
    sw   zero, 0(a3)
    lr.w a1, (a0)
    lr.w a1, (a3)
    sc.w a4, a2, (a0)
    EXPECTI a4, 1
    lr.w a1, (a3)
    sc.w a4, a2, (a3)
    EXPECTI a4, 0
    lw   t1, 0(a3)
    EXPECTI t1, 0x77

    # A typical LR/SC increment loop, result forwarded into the branch
    li   a5, 0
    sw   zero, 0(a0)
    li   a6, 10
1:  lr.w a1, (a0)
    addi a1, a1, 3
    sc.w a4, a1, (a0)
    bnez a4, 1b
    addi a5, a5, 1
    bne  a5, a6, 1b
    EXPECT_MEM 30

done:
    li   gp, 0xD0E
halt:
    j    halt
