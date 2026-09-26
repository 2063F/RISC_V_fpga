/* 経過時間の測り方:
 *   PC版 / ホスト上のテスト版 : clock()
 *   FPGA版                    : CPU のサイクルカウンタ (MMIO 0x8000_0020, 50MHz) */
#if defined(OTHELLO_BAREMETAL) && !defined(OTHELLO_HOST_TEST)
#define USE_CYCLE_COUNTER 1
#endif

#ifndef OTHELLO_BAREMETAL
#include <stdlib.h>
#endif
#ifndef USE_CYCLE_COUNTER
#include <time.h>
#endif
#include "othello.h"
#include "evaluate.h"
#include "search.h"

/* 置換表のサイズ(2^TT_BITS エントリ)。ベアメタル版は RAM 64KB に収まるよう小さくする */
#ifndef TT_BITS
#ifdef OTHELLO_BAREMETAL
#define TT_BITS 10
#else
#define TT_BITS 20
#endif
#endif
#define TT_SIZE (1u << TT_BITS)
#define TT_MASK (TT_SIZE - 1)

typedef enum { TT_EXACT = 0, TT_LOWER = 1, TT_UPPER = 2 } TTFlag;

typedef struct {
    uint64_t hash;
    int8_t depth;
    int8_t flag;
    int8_t best_move;
    int8_t used;
    Score value;
} TTEntry;

#ifdef OTHELLO_BAREMETAL
static TTEntry tt_storage[TT_SIZE]; /* malloc が無いので静的確保(.bss でゼロ初期化) */
static TTEntry *tt = tt_storage;
#else
static TTEntry *tt = NULL;
#endif
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

/* 探索で使う定数。PC版(double)は従来と同じ値、ベアメタル版(int32固定小数点)は
   オーバーフローしない範囲の値にする */
#ifdef OTHELLO_BAREMETAL
#define SCORE_INF ((Score)0x3FFFFFFF)
#define SCORE_EPS ((Score)1)
#else
#define SCORE_INF 1e18
#define SCORE_EPS 1e-6
#endif
/* 手の並べ替え用ボーナス（石数換算。評価値の範囲より十分大きければよい） */
#define ORDER_BONUS_TT     ((Score)1000000 * SCORE_SCALE)
#define ORDER_BONUS_KILLER1 ((Score)500000 * SCORE_SCALE)
#define ORDER_BONUS_KILLER2 ((Score)400000 * SCORE_SCALE)

/*
 * 時間管理。FPGA版は1ノードが数十μs掛かるので毎ノード時刻を確認する
 * （サイクルカウンタの読み出しはロード1命令なので安い）。
 */
#ifdef USE_CYCLE_COUNTER
#define CYCLE_COUNTER (*(volatile uint32_t *)0x80000020)
#ifndef OTHELLO_CPU_KHZ
#define OTHELLO_CPU_KHZ 50000u /* 50 MHz */
#endif
#define TIME_CHECK_MASK 0
static uint32_t g_start;
static uint32_t g_limit_cycles;
#else
#ifdef OTHELLO_BAREMETAL
#define TIME_CHECK_MASK 15
#else
#define TIME_CHECK_MASK 1023
#endif
static clock_t g_start;
#endif
static long g_time_limit_ms;
/* 反復深化の各反復でルート局面を探索中か。時間切れで打ち切られた反復でも、
   ルートの手を1つ以上最後まで読めていればその結果を使う */
static int g_is_root;
static int g_root_move_done;
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
#ifndef OTHELLO_BAREMETAL
    tt = (TTEntry *)calloc(TT_SIZE, sizeof(TTEntry));
#endif
    for (int d = 0; d < MAX_KILLER_DEPTH; d++) { killer[d][0] = -1; killer[d][1] = -1; }
    g_init_done = 1;
}

#ifdef OTHELLO_BAREMETAL
/* ベアメタル版は Zobrist (石の数だけ表引き) の代わりに乗算による混合で求める。
   RV32 では1局面あたり数百サイクル速い。置換表は64bit全体を照合するので、
   衝突の起きにくさは Zobrist と同程度 */
static inline uint64_t mix64(uint64_t x) {
    x ^= x >> 31;
    x *= 0x7FB5D329728EA185ULL;
    x ^= x >> 27;
    x *= 0x81DADEF4BC2DD44DULL;
    x ^= x >> 33;
    return x;
}

