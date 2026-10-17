# =============================================================================
# trap_test.S - Self-checking test for CSRs, exceptions and interrupts
# =============================================================================
# Run by sim/tb_trap.v with TIMER_DIV = 1 (mtime advances every clock).
#
# Register conventions (this is a test, not ABI code):
#   s0  = checks passed          s1 = checks failed
#   s2  = number of the current check
#   s3  = number of the first failing check (0 = none)
#   s10 = 0x10000, base of the trap record written by the handler:
#           +0 mcause  +4 mepc  +8 mtval  +12 mstatus at entry
#           +16 byte read by the UART interrupt   +20 vector marker
#           +24 "ready for UART byte" flag
#   s11 = number of traps taken
#   t3-t6 belong to the trap handlers; the test code never uses them.
#   gp  = 0xD0E once everything has run (the testbench waits for it)
#
# Rebuild:
#   riscv64-unknown-elf-gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib \
#     -T tools/link.ld sim/trap_test.S -o sim/trap_test.elf
#   riscv64-unknown-elf-objcopy -O binary sim/trap_test.elf sim/trap_test.bin
#   python tools/bin2hex.py sim/trap_test.bin > sim/trap_test.hex
# =============================================================================

    .equ MSIP,       0x80000100
    .equ MTIMECMP,   0x80000108
    .equ MTIMECMPH,  0x8000010C
    .equ MTIME,      0x80000110
    .equ UART_RX,    0x80000018

    .equ MIE_MSIE,   0x008
    .equ MIE_MTIE,   0x080
    .equ MIE_MEIE,   0x800

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

# Check the last trap record: mcause and mepc (label).
.macro EXPECT_TRAP cause, pc_label
    lw   a4, 0(s10)
    EXPECTI a4, \cause
    lw   a4, 4(s10)
    la   a5, \pc_label
    EXPECT a4, a5
.endm

    .section .text
    .globl _start
_start:
    li   s0, 0
    li   s1, 0
    li   s2, 0
    li   s3, 0
    li   s10, 0x10000
    li   s11, 0
    la   t0, trap_entry
    csrw mtvec, t0

# -----------------------------------------------------------------------------
# 1. CSR instructions
# -----------------------------------------------------------------------------
    li   a0, 0x12345678
    csrw mscratch, a0
    csrr a1, mscratch
    EXPECT a1, a0

    li   a0, 0x0000F0F0
    csrrs a1, mscratch, a0          # old value back, then set bits
    EXPECTI a1, 0x12345678
    csrr a1, mscratch
    EXPECTI a1, 0x1234F6F8
    csrrc a1, mscratch, a0          # clear bits
    csrr a1, mscratch
    EXPECTI a1, 0x12340608

    csrrwi a1, mscratch, 21
    EXPECTI a1, 0x12340608
    csrrsi a1, mscratch, 8          # 21 | 8 = 29
    csrrci a1, mscratch, 1          # 29 & ~1 = 28
    EXPECTI a1, 29
    csrr a1, mscratch
    EXPECTI a1, 28

    csrrw a1, mscratch, x0          # CSR value forwarded to the next instruction
    addi a2, a1, 1
    EXPECTI a2, 29

    csrr a1, misa
    EXPECTI a1, 0x40001100
    csrw misa, x0                   # WARL: ignored, no trap
    csrr a1, misa
    EXPECTI a1, 0x40001100
    csrr a1, mhartid
    EXPECTI a1, 0
    csrr a1, mstatus
    EXPECTI a1, 0x1800              # MPP = M, MIE = MPIE = 0
    csrr a1, mtvec
    la   a2, trap_entry
    EXPECT a1, a2
    EXPECTI s11, 0                  # nothing above may trap

# -----------------------------------------------------------------------------
# 2. ECALL / EBREAK
# -----------------------------------------------------------------------------
t_ecall:
    ecall
    EXPECT_TRAP 11, t_ecall
    EXPECTI s11, 1
    lw   a4, 12(s10)
    EXPECTI a4, 0x1800              # trap from MIE = 0: MPIE = 0
