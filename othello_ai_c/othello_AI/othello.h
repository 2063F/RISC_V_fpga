#ifndef OTHELLO_H
#define OTHELLO_H

#include <stdint.h>
#include <stdbool.h>

/*
 * オセロ盤面をビットボード(64bit整数2つ: black, white)で表現する。
 * マス番号 sq = row*8 + col  (col: 0='a'〜7='h', row: 0='1'〜7='8')
 * 例: a1 = 0, h1 = 7, a8 = 56, h8 = 63
 */

typedef uint64_t Bitboard;

#define BOARD_FULL 0xFFFFFFFFFFFFFFFFULL

/* 初期配置（d4=白, e4=黒, d5=黒, e5=白） */
extern const Bitboard INIT_BLACK;
extern const Bitboard INIT_WHITE;

/*
 * 8方向シフト。
 * d = +8:北(行+1) -8:南(行-1) +1:東(列+1) -1:西(列-1)
 *     +9:北東 +7:北西 -7:南東 -9:南西
 * 盤外へのラップアラウンド（例: h列から次の行のa列へ）はここでマスクして防ぐ。
 */
Bitboard shift_dir(Bitboard bb, int d);

/* 現在の手番(P=自分, O=相手)の合法手ビットボードを返す */
Bitboard get_moves(Bitboard P, Bitboard O);

/*
 * sq に着手した場合の新しい (P, O) を計算する。
 * 呼び出し側は sq が get_moves(P,O) に含まれる合法手であることを
 * 保証すること（本関数自体は合法性チェックをしない）。
 */
void apply_move(Bitboard P, Bitboard O, int sq, Bitboard *newP, Bitboard *newO);

/* 空きマス sq に P が打ったときに裏返る石。0 なら sq は合法手ではない */
Bitboard compute_flips(Bitboard P, Bitboard O, int sq);

#ifdef OTHELLO_BAREMETAL
/* RV32 には popcount 命令が無く、libgcc の __popcountdi2 は表引きで遅いので
   SWAR で数える。上位・下位32bitは4bit単位の和まで別々に求めてから足し合わせる */
static inline int popcount32(uint32_t x) {
    x = x - ((x >> 1) & 0x55555555u);
    x = (x & 0x33333333u) + ((x >> 2) & 0x33333333u);
    x = (x + (x >> 4)) & 0x0F0F0F0Fu;
    x += x >> 8;
    x += x >> 16;
    return (int)(x & 0x3F);
}
static inline int popcount(Bitboard bb) {
    uint32_t a = (uint32_t)bb, b = (uint32_t)(bb >> 32);
    a = a - ((a >> 1) & 0x55555555u);
    b = b - ((b >> 1) & 0x55555555u);
    a = (a & 0x33333333u) + ((a >> 2) & 0x33333333u);
    b = (b & 0x33333333u) + ((b >> 2) & 0x33333333u);
    a += b;                                  /* 各4bitは最大8 */
    a = (a & 0x0F0F0F0Fu) + ((a >> 4) & 0x0F0F0F0Fu); /* 各8bitは最大16 */
    a += a >> 8;
    a += a >> 16;
    return (int)(a & 0x7F);
}
/* 最下位の1のビット位置 (bb != 0)。libgcc の __ctzdi2 呼び出しを避けるため
   de Bruijn 列の乗算で求める */
static inline int ctz64(Bitboard bb) {
    static const uint8_t DEBRUIJN32[32] = {
        0, 1, 28, 2, 29, 14, 24, 3, 30, 22, 20, 15, 25, 17, 4, 8,
        31, 27, 13, 23, 21, 19, 16, 7, 26, 12, 18, 6, 11, 5, 10, 9
    };
    uint32_t lo = (uint32_t)bb;
    if (lo) return DEBRUIJN32[((lo & -lo) * 0x077CB531u) >> 27];
    uint32_t hi = (uint32_t)(bb >> 32);
    return 32 + DEBRUIJN32[((hi & -hi) * 0x077CB531u) >> 27];
}
#else
static inline int popcount(Bitboard bb) {
    return __builtin_popcountll(bb);
}
static inline int ctz64(Bitboard bb) {
    return __builtin_ctzll(bb);
}
#endif

static inline int sq_of(int col, int row) { return row * 8 + col; }
static inline int col_of(int sq) { return sq % 8; }
static inline int row_of(int sq) { return sq / 8; }

/* "f5" のような2文字表記 -> マス番号。不正な文字列なら -1 を返す */
int parse_square(const char *s);

/* マス番号 -> "f5" のような2文字表記（out は3バイト以上確保すること） */
void square_to_str(int sq, char *out);

#ifndef OTHELLO_BAREMETAL
/* デバッグ用に盤面をテキストで表示する（stdio が無いベアメタル版では除外） */
void print_board(Bitboard black, Bitboard white);
#endif

#endif
