#include "othello.h"
#include "evaluate.h"
#include "search.h"

/*
 * 2 ハートでの並列探索 (YBW: Young Brothers Wait)
 * -----------------------------------------------
 * 探索を始めるのはハート 0。ハート 1 は手が空いていて、手伝える分割点が
 * あればそこへ入る。
 *
 * 分割点: 深さ SPLIT_MIN_DEPTH 以上のノードで、最初の手を自分で読み終え
 * (β カットが起きなかったら)、そのとき相手のハートが手すきなら、残りの手を
 * 分割点 (SplitPoint) として公開する。以後はその手を、作ったハート (owner)
 * と手伝うハートが next から 1 手ずつ取り合い、その時点の α で null window
 * 探索し、α を超えたら全幅で読み直す (逐次版の PVS と同じ)。最善値と
 * 最善手は分割点の spinlock で守る。β カットが起きたら残りの手は配らない。
 *
 * owner は配る手がなくなったら、手伝いが抜けるのを待つ。その間に手伝いの
 * ハートが自分の探索の中で分割点を公開したら、owner はそちらを手伝う
 * (helpful master)。こうして、先に手が空いたハートも遊ばずに済む。
 * 分割点はこのように入れ子になるだけなので、スタックで管理できる。
 *
 * ルートの同点の手は並び順で前のものを選ぶ (逐次版と同じ規則)。そのため、
 * ルートで最善手より前の手は α - EPS を下限にして読み、最善値と同点でも
 * 値が確定するようにする。選ぶ手と評価値は逐次版と一致し、違うのは
 * ノード数 (キラー表がハートごとで、α の伝わり方も変わる) だけ。
 */

#define MAX_KILLER_DEPTH 64
#define SEARCH_HARTS 2
#define INF 1e18
#define EPS 1e-6    /* PVS の null window の幅 */
#define SPLIT_MIN_DEPTH 2   /* これより浅いノードは分けても割に合わない */

/* ハートごとの探索状態。キラームーブ表: 各深さで直近にβカットを起こした手を
   2つまで記憶し、次にその深さへ来たとき最優先で試す */
typedef struct {
    int killer[MAX_KILLER_DEPTH][2];
    long nodes;
    int hart;
} SearchCtx;

static SearchCtx ctx[SEARCH_HARTS];

static void reset_ctx(SearchCtx *c, int hart) {
    c->hart = hart;
    c->nodes = 0;
    for (int d = 0; d < MAX_KILLER_DEPTH; d++) { c->killer[d][0] = -1; c->killer[d][1] = -1; }
}

static void store_killer(SearchCtx *c, int depth, int move) {
    if (depth < 0 || depth >= MAX_KILLER_DEPTH) return;
    if (c->killer[depth][0] == move) return; /* 既に1番手 */
    c->killer[depth][1] = c->killer[depth][0];
    c->killer[depth][0] = move;
}

/* moves を手番側から見た 1 手先の評価値 (キラームーブは優先) の降順に並べて
   sqs に入れ、手の数を返す */
static int order_moves(const SearchCtx *c, Bitboard black, Bitboard white, int player_is_black,
                       Bitboard moves, int depth, int *sqs) {
    Bitboard P = player_is_black ? black : white;
    Bitboard O = player_is_black ? white : black;
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
        if (sq == c->killer[depth][0]) sc += 5e5;       /* キラームーブ1番手 */
        else if (sq == c->killer[depth][1]) sc += 4e5;  /* キラームーブ2番手 */
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
    return n;
}

/* 手番側が sq に打った後の (black, white) */
static void play(Bitboard black, Bitboard white, int player_is_black, int sq,
                 Bitboard *newblack, Bitboard *newwhite) {
    Bitboard nb, nw;
    if (player_is_black) {
        apply_move(black, white, sq, &nb, &nw);
        *newblack = nb; *newwhite = nw;
    } else {
        apply_move(white, black, sq, &nw, &nb);
        *newblack = nb; *newwhite = nw;
    }
}

/* 分割点。入れ子になるだけなのでスタックに積む */
typedef struct {
    Bitboard black, white;
    int player_is_black;
    int depth;
    double alpha0, beta;    /* ノードに来たときの窓 */
    int root;               /* ルートなら 1 (同点の扱い) */
    int n;
    const int *sqs;         /* 並べた手 (owner のスタック上。RAM は共有) */
    unsigned lock;          /* 以下を守る */
    int next;               /* 次に配る手の番号 */
    double best_val;
    int best_idx;
    int helpers;            /* 入っている手伝いの数 */
} SplitPoint;

#define MAX_SPLITS 32

static SplitPoint splits[MAX_SPLITS];
static int split_count;             /* 使用中の分割点の数 */
static SplitPoint *offer;           /* 手伝いを募集中の分割点。なければ NULL */
static int idle[SEARCH_HARTS];      /* そのハートが手すきなら 1 */
static int hart1_ready;             /* search_hart_main が動いていれば 1 */
static unsigned search_id;          /* find_best_move ごとに増える (キラー表のリセット用) */

