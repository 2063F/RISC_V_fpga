// search_bench.c - One hart vs two harts on the CPU (run by sim/tb_othello_mp.v)
//
// Plays a few random opening moves, then times find_best_move on hart 0
// alone and with hart 1's help, for BENCH_POSITIONS positions, checks that
// both pick the same move with the same score, and prints the cycle counts.
// Ends with "ALL OK" or "SOME FAILED".
//
// Build like othello (main.c), with search_bench.c in place of main.c:
//   riscv64-unknown-elf-gcc -march=rv32ima_zicsr -mabi=ilp32 -O2 -nostdlib
//     -nostartfiles -I examples -T tools/link_mp.ld
//     -Wl,--defsym=__hart_stack_size=0x2800 tools/crt0.S
//     examples/othello_embedded/{search_bench,othello,evaluate,search}.c -lgcc
//     -o examples/othello_embedded/search_bench.elf
#include "othello.h"
#include "search.h"
#include "uart.h"
#include "csr.h"
#include "mp.h"
#include <stdint.h>

#ifndef BENCH_DEPTH
#define BENCH_DEPTH 3
#endif
#ifndef BENCH_POSITIONS
#define BENCH_POSITIONS 3
#endif

void hart_main(unsigned int hartid)
{
    (void)hartid;
    search_hart_main();
}

static uint32_t rng = 12345u;

static uint32_t rng_next(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

static void play_random(Bitboard *black, Bitboard *white, int *is_black)
{
    Bitboard P = *is_black ? *black : *white;
    Bitboard O = *is_black ? *white : *black;
    Bitboard moves = get_moves(P, O);
    int n = popcount(moves);
    int k = (int)(rng_next() % (uint32_t)n);
    while (k--)
        moves &= moves - 1;
    Bitboard np, no;
    apply_move(P, O, ctz64(moves), &np, &no);
    *black = *is_black ? np : no;
    *white = *is_black ? no : np;
    *is_black = !*is_black;
}

int main(void)
{
    hart_start(1);
    printf("=== othello search: 1 hart vs 2 harts (depth %d) ===\n", BENCH_DEPTH);

    Bitboard black = INIT_BLACK, white = INIT_WHITE;
    int is_black = 1;
    uint32_t total1 = 0, total2 = 0;
    int failures = 0;

    for (int p = 0; p < BENCH_POSITIONS; p++) {
        for (int i = 0; i < 6; i++)     // 6 random plies between positions
            play_random(&black, &white, &is_black);

        uint32_t c0 = read_csr(mcycle);
        SearchResult r1 = find_best_move(black, white, is_black, BENCH_DEPTH, 1);
        uint32_t c1 = read_csr(mcycle);
        SearchResult r2 = find_best_move(black, white, is_black, BENCH_DEPTH, 2);
        uint32_t c2 = read_csr(mcycle);

        int ok = r1.square == r2.square && r1.score == r2.score;
        failures += !ok;
        total1 += c1 - c0;
        total2 += c2 - c1;
        printf("position %d: move %d / %d, nodes %d / %d, kcycles %d / %d  %s\n",
               p, r1.square, r2.square, (int)r1.nodes, (int)r2.nodes,
               (int)((c1 - c0) / 1000u), (int)((c2 - c1) / 1000u), ok ? "ok" : "FAIL");
    }

    uint32_t x100 = total1 / (total2 / 100u);   // speed-up x 100
    printf("total kcycles: 1 hart %d, 2 harts %d (x%d.%d%d)\n",
           (int)(total1 / 1000u), (int)(total2 / 1000u),
           (int)(x100 / 100u), (int)(x100 / 10u % 10u), (int)(x100 % 10u));
    printf(failures ? "SOME FAILED\n" : "ALL OK\n");
    for (;;)
        ;
}
