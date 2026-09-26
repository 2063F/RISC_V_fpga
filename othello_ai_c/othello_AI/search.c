#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "othello.h"
#include "evaluate.h"
#include "search.h"

#define TT_BITS 20
#define TT_SIZE (1u << TT_BITS)
#define TT_MASK (TT_SIZE - 1)

typedef enum { TT_EXACT = 0, TT_LOWER = 1, TT_UPPER = 2 } TTFlag;

typedef struct {
    uint64_t hash;
    int8_t depth;
    int8_t flag;
    int8_t best_move;
    int8_t used;
    double value;
} TTEntry;

static TTEntry *tt = NULL;
static uint64_t ZOBRIST[2][64];
static uint64_t ZOBRIST_SIDE;
static int g_init_done = 0;

/* キラームーブ表: 各深さで直近にβカットを起こした手を2つまで記憶し、
   次にその深さへ来たとき最優先で試す（1手先評価より安く、効果は大きい） */
#define MAX_KILLER_DEPTH 64
static int killer[MAX_KILLER_DEPTH][2];

static void store_killer(int depth, int move) {
    if (depth < 0 || depth >= MAX_KILLER_DEPTH) return;
    if (killer[depth][0] == move) return; /* 既に1番手 */
    killer[depth][1] = killer[depth][0];
    killer[depth][0] = move;
}

static clock_t g_start;
static long g_time_limit_ms;
static int g_time_up;
static long g_nodes;

static uint64_t xorshift_state = 88172645463325252ULL;
static uint64_t xorshift64(void) {
    uint64_t x = xorshift_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    xorshift_state = x;
    return x;
}

static void init_engine(void) {
    if (g_init_done) return;
    for (int c = 0; c < 2; c++)
        for (int s = 0; s < 64; s++)
            ZOBRIST[c][s] = xorshift64();
    ZOBRIST_SIDE = xorshift64();
    tt = (TTEntry *)calloc(TT_SIZE, sizeof(TTEntry));
    for (int d = 0; d < MAX_KILLER_DEPTH; d++) { killer[d][0] = -1; killer[d][1] = -1; }
    g_init_done = 1;
}

static uint64_t compute_hash(Bitboard black, Bitboard white, int player_is_black) {
    uint64_t h = 0;
    Bitboard b = black;
    while (b) { int sq = __builtin_ctzll(b); h ^= ZOBRIST[0][sq]; b &= b - 1; }
    Bitboard w = white;
    while (w) { int sq = __builtin_ctzll(w); h ^= ZOBRIST[1][sq]; w &= w - 1; }
    if (player_is_black) h ^= ZOBRIST_SIDE;
    return h;
}

static void time_check(void) {
    long elapsed_ms = (long)((clock() - g_start) * 1000L / CLOCKS_PER_SEC);
    if (elapsed_ms >= g_time_limit_ms) g_time_up = 1;
}

/*
 * negamax + αβ枝刈り + 置換表。
 * depth: 残り探索深さ。パスは depth を消費しない（終盤読み切りの正確さを保つため）。
 * 戻り値は「player_is_black側から見た」評価値。
 *   depth==0 に到達 -> evaluate_position()（学習済み線形回帰）
 *   両者とも合法手なし -> その時点の確定石差（正確な値）
 */