t_ebreak:
    ebreak
    EXPECT_TRAP 3, t_ebreak

# -----------------------------------------------------------------------------
# 3. Illegal instructions (mtval = the instruction)
# -----------------------------------------------------------------------------
t_ill_zero:
    .word 0x00000000
    EXPECT_TRAP 2, t_ill_zero
    lw   a4, 8(s10)
    EXPECTI a4, 0

t_ill_ones:
    .word 0xFFFFFFFF
    EXPECT_TRAP 2, t_ill_ones
    lw   a4, 8(s10)
    EXPECTI a4, 0xFFFFFFFF

    li   a1, 0x55
t_ill_csr:
    csrr a1, 0x7C0                  # unimplemented CSR
    EXPECT_TRAP 2, t_ill_csr
    EXPECTI a1, 0x55                # rd untouched
    lw   a4, 8(s10)
    la   a5, t_ill_csr
    lw   a5, 0(a5)                  # the encoding, read back from ROM
    EXPECT a4, a5

t_ill_ro:
    csrw cycle, a0                  # write to a read-only CSR
    EXPECT_TRAP 2, t_ill_ro
    mv   a6, s11
    csrr a1, cycle                  # reading it is fine
    EXPECT s11, a6

t_ill_rvc:
    .word 0x00010001                # two c.nop: compressed is not supported
    EXPECT_TRAP 2, t_ill_rvc

t_ill_sret:
    .word 0x10200073                # sret: no supervisor mode
    EXPECT_TRAP 2, t_ill_sret

    li   a1, 0x55
t_ill_funct7:
    .word 0x040005B3                # "add a1, x0, x0" with funct7 = 0000010
    EXPECT_TRAP 2, t_ill_funct7
    EXPECTI a1, 0x55

# -----------------------------------------------------------------------------
# 4. Misaligned loads and stores
# -----------------------------------------------------------------------------
    li   a0, 0x10100
    li   a1, 0xAABBCCDD
    sw   a1, 0(a0)

    li   a0, 0x10101
    li   a1, 0x77
t_lw_mis:
    lw   a1, 0(a0)
    EXPECT_TRAP 4, t_lw_mis
    lw   a4, 8(s10)
    EXPECTI a4, 0x10101
    EXPECTI a1, 0x77

    li   a0, 0x10103
t_sh_mis:
    sh   a1, 0(a0)
    EXPECT_TRAP 6, t_sh_mis
    lw   a4, 8(s10)
    EXPECTI a4, 0x10103
    li   a0, 0x10100
    lw   a1, 0(a0)
    EXPECTI a1, 0xAABBCCDD          # the store did not happen

    mv   a6, s11
    lhu  a1, 2(a0)                  # aligned halfword, odd byte: no trap
    lbu  a2, 3(a0)
    EXPECT s11, a6
    EXPECTI a1, 0xAABB
    EXPECTI a2, 0xAA

# -----------------------------------------------------------------------------
# 5. Misaligned jump and branch targets
# -----------------------------------------------------------------------------
    la   t1, jump_target
    li   a1, 0x66
t_jalr_mis:
    jalr a1, 2(t1)                  # target jump_target + 2
    j    1f
jump_target:
    nop
    nop
1:
    EXPECT_TRAP 0, t_jalr_mis
    EXPECTI a1, 0x66                # link register untouched
    lw   a4, 8(s10)
    addi a5, t1, 2
    EXPECT a4, a5

t_jal_mis:
    .word 0x006005EF                # jal a1, .+6
    nop
    nop
    EXPECT_TRAP 0, t_jal_mis

    mv   a6, s11
    .word 0x00001363                # bne x0, x0, .+6: not taken, no trap
    EXPECT s11, a6
t_beq_mis:
    .word 0x00000363                # beq x0, x0, .+6: taken
    nop
    nop
    EXPECT_TRAP 0, t_beq_mis
    lw   a4, 8(s10)
    la   a5, t_beq_mis
    addi a5, a5, 6
    EXPECT a4, a5

