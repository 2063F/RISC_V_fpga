#include "othello.h"
#include "evaluate.h"
#include "search.h"

/*
 * 2 ハートでの並列探索 (YBW: Young Brothers Wait)
 * -----------------------------------------------
 * 探索はハート 0 が進め、ハート 1 は手伝うだけ。ハート 0 は PV ノード
 * (ルートと、そこから最初の手をたどったノード。窓が null window でないもの)
 * で、最初の手を自分だけで読み終えたら、残りの手を「分割点」(job) として
 * 公開する。以後はその手を 2 つのハートが job.next から 1 手ずつ取り合い、
 * その時点の α で null window 探索し、α を超えたら全幅で読み直す
 * (逐次版の PVS と同じ)。最善値と最善手は spinlock で守る。β カットが
 * 起きたら残りの手は配らない。
 *
 * 分割点は同時に 1 つだけ。最初の手を読んでいる間 (その下で分割点が
 * 作られる) はハート 1 は前の分割点を終えて待っているので、ルートから
 * PV を下った各ノードで順に手伝える。
 *
 * ルートの同点の手は並び順で前のものを選ぶ (逐次版と同じ規則)。そのため、
 * ルートで最善手より前の手は α - EPS を下限にして読み、最善値と同点でも
 * 値が確定するようにする。選ぶ手と評価値は逐次版と一致し、違うのは
 * ノード数 (キラー表がハートごとで、α の伝わり方も変わる) だけ。
 *
 * ハート 1 は search_hart_main() で job.gen の変化を待つ。
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
} SearchCtx;

static SearchCtx ctx[SEARCH_HARTS];

static void reset_ctx(SearchCtx *c) {
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

static double split(Bitboard black, Bitboard white, int player_is_black, int depth,
                    double alpha, double beta, const int *sqs, int n,
                    double first_val, int root, int *out_move);

static int job_active;      /* ハート 0 だけが読み書きする */
static int hart1_ready;     /* search_hart_main が動いていれば 1 */

