// trap_demo.c - Exceptions, timer interrupt and UART receive interrupt
//
// 1. Raises an ECALL and an illegal instruction; the trap handler reports each
//    one and resumes after it.
// 2. Toggles led[1] from a timer interrupt every 500 ms and prints a tick line.
// 3. Echoes each received UART character from the external interrupt.
//
// Build with -march=rv32im_zicsr (see README).

#include "uart.h"
#include "csr.h"

#define TICK_US   500000u
#define LED_CTRL  ((volatile unsigned int *)0x80000020)

static unsigned long long next_tick;
static volatile unsigned int ticks;
static volatile int rx_char = -1;

// GCC's interrupt attribute saves every register the handler touches and
// returns with mret, so the handler can be plain C.
void __attribute__((interrupt("machine"))) trap_handler(void) {
    unsigned int cause = read_csr(mcause);

    if (cause & MCAUSE_INTERRUPT) {
        switch (MCAUSE_CODE(cause)) {
        case IRQ_M_TIMER:
            next_tick += TICK_US;
            timer_set_cmp(next_tick);
            ticks++;
            *LED_CTRL = ticks & 1;
            break;
        case IRQ_M_EXT:
            rx_char = *UART_RX_DATA;    // reading the byte clears the interrupt
            break;
        default:
            break;
        }
    } else {
        unsigned int epc = read_csr(mepc);
        printf("  trap: mcause=%u mepc=0x%x mtval=0x%x\n",
               cause, epc, read_csr(mtval));
        write_csr(mepc, epc + 4);       // skip the faulting instruction
    }
}

int main(void) {
    printf("=== CSR / trap / interrupt demo ===\n");
    write_csr(mtvec, (unsigned int)trap_handler);
    printf("misa=0x%x mhartid=%u\n", read_csr(misa), read_csr(mhartid));

    printf("ecall:\n");
    __asm__ volatile ("ecall");
    printf("illegal instruction:\n");
    __asm__ volatile (".word 0x00000000");

    next_tick = timer_now() + TICK_US;
    timer_set_cmp(next_tick);
    set_csr(mie, MIE_MTIE | MIE_MEIE);
    set_csr(mstatus, MSTATUS_MIE);
    printf("interrupts on\n");

    unsigned int seen = 0;
    while (1) {
        __asm__ volatile ("wfi");
        if (ticks != seen) {
            seen = ticks;
            printf("tick %u\n", seen);
        }
        if (rx_char >= 0) {
            int c = rx_char;
            rx_char = -1;
            printf("rx '%c'\n", c);
        }
    }
}