# -----------------------------------------------------------------------------
# 6. Instruction access fault (fetch outside the ROM)
# -----------------------------------------------------------------------------
    li   t0, 0x8000
    jalr ra, 0(t0)                  # the handler returns to ra
    lw   a4, 0(s10)
    EXPECTI a4, 1
    lw   a4, 4(s10)
    EXPECTI a4, 0x8000
    lw   a4, 8(s10)
    EXPECTI a4, 0x8000

# -----------------------------------------------------------------------------
# 7. FENCE, FENCE.I and WFI are no-ops
# -----------------------------------------------------------------------------
    mv   a6, s11
    fence
    fence.i
    wfi
    EXPECT s11, a6

# -----------------------------------------------------------------------------
# 8. Counters
# -----------------------------------------------------------------------------
    rdcycle a0
    rdcycle a1
    sub  a2, a1, a0
    EXPECTI a2, 1

    rdinstret a0
    nop
    nop
    nop
    rdinstret a1
    sub  a2, a1, a0
    EXPECTI a2, 4

    rdtime a0                       # TIMER_DIV = 1: one tick per clock
    nop
    rdtime a1
    sub  a2, a1, a0
    EXPECTI a2, 2

    csrw mcycle, x0
    csrr a0, mcycle
    EXPECTI a0, 0
    csrw minstret, x0
    csrr a0, minstret
    EXPECTI a0, 0

# -----------------------------------------------------------------------------
# 9. Timer interrupt: masked by mstatus.MIE, then taken
# -----------------------------------------------------------------------------
    li   t0, MTIMECMPH
    sw   zero, 0(t0)
    li   t0, MTIMECMP
    sw   zero, 0(t0)                # mtimecmp = 0: pending right away
    li   t0, MIE_MTIE
    csrw mie, t0
    nop
    nop
    csrr a0, mip
    andi a0, a0, MIE_MTIE
    EXPECTI a0, MIE_MTIE            # pending...
    mv   a6, s11
    EXPECT s11, a6                  # ...but not taken while MIE = 0

    csrsi mstatus, 8
t_timer_irq:
    nop                             # interrupted before this executes
    EXPECT_TRAP 0x80000007, t_timer_irq
    lw   a4, 12(s10)
    EXPECTI a4, 0x1880              # at entry: MIE = 0, MPIE = 1
    csrr a0, mstatus
    EXPECTI a0, 0x1888              # MRET restored MIE
    csrci mstatus, 8

# -----------------------------------------------------------------------------
# 10. Software interrupt
# -----------------------------------------------------------------------------
    li   t0, MIE_MSIE
    csrw mie, t0
    csrsi mstatus, 8
    li   t1, MSIP
    li   t0, 1
    sw   t0, 0(t1)
t_soft_irq:
    nop
    EXPECT_TRAP 0x80000003, t_soft_irq
    lw   a0, 0(t1)
    EXPECTI a0, 0                   # handler cleared msip
    csrci mstatus, 8

# -----------------------------------------------------------------------------
# 11. Vectored mtvec
# -----------------------------------------------------------------------------
    la   t0, vec_table
    ori  t0, t0, 1
    csrw mtvec, t0
    csrsi mstatus, 8
    li   t1, MSIP
    li   t0, 1
    sw   t0, 0(t1)                  # MSI -> vec_table + 4*3
t_vec_soft:
    nop
    EXPECT_TRAP 0x80000003, t_vec_soft
    lw   a4, 20(s10)
    EXPECTI a4, 0x53
t_vec_ecall:
    ecall                           # exceptions -> vec_table + 0
    EXPECT_TRAP 11, t_vec_ecall
    lw   a4, 20(s10)
    EXPECTI a4, 0xE0
    csrci mstatus, 8
    la   t0, trap_entry
    csrw mtvec, t0