static uint64_t compute_hash(Bitboard black, Bitboard white, int player_is_black) {
    uint64_t h = mix64(black ^ mix64(white + 0x9E3779B97F4A7C15ULL));
    if (player_is_black) h ^= ZOBRIST_SIDE;
    return h;
}
#else
static uint64_t compute_hash(Bitboard black, Bitboard white, int player_is_black) {
    uint64_t h = 0;
    Bitboard b = black;
    while (b) { int sq = ctz64(b); h ^= ZOBRIST[0][sq]; b &= b - 1; }
    Bitboard w = white;
    while (w) { int sq = ctz64(w); h ^= ZOBRIST[1][sq]; w &= w - 1; }
    if (player_is_black) h ^= ZOBRIST_SIDE;
    return h;
}
#endif

static void timer_start(long time_limit_ms) {
    g_time_limit_ms = time_limit_ms;
#ifdef USE_CYCLE_COUNTER
    /* 32bit カウンタなので約85秒までしか測れない。それ以上は切り詰める */
    if (time_limit_ms > 80000) time_limit_ms = 80000;
    if (time_limit_ms < 0) time_limit_ms = 0;
    g_limit_cycles = (uint32_t)time_limit_ms * OTHELLO_CPU_KHZ;
    g_start = CYCLE_COUNTER;
#else
    g_start = clock();
#endif
}

/* 開始時刻はそのままで、制限時間だけ変える */
static void timer_extend(long time_limit_ms) {
    g_time_limit_ms = time_limit_ms;
#ifdef USE_CYCLE_COUNTER
    if (time_limit_ms > 80000) time_limit_ms = 80000;
    if (time_limit_ms < 0) time_limit_ms = 0;
    g_limit_cycles = (uint32_t)time_limit_ms * OTHELLO_CPU_KHZ;
#endif
}

#ifndef USE_CYCLE_COUNTER
static long elapsed_ms(void) {
    return (long)((clock() - g_start) * 1000L / CLOCKS_PER_SEC);
}
#endif

static void time_check(void) {
#ifdef USE_CYCLE_COUNTER
    if (CYCLE_COUNTER - g_start >= g_limit_cycles) g_time_up = 1;
#else
    if (elapsed_ms() >= g_time_limit_ms) g_time_up = 1;
#endif
}

/*
 * 深さ0の局面の値（negamax を depth=0 で呼んだのと同じ結果を返す）。
 * P = 手番側。合法手が無ければパスして相手側から評価し、両者とも無ければ終局の石差。
 */
static Score leaf_value(Bitboard P, Bitboard O) {
    g_nodes++;
    Bitboard pm = get_moves(P, O);
    Bitboard om = get_moves(O, P);
    if (pm) return evaluate_po(P, O, pm, om);
    if (!om) return (Score)(popcount(P) - popcount(O)) * SCORE_SCALE;
    g_nodes++; /* パスした先の局面も1ノードと数える（従来の数え方に合わせる） */
    return -evaluate_po(O, P, om, pm);
}

/*
 * negamax + αβ枝刈り + 置換表。
 * depth: 残り探索深さ。パスは depth を消費しない（終盤読み切りの正確さを保つため）。
 * 戻り値は「player_is_black側から見た」評価値。
 *   depth==0 に到達 -> evaluate_position()（学習済み線形回帰）
 *   両者とも合法手なし -> その時点の確定石差（正確な値）
 */
