#ifndef CSR_H
#define CSR_H

// CSR access, trap constants and the machine timer for the RV32IM core.
// Code that includes this must be built with -march=rv32im_zicsr: GCC 12 and
// later no longer accept CSR instructions under plain rv32im.

#define read_csr(reg) ({ unsigned int __v; \
    __asm__ volatile ("csrr %0, " #reg : "=r"(__v)); __v; })
#define write_csr(reg, val) \
    __asm__ volatile ("csrw " #reg ", %0" :: "rK"(val))
#define set_csr(reg, bits) \
    __asm__ volatile ("csrs " #reg ", %0" :: "rK"(bits))
#define clear_csr(reg, bits) \
    __asm__ volatile ("csrc " #reg ", %0" :: "rK"(bits))

#define MSTATUS_MIE     0x00000008u
#define MSTATUS_MPIE    0x00000080u

#define MIE_MSIE        0x00000008u   // machine software interrupt (timer.v msip)
#define MIE_MTIE        0x00000080u   // machine timer interrupt
#define MIE_MEIE        0x00000800u   // machine external interrupt (UART RX)

#define MCAUSE_INTERRUPT        0x80000000u
#define MCAUSE_CODE(c)          ((c) & 0x7FFFFFFFu)

#define EXC_INST_MISALIGNED     0
#define EXC_INST_ACCESS         1
#define EXC_ILLEGAL_INST        2
#define EXC_BREAKPOINT          3
#define EXC_LOAD_MISALIGNED     4
#define EXC_STORE_MISALIGNED    6
#define EXC_ECALL_M             11

#define IRQ_M_SOFT              3
#define IRQ_M_TIMER             7
#define IRQ_M_EXT               11

// Machine timer (src/timer.v). mtime counts microseconds on the board.
#define TIMER_MSIP      ((volatile unsigned int *)0x80000100)
#define TIMER_CMP_LO    ((volatile unsigned int *)0x80000108)
#define TIMER_CMP_HI    ((volatile unsigned int *)0x8000010C)
#define TIMER_TIME_LO   ((volatile unsigned int *)0x80000110)
#define TIMER_TIME_HI   ((volatile unsigned int *)0x80000114)

static inline unsigned long long timer_now(void) {
    unsigned int hi, lo;
    do {                        // re-read if the low word wrapped in between
        hi = *TIMER_TIME_HI;
        lo = *TIMER_TIME_LO;
    } while (hi != *TIMER_TIME_HI);
    return ((unsigned long long)hi << 32) | lo;
}

// The timer interrupt is pending while mtime >= mtimecmp. Parking the low word
// at its maximum first keeps the half-written value from firing early.
static inline void timer_set_cmp(unsigned long long t) {
    *TIMER_CMP_LO = 0xFFFFFFFFu;
    *TIMER_CMP_HI = (unsigned int)(t >> 32);
    *TIMER_CMP_LO = (unsigned int)t;
}

#endif // CSR_H