# -----------------------------------------------------------------------------
# 12. Timer interrupts landing on loads, stores, multiplies and divides
# -----------------------------------------------------------------------------
    la   t0, stress_handler
    csrw mtvec, t0
    li   s11, 0
    li   t0, MTIMECMPH
    sw   zero, 0(t0)
    li   t0, MTIME
    lw   t1, 0(t0)
    addi t1, t1, 37
    li   t0, MTIMECMP
    sw   t1, 0(t0)
    li   t0, MIE_MTIE
    csrw mie, t0
    csrsi mstatus, 8

    li   a7, 0                      # mismatches
    li   a6, 200                    # iterations
    li   a0, 1000003
    li   a1, 7
    li   a3, 0x10200
stress_loop:
    div  a2, a0, a1
    rem  a4, a0, a1
    mul  a5, a2, a1
    add  a5, a5, a4
    beq  a5, a0, 1f
    addi a7, a7, 1
1:  sw   a6, 0(a3)
    lw   a5, 0(a3)
    beq  a5, a6, 2f
    addi a7, a7, 1
2:  li   a5, 142857
    beq  a2, a5, 3f
    addi a7, a7, 1
3:  addi a6, a6, -1
    bnez a6, stress_loop

    csrci mstatus, 8
    EXPECTI a7, 0
    sltiu a0, s11, 20               # at least 20 interrupts landed
    EXPECTI a0, 0

# -----------------------------------------------------------------------------
# 13. UART receive as the machine external interrupt
# -----------------------------------------------------------------------------
    la   t0, trap_entry
    csrw mtvec, t0
    li   t0, MIE_MEIE
    csrw mie, t0
    csrsi mstatus, 8
    li   t0, 1
    sw   t0, 24(s10)                # tell the testbench to send a byte
1:  lw   a0, 16(s10)
    beqz a0, 1b
    csrci mstatus, 8
    EXPECTI a0, 0x4B                # 'K'
    lw   a4, 0(s10)
    EXPECTI a4, 0x8000000B

# -----------------------------------------------------------------------------
done:
    li   gp, 0xD0E
halt:
    j    halt

# =============================================================================
# Trap handlers
# =============================================================================
# Records the trap, then returns past the faulting instruction (or to ra for a
# fetch fault, whose mepc is not code). Interrupts are cleared at the source.
trap_entry:
    csrr t3, mcause
    csrr t4, mepc
    csrr t5, mtval
    csrr t6, mstatus
    sw   t3, 0(s10)
    sw   t4, 4(s10)
    sw   t5, 8(s10)
    sw   t6, 12(s10)
    addi s11, s11, 1
    bltz t3, trap_irq
    li   t6, 1
    beq  t3, t6, trap_ret_ra
    addi t4, t4, 4
    csrw mepc, t4
    mret
trap_ret_ra:
    csrw mepc, ra
    mret

trap_irq:
    slli t3, t3, 1
    srli t3, t3, 1
    li   t6, 7
    beq  t3, t6, trap_timer
    li   t6, 3
    beq  t3, t6, trap_soft
    li   t6, UART_RX                # external: take the byte
    lw   t5, 0(t6)
    sw   t5, 16(s10)
    mret
trap_timer:
    li   t6, MTIMECMPH              # push mtimecmp out of reach
    li   t5, -1
    sw   t5, 0(t6)
    mret
trap_soft:
    li   t6, MSIP
    sw   zero, 0(t6)
    mret

# Re-arms the timer 37 ticks ahead and counts.
stress_handler:
    li   t6, MTIME
    lw   t5, 0(t6)
    addi t5, t5, 37
    li   t6, MTIMECMP
    sw   t5, 0(t6)
    addi s11, s11, 1
    mret

    .balign 64
vec_table:
    j    vec_exc                    # 0: all exceptions
    j    trap_entry
    j    trap_entry
    j    vec_soft                   # 3: machine software interrupt
    j    trap_entry
    j    trap_entry
    j    trap_entry
    j    trap_entry                 # 7: machine timer interrupt
    j    trap_entry
    j    trap_entry
    j    trap_entry
    j    trap_entry                 # 11: machine external interrupt
vec_exc:
    li   t3, 0xE0
    sw   t3, 20(s10)
    j    trap_entry
vec_soft:
    li   t3, 0x53
    sw   t3, 20(s10)
    j    trap_entry
