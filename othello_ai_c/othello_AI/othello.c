#include <stdio.h>
#include <ctype.h>
#include "othello.h"

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

Bitboard get_moves(Bitboard P, Bitboard O) {
    Bitboard empty = ~(P | O);
    Bitboard moves = 0;
    for (int i = 0; i < 8; i++) {
        int d = DIRS[i];
        Bitboard x = shift_dir(P, d) & O;
        for (int k = 0; k < 5; k++) {
            x |= shift_dir(x, d) & O;
        }
        moves |= shift_dir(x, d) & empty;
    }
    return moves;
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

int parse_square(const char *s) {
    if (!s || !s[0] || !s[1]) return -1;
    char c0 = (char)tolower((unsigned char)s[0]);
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
