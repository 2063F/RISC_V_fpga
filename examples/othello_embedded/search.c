#include "othello.h"
#include "evaluate.h"
#include "search.h"

/* キラームーブ表: 各深さで直近にβカットを起こした手を2つまで記憶し、
   次にその深さへ来たとき最優先で試す */
#define MAX_KILLER_DEPTH 64
static int killer[MAX_KILLER_DEPTH][2];

static void store_killer(int depth, int move) {
    if (depth < 0 || depth >= MAX_KILLER_DEPTH) return;
    if (killer[depth][0] == move) return; /* 既に1番手 */
    killer[depth][1] = killer[depth][0];
    killer[depth][0] = move;
}

static long g_nodes;

/*
 * negamax + αβ枝刈り + PVS(NegaScout)。
 * オリジナル版にあった置換表(hash)は使わない: 評価値によるムーブオーダリングと
 * キラームーブだけでも実用的な枝刈りが得られ、RAMもほぼ使わない。
 */
static double negamax(Bitboard black, Bitboard white, int player_is_black,
                       int depth, double alpha, double beta, int *out_move) {
    g_nodes++;

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

    int sqs[64];
    double order_score[64];
    int n = 0;
    Bitboard m = moves;
    while (m) {
        int sq = ctz64(m);
        m &= m - 1;
        sqs[n] = sq;
        Bitboard nb, nw;
        apply_move(P, O, sq, &nb, &nw);
        Bitboard newblack = player_is_black ? nb : nw;
        Bitboard newwhite = player_is_black ? nw : nb;
        double sc = -evaluate_position(newblack, newwhite, !player_is_black);
        if (sq == killer[depth][0]) sc += 5e5;       /* キラームーブ1番手 */
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
    const double EPS = 1e-6; /* PVSのnull window幅 */

    for (int i = 0; i < n; i++) {
        Bitboard nb, nw;
        apply_move(P, O, sqs[i], &nb, &nw);
        Bitboard newblack = player_is_black ? nb : nw;
        Bitboard newwhite = player_is_black ? nw : nb;
        int child_move;
        double v;

        if (i == 0) {
            v = -negamax(newblack, newwhite, !player_is_black, depth - 1, -beta, -alpha, &child_move);
        } else {
            v = -negamax(newblack, newwhite, !player_is_black, depth - 1, -(alpha + EPS), -alpha, &child_move);
            if (v > alpha && v < beta) {
                v = -negamax(newblack, newwhite, !player_is_black, depth - 1, -beta, -alpha, &child_move);
            }
        }

        if (v > best_val) { best_val = v; best_move = sqs[i]; }
        if (v > alpha) alpha = v;
        if (alpha >= beta) {
            store_killer(depth, sqs[i]);
            break;
        }
    }

    if (out_move) *out_move = best_move;
    return best_val;
}

SearchResult find_best_move(Bitboard black, Bitboard white, int player_is_black,
                             int search_depth) {
    g_nodes = 0;
    for (int d = 0; d < MAX_KILLER_DEPTH; d++) { killer[d][0] = -1; killer[d][1] = -1; }

    int empty = 64 - popcount(black) - popcount(white);
    int depth = search_depth;
    if (empty <= search_depth) depth = empty + 1; /* 終局まで正確に読み切る */
    if (depth < 1) depth = 1;
    if (depth >= MAX_KILLER_DEPTH) depth = MAX_KILLER_DEPTH - 1;

    int move = -1;
    double val = negamax(black, white, player_is_black, depth, -1e18, 1e18, &move);

    SearchResult result;
    result.square = move;
    result.score = val;
    result.nodes = g_nodes;
    result.depth_reached = depth;
    return result;
}

#define CORNER_SQUARES 0x8100000000000081ULL

SearchResult find_weak_move(Bitboard black, Bitboard white, int player_is_black,
                             WeakPick pick, uint32_t rnd) {
    Bitboard P = player_is_black ? black : white;
    Bitboard O = player_is_black ? white : black;
    Bitboard moves = get_moves(P, O);
    int avoid_corners = (pick == PICK_WORST);

    int sqs[64];
    double score[64];
    int n = 0;
    Bitboard m = moves;
    while (m) {
        int sq = ctz64(m);
        m &= m - 1;
        Bitboard nb, nw;
        apply_move(P, O, sq, &nb, &nw);
        Bitboard newblack = player_is_black ? nb : nw;
        Bitboard newwhite = player_is_black ? nw : nb;
        double sc = -evaluate_position(newblack, newwhite, !player_is_black);
        if (avoid_corners && ((CORNER_SQUARES >> sq) & 1u)) sc += 1e9; /* 角は最後の手段 */
        sqs[n] = sq;
        score[n] = sc;
        n++;
    }

    /* 選択ソート（昇順）: 手番側にとって悪い手ほど前へ */
    for (int i = 0; i < n; i++) {
        int worst = i;
        for (int j = i + 1; j < n; j++) if (score[j] < score[worst]) worst = j;
        if (worst != i) {
            int ts = sqs[i]; sqs[i] = sqs[worst]; sqs[worst] = ts;
            double td = score[i]; score[i] = score[worst]; score[worst] = td;
        }
    }

    SearchResult result;
    result.square = -1;
    result.score = 0.0;
    result.nodes = n;
    result.depth_reached = 1;
    if (n == 0) return result;

    /* 候補を [lo, lo+k) に絞り、その中からランダムに選ぶ。
       常に同じ手を選ぶと見え見えなので、どのレベルも少しばらつかせる */
    int lo, k;
    if (pick == PICK_WORST) {
        /* 角はソートで末尾に集まっているので、角以外の手だけを候補にする */
        int pool = n - popcount(moves & CORNER_SQUARES);
        if (pool == 0) pool = n;
        lo = 0;
        k = (pool + 2) / 3;           /* 悪い方から1/3 */
    } else if (pick == PICK_RANDOM) {
        lo = 0;
        k = n;                        /* 全合法手から完全ランダム */
    } else {
        k = (n + 2) / 3;              /* 良い方から1/3 */
        lo = n - k;
    }
    int idx = lo + (int)(rnd % (uint32_t)k);
    result.square = sqs[idx];
    result.score = score[idx];
    return result;
}
