/*
 * GUI(othello_gui.py)からAIの手を問い合わせるための常駐プロセス。
 * 標準入力から1行ずつコマンドを受け取り、標準出力に結果を1行返す。
 * (プロセスを毎手起動し直すと置換表が毎回空になり遅くなるため、
 *  対局中はこのプロセスを立ち上げっぱなしにして使う)
 *
 * コマンド:
 *   BESTMOVE <black_hex16> <white_hex16> <player:b|w> <max_depth> <time_ms> <endgame_threshold>
 *     -> MOVE <square|PASS> <score> <depth> <nodes>
 *   QUIT
 *     -> プロセス終了
 *
 * black_hex16/white_hex16 は uint64_t のビットボードを16桁の16進数で表したもの。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include "othello.h"
#include "search.h"

int main(void) {
    char line[256];
    setvbuf(stdout, NULL, _IOLBF, 0); /* 行バッファ: 1行書いたらすぐ相手に届くようにする */

    while (fgets(line, sizeof(line), stdin)) {
        char cmd[32];
        if (sscanf(line, "%31s", cmd) != 1) continue;

        if (strcmp(cmd, "QUIT") == 0) {
            break;
        } else if (strcmp(cmd, "BESTMOVE") == 0) {
            char black_hex[32], white_hex[32], player_ch[8];
            int max_depth; long time_ms; int endgame_threshold;
            int got = sscanf(line, "%*s %31s %31s %7s %d %ld %d",
                              black_hex, white_hex, player_ch,
                              &max_depth, &time_ms, &endgame_threshold);
            if (got != 6) {
                printf("ERROR bad BESTMOVE args\n");
                continue;
            }
            Bitboard black = (Bitboard)strtoull(black_hex, NULL, 16);
            Bitboard white = (Bitboard)strtoull(white_hex, NULL, 16);
            int player_is_black = (player_ch[0] == 'b' || player_ch[0] == 'B');

            SearchResult r = find_best_move(black, white, player_is_black,
                                             max_depth, time_ms, endgame_threshold);
            if (r.square < 0) {
                printf("MOVE PASS %.2f %d %ld\n", r.score, r.depth_reached, r.nodes);
            } else {
                char s[3];
                square_to_str(r.square, s);
                printf("MOVE %s %.2f %d %ld\n", s, r.score, r.depth_reached, r.nodes);
            }
        } else {
            printf("ERROR unknown command\n");
        }
    }
    return 0;
}
