#ifndef OTHELLO_BAREMETAL
#include <stdio.h>
#endif
#include "othello.h"

/* d4=index(row3,col3)=27(白) e4=index(row3,col4)=28(黒)
   d5=index(row4,col3)=35(黒) e5=index(row4,col4)=36(白) */
const Bitboard INIT_BLACK = (1ULL << 28) | (1ULL << 35);
const Bitboard INIT_WHITE = (1ULL << 27) | (1ULL << 36);

#define FILE_A 0x0101010101010101ULL
#define FILE_H 0x8080808080808080ULL
#define NOT_A  (~FILE_A)
#define NOT_H  (~FILE_H)

Bitboard shift_dir(Bitboard bb, int d) {
    /* 列方向にまたがる手（東方向成分を含む: +1,+9,-7）はH列がラップしないよう
       あらかじめH列を落としておく。西方向成分(-1,+7,-9)はA列を落とす。 */
    if (d == 1 || d == 9 || d == -7) {
        bb &= NOT_H;
    } else if (d == -1 || d == 7 || d == -9) {
        bb &= NOT_A;
    }
    if (d > 0) {
        return bb << d;
    } else {
        return bb >> (-d);
    }
}

/*
 * 合法手生成・反転計算は方向ごとにシフト量を定数にした inline 関数で行う。
 * （RV32 では64bitの可変量シフトが分岐入りの長い命令列になるため、定数シフトに
 *   展開させると数倍速い。PC版でも速くなる）
 * 横・斜め方向は相手石を B〜G 列だけに絞った mO を使うことで、盤端をまたいだ
 * ラップアラウンドを防ぐ（A/H列の相手石は挟めないので結果は変わらない）。
 */
#define INNER_COLS 0x7E7E7E7E7E7E7E7EULL

/* 方向 +s (左シフト) の合法手。Kogge-Stone 風に倍々で伸ばす（最大6連続） */
static inline Bitboard moves_l(Bitboard P, Bitboard mO, Bitboard empty, int s) {
    Bitboard t = mO & (P << s);
    t |= mO & (t << s);
    Bitboard m = mO & (mO << s);
    t |= m & (t << (2 * s));
    t |= m & (t << (2 * s));
    return (t << s) & empty;
}

static inline Bitboard moves_r(Bitboard P, Bitboard mO, Bitboard empty, int s) {
    Bitboard t = mO & (P >> s);
    t |= mO & (t >> s);
    Bitboard m = mO & (mO >> s);
    t |= m & (t >> (2 * s));
    t |= m & (t >> (2 * s));
    return (t >> s) & empty;
}

Bitboard get_moves(Bitboard P, Bitboard O) {
    Bitboard empty = ~(P | O);
    Bitboard mO = O & INNER_COLS;
    return moves_l(P, O, empty, 8)  | moves_r(P, O, empty, 8)    /* 北・南 */
         | moves_l(P, mO, empty, 1) | moves_r(P, mO, empty, 1)   /* 東・西 */
         | moves_l(P, mO, empty, 9) | moves_r(P, mO, empty, 9)   /* 北東・南西 */
         | moves_l(P, mO, empty, 7) | moves_r(P, mO, empty, 7);  /* 北西・南東 */
}

/* 着手 mb から方向 +s / -s に挟める石。隣が相手石でない方向（大半）はすぐ抜ける */
static inline Bitboard flips_l(Bitboard P, Bitboard mO, Bitboard mb, int s) {
    Bitboard f = mO & (mb << s);
    if (!f) return 0;
    Bitboard n = f << s;
    while (n & mO) { f |= n; n <<= s; }
    return (n & P) ? f : 0;
}

static inline Bitboard flips_r(Bitboard P, Bitboard mO, Bitboard mb, int s) {
    Bitboard f = mO & (mb >> s);
    if (!f) return 0;
    Bitboard n = f >> s;
    while (n & mO) { f |= n; n >>= s; }
    return (n & P) ? f : 0;
}

Bitboard compute_flips(Bitboard P, Bitboard O, int sq) {
    Bitboard mb = 1ULL << sq;
    Bitboard mO = O & INNER_COLS;
    return flips_l(P, O, mb, 8)  | flips_r(P, O, mb, 8)
         | flips_l(P, mO, mb, 1) | flips_r(P, mO, mb, 1)
         | flips_l(P, mO, mb, 9) | flips_r(P, mO, mb, 9)
         | flips_l(P, mO, mb, 7) | flips_r(P, mO, mb, 7);
}

void apply_move(Bitboard P, Bitboard O, int sq, Bitboard *newP, Bitboard *newO) {
    Bitboard flips = compute_flips(P, O, sq);
    *newP = P | (1ULL << sq) | flips;
    *newO = O & ~flips;
}

int parse_square(const char *s) {
    if (!s || !s[0] || !s[1]) return -1;
    char c0 = s[0];
    if (c0 >= 'A' && c0 <= 'Z') c0 = (char)(c0 - 'A' + 'a'); /* ctype.h 無しで小文字化 */
    char c1 = s[1];
    if (c0 < 'a' || c0 > 'h') return -1;
    if (c1 < '1' || c1 > '8') return -1;
    int col = c0 - 'a';
    int row = c1 - '1';
    return sq_of(col, row);
}

void square_to_str(int sq, char *out) {
    out[0] = (char)('a' + col_of(sq));
    out[1] = (char)('1' + row_of(sq));
    out[2] = '\0';
}

#ifndef OTHELLO_BAREMETAL
void print_board(Bitboard black, Bitboard white) {
    for (int r = 7; r >= 0; r--) {
        printf("%d ", r + 1);
        for (int c = 0; c < 8; c++) {
            int sq = sq_of(c, r);
            Bitboard bit = 1ULL << sq;
            char ch = '.';
            if (black & bit) ch = 'B';
            else if (white & bit) ch = 'W';
            printf("%c ", ch);
        }
        printf("\n");
    }
    printf("  a b c d e f g h\n");
}
#endif
