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

static inline int popcount(Bitboard bb) {
    return __builtin_popcountll(bb);
}

static inline int sq_of(int col, int row) { return row * 8 + col; }
static inline int col_of(int sq) { return sq % 8; }
static inline int row_of(int sq) { return sq / 8; }

/* "f5" のような2文字表記 -> マス番号。不正な文字列なら -1 を返す */
int parse_square(const char *s);

/* マス番号 -> "f5" のような2文字表記（out は3バイト以上確保すること） */
void square_to_str(int sq, char *out);

/* デバッグ用に盤面をテキストで表示する */
void print_board(Bitboard black, Bitboard white);

#endif
