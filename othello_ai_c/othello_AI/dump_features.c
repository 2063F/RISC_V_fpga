/*
 * WTHOR形式CSVを読み込み、全局面の評価変数をCSVとして標準出力に書き出す。
 * Python版(extract_features_wthor.py)の出力と列を揃えており、
 * 同じ入力から同じ数値が出るかを突き合わせることでCの特徴量計算を検証できる。
 *
 * 使い方: ./dump_features file.csv > out.csv
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "othello.h"
#include "evaluate.h"

#define MAX_LINE 4096
#define MAX_FIELDS 16
#define MAX_FIELD_LEN 512

static int split_csv(const char *line, char fields[MAX_FIELDS][MAX_FIELD_LEN]) {
    int nf = 0;
    const char *p = line;
    while (*p && *p != '\n' && *p != '\r' && nf < MAX_FIELDS) {
        int fi = 0;
        if (*p == '"') {
            p++;
            while (*p) {
                if (*p == '"') {
                    if (*(p + 1) == '"') { fields[nf][fi++] = '"'; p += 2; }
                    else { p++; break; }
                } else {
                    if (fi < MAX_FIELD_LEN - 1) fields[nf][fi++] = *p;
                    p++;
                }
            }
        } else {
            while (*p && *p != ',' && *p != '\n' && *p != '\r') {
                if (fi < MAX_FIELD_LEN - 1) fields[nf][fi++] = *p;
                p++;
            }
        }
        fields[nf][fi] = '\0';
        nf++;
        if (*p == ',') p++;
        else break;
    }
    return nf;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s file.csv > out.csv\n", argv[0]);
        return 1;
    }
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }

    const char *base = strrchr(argv[1], '/');
    base = base ? base + 1 : argv[1];

    printf("source_file,game_row,move_no,player,square,ply,empty_count,parity,"
           "stone_diff,mobility_diff,corner_diff,x_square_diff,c_square_diff,"
           "frontier_diff,stable_diff,edge_diff\n");

    char line[MAX_LINE];
    char fields[MAX_FIELDS][MAX_FIELD_LEN];
    int line_no = 0, game_row = 0;

    while (fgets(line, sizeof(line), fp)) {
        line_no++;
        char *p = line;
        if ((unsigned char)p[0] == 0xEF && (unsigned char)p[1] == 0xBB && (unsigned char)p[2] == 0xBF) p += 3;
        if (line_no == 1) continue;

        int nf = split_csv(p, fields);
        if (nf < 9) continue;
        const char *transcript = fields[8];
        int n = (int)strlen(transcript) / 2;

        Bitboard black = INIT_BLACK, white = INIT_WHITE;
        int player_is_black = 1;
        int move_no = 0;

        for (int i = 0; i < n; i++) {
            int sq = parse_square(transcript + i * 2);
            if (sq < 0) break;

            Bitboard P = player_is_black ? black : white;
            Bitboard O = player_is_black ? white : black;
            Bitboard legal = get_moves(P, O);
            if (!(legal & (1ULL << sq))) {
                player_is_black = !player_is_black;
                P = player_is_black ? black : white;
                O = player_is_black ? white : black;
                legal = get_moves(P, O);
                if (!(legal & (1ULL << sq))) break;
            }

            Bitboard newP, newO;
            apply_move(P, O, sq, &newP, &newO);
            if (player_is_black) { black = newP; white = newO; }
            else { white = newP; black = newO; }
            move_no++;

            Features feat = extract_features(black, white, player_is_black);
            int empty_count = 64 - popcount(black) - popcount(white);
            char sqstr[3];
            square_to_str(sq, sqstr);

            printf("%s,%d,%d,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
                   base, game_row, move_no, player_is_black ? "black" : "white",
                   sqstr, move_no, empty_count, empty_count % 2,
                   feat.stone_diff, feat.mobility_diff, feat.corner_diff,
                   feat.x_square_diff, feat.c_square_diff, feat.frontier_diff,
                   feat.stable_diff, feat.edge_diff);

            player_is_black = !player_is_black;
        }
        game_row++;
    }
    fclose(fp);
    return 0;
}