/*
 * negamax + αβ枝刈り + PVS(NegaScout)。
 * オリジナル版にあった置換表(hash)は使わない: 評価値によるムーブオーダリングと
 * キラームーブだけでも実用的な枝刈りが得られ、RAMもほぼ使わない。
 * c == &ctx[0] (ハート 0) で can_split なら、PV ノードでハート 1 と手分けする。
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
        Bitboard newblack, newwhite;
        play(black, white, player_is_black, sqs[i], &newblack, &newwhite);
        double v;

        if (i == 0) {
            /* 最初の手は PV。その先でも手分けできる */
            v = -negamax(c, newblack, newwhite, !player_is_black, depth - 1, -beta, -alpha,
                         can_split, 0, 0);
            if (can_split && n > 1 && depth >= SPLIT_MIN_DEPTH && v < beta && !job_active &&
                __atomic_load_n(&hart1_ready, __ATOMIC_ACQUIRE)) {
                return split(black, white, player_is_black, depth, alpha, beta, sqs, n,
                             v, root, out_move);
            }
        } else {
            v = -negamax(c, newblack, newwhite, !player_is_black, depth - 1, -(alpha + EPS),
                         -alpha, 0, 0, 0);
            if (v > alpha && v < beta) {
                v = -negamax(c, newblack, newwhite, !player_is_black, depth - 1, -beta, -alpha,
                             0, 0, 0);
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

/* 分割点の共有状態 */
static struct {
    Bitboard black, white;
    int player_is_black;
    int depth;
    double alpha0, beta;    /* ノードに来たときの窓 */
    int root;               /* ルートなら 1 (同点の扱い) */
    int n;
    const int *sqs;         /* 並べた手 (ハート 0 のスタック上。RAM は共有) */
    int next;               /* 次に読む手の番号 (AMO で取り合う) */
    unsigned lock;          /* best_val / best_idx を守る */
    double best_val;
    int best_idx;
    int busy;               /* 作業中のハート 1 の数 */
    unsigned gen;           /* 新しい分割点ごとに増える。ハート 1 はこれを待つ */
    unsigned search_id;     /* find_best_move ごとに増える (キラー表のリセット用) */
} job;

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

static void job_lock(void) {
    while (__atomic_exchange_n(&job.lock, 1u, __ATOMIC_ACQUIRE))
        spin_pause();
}

static void job_unlock(void) {
    __atomic_store_n(&job.lock, 0u, __ATOMIC_RELEASE);
}

/* job.next から手を取っては読む。0 番目の手は読み終えている */
static void split_worker(SearchCtx *c) {
    for (;;) {
        int i = __atomic_fetch_add(&job.next, 1, __ATOMIC_RELAXED);
        if (i >= job.n) break;

        job_lock();
        double alpha = job.best_val > job.alpha0 ? job.best_val : job.alpha0;
        int best_idx = job.best_idx;
        job_unlock();
        if (alpha >= job.beta) break;   /* β カット済み */
        /* ルートで最善手より前の手は、同点でも値が確定するよう窓を EPS だけ下げる */
        if (job.root && i < best_idx) alpha -= EPS;

        Bitboard newblack, newwhite;
        play(job.black, job.white, job.player_is_black, job.sqs[i], &newblack, &newwhite);
        double v = -negamax(c, newblack, newwhite, !job.player_is_black, job.depth - 1,
                            -(alpha + EPS), -alpha, 0, 0, 0);
        if (v > alpha && v < job.beta) {
            v = -negamax(c, newblack, newwhite, !job.player_is_black, job.depth - 1,
                         -job.beta, -alpha, 0, 0, 0);
        }

        /* ルートでは α 以下の値は上限でしかないので、最善手の候補にしない */
        if (!job.root || v > alpha) {
            job_lock();
            if (v > job.best_val || (v == job.best_val && i < job.best_idx)) {
                job.best_val = v;
                job.best_idx = i;
            }
            if (v >= job.beta) {
                job.next = job.n;       /* 残りは配らない */
                store_killer(c, job.depth, job.sqs[i]);
            }
            job_unlock();
        }
    }
}

/* PV ノードの 1 番目以降の手をハート 1 と手分けして読む (ハート 0 から呼ぶ) */
static double split(Bitboard black, Bitboard white, int player_is_black, int depth,
                    double alpha, double beta, const int *sqs, int n,
                    double first_val, int root, int *out_move) {
    job.black = black;
    job.white = white;
    job.player_is_black = player_is_black;
    job.depth = depth;
    job.alpha0 = alpha;
    job.beta = beta;
    job.root = root;
    job.n = n;
    job.sqs = sqs;
    job.best_val = first_val;
    job.best_idx = 0;
    job.next = 1;
    job.busy = 1;
    job_active = 1;
    __atomic_fetch_add(&job.gen, 1u, __ATOMIC_RELEASE);   /* ハート 1 を起こす */

    split_worker(&ctx[0]);
    while (__atomic_load_n(&job.busy, __ATOMIC_ACQUIRE))
        spin_pause();
    job_active = 0;

    if (out_move) *out_move = job.sqs[job.best_idx];
    return job.best_val;
}

void search_hart_main(void) {
    unsigned seen = __atomic_load_n(&job.gen, __ATOMIC_ACQUIRE);
    unsigned search = job.search_id - 1u;
    __atomic_store_n(&hart1_ready, 1, __ATOMIC_RELEASE);
    for (;;) {
        unsigned g;
        while ((g = __atomic_load_n(&job.gen, __ATOMIC_ACQUIRE)) == seen)
            spin_pause();
        seen = g;
        if (job.search_id != search) {  /* 新しい探索: キラー表を消す */
            search = job.search_id;
            reset_ctx(&ctx[1]);
        }
        split_worker(&ctx[1]);
        __atomic_fetch_sub(&job.busy, 1, __ATOMIC_RELEASE);
    }
}

SearchResult find_best_move(Bitboard black, Bitboard white, int player_is_black,
                             int search_depth, int harts) {
    reset_ctx(&ctx[0]);
    ctx[1].nodes = 0;
    job.search_id++;

    int empty = 64 - popcount(black) - popcount(white);
    int depth = search_depth;
    if (empty <= search_depth) depth = empty + 1; /* 終局まで正確に読み切る */
    if (depth < 1) depth = 1;
    if (depth >= MAX_KILLER_DEPTH) depth = MAX_KILLER_DEPTH - 1;

    int move = -1;
    double val = negamax(&ctx[0], black, white, player_is_black, depth, -INF, INF,
                         harts >= 2, 1, &move);

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
