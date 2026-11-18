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

/* rv32im には popcount/ctz 命令が無いのでソフトウェアで実装する
   (libgcc の __popcountdi2 / __ctzdi2 呼び出しを避け、依存を減らす)。
   どちらも 32 ビットの半分ずつ、ループなしで数える (ビットを 1 つずつ
   数えるループより 1 桁速い。評価関数が十数回呼ぶ) */
static inline int popcount32(uint32_t x) {
    x = x - ((x >> 1) & 0x55555555u);
    x = (x & 0x33333333u) + ((x >> 2) & 0x33333333u);
    x = (x + (x >> 4)) & 0x0F0F0F0Fu;
    return (int)((x * 0x01010101u) >> 24);
}

static inline int popcount(Bitboard bb) {
    return popcount32((uint32_t)bb) + popcount32((uint32_t)(bb >> 32));
}

/* 最下位の 1 のビット位置 (bb != 0 であること)。de Bruijn 列で引く */
static inline int ctz32(uint32_t x) {
    static const unsigned char TABLE[32] = {
        0, 1, 28, 2, 29, 14, 24, 3, 30, 22, 20, 15, 25, 17, 4, 8,
        31, 27, 13, 23, 21, 19, 16, 7, 26, 12, 18, 6, 11, 5, 10, 9
    };
    return TABLE[((x & (0u - x)) * 0x077CB531u) >> 27];
}

static inline int ctz64(Bitboard bb) {
    uint32_t lo = (uint32_t)bb;
    return lo ? ctz32(lo) : 32 + ctz32((uint32_t)(bb >> 32));
}

static inline int sq_of(int col, int row) { return row * 8 + col; }
static inline int col_of(int sq) { return sq % 8; }
static inline int row_of(int sq) { return sq / 8; }

/* マス番号 -> "f5" のような2文字表記（out は3バイト以上確保すること） */
void square_to_str(int sq, char *out);

/* 盤面をUARTにテキスト表示する (要 uart.h)。hints のマス（合法手）にも
   印を付ける (不要なら 0 を渡す)。
   symbols = 0: 黒石 R・白石 G・合法手 〇 (赤 / 緑で呼ぶとき)
   symbols = 1: 黒石 ●・白石 ○・合法手 △ と、その凡例 (黒 / 白で呼ぶとき) */
void print_board(Bitboard black, Bitboard white, Bitboard hints, int symbols);

#endif
