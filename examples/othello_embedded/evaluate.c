#include "evaluate.h"
#include "eval_weights_int.h"

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

#define NOT_A_FILE 0xFEFEFEFEFEFEFEFEULL
#define NOT_H_FILE 0x7F7F7F7F7F7F7F7FULL

/* 空きマスに 8 方向で隣接するマス。シフト量を定数にして 1 回だけ計算する
   (開放度は両者で同じものを使う) */
static Bitboard empty_neighbors(Bitboard empty) {
    Bitboard e_h = empty & NOT_H_FILE;   /* 東へずらすとき h 列は回り込む */
    Bitboard e_a = empty & NOT_A_FILE;   /* 西へずらすとき a 列は回り込む */
    return (empty << 8) | (empty >> 8)
         | (e_h << 1) | (e_a >> 1)
         | (e_h << 9) | (e_a << 7)
         | (e_h >> 7) | (e_a >> 9);
}

/* 8 ビットの辺 x (隅がビット 0 とビット 7) で、両端の隅から内側へ続く 1 の並び */
static uint32_t edge_runs(uint32_t x) {
    uint32_t low = x & ~(x + 1u);           /* ビット 0 から続く 1 */
    uint32_t y = ~x & 0xFFu;                /* ビット 7 から続く 1 = y の最上位の 1 より上 */
    y |= y >> 1;
    y |= y >> 2;
    y |= y >> 4;
    return (low | ~y) & 0xFFu;
}

/* a 列 / h 列を 8 ビットに集める (ビット k = k 行目) */
static uint32_t file_a(Bitboard bb) {
    uint32_t lo = (uint32_t)bb, hi = (uint32_t)(bb >> 32);
    return (lo & 1u) | ((lo >> 7) & 2u) | ((lo >> 14) & 4u) | ((lo >> 21) & 8u)
         | ((hi & 1u) << 4) | ((hi >> 3) & 0x20u) | ((hi >> 10) & 0x40u) | ((hi >> 17) & 0x80u);
}

static uint32_t file_h(Bitboard bb) {
    uint32_t lo = (uint32_t)bb, hi = (uint32_t)(bb >> 32);
    return ((lo >> 7) & 1u) | ((lo >> 14) & 2u) | ((lo >> 21) & 4u) | ((lo >> 28) & 8u)
         | ((hi >> 3) & 0x10u) | ((hi >> 10) & 0x20u) | ((hi >> 17) & 0x40u) | ((hi >> 24) & 0x80u);
}

/* 簡易確定石数：4辺それぞれについて、両端(隅側)から内側に向かって
   同色が連続する区間を確定石とみなす近似計算。
   (Pythonのstable_count_simpleと同じ数を、辺を 8 ビットとしてビット演算で
   数える。隅は行と列の両方に入るので、列の側では数えない) */
static int stable_count(Bitboard x) {
    int n = popcount32(edge_runs((uint32_t)x & 0xFFu))             /* 1 行目 */
          + popcount32(edge_runs((uint32_t)(x >> 56)))             /* 8 行目 */
          + popcount32(edge_runs(file_a(x)) & 0x7Eu)               /* a 列 */
          + popcount32(edge_runs(file_h(x)) & 0x7Eu);              /* h 列 */
    return n;
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

    Bitboard nb = empty_neighbors(empty);
    f.frontier_diff = popcount(P & nb) - popcount(O & nb);

    f.stable_diff = stable_count(P) - stable_count(O);

    return f;
}

int evaluate_position(Bitboard black, Bitboard white, int player_is_black) {
    int empty_count = 64 - popcount(black) - popcount(white);
    int phase = empty_count;
    if (phase < 0) phase = 0;
    if (phase >= EVAL_N_PHASE) phase = EVAL_N_PHASE - 1;

    Features f = extract_features(black, white, player_is_black);
    /* 整数で計算する: この CPU に浮動小数点は無く、double はソフトウェアで
       計算されて評価全体の 1/4 を占めていた */
    const int16_t *w = EVAL_WEIGHTS_INT[phase];

    int v = w[0];
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
