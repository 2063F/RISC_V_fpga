/*
 * 強さ検証用ベンチマーク。
 *
 * 元の開発方針の最終ステップ「自己対戦や既存の弱いAIとの対戦で検証」に対応。
 * 3種類のプレイヤーを用意し、総当りで対戦させて勝率を集計する。
 *   random : 合法手からランダムに選ぶ（最弱の基準点）
 *   greedy : その手を打った直後に取れる石数が最大になる手を選ぶ
 *            （オセロでは「弱い戦略」として有名。序盤に強く打ちすぎると
 *              かえって不利になることを示す代表的な例）
 *   engine : このプロジェクトのAI本体（探索深さ/時間/終盤しきい値を指定可）
 *
 * 対局ごとに先手/後手を入れ替え、さらに序盤数手をランダムに打たせることで
 * （決定的な探索同士でも）毎回違う展開の対局にしてから統計を取る。
 *
 * 使い方:
 *   ./benchmark random   engine:d6:300  50
 *   ./benchmark greedy   engine:d10:1000 50
 *   ./benchmark engine:d6:300 engine:d10:1000 50
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "othello.h"
#include "search.h"

#define OPENING_RANDOM_PLIES 4
#define ENDGAME_THRESHOLD 16

typedef struct {
    const char *name;
    int is_engine;
    int depth;
    long time_ms;
} Agent;

static uint64_t rng_state;
static uint64_t rng_next(void) {
    uint64_t x = rng_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    rng_state = x;
    return x;
}

static int pick_random_move(Bitboard moves) {
    int cand[64], n = 0;
    Bitboard m = moves;
    while (m) { int sq = __builtin_ctzll(m); m &= m - 1; cand[n++] = sq; }
    return cand[rng_next() % n];
}

static int random_agent_move(Bitboard black, Bitboard white, int player_is_black) {
    Bitboard P = player_is_black ? black : white, O = player_is_black ? white : black;
    Bitboard moves = get_moves(P, O);
    if (moves == 0) return -1;
    return pick_random_move(moves);
}

/* その場の石数(own-opp)が最大になる手を選ぶ、いわゆる「大味な」貪欲戦略 */
static int greedy_agent_move(Bitboard black, Bitboard white, int player_is_black) {
    Bitboard P = player_is_black ? black : white, O = player_is_black ? white : black;
    Bitboard moves = get_moves(P, O);
    if (moves == 0) return -1;
    int best_sq = -1, best_diff = -999;
    Bitboard m = moves;
    while (m) {
        int sq = __builtin_ctzll(m); m &= m - 1;
        Bitboard nb, nw;
        apply_move(P, O, sq, &nb, &nw);
        int diff = popcount(nb) - popcount(nw);
        if (diff > best_diff) { best_diff = diff; best_sq = sq; }
    }
    return best_sq;
}

static int engine_agent_move(Bitboard black, Bitboard white, int player_is_black, const Agent *ag) {
    SearchResult r = find_best_move(black, white, player_is_black, ag->depth, ag->time_ms, ENDGAME_THRESHOLD);
    return r.square;
}

static int agent_move(const Agent *ag, Bitboard black, Bitboard white, int player_is_black) {
    if (ag->is_engine) return engine_agent_move(black, white, player_is_black, ag);
    if (strcmp(ag->name, "random") == 0) return random_agent_move(black, white, player_is_black);
    return greedy_agent_move(black, white, player_is_black);
}

static Agent parse_agent(const char *s) {
    Agent a; a.name = s; a.is_engine = 0; a.depth = 0; a.time_ms = 0;
    if (strncmp(s, "engine:d", 8) == 0) {
        a.is_engine = 1;
        int depth = 0; long tms = 0;
        sscanf(s + 8, "%d:%ld", &depth, &tms);
        a.depth = depth; a.time_ms = tms;
    }
    return a;
}

/* 1局対戦する。black_agent/white_agent がそれぞれ黒番/白番を担当。
   戻り値: black石数 - white石数 */
static int play_one_game(const Agent *black_agent, const Agent *white_agent) {
    Bitboard black = INIT_BLACK, white = INIT_WHITE;
    int player_is_black = 1;
    int ply = 0;

    while (1) {
        Bitboard P = player_is_black ? black : white, O = player_is_black ? white : black;
        Bitboard moves = get_moves(P, O);
        Bitboard omoves = get_moves(O, P);
        if (moves == 0 && omoves == 0) break;
        if (moves == 0) { player_is_black = !player_is_black; continue; }

        int sq;
        if (ply < OPENING_RANDOM_PLIES) {
            sq = pick_random_move(moves); /* 序盤は両者ランダムにして対局を多様化 */
        } else {
            const Agent *ag = player_is_black ? black_agent : white_agent;
            sq = agent_move(ag, black, white, player_is_black);
        }
        if (sq < 0) { player_is_black = !player_is_black; continue; }

        Bitboard nb, nw;
        apply_move(P, O, sq, &nb, &nw);
        if (player_is_black) { black = nb; white = nw; } else { white = nb; black = nw; }
        player_is_black = !player_is_black;
        ply++;
    }
    return popcount(black) - popcount(white);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <agentA> <agentB> <n_games> [seed]\n", argv[0]);
        fprintf(stderr, "  agent = random | greedy | engine:d<depth>:<time_ms>\n");
        fprintf(stderr, "  example: %s greedy engine:d8:500 50\n", argv[0]);
        return 1;
    }
    Agent A = parse_agent(argv[1]);
    Agent B = parse_agent(argv[2]);
    int n_games = atoi(argv[3]);
    rng_state = (argc >= 5) ? (uint64_t)strtoull(argv[4], NULL, 10) : (uint64_t)time(NULL);
    if (rng_state == 0) rng_state = 1;

    int a_win = 0, b_win = 0, draw = 0;
    long a_total_diff = 0;

    for (int g = 0; g < n_games; g++) {
        /* 1局ごとに先手後手を入れ替えて公平にする */
        int a_is_black = (g % 2 == 0);
        const Agent *black_agent = a_is_black ? &A : &B;
        const Agent *white_agent = a_is_black ? &B : &A;

        int diff = play_one_game(black_agent, white_agent); /* black - white */
        int a_diff = a_is_black ? diff : -diff;              /* Aから見た石差 */
        a_total_diff += a_diff;

        if (a_diff > 0) a_win++;
        else if (a_diff < 0) b_win++;
        else draw++;

        printf("game %3d: %s(%s) vs %s(%s) -> A_diff=%+3d\n",
               g, A.name, a_is_black ? "黒" : "白", B.name, a_is_black ? "白" : "黒", a_diff);
    }

    printf("\n=== 結果: %s vs %s (%d局, 先手後手を毎局交代) ===\n", A.name, B.name, n_games);
    printf("A(%s) 勝ち: %d  B(%s) 勝ち: %d  引き分け: %d\n", A.name, a_win, B.name, b_win, draw);
    printf("A(%s) 勝率: %.1f%%   平均石差(A視点): %.2f\n",
           A.name, 100.0 * a_win / n_games, (double)a_total_diff / n_games);
    return 0;
}
