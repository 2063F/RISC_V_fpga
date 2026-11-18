#include "othello.h"
#include "uart.h"

/* d4=index(row3,col3)=27(白) e4=index(row3,col4)=28(黒)
   d5=index(row4,col3)=35(黒) e5=index(row4,col4)=36(白) */
const Bitboard INIT_BLACK = (1ULL << 28) | (1ULL << 35);
const Bitboard INIT_WHITE = (1ULL << 27) | (1ULL << 36);

#define FILE_A 0x0101010101010101ULL
#define FILE_H 0x8080808080808080ULL
#define NOT_A  (~FILE_A)
#define NOT_H  (~FILE_H)

static const int DIRS[8] = {8, -8, 1, -1, 9, 7, -7, -9};

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

/* 1 方向ぶんの合法手。シフト量を定数にして (インライン展開される)、
   列をまたぐ方向では相手の石を b-g 列に限ることで回り込みを防ぐ:
   連続する相手の石が a 列や h 列を通ることはないので、端で折り返した
   ビットは途中で消える。可変のシフト量で 64 ビットを動かすと RV32 では
   分岐だらけになり、評価関数の中で一番重かった */
#define INNER_COLS 0x7E7E7E7E7E7E7E7EULL

static inline Bitboard moves_up(Bitboard P, Bitboard mO, Bitboard empty, int s) {
    Bitboard x = (P << s) & mO;
    x |= (x << s) & mO;
    x |= (x << s) & mO;
    x |= (x << s) & mO;
    x |= (x << s) & mO;
    x |= (x << s) & mO;
    return (x << s) & empty;
}

static inline Bitboard moves_down(Bitboard P, Bitboard mO, Bitboard empty, int s) {
    Bitboard x = (P >> s) & mO;
    x |= (x >> s) & mO;
    x |= (x >> s) & mO;
    x |= (x >> s) & mO;
    x |= (x >> s) & mO;
    x |= (x >> s) & mO;
    return (x >> s) & empty;
}

Bitboard get_moves(Bitboard P, Bitboard O) {
    Bitboard empty = ~(P | O);
    Bitboard inner = O & INNER_COLS;
    return moves_up(P, O, empty, 8)     | moves_down(P, O, empty, 8)        /* 縦 */
         | moves_up(P, inner, empty, 1) | moves_down(P, inner, empty, 1)    /* 横 */
         | moves_up(P, inner, empty, 9) | moves_down(P, inner, empty, 9)    /* 斜め */
         | moves_up(P, inner, empty, 7) | moves_down(P, inner, empty, 7);
}

void apply_move(Bitboard P, Bitboard O, int sq, Bitboard *newP, Bitboard *newO) {
    Bitboard mb = 1ULL << sq;
    Bitboard flips = 0;
    for (int i = 0; i < 8; i++) {
        int d = DIRS[i];
        Bitboard cur = shift_dir(mb, d);
        Bitboard ray = 0;
        while (cur & O) {
            ray |= cur;
            cur = shift_dir(cur, d);
        }
        if (cur & P) {
            flips |= ray;
        }
    }
    *newP = P | mb | flips;
    *newO = O & ~flips;
}

void square_to_str(int sq, char *out) {
    out[0] = (char)('a' + col_of(sq));
    out[1] = (char)('1' + row_of(sq));
    out[2] = '\0';
}

/* UTF-8 の記号。日本語の端末 (Tera Term など) では全角、つまり 2 桁ぶんで
   表示されるので、後ろに空白は付けない。空きマスは半角の「. 」で 2 桁 */
#define SYM_BLACK "\xE2\x97\x8F"     /* U+25CF ● */
#define SYM_WHITE "\xE2\x97\x8B"     /* U+25CB ○ */
#define SYM_HINT  "\xE2\x96\xB3"     /* U+25B3 △ */
#define SYM_HINT0 "\xE3\x80\x87"     /* U+3007 〇 */

void print_board(Bitboard black, Bitboard white, Bitboard hints, int symbols) {
    for (int r = 0; r < 8; r++) {
        printf("%d ", r + 1);
        for (int c = 0; c < 8; c++) {
            Bitboard bit = 1ULL << sq_of(c, r);
            if (black & bit)      uart_print(symbols ? SYM_BLACK : "R ");
            else if (white & bit) uart_print(symbols ? SYM_WHITE : "G ");
            else if (hints & bit) uart_print(symbols ? SYM_HINT : SYM_HINT0);
            else                  uart_print(". ");
        }
        uart_print("\n");
    }
    uart_print("  a b c d e f g h\n");
    if (symbols) {
        uart_print(SYM_BLACK " Black  " SYM_WHITE " White");
        if (hints)
            uart_print("  " SYM_HINT " can play");
        uart_print("\n");
    }
}
