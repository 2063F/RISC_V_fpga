#include "evaluate.h"
#include "eval_weights.h"

/* 隅 a1,h1,a8,h8 */
#define CORNER_MASK 0x8100000000000081ULL
/* Xマス b2,g2,b7,g7（隅の斜め隣） */
#define X_MASK 0x0042000000004200ULL
/* Cマス a2,b1,g1,h2,a7,h7,b8,g8（隅の辺隣） */
#define C_MASK 0x4281000000008142ULL
/* 外周（1行目・8行目・a列・h列） */
#define EDGE_MASK 0xFF818181818181FFULL

static int popcount_masked(Bitboard bb, Bitboard mask) {
    return popcount(bb & mask);
}

static int frontier_count(Bitboard own, Bitboard empty) {
    static const int DIRS[8] = {8, -8, 1, -1, 9, 7, -7, -9};
    Bitboard nb = 0;
    for (int i = 0; i < 8; i++) {
        nb |= shift_dir(empty, DIRS[i]);
    }
    return popcount(own & nb);
}

/* 簡易確定石数：4辺それぞれについて、両端(隅側)から内側に向かって
   同色が連続する区間を確定石とみなす近似計算。
   (Pythonのstable_count_simpleと完全に同じロジック) */
static int stable_count_simple(Bitboard black, Bitboard white, int player_is_black) {
    Bitboard own = player_is_black ? black : white;
    Bitboard stable = 0;
    int lines[4][8];
    for (int c = 0; c < 8; c++) lines[0][c] = c;            /* 1行目 a1..h1 */
    for (int c = 0; c < 8; c++) lines[1][c] = 56 + c;       /* 8行目 a8..h8 */
    for (int r = 0; r < 8; r++) lines[2][r] = r * 8;        /* a列  a1..a8 */
    for (int r = 0; r < 8; r++) lines[3][r] = r * 8 + 7;    /* h列  h1..h8 */

    for (int li = 0; li < 4; li++) {
        for (int dir = 0; dir < 2; dir++) {
            int seq[8];
            for (int k = 0; k < 8; k++) {
                seq[k] = (dir == 0) ? lines[li][k] : lines[li][7 - k];
            }
            int color = 0; /* 0=未定, 1=黒, -1=白 */
            for (int k = 0; k < 8; k++) {
                int idx = seq[k];
                Bitboard bit = 1ULL << idx;
                int c;
                if (black & bit) c = 1;
                else if (white & bit) c = -1;
                else break;
                if (color == 0) color = c;
                if (c != color) break;
                stable |= bit;
            }
        }
    }
    return popcount(stable & own);
}

Features extract_features(Bitboard black, Bitboard white, int player_is_black) {
    Features f;
    Bitboard P = player_is_black ? black : white;
    Bitboard O = player_is_black ? white : black;
    Bitboard empty = ~(black | white);

    int b = popcount(black), w = popcount(white);
    int own = player_is_black ? b : w;
    int opp = player_is_black ? w : b;
    f.stone_diff = own - opp;

    int my_moves = popcount(get_moves(P, O));
    int op_moves = popcount(get_moves(O, P));
    f.mobility_diff = my_moves - op_moves;

    f.corner_diff = popcount_masked(P, CORNER_MASK) - popcount_masked(O, CORNER_MASK);
    f.x_square_diff = popcount_masked(P, X_MASK) - popcount_masked(O, X_MASK);
    f.c_square_diff = popcount_masked(P, C_MASK) - popcount_masked(O, C_MASK);
    f.edge_diff = popcount_masked(P, EDGE_MASK) - popcount_masked(O, EDGE_MASK);

    f.frontier_diff = frontier_count(P, empty) - frontier_count(O, empty);

    int stable_own = stable_count_simple(black, white, player_is_black);
    int stable_opp = stable_count_simple(black, white, !player_is_black);
    f.stable_diff = stable_own - stable_opp;

    return f;
}

#ifdef OTHELLO_BAREMETAL
/* eval_weights.h の double の重みを SCORE_SCALE 倍した整数に変換した表。
   eval_weights.h は学習スクリプトの自動生成物なのでそのまま使い、
   初回呼び出し時に IEEE754 のビット列を直接読んで変換する
   （ソフトウェア浮動小数点ライブラリを一切リンクせずに済む）。 */
static int32_t W_FIX[EVAL_N_PHASE][EVAL_N_FEATURES + 1];
static int w_fix_ready = 0;

static int32_t double_to_fixed(const double *d) {
    union { double d; uint64_t u; } cv;
    cv.d = *d;
    uint64_t u = cv.u;
    int neg = (int)(u >> 63);
    int exp = (int)((u >> 52) & 0x7FF);
    if (exp == 0) return 0; /* 0 / 非正規化数 */
    uint64_t mant = (u & 0x000FFFFFFFFFFFFFULL) | (1ULL << 52);
    /* 値 = mant * 2^(exp-1075)。これに SCORE_SCALE(=2^SCORE_SCALE_BITS) を掛けて丸める */
    int sh = exp - 1075 + SCORE_SCALE_BITS;
    int64_t v;
    if (sh >= 0) {
        v = (int64_t)(mant << sh); /* 重みは高々数十なのでオーバーフローしない */
    } else if (sh > -63) {
        v = (int64_t)((mant + (1ULL << (-sh - 1))) >> (-sh)); /* 四捨五入 */
    } else {
        v = 0;
    }
    return (int32_t)(neg ? -v : v);
}

static void init_fixed_weights(void) {
    for (int p = 0; p < EVAL_N_PHASE; p++)
        for (int i = 0; i <= EVAL_N_FEATURES; i++)
            W_FIX[p][i] = double_to_fixed(&EVAL_WEIGHTS[p][i]);
    w_fix_ready = 1;
}
#endif

Score evaluate_position(Bitboard black, Bitboard white, int player_is_black) {
    int empty_count = 64 - popcount(black) - popcount(white);
    int phase = empty_count;
    if (phase < 0) phase = 0;
    if (phase >= EVAL_N_PHASE) phase = EVAL_N_PHASE - 1;

    Features f = extract_features(black, white, player_is_black);
#ifdef OTHELLO_BAREMETAL
    if (!w_fix_ready) init_fixed_weights();
    const int32_t *w = W_FIX[phase];
    Score v = w[0];
#else
    const double *w = EVAL_WEIGHTS[phase];
    double v = w[0];
#endif
    v += w[1] * f.stone_diff;
    v += w[2] * f.mobility_diff;
    v += w[3] * f.corner_diff;
    v += w[4] * f.x_square_diff;
    v += w[5] * f.c_square_diff;
    v += w[6] * f.frontier_diff;
    v += w[7] * f.stable_diff;
    v += w[8] * f.edge_diff;
    return v;
}
