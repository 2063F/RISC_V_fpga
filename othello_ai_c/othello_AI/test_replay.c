/*
 * WTHOR形式CSV (...,blackScore,blackTheoreticalScore,transcript) を読み込み、
 * ビットボードエンジンで棋譜を最後まで再生し、
 * 再現した黒石数が blackScore 列と一致するかを検証する。
 *
 * 使い方: ./test_replay file1.csv [file2.csv ...]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "othello.h"

#define MAX_LINE 4096
#define MAX_FIELDS 16
#define MAX_FIELD_LEN 512

/* 簡易CSVパーサ（ダブルクォート対応）。line は破壊されない。
   fields[i] に各フィールドを書き込み、フィールド数を返す。 */
static int split_csv(const char *line, char fields[MAX_FIELDS][MAX_FIELD_LEN]) {
    int nf = 0;
    const char *p = line;
    while (*p && *p != '\n' && *p != '\r' && nf < MAX_FIELDS) {
        int fi = 0;
        if (*p == '"') {
            p++;
            while (*p) {
                if (*p == '"') {
                    if (*(p + 1) == '"') {
                        fields[nf][fi++] = '"';
                        p += 2;
                    } else {
                        p++;
                        break;
                    }
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

/* 棋譜(transcript)を再生する。
   戻り値: 実際に打てた手数。black_out/white_out に最終盤面を格納。
   パスは記録されていないため、現手番で非合法なら相手番を試す。 */
static int replay_transcript(const char *transcript, Bitboard *black_out, Bitboard *white_out) {
    Bitboard black = INIT_BLACK, white = INIT_WHITE;
    int player_is_black = 1;
    int n = (int)strlen(transcript) / 2;
    int played = 0;

    for (int i = 0; i < n; i++) {
        int sq = parse_square(transcript + i * 2);
        if (sq < 0) break;

        Bitboard P = player_is_black ? black : white;
        Bitboard O = player_is_black ? white : black;
        Bitboard legal = get_moves(P, O);

        if (!(legal & (1ULL << sq))) {
            /* パス扱い：手番を入れ替えて再挑戦 */
            player_is_black = !player_is_black;
            P = player_is_black ? black : white;
            O = player_is_black ? white : black;
            legal = get_moves(P, O);
            if (!(legal & (1ULL << sq))) {
                break; /* どちらの手番でも非合法 = 異常データ */
            }
        }

        Bitboard newP, newO;
        apply_move(P, O, sq, &newP, &newO);
        if (player_is_black) {
            black = newP; white = newO;
        } else {
            white = newP; black = newO;
        }
        played++;
        player_is_black = !player_is_black;
    }

    *black_out = black;
    *white_out = white;
    return played;
}

static void self_test(void) {
    /* 初期局面: 黒の合法手は4つ (d3,c4,f5,e6) のはず */
    Bitboard moves = get_moves(INIT_BLACK, INIT_WHITE);
    int cnt = popcount(moves);
    printf("[self_test] initial black legal moves = %d (expect 4)\n", cnt);
    if (cnt != 4) {
        fprintf(stderr, "[self_test] FAILED\n");
        exit(1);
    }

    /* f5 に着手 -> e5が反転し、白の合法手は d6,f4,f6 の3つになるはず */
    Bitboard newB, newW;
    apply_move(INIT_BLACK, INIT_WHITE, parse_square("f5"), &newB, &newW);
    Bitboard wmoves = get_moves(newW, newB);
    int wcnt = popcount(wmoves);
    printf("[self_test] after f5, white legal moves = %d (expect 3)\n", wcnt);
    if (wcnt != 3) {
        fprintf(stderr, "[self_test] FAILED\n");
        exit(1);
    }
    printf("[self_test] OK\n\n");
}

int main(int argc, char **argv) {
    self_test();

    if (argc < 2) {
        fprintf(stderr, "usage: %s file1.csv [file2.csv ...]\n", argv[0]);
        return 1;
    }

    long total_games = 0, total_verified60 = 0, total_matched = 0, total_anomaly = 0;
    char line[MAX_LINE];
    char fields[MAX_FIELDS][MAX_FIELD_LEN];

    for (int fi = 1; fi < argc; fi++) {
        FILE *fp = fopen(argv[fi], "rb");
        if (!fp) {
            fprintf(stderr, "cannot open %s\n", argv[fi]);
            continue;
        }

        long games = 0, matched = 0, verified60 = 0, anomaly = 0;
        int line_no = 0;
        while (fgets(line, sizeof(line), fp)) {
            line_no++;
            char *p = line;
            /* 先頭行のBOM(EF BB BF)を除去 */
            if ((unsigned char)p[0] == 0xEF && (unsigned char)p[1] == 0xBB && (unsigned char)p[2] == 0xBF) {
                p += 3;
            }
            if (line_no == 1) continue; /* header */

            int nf = split_csv(p, fields);
            if (nf < 9) continue;
            const char *black_score_s = fields[6];
            const char *transcript = fields[8];
            int transcript_len = (int)strlen(transcript);
            int move_count = transcript_len / 2;

            Bitboard black, white;
            int played = replay_transcript(transcript, &black, &white);
            games++;
            if (played < move_count) anomaly++;

            if (move_count == 60 && played == 60) {
                verified60++;
                int black_score = atoi(black_score_s);
                if (popcount(black) == black_score) matched++;
            }
        }
        fclose(fp);

        printf("%-40s games=%6ld anomaly=%4ld verify60=%6ld matched=%6ld (%.2f%%)\n",
               argv[fi], games, anomaly, verified60, verified60 ? matched : 0,
               verified60 ? 100.0 * matched / verified60 : 0.0);

        total_games += games;
        total_verified60 += verified60;
        total_matched += matched;
        total_anomaly += anomaly;
    }

    printf("\n=== TOTAL ===\n");
    printf("games=%ld anomaly=%ld verify60=%ld matched=%ld (%.2f%%)\n",
           total_games, total_anomaly, total_verified60, total_matched,
           total_verified60 ? 100.0 * total_matched / total_verified60 : 0.0);

    return 0;
}
