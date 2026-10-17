#include "uart.h"
#include "zbb.h"

// Checks the hardware CPOP / CTZ (zbb.h) against plain C bit loops and
// prints the result over UART.

static uint32_t ref_cpop32(uint32_t x) {
    uint32_t n = 0;
    while (x) { n += x & 1; x >>= 1; }
    return n;
}

static uint32_t ref_ctz32(uint32_t x) {
    uint32_t n = 0;
    if (x == 0) return 32;
    while (!(x & 1)) { n++; x >>= 1; }
    return n;
}

static int fails;

static void check32(uint32_t x) {
    uint32_t c = zbb_cpop32(x), t = zbb_ctz32(x);
    if (c != ref_cpop32(x) || t != ref_ctz32(x)) {
        printf("[FAIL] x=0x%x cpop=%d ctz=%d\n", x, (int)c, (int)t);
        fails++;
    }
}

int main(void) {
    printf("=== Zbb CPOP / CTZ Demo ===\n");

    printf("cpop(0xF0F0F0F0) = %d\n", (int)zbb_cpop32(0xF0F0F0F0u));
    printf("ctz(0xF0F0F0F0)  = %d\n", (int)zbb_ctz32(0xF0F0F0F0u));
    printf("ctz(0)           = %d\n", (int)zbb_ctz32(0));

    check32(0);
    check32(0xFFFFFFFFu);
    for (int i = 0; i < 32; i++) {
        check32(1u << i);
        check32((1u << i) - 1);
        check32(~((1u << i) - 1));
    }
    uint32_t s = 2463534242u;      // xorshift32
    for (int i = 0; i < 200; i++) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        check32(s);
    }

    uint64_t bb = 0x0000001008000000ull; // Othello start position (d5, e4)
    printf("bb = hi 0x%x / lo 0x%x: cpop64 = %d, ctz64 = %d\n",
           (uint32_t)(bb >> 32), (uint32_t)bb, (int)zbb_cpop64(bb), (int)zbb_ctz64(bb));
    if (zbb_cpop64(bb) != 2 || zbb_ctz64(bb) != 27 || zbb_ctz64(0) != 64) fails++;

    if (fails == 0) printf("[PASS] all CPOP / CTZ checks\n");
    else            printf("[FAIL] %d mismatches\n", fails);
    return 0;
}