static double negamax(Bitboard black, Bitboard white, int player_is_black,
                       int depth, double alpha, double beta, int *out_move) {
    g_nodes++;
    if ((g_nodes & 1023) == 0) time_check();
    if (g_time_up) { if (out_move) *out_move = -1; return 0.0; }

    Bitboard P = player_is_black ? black : white;
    Bitboard O = player_is_black ? white : black;
    Bitboard moves = get_moves(P, O);

    if (moves == 0) {
        Bitboard omoves = get_moves(O, P);
        if (omoves == 0) {
            int b = popcount(black), w = popcount(white);
            int own = player_is_black ? b : w;
            int opp = player_is_black ? w : b;
            if (out_move) *out_move = -1;
            return (double)(own - opp);
        }
        int child_move;
        double v = -negamax(black, white, !player_is_black, depth, -beta, -alpha, &child_move);
        if (out_move) *out_move = -1;
        return v;
    }

    if (depth <= 0) {
        if (out_move) *out_move = -1;
        return evaluate_position(black, white, player_is_black);
    }

    uint64_t hash = compute_hash(black, white, player_is_black);
    TTEntry *e = &tt[hash & TT_MASK];
    int tt_move = -1;
    double orig_alpha = alpha;
    if (e->used && e->hash == hash) {
        tt_move = e->best_move;
        if (e->depth >= depth) {
            if (e->flag == TT_EXACT) { if (out_move) *out_move = e->best_move; return e->value; }
            else if (e->flag == TT_LOWER) { if (e->value > alpha) alpha = e->value; }
            else if (e->flag == TT_UPPER) { if (e->value < beta) beta = e->value; }
            if (alpha >= beta) { if (out_move) *out_move = e->best_move; return e->value; }
        }
    }

    int sqs[64];
    double order_score[64];
    int n = 0;
    Bitboard m = moves;
    while (m) {
        int sq = __builtin_ctzll(m);
        m &= m - 1;
        sqs[n] = sq;
        Bitboard nb, nw;
        apply_move(P, O, sq, &nb, &nw);
        Bitboard newblack = player_is_black ? nb : nw;
        Bitboard newwhite = player_is_black ? nw : nb;
        double sc = -evaluate_position(newblack, newwhite, !player_is_black);
        if (sq == tt_move) sc += 1e6;               /* 置換表の手を最優先 */
        else if (sq == killer[depth][0]) sc += 5e5;  /* キラームーブ1番手 */
        else if (sq == killer[depth][1]) sc += 4e5;  /* キラームーブ2番手 */
        order_score[n] = sc;
        n++;
    }
    /* 選択ソート（降順）。1ノードあたり高々32手程度なのでO(n^2)で十分 */
    for (int i = 0; i < n; i++) {
        int best = i;
        for (int j = i + 1; j < n; j++) if (order_score[j] > order_score[best]) best = j;
        if (best != i) {
            int ts = sqs[i]; sqs[i] = sqs[best]; sqs[best] = ts;
            double td = order_score[i]; order_score[i] = order_score[best]; order_score[best] = td;
        }
    }

    double best_val = -1e18;
    int best_move = sqs[0];
    const double EPS = 1e-6; /* PVSのnull window幅（doubleなので0ではなく極小値を使う） */

    for (int i = 0; i < n; i++) {
        Bitboard nb, nw;
        apply_move(P, O, sqs[i], &nb, &nw);
        Bitboard newblack = player_is_black ? nb : nw;
        Bitboard newwhite = player_is_black ? nw : nb;
        int child_move;
        double v;

        if (i == 0) {
            /* 最初の手（最も期待できる手）はフルウィンドウで探索 */
            v = -negamax(newblack, newwhite, !player_is_black, depth - 1, -beta, -alpha, &child_move);
        } else {
            /* PVS(NegaScout): まず狭いウィンドウで「alphaを超えるかどうか」だけ安く確認する */
            v = -negamax(newblack, newwhite, !player_is_black, depth - 1, -(alpha + EPS), -alpha, &child_move);
            if (!g_time_up && v > alpha && v < beta) {
                /* 狭いウィンドウで alpha を超えた = 本当に良い手の可能性 -> フルウィンドウで再探索 */
                v = -negamax(newblack, newwhite, !player_is_black, depth - 1, -beta, -alpha, &child_move);
            }
        }

        if (g_time_up) { if (out_move) *out_move = best_move; return best_val > -1e17 ? best_val : 0.0; }
        if (v > best_val) { best_val = v; best_move = sqs[i]; }
        if (v > alpha) alpha = v;
        if (alpha >= beta) {
            store_killer(depth, sqs[i]);
            break;
        }
    }

    TTFlag flag;
    if (best_val <= orig_alpha) flag = TT_UPPER;
    else if (best_val >= beta) flag = TT_LOWER;
    else flag = TT_EXACT;
    e->hash = hash; e->depth = (int8_t)depth; e->flag = (int8_t)flag;
    e->best_move = (int8_t)best_move; e->value = best_val; e->used = 1;

    if (out_move) *out_move = best_move;
    return best_val;
}

static SearchResult iterative_deepening(Bitboard black, Bitboard white, int player_is_black,
                                          int target_depth, long time_limit_ms) {
    g_start = clock();
    g_time_limit_ms = time_limit_ms;
    g_time_up = 0;
    g_nodes = 0;
    for (int d = 0; d < MAX_KILLER_DEPTH; d++) { killer[d][0] = -1; killer[d][1] = -1; }

    SearchResult result;
    result.square = -1;
    result.score = 0.0;
    result.nodes = 0;
    result.depth_reached = 0;

    for (int d = 1; d <= target_depth; d++) {
        int move = -1;
        double val = negamax(black, white, player_is_black, d, -1e18, 1e18, &move);
        if (g_time_up && d > 1) break; /* 深さ1すら終わらないほど時間が無い場合は結果を採用 */
        result.square = move;
        result.score = val;
        result.depth_reached = d;
        result.nodes = g_nodes;
        if (g_time_up) break;
    }
    return result;
}

SearchResult find_best_move(Bitboard black, Bitboard white, int player_is_black,
                             int max_depth, long time_limit_ms, int endgame_threshold) {
    init_engine();
    int empty = 64 - popcount(black) - popcount(white);
    if (empty <= endgame_threshold) {
        return endgame_search(black, white, player_is_black, time_limit_ms);
    }
    return iterative_deepening(black, white, player_is_black, max_depth, time_limit_ms);
}

SearchResult endgame_search(Bitboard black, Bitboard white, int player_is_black, long time_limit_ms) {
    init_engine();
    int empty = 64 - popcount(black) - popcount(white);
    int target_depth = empty + 1; /* pass は depth を消費しないので +1 で十分 */
    if (target_depth < 1) target_depth = 1;
    return iterative_deepening(black, white, player_is_black, target_depth, time_limit_ms);
}