/*
 * 待ちループで共有変数を読み続けると、データバス (2 ハートで 1 本) を
 * 取り合って、相手のハートの探索を遅くする。読み直す前に、バスを使わない
 * nop を SPIN_PAUSE 回はさむ (命令はハートごとの ROM ポートから取る)。
 */
#ifndef SPIN_PAUSE
#define SPIN_PAUSE 64
#endif

static void spin_pause(void) {
    for (int i = 0; i < SPIN_PAUSE; i++)
        __asm__ volatile ("nop");
}

static void sp_lock(SplitPoint *sp) {
    while (__atomic_exchange_n(&sp->lock, 1u, __ATOMIC_ACQUIRE))
        spin_pause();
}

static void sp_unlock(SplitPoint *sp) {
    __atomic_store_n(&sp->lock, 0u, __ATOMIC_RELEASE);
}

static double split(SearchCtx *c, Bitboard black, Bitboard white, int player_is_black,
                    int depth, double alpha, double beta, const int *sqs, int n,
                    int first, double best_val, int best_idx, int root, int *out_move);

/*
 * negamax + αβ枝刈り + PVS(NegaScout)。
 * オリジナル版にあった置換表(hash)は使わない: 評価値によるムーブオーダリングと
 * キラームーブだけでも実用的な枝刈りが得られ、RAMもほぼ使わない。
 * can_split なら、相手のハートが手すきのとき残りの手を分割点にする。
 */
static double negamax(SearchCtx *c, Bitboard black, Bitboard white, int player_is_black,
                      int depth, double alpha, double beta, int can_split, int root,
                      int *out_move) {
    c->nodes++;

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
        double v = -negamax(c, black, white, !player_is_black, depth, -beta, -alpha,
                            can_split, 0, 0);
        if (out_move) *out_move = -1;
        return v;
    }

    if (depth <= 0) {
        if (out_move) *out_move = -1;
        return evaluate_position(black, white, player_is_black);
    }

    int sqs[64];
    int n = order_moves(c, black, white, player_is_black, moves, depth, sqs);

    double best_val = -INF;
    int best_move = sqs[0];

    for (int i = 0; i < n; i++) {
        /* 2 手目以降: 相手が手すきなら残りを分割点にする */
        if (i > 0 && can_split && depth >= SPLIT_MIN_DEPTH && i < n - 1 &&
            __atomic_load_n(&idle[!c->hart], __ATOMIC_ACQUIRE) &&
            __atomic_load_n(&offer, __ATOMIC_ACQUIRE) == 0 &&
            __atomic_load_n(&split_count, __ATOMIC_ACQUIRE) < MAX_SPLITS) {
            int best_idx = 0;
            while (sqs[best_idx] != best_move) best_idx++;
            return split(c, black, white, player_is_black, depth, alpha, beta, sqs, n,
                         i, best_val, best_idx, root, out_move);
        }

        Bitboard newblack, newwhite;
        play(black, white, player_is_black, sqs[i], &newblack, &newwhite);
        double v;

        if (i == 0) {
            v = -negamax(c, newblack, newwhite, !player_is_black, depth - 1, -beta, -alpha,
                         can_split, 0, 0);
        } else {
            v = -negamax(c, newblack, newwhite, !player_is_black, depth - 1, -(alpha + EPS),
                         -alpha, can_split, 0, 0);
            if (v > alpha && v < beta) {
                v = -negamax(c, newblack, newwhite, !player_is_black, depth - 1, -beta, -alpha,
                             can_split, 0, 0);
            }
        }

        if (v > best_val) { best_val = v; best_move = sqs[i]; }
        if (v > alpha) alpha = v;
        if (alpha >= beta) {
            store_killer(c, depth, sqs[i]);
            break;
        }
    }

    if (out_move) *out_move = best_move;
    return best_val;
}

/* 分割点 sp から手を取っては読む。配る手がなくなったら戻る */
static void split_worker(SearchCtx *c, SplitPoint *sp) {
    for (;;) {
        sp_lock(sp);
        int i = sp->next;
        double alpha = sp->best_val > sp->alpha0 ? sp->best_val : sp->alpha0;
        int best_idx = sp->best_idx;
        if (i < sp->n && alpha < sp->beta)
            sp->next = i + 1;
        else
            i = sp->n;
        sp_unlock(sp);
        if (i >= sp->n) break;

        /* ルートで最善手より前の手は、同点でも値が確定するよう窓を EPS だけ下げる */
        if (sp->root && i < best_idx) alpha -= EPS;

        Bitboard newblack, newwhite;
        play(sp->black, sp->white, sp->player_is_black, sp->sqs[i], &newblack, &newwhite);
        double v = -negamax(c, newblack, newwhite, !sp->player_is_black, sp->depth - 1,
                            -(alpha + EPS), -alpha, 1, 0, 0);
        if (v > alpha && v < sp->beta) {
            v = -negamax(c, newblack, newwhite, !sp->player_is_black, sp->depth - 1,
                         -sp->beta, -alpha, 1, 0, 0);
        }

        /* ルートでは α 以下の値は上限でしかないので、最善手の候補にしない */
        if (!sp->root || v > alpha) {
            sp_lock(sp);
            if (v > sp->best_val || (v == sp->best_val && i < sp->best_idx)) {
                sp->best_val = v;
                sp->best_idx = i;
            }
            if (v >= sp->beta) {
                sp->next = sp->n;       /* 残りは配らない */
                store_killer(c, sp->depth, sp->sqs[i]);
            }
            sp_unlock(sp);
        }
    }
}

