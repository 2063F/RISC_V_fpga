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

/* 空きマスに隣接するマス（8方向）。frontier 計算用に1回だけ求めて両者で共有する */
static Bitboard empty_neighbors(Bitboard empty) {
    Bitboard e_noA = empty & ~0x0101010101010101ULL; /* 西へずらすとき A列は落とす */
    Bitboard e_noH = empty & ~0x8080808080808080ULL; /* 東へずらすとき H列は落とす */
    return (empty << 8) | (empty >> 8)
         | (e_noH << 1) | (e_noH << 9) | (e_noH >> 7)
         | (e_noA >> 1) | (e_noA << 7) | (e_noA >> 9);
}

/*
 * 簡易確定石：4辺それぞれについて、両端(隅側)から内側に向かって
 * 同色が連続する区間を確定石とみなす近似計算。
 * (Pythonのstable_count_simpleと完全に同じロジック)
 * 自分と相手の分を1回の走査でまとめて求め、差を返す。
 */

/* 辺1本分(8bit, bit0 が一方の隅)の黒 b・白 w から、両端から続く同色区間を返す */
static inline uint32_t edge_runs(uint32_t b, uint32_t w) {
    /* bit0 側: 隅の色の石が連続する区間 = x の下位から連続する1 */
    uint32_t x = (b & 1) ? b : ((w & 1) ? w : 0);
    uint32_t lo = x & ~(x + 1);
    /* bit7 側: y の上位から連続する1 */
    uint32_t y = (b & 0x80) ? b : ((w & 0x80) ? w : 0);
    uint32_t ny = ~y & 0xFF;
    ny |= ny >> 1; ny |= ny >> 2; ny |= ny >> 4;
    uint32_t hi = ~ny & 0xFF;
    return lo | hi;
}

/* A列 / H列の8マスを8bitに集める（bit i = i行目）。RV32 で速いよう32bitずつ定数シフト */
static inline uint32_t file_a(Bitboard bb) {
    uint32_t lo = (uint32_t)bb, hi = (uint32_t)(bb >> 32);
    return (lo & 1) | ((lo >> 7) & 2) | ((lo >> 14) & 4) | ((lo >> 21) & 8)
         | ((hi << 4) & 16) | ((hi >> 3) & 32) | ((hi >> 10) & 64) | ((hi >> 17) & 128);
}

static inline uint32_t file_h(Bitboard bb) {
    uint32_t lo = (uint32_t)bb, hi = (uint32_t)(bb >> 32);
    return ((lo >> 7) & 1) | ((lo >> 14) & 2) | ((lo >> 21) & 4) | ((lo >> 28) & 8)
         | ((hi >> 3) & 16) | ((hi >> 10) & 32) | ((hi >> 17) & 64) | ((hi >> 24) & 128);
}

/* 8bit の popcount */
static inline int popcount8(uint32_t x) {
    x = x - ((x >> 1) & 0x55);
    x = (x & 0x33) + ((x >> 2) & 0x33);
    return (int)((x + (x >> 4)) & 0x0F);
}

/* 辺1本の確定石の (自分 - 相手)。inner_mask で数えるマスを絞る */
static inline int edge_stable_diff(uint32_t p, uint32_t o, uint32_t inner_mask) {
    uint32_t st = edge_runs(p, o) & inner_mask;
    return popcount8(st & p) - popcount8(st & o);
}

/* 確定石数の差（自分 - 相手）。確定石集合は4辺の区間の和集合で、
   隅は行と列の両方に含まれるので列側では数えない（隅は石があれば必ず区間に入る） */
static int stable_diff_simple(Bitboard P, Bitboard O) {
    return edge_stable_diff((uint32_t)P & 0xFF, (uint32_t)O & 0xFF, 0xFF)
         + edge_stable_diff((uint32_t)(P >> 56), (uint32_t)(O >> 56), 0xFF)
         + edge_stable_diff(file_a(P), file_a(O), 0x7E)
         + edge_stable_diff(file_h(P), file_h(O), 0x7E);
}

/* 手番側 P / 相手側 O から見た特徴量。pm/om は P/O それぞれの合法手 */
static inline Features features_po(Bitboard P, Bitboard O, Bitboard pm, Bitboard om) {
    Features f;
    Bitboard empty = ~(P | O);

    f.stone_diff = popcount(P) - popcount(O);
    f.mobility_diff = popcount(pm) - popcount(om);

    f.corner_diff = popcount_masked(P, CORNER_MASK) - popcount_masked(O, CORNER_MASK);
    f.x_square_diff = popcount_masked(P, X_MASK) - popcount_masked(O, X_MASK);
    f.c_square_diff = popcount_masked(P, C_MASK) - popcount_masked(O, C_MASK);
    f.edge_diff = popcount_masked(P, EDGE_MASK) - popcount_masked(O, EDGE_MASK);

    Bitboard nb = empty_neighbors(empty);
    f.frontier_diff = popcount(P & nb) - popcount(O & nb);

    f.stable_diff = stable_diff_simple(P, O);

    return f;
}

Features extract_features(Bitboard black, Bitboard white, int player_is_black) {
    Bitboard P = player_is_black ? black : white;
    Bitboard O = player_is_black ? white : black;
    return features_po(P, O, get_moves(P, O), get_moves(O, P));
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

Score evaluate_po(Bitboard P, Bitboard O, Bitboard pm, Bitboard om) {
    int empty_count = 64 - popcount(P) - popcount(O);
    int phase = empty_count;
    if (phase < 0) phase = 0;
    if (phase >= EVAL_N_PHASE) phase = EVAL_N_PHASE - 1;

    Features f = features_po(P, O, pm, om);
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

Score evaluate_position(Bitboard black, Bitboard white, int player_is_black) {
    Bitboard P = player_is_black ? black : white;
    Bitboard O = player_is_black ? white : black;
    return evaluate_po(P, O, get_moves(P, O), get_moves(O, P));
}