static Score negamax(Bitboard black, Bitboard white, int player_is_black,
                      int depth, Score alpha, Score beta, int *out_move) {
    int is_root = g_is_root;
    g_is_root = 0;
    g_nodes++;
    if ((g_nodes & TIME_CHECK_MASK) == 0) time_check();
    if (g_time_up) { if (out_move) *out_move = -1; return 0; }

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
            return (Score)(own - opp) * SCORE_SCALE;
        }
        int child_move;
        Score v = -negamax(black, white, !player_is_black, depth, -beta, -alpha, &child_move);
        if (out_move) *out_move = -1;
        return v;
    }

    if (depth <= 0) {
        if (out_move) *out_move = -1;
        return evaluate_po(P, O, moves, get_moves(O, P));
    }

    uint64_t hash = compute_hash(black, white, player_is_black);
    TTEntry *e = &tt[hash & TT_MASK];
    int tt_move = -1;
    Score orig_alpha = alpha;
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
    Score order_score[64];
    int n = 0;
    Bitboard m = moves;

    if (depth == 1) {
        /*
         * 残り深さ1: 子はすべて葉なので、子の値 = 子の評価値。
         * 並べ替えのために全ての子を評価してから negamax(depth=0) で評価し直すと
         * 同じ評価を2回計算することになるので、ここで子を1回ずつ評価する。
         * 置換表の手・キラームーブを先に試し、β以上の手が見つかった時点で打ち切る。
         */
        Score best_val = -SCORE_INF;
        int best_move = -1;
        int first[3] = { tt_move, killer[1][0], killer[1][1] };
        Bitboard rest = moves;
        for (int k = 0; k < 3 + 64; k++) {
            int sq;
            if (k < 3) {
                sq = first[k];
                if (sq < 0 || !(rest & (1ULL << sq))) continue;
            } else {
                if (!rest) break;
                sq = ctz64(rest);
            }
            rest &= ~(1ULL << sq);
            Bitboard nP, nO;
            apply_move(P, O, sq, &nP, &nO);
            Score v = -leaf_value(nO, nP);
            if (v > best_val) { best_val = v; best_move = sq; }
            if (v >= beta) { store_killer(1, sq); break; }
        }
        TTFlag flag1;
        if (best_val <= orig_alpha) flag1 = TT_UPPER;
        else if (best_val >= beta) flag1 = TT_LOWER;
        else flag1 = TT_EXACT;
        e->hash = hash; e->depth = 1; e->flag = (int8_t)flag1;
        e->best_move = (int8_t)best_move; e->value = best_val; e->used = 1;
        if (out_move) *out_move = best_move;
        return best_val;
    }

    while (m) {
        int sq = ctz64(m);
        m &= m - 1;
        sqs[n] = sq;
        Bitboard nP, nO;
        apply_move(P, O, sq, &nP, &nO);
        Score sc;
        if (depth == 2) {
            /* 残り深さ2では並べ替えに評価関数を使わず、相手の着手可能数が少ない順にする
               （評価関数の約1/3のコスト。子の深さ1ノードは TT/キラーから先に試すので十分） */
            sc = -(Score)popcount(get_moves(nO, nP)) * SCORE_SCALE;
        } else {
            sc = -evaluate_po(nO, nP, get_moves(nO, nP), get_moves(nP, nO));
        }
        if (sq == tt_move) sc += ORDER_BONUS_TT;                 /* 置換表の手を最優先 */
        else if (sq == killer[depth][0]) sc += ORDER_BONUS_KILLER1; /* キラームーブ1番手 */
        else if (sq == killer[depth][1]) sc += ORDER_BONUS_KILLER2; /* キラームーブ2番手 */
        order_score[n] = sc;
        n++;
    }
    /* 選択ソート（降順）。1ノードあたり高々32手程度なのでO(n^2)で十分 */
    for (int i = 0; i < n; i++) {
        int best = i;
        for (int j = i + 1; j < n; j++) if (order_score[j] > order_score[best]) best = j;
        if (best != i) {
            int ts = sqs[i]; sqs[i] = sqs[best]; sqs[best] = ts;
            Score td = order_score[i]; order_score[i] = order_score[best]; order_score[best] = td;
        }
    }

    Score best_val = -SCORE_INF;
    int best_move = sqs[0];
    const Score EPS = SCORE_EPS; /* PVSのnull window幅（double版は0ではなく極小値、固定小数点版は1） */

    for (int i = 0; i < n; i++) {
        Bitboard nb, nw;
        apply_move(P, O, sqs[i], &nb, &nw);
        Bitboard newblack = player_is_black ? nb : nw;
        Bitboard newwhite = player_is_black ? nw : nb;
        int child_move;
        Score v;

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

        if (g_time_up) { if (out_move) *out_move = best_move; return best_val > -SCORE_INF ? best_val : 0; }
        if (is_root) g_root_move_done = 1;
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

/* 反復深化の本体。タイマーは呼び出し側で開始しておくこと */
static SearchResult iterative_deepening_run(Bitboard black, Bitboard white, int player_is_black,
                                             int target_depth) {
    g_time_up = 0;
    for (int d = 0; d < MAX_KILLER_DEPTH; d++) { killer[d][0] = -1; killer[d][1] = -1; }

    SearchResult result;
    result.square = -1;
    result.score = 0;
    result.nodes = 0;
    result.depth_reached = 0;

    for (int d = 1; d <= target_depth; d++) {
        int move = -1;
        g_is_root = 1;
        g_root_move_done = 0;
        Score val = negamax(black, white, player_is_black, d, -SCORE_INF, SCORE_INF, &move);
        if (g_time_up && d > 1) {
            /* 途中で時間切れ。ルートの最初の手(前回の最善手)を読み終えていれば、
               読み終えた手の中の最善はこの深さでも前回の最善手以上なので採用する */
            if (g_root_move_done && move >= 0) {
                result.square = move;
                result.score = val;
            }
            break;
        }
        result.square = move;
        result.score = val;
        result.depth_reached = d;
        result.nodes = g_nodes;
        if (g_time_up) break;
    }
    result.nodes = g_nodes;
    return result;
}

static SearchResult iterative_deepening(Bitboard black, Bitboard white, int player_is_black,
                                          int target_depth, long time_limit_ms) {
    timer_start(time_limit_ms);
    g_nodes = 0;
    return iterative_deepening_run(black, white, player_is_black, target_depth);
}

/* ------------------------------------------------------------------------
 * 終盤完全読み専用ソルバ。
 * 評価関数を使わず、終局時の石差 (手番側 - 相手) を整数で正確に求める。
 *   - 空きが多いうちは「相手の着手可能数が少ない手から」(fastest-first) 並べ替える
 *   - 空きが少なくなったら並べ替えはせず、最後の1マスは直接石差を計算する
 * ------------------------------------------------------------------------ */
#define SOLVE_ORDER_MIN_EMPTY 6   /* 空きがこれ以上なら手を並べ替える */
#define SOLVE_INF 127

#define SOLVE_SMALL_EMPTY 5       /* 空きがこれ以下なら合法手生成をせず空きマスを直接試す */

/*
 * 空きが少ないときの完全読み。get_moves で合法手を列挙する代わりに、
 * 空きマスそれぞれで裏返る石を直接計算する（空きが少ないとこの方が速い）。
 */
static int solve_small(Bitboard P, Bitboard O, int alpha, int beta, int n_empty, Bitboard empties) {
    g_nodes++;
    if ((g_nodes & TIME_CHECK_MASK) == 0) time_check();
    if (g_time_up) return 0;

    if (n_empty == 1) {
        int sq = ctz64(empties);
        Bitboard f = compute_flips(P, O, sq);
        if (f) {
            int nf = popcount(f);
            return (popcount(P) + 1 + nf) - (popcount(O) - nf);
        }
        f = compute_flips(O, P, sq);
        if (f) {
            int nf = popcount(f);
            return (popcount(P) - nf) - (popcount(O) + 1 + nf);
        }
        return popcount(P) - popcount(O);
    }

    int best = -SOLVE_INF;
    Bitboard e = empties;
    while (e) {
        int sq = ctz64(e);
        Bitboard bit = e & (0 - e);
        e &= e - 1;
        Bitboard f = compute_flips(P, O, sq);
        if (!f) continue;
        int v = -solve_small(O & ~f, P | f | bit, -beta, -alpha, n_empty - 1, empties & ~bit);
        if (v > best) {
            best = v;
            if (v > alpha) { alpha = v; if (alpha >= beta) break; }
        }
    }
    if (best == -SOLVE_INF) {
        /* 打てる手が無い: 相手も打てなければ終局、打てればパス */
        e = empties;
        while (e) {
            int sq = ctz64(e);
            e &= e - 1;
            if (compute_flips(O, P, sq))
                return -solve_small(O, P, -beta, -alpha, n_empty, empties);
        }
        return popcount(P) - popcount(O);
    }
    return best;
}

static int solve(Bitboard P, Bitboard O, int alpha, int beta, int n_empty) {
    if (n_empty <= SOLVE_SMALL_EMPTY)
        return solve_small(P, O, alpha, beta, n_empty, ~(P | O));

    g_nodes++;
    if ((g_nodes & TIME_CHECK_MASK) == 0) time_check();
    if (g_time_up) return 0;

    Bitboard moves = get_moves(P, O);
    if (!moves) {
        Bitboard om = get_moves(O, P);
        if (!om) return popcount(P) - popcount(O);
        return -solve(O, P, -beta, -alpha, n_empty);
    }

    Bitboard nP, nO;
    if (n_empty == 1) {
        /* 最後の1マス: 打てばそのまま終局 */
        apply_move(P, O, ctz64(moves), &nP, &nO);
        return popcount(nP) - popcount(nO);
    }

    int best = -SOLVE_INF;
    if (n_empty >= SOLVE_ORDER_MIN_EMPTY) {
        Bitboard cP[32], cO[32];
        int key[32];
        int n = 0;
        Bitboard m = moves;
        while (m && n < 32) {
            int sq = ctz64(m);
            m &= m - 1;
            apply_move(P, O, sq, &nP, &nO);
            int k = popcount(get_moves(nO, nP));   /* 相手の着手可能数 */
            /* 挿入ソート（key 昇順） */
            int i = n++;
            while (i > 0 && key[i - 1] > k) {
                key[i] = key[i - 1]; cP[i] = cP[i - 1]; cO[i] = cO[i - 1];
                i--;
            }
            key[i] = k; cP[i] = nP; cO[i] = nO;
        }
        for (int i = 0; i < n; i++) {
            int v;
            if (i == 0) {
                v = -solve(cO[i], cP[i], -beta, -alpha, n_empty - 1);
            } else {
                /* PVS: まず null window で alpha を超えるか確かめる */
                v = -solve(cO[i], cP[i], -alpha - 1, -alpha, n_empty - 1);
                if (!g_time_up && v > alpha && v < beta)
                    v = -solve(cO[i], cP[i], -beta, -alpha, n_empty - 1);
            }
            if (g_time_up) return 0;
            if (v > best) {
                best = v;
                if (v > alpha) { alpha = v; if (alpha >= beta) break; }
            }
        }
    } else {
        Bitboard m = moves;
        while (m) {
            int sq = ctz64(m);
            m &= m - 1;
            apply_move(P, O, sq, &nP, &nO);
            int v = -solve(nO, nP, -beta, -alpha, n_empty - 1);
            if (v > best) {
                best = v;
                if (v > alpha) { alpha = v; if (alpha >= beta) break; }
            }
        }
    }
    return best;
}

/* 完全読み。読み切れたら 1 を返し、*best_sq / *score に結果を入れる。
   first_sq を最初に調べる（中盤探索の最善手を渡すと枝刈りが効きやすい） */
static int solve_root(Bitboard P, Bitboard O, int first_sq, int *best_sq, int *score) {
    int n_empty = 64 - popcount(P) - popcount(O);
    Bitboard moves = get_moves(P, O);
    if (!moves) return 0;

    int sqs[32], key[32];
    int n = 0;
    Bitboard m = moves;
    while (m && n < 32) {
        int sq = ctz64(m);
        m &= m - 1;
        Bitboard nP, nO;
        apply_move(P, O, sq, &nP, &nO);
        int k = (sq == first_sq) ? -1 : popcount(get_moves(nO, nP));
        int i = n++;
        while (i > 0 && key[i - 1] > k) { key[i] = key[i - 1]; sqs[i] = sqs[i - 1]; i--; }
        key[i] = k; sqs[i] = sq;
    }

    int alpha = -SOLVE_INF, beta = SOLVE_INF, best = sqs[0];
    for (int i = 0; i < n; i++) {
        Bitboard nP, nO;
        apply_move(P, O, sqs[i], &nP, &nO);
        int v;
        if (i == 0) {
            v = -solve(nO, nP, -beta, -alpha, n_empty - 1);
        } else {
            v = -solve(nO, nP, -alpha - 1, -alpha, n_empty - 1);
            if (!g_time_up && v > alpha)
                v = -solve(nO, nP, -beta, -alpha, n_empty - 1);
        }
        if (g_time_up) return 0;
        if (v > alpha) { alpha = v; best = sqs[i]; }
    }
    *best_sq = best;
    *score = alpha;
    return 1;
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

/*
 * 終盤: まず持ち時間の1/6で通常の探索をして手を確保し、残りの時間で完全読みを試みる。
 * 時間内に読み切れればその手（石差は正確な値）、読み切れなければ通常探索の手を返す。
 */
SearchResult endgame_search(Bitboard black, Bitboard white, int player_is_black, long time_limit_ms) {
    init_engine();
    int empty = 64 - popcount(black) - popcount(white);
    int target_depth = empty + 1; /* pass は depth を消費しないので +1 で十分 */
    if (target_depth < 1) target_depth = 1;

    g_nodes = 0;
    timer_start(time_limit_ms / 6);
    SearchResult r = iterative_deepening_run(black, white, player_is_black, target_depth);
    if (r.square < 0) return r; /* パス */

    timer_extend(time_limit_ms);
    g_time_up = 0;
    Bitboard P = player_is_black ? black : white;
    Bitboard O = player_is_black ? white : black;
    int sq, v;
    if (solve_root(P, O, r.square, &sq, &v)) {
        r.square = sq;
        r.score = (Score)v * SCORE_SCALE;
        r.depth_reached = empty;
    }
    r.nodes = g_nodes;
    return r;
}