/* 募集中の分割点があれば入って手伝う。手伝ったら 1 */
static int help(SearchCtx *c) {
    SplitPoint *sp = __atomic_load_n(&offer, __ATOMIC_ACQUIRE);
    if (!sp) return 0;
    sp_lock(sp);
    int joined = (__atomic_load_n(&offer, __ATOMIC_ACQUIRE) == sp) && sp->next < sp->n;
    if (joined) sp->helpers++;
    sp_unlock(sp);
    if (!joined) return 0;

    __atomic_store_n(&idle[c->hart], 0, __ATOMIC_RELEASE);
    split_worker(c, sp);
    sp_lock(sp);
    sp->helpers--;
    sp_unlock(sp);
    return 1;
}

/* sqs[first] 以降の手を分割点にして、相手のハートと手分けして読む */
static double split(SearchCtx *c, Bitboard black, Bitboard white, int player_is_black,
                    int depth, double alpha, double beta, const int *sqs, int n,
                    int first, double best_val, int best_idx, int root, int *out_move) {
    SplitPoint *sp = &splits[__atomic_fetch_add(&split_count, 1, __ATOMIC_ACQ_REL)];
    sp->black = black;
    sp->white = white;
    sp->player_is_black = player_is_black;
    sp->depth = depth;
    sp->alpha0 = alpha;
    sp->beta = beta;
    sp->root = root;
    sp->n = n;
    sp->sqs = sqs;
    sp->lock = 0;
    sp->next = first;
    sp->best_val = best_val;
    sp->best_idx = best_idx;
    sp->helpers = 0;
    __atomic_store_n(&offer, sp, __ATOMIC_RELEASE);     /* 手伝いを募集 */

    split_worker(c, sp);

    /* 配る手がなくなった。募集をやめ、手伝いが抜けるのを待つ。その間に
       手伝いが公開した分割点 (この分割点の下にある) があれば手伝う */
    sp_lock(sp);
    if (__atomic_load_n(&offer, __ATOMIC_ACQUIRE) == sp)
        __atomic_store_n(&offer, 0, __ATOMIC_RELEASE);
    sp_unlock(sp);
    __atomic_store_n(&idle[c->hart], 1, __ATOMIC_RELEASE);
    for (;;) {
        sp_lock(sp);
        int helpers = sp->helpers;
        sp_unlock(sp);
        if (helpers == 0) break;
        if (!help(c)) spin_pause();
        __atomic_store_n(&idle[c->hart], 1, __ATOMIC_RELEASE);
    }
    __atomic_store_n(&idle[c->hart], 0, __ATOMIC_RELEASE);
    __atomic_fetch_sub(&split_count, 1, __ATOMIC_ACQ_REL);

    if (out_move) *out_move = sp->sqs[sp->best_idx];
    return sp->best_val;
}

void search_hart_main(void) {
    unsigned search = search_id - 1u;
    reset_ctx(&ctx[1], 1);
    __atomic_store_n(&idle[1], 1, __ATOMIC_RELEASE);
    __atomic_store_n(&hart1_ready, 1, __ATOMIC_RELEASE);
    for (;;) {
        SplitPoint *sp = __atomic_load_n(&offer, __ATOMIC_ACQUIRE);
        if (!sp) {
            spin_pause();
            continue;
        }
        unsigned id = __atomic_load_n(&search_id, __ATOMIC_ACQUIRE);
        if (id != search) {             /* 新しい探索: キラー表を消す */
            search = id;
            reset_ctx(&ctx[1], 1);
        }
        help(&ctx[1]);
        __atomic_store_n(&idle[1], 1, __ATOMIC_RELEASE);
    }
}

SearchResult find_best_move(Bitboard black, Bitboard white, int player_is_black,
                             int search_depth, int harts) {
    reset_ctx(&ctx[0], 0);
    ctx[1].nodes = 0;
    __atomic_fetch_add(&search_id, 1u, __ATOMIC_RELEASE);

    int empty = 64 - popcount(black) - popcount(white);
    int depth = search_depth;
    if (empty <= search_depth) depth = empty + 1; /* 終局まで正確に読み切る */
    if (depth < 1) depth = 1;
    if (depth >= MAX_KILLER_DEPTH) depth = MAX_KILLER_DEPTH - 1;

    int parallel = harts >= 2 && __atomic_load_n(&hart1_ready, __ATOMIC_ACQUIRE);
    int move = -1;
    double val = negamax(&ctx[0], black, white, player_is_black, depth, -INF, INF,
                         parallel, 1, &move);

    SearchResult result;
    result.square = move;
    result.score = val;
    result.nodes = ctx[0].nodes + ctx[1].nodes;
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
