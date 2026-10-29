// multicore_demo.c - Two harts sharing the RAM
//
// Hart 0 starts hart 1, and then:
//   1. Both harts fill and sum an array of their own at the same time, so the
//      data bus is busy from both sides. Hart 0 checks hart 1's result.
//   2. Hart 1 checksums a string from .rodata (which link_mp.ld puts in RAM).
//   3. Ping-pong: the harts take turns bumping two counters, each written by
//      only one hart, 1000 times. Any lost or reordered access would hang it
//      or leave the counters apart.
//   4. Both harts update shared counters at the same time, ROUNDS times each:
//      with AMOADD, with an LR/SC loop, and with plain loads and stores
//      inside a spinlock built on AMOSWAP. Every update must count.
//   5. Hart 0 interrupts hart 1 through hart 1's msip (software interrupt).
// Only hart 0 prints.
//
// Build with tools/link_mp.ld and -march=rv32ima_zicsr (see README).

#include "uart.h"
#include "csr.h"
#include "mp.h"

#define N       256
#define ROUNDS  1000

static unsigned int array0[N];
static unsigned int array1[N];

static const char message[] = "two harts, one bus";

static volatile unsigned int sum1;
static volatile unsigned int checksum1;
static volatile unsigned int ping;          // written by hart 0 only
static volatile unsigned int pong;          // written by hart 1 only
static volatile unsigned int hart1_stage;   // written by hart 1 only
static volatile unsigned int ipi_count;     // written by hart 1 only
static volatile unsigned int go;            // written by hart 0 only

// Written by both harts
static unsigned int amo_counter;
static unsigned int lrsc_counter;
static volatile unsigned int locked_counter;
static unsigned int lock;

static void spin_lock(unsigned int *l) {
    while (__atomic_exchange_n(l, 1, __ATOMIC_ACQUIRE))
        ;
}

static void spin_unlock(unsigned int *l) {
    __atomic_store_n(l, 0, __ATOMIC_RELEASE);
}

// counter += 1 with an LR/SC retry loop.
static void lrsc_increment(unsigned int *counter) {
    unsigned int value, failed;
    __asm__ volatile (
        "1: lr.w  %0, (%2)\n"
        "   addi  %0, %0, 1\n"
        "   sc.w  %1, %0, (%2)\n"
        "   bnez  %1, 1b\n"
        : "=&r"(value), "=&r"(failed) : "r"(counter) : "memory");
}

// A few cycles of delay that differ per hart and per round. Without it the
// two harts settle into a fixed rhythm in which their LR/SC windows never
// overlap, and the reservation logic would go untested.
static void jitter(unsigned int hartid, unsigned int i) {
    unsigned int n = (i ^ (i >> 2)) & (hartid ? 3 : 1);
    while (n--)
        __asm__ volatile ("nop");
}

// The three ways of updating a shared counter, ROUNDS times each. Each runs
// as a loop of its own so that the harts collide on it as often as possible.
static void shared_updates(unsigned int hartid) {
    for (unsigned int i = 0; i < ROUNDS; i++)
        __atomic_fetch_add(&amo_counter, 1, __ATOMIC_RELAXED);      // amoadd.w

    for (unsigned int i = 0; i < ROUNDS; i++) {
        lrsc_increment(&lrsc_counter);                              // lr.w / sc.w
        jitter(hartid, i);
    }

    for (unsigned int i = 0; i < ROUNDS; i++) {
        spin_lock(&lock);                                           // amoswap.w
        locked_counter = locked_counter + 1;                        // lw / sw
        spin_unlock(&lock);
    }
}

static unsigned int fill_and_sum(unsigned int *a, unsigned int mul, unsigned int add) {
    unsigned int s = 0;
    for (unsigned int i = 0; i < N; i++)
        a[i] = i * mul + add;
    for (unsigned int i = 0; i < N; i++)
        s += a[i];
    return s;
}

static unsigned int checksum(const char *s) {
    unsigned int h = 5381;
    while (*s)
        h = h * 33 + (unsigned char)*s++;
    return h;
}

void __attribute__((interrupt("machine"))) hart1_trap(void) {
    if (read_csr(mcause) == (MCAUSE_INTERRUPT | IRQ_M_SOFT)) {
        send_ipi(1, 0);                 // clear our own msip
        ipi_count = ipi_count + 1;
    }
}

void hart_main(unsigned int hartid) {
    (void)hartid;

    sum1 = fill_and_sum(array1, 7, 3);
    checksum1 = checksum(message);
    hart1_stage = 1;

    for (unsigned int i = 0; i < ROUNDS; i++) {
        while (ping == pong)
            ;
        pong = pong + 1;
    }
    hart1_stage = 2;

    while (!go)                     // start together with hart 0
        ;
    shared_updates(1);
    hart1_stage = 3;

    write_csr(mtvec, (unsigned int)hart1_trap);
    set_csr(mie, MIE_MSIE);
    set_csr(mstatus, MSTATUS_MIE);
    hart1_stage = 4;

    for (;;)
        ;
}

static int failures;

static void report(const char *what, unsigned int got, unsigned int want) {
    printf("%s: %u ", what, got);
    if (got == want) {
        printf("ok\n");
    } else {
        printf("FAIL (want %u)\n", want);
        failures++;
    }
}

int main(void) {
    printf("=== multicore demo ===\n");
    printf("hart 0 starts hart 1\n");
    hart_start(1);

    unsigned int sum0 = fill_and_sum(array0, 5, 1);
    while (hart1_stage < 1)
        ;

    unsigned int want1 = 0;
    for (unsigned int i = 0; i < N; i++)
        want1 += i * 7 + 3;
    report("sum0", sum0, N * (N - 1) / 2 * 5 + N);
    report("sum1", sum1, want1);
    report("array1[N-1]", array1[N - 1], (N - 1) * 7 + 3);
    report("checksum", checksum1, checksum(message));

    for (unsigned int i = 0; i < ROUNDS; i++) {
        while (pong != ping)
            ;
        ping = ping + 1;
    }
    while (hart1_stage < 2)
        ;
    report("ping-pong", pong, ROUNDS);

    go = 1;
    shared_updates(0);
    while (hart1_stage < 3)
        ;
    report("amoadd", amo_counter, 2 * ROUNDS);
    report("lr/sc", lrsc_counter, 2 * ROUNDS);
    report("spinlock", locked_counter, 2 * ROUNDS);

    while (hart1_stage < 4)
        ;
    send_ipi(1, 1);
    while (ipi_count == 0)
        ;
    report("ipi", ipi_count, 1);

    printf(failures ? "SOME FAILED\n" : "ALL OK\n");
    for (;;)
        ;
}
