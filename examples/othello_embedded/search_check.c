// search_check.c - Host-side check of the two-hart search in search.c
//
// Runs find_best_move with one hart and with two (hart 1 being a thread
// here) on positions from random games, and checks that both pick the same
// move with the same score. Also prints the time each took.
//
//   gcc -O2 -pthread -I examples examples/othello_embedded/search_check.c
//       examples/othello_embedded/{othello,evaluate,search}.c -o search_check
//   ./search_check [games] [depth]
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "othello.h"
#include "search.h"

static void *hart1(void *arg) {
    (void)arg;
    search_hart_main();
    return NULL;
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
    int games = argc > 1 ? atoi(argv[1]) : 20;
    int depth = argc > 2 ? atoi(argv[2]) : 4;

    pthread_t t;
    pthread_create(&t, NULL, hart1, NULL);
    // find_best_move falls back to one hart until hart 1 has started
    struct timespec ms = {0, 1000000};
    nanosleep(&ms, NULL);

    srand(1);
    int positions = 0, mismatches = 0;
    long nodes1 = 0, nodes2 = 0;
    double time1 = 0, time2 = 0;
    for (int g = 0; g < games; g++) {
        Bitboard black = INIT_BLACK, white = INIT_WHITE;
        int is_black = 1, passes = 0;
        while (passes < 2) {
            Bitboard P = is_black ? black : white, O = is_black ? white : black;
            Bitboard moves = get_moves(P, O);
            if (!moves) { passes++; is_black = !is_black; continue; }
            passes = 0;

            double a = now();
            SearchResult r1 = find_best_move(black, white, is_black, depth, 1);
            double b = now();
            SearchResult r2 = find_best_move(black, white, is_black, depth, 2);
            double c = now();
            positions++;
            nodes1 += r1.nodes; nodes2 += r2.nodes;
            time1 += b - a; time2 += c - b;
            if (r1.square != r2.square || r1.score != r2.score) {
                mismatches++;
                printf("MISMATCH game %d: 1 hart %d (%.6f), 2 harts %d (%.6f)\n",
                       g, r1.square, r1.score, r2.square, r2.score);
            }

            // continue the game with a random legal move
            int n = 0, sqs[64];
            for (Bitboard m = moves; m; m &= m - 1) sqs[n++] = ctz64(m);
            Bitboard np, no;
            apply_move(P, O, sqs[rand() % n], &np, &no);
            black = is_black ? np : no;
            white = is_black ? no : np;
            is_black = !is_black;
        }
    }
    printf("%d positions at depth %d: %d mismatches\n", positions, depth, mismatches);
    printf("nodes: 1 hart %ld, 2 harts %ld\n", nodes1, nodes2);
    printf("time:  1 hart %.2f s, 2 harts %.2f s (x%.2f)\n", time1, time2, time1 / time2);
    return mismatches != 0;
}
