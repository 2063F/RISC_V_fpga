/*
 * オセロAI 対戦用CLI。
 *
 * 通常対戦:  ./play            (人間=黒 vs AI=白)
 *           ./play white       (人間=白 vs AI=黒)
 * 自己対戦テスト（AI vs AI を複数局回して、探索が正常終了するか確認）:
 *           ./play --selfplay 20
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "othello.h"
#include "search.h"

#define AI_MAX_DEPTH 30      /* 事実上の上限なし。実際の深さは時間予算(AI_TIME_MS)で決まる */
#define AI_TIME_MS 2000
#define ENDGAME_THRESHOLD 16 /* 残り16マス以下で完全読みに切り替え（手元の計測では平均1.5秒程度） */

static void print_board_ui(Bitboard black, Bitboard white) {
    printf("\n   a b c d e f g h\n");
    for (int r = 7; r >= 0; r--) {
        printf("%2d ", r + 1);
        for (int c = 0; c < 8; c++) {
            int sq = sq_of(c, r);
            Bitboard bit = 1ULL << sq;
            char ch = '.';
            if (black & bit) ch = 'X';
            else if (white & bit) ch = 'O';
            printf("%c ", ch);
        }
        printf("\n");
    }
    printf("黒(X)=%d 白(O)=%d\n", popcount(black), popcount(white));
}

static int ai_move(Bitboard black, Bitboard white, int player_is_black) {
    SearchResult r = find_best_move(black, white, player_is_black,
                                     AI_MAX_DEPTH, AI_TIME_MS, ENDGAME_THRESHOLD);
    char s[3];
    if (r.square >= 0) square_to_str(r.square, s); else strcpy(s, "--");
    printf("[AI] 着手=%s 評価値=%.2f 深さ=%d ノード数=%ld\n",
           s, r.score, r.depth_reached, r.nodes);
    return r.square;
}

static void play_human(int human_is_black) {
    Bitboard black = INIT_BLACK, white = INIT_WHITE;
    int player_is_black = 1; /* 黒から開始 */

    while (1) {
        Bitboard P = player_is_black ? black : white;
        Bitboard O = player_is_black ? white : black;
        Bitboard moves = get_moves(P, O);
        Bitboard omoves = get_moves(O, P);

        if (moves == 0 && omoves == 0) break; /* 終局 */

        print_board_ui(black, white);

        if (moves == 0) {
            printf("%s は合法手が無いためパスします。\n", player_is_black ? "黒" : "白");
            player_is_black = !player_is_black;
            continue;
        }

        int sq;
        int is_human_turn = (player_is_black == human_is_black);
        if (is_human_turn) {
            printf("%s(あなた)の番です。着手可能: ", player_is_black ? "黒" : "白");
            Bitboard m = moves;
            while (m) {
                int s = __builtin_ctzll(m);
                m &= m - 1;
                char buf[3]; square_to_str(s, buf);
                printf("%s ", buf);
            }
            printf("\n手を入力してください (例: f5): ");
            char line[32];
            if (!fgets(line, sizeof(line), stdin)) return;
            sq = parse_square(line);
            if (sq < 0 || !(moves & (1ULL << sq))) {
                printf("不正な手です。もう一度。\n");
                continue;
            }
        } else {
            sq = ai_move(black, white, player_is_black);
            if (sq < 0) { player_is_black = !player_is_black; continue; }
        }

        Bitboard nb, nw;
        apply_move(P, O, sq, &nb, &nw);
        if (player_is_black) { black = nb; white = nw; } else { white = nb; black = nw; }
        player_is_black = !player_is_black;
    }

    print_board_ui(black, white);
    int b = popcount(black), w = popcount(white);
    if (b > w) printf("黒の勝ち！ (%d - %d)\n", b, w);
    else if (w > b) printf("白の勝ち！ (%d - %d)\n", w, b);
    else printf("引き分け (%d - %d)\n", b, w);
}

static void selfplay(int n_games) {
    long total_nodes = 0;
    for (int g = 0; g < n_games; g++) {
        Bitboard black = INIT_BLACK, white = INIT_WHITE;
        int player_is_black = 1;
        int plies = 0;

        while (1) {
            Bitboard P = player_is_black ? black : white;
            Bitboard O = player_is_black ? white : black;
            Bitboard moves = get_moves(P, O);
            Bitboard omoves = get_moves(O, P);
            if (moves == 0 && omoves == 0) break;
            if (moves == 0) { player_is_black = !player_is_black; continue; }

            /* 自己対戦は高速化のため浅め＆終盤しきい値も小さくする
               （ENDGAME_THRESHOLDのまま200msだと終盤読み切りが時間切れで
                 中断されやすく、実行ごとに結果がぶれてしまうため） */
            SearchResult r = find_best_move(black, white, player_is_black,
                                             6, 200, 10);
            total_nodes += r.nodes;
            int sq = r.square;
            if (sq < 0) { player_is_black = !player_is_black; continue; }

            Bitboard nb, nw;
            apply_move(P, O, sq, &nb, &nw);
            if (player_is_black) { black = nb; white = nw; } else { white = nb; black = nw; }
            player_is_black = !player_is_black;
            plies++;
            if (plies > 200) { fprintf(stderr, "game %d: 異常に長い(%d手)。中断。\n", g, plies); break; }
        }

        int b = popcount(black), w = popcount(white);
        int total = b + w;
        printf("game %2d: black=%2d white=%2d total=%2d %s\n",
               g, b, w, total, (total == 64 || total < 64) ? "OK" : "??");
        if (b + w > 64) {
            fprintf(stderr, "game %d: 石の総数が64を超えています！バグの可能性。\n", g);
        }
    }
    printf("selfplay done. total nodes searched = %ld\n", total_nodes);
}

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "--selfplay") == 0) {
        selfplay(atoi(argv[2]));
        return 0;
    }
    int human_is_black = 1;
    if (argc >= 2 && strcmp(argv[1], "white") == 0) human_is_black = 0;
    play_human(human_is_black);
    return 0;
}
