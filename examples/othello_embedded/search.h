#ifndef SEARCH_H
#define SEARCH_H

#include "othello.h"

typedef struct {
    int square;        /* 選んだ手のマス番号。-1 はパス（合法手が無い場合） */
    double score;      /* 手番側から見た評価値（中盤=評価関数値、終盤=確定石差） */
    long nodes;         /* 探索したノード数（デバッグ・速度確認用） */
    int depth_reached;  /* 実際に探索した深さ */
} SearchResult;

/*
 * 固定深さの negamax + αβ枝刈り。
 * オリジナル版(othello_ai_c)にあった置換表(約25MB)・反復深化・
 * clock() による時間制限は、この基板の RAM 64KB / タイマー無しという
 * 制約に合わせて全て取り除いてある。
 *
 * search_depth: 探索する手数。残り空きマス数が search_depth 以下の場合は
 *               自動的に「空きマス数+1」まで深さを伸ばし、終局まで正確に
 *               読み切る（終盤の完全読みを兼ねる）。
 */
SearchResult find_best_move(Bitboard black, Bitboard white, int player_is_black,
                             int search_depth);

/* find_weak_move の手の選び方 */
typedef enum {
    PICK_WORST,   /* 悪い方から1/3。角は（角しか打てない場合を除き）取らない（接待用） */
    PICK_RANDOM,  /* 全合法手から完全ランダム */
    PICK_GOOD     /* 良い方から1/3 */
} WeakPick;

/*
 * 低レベル用のわざと弱い着手選択。
 * 全合法手を1手先の評価値で採点し、pick で決まる候補の中から rnd でランダムに
 * 1手を選ぶ。探索はしないので一瞬で返る。nodes には採点した手の数が入る。
 */
SearchResult find_weak_move(Bitboard black, Bitboard white, int player_is_black,
                             WeakPick pick, uint32_t rnd);

#endif
