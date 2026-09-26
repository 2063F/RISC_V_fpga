#ifndef SEARCH_H
#define SEARCH_H

#include "othello.h"
#include "evaluate.h"

typedef struct {
    int square;        /* 選んだ手のマス番号。-1 はパス（合法手が無い場合） */
    Score score;        /* 手番側から見た評価値（中盤=評価関数値、終盤=確定石差）。
                           ベアメタル版は SCORE_SCALE 倍の固定小数点 */
    long nodes;         /* 探索したノード数（デバッグ・速度確認用） */
    int depth_reached;  /* 反復深化で実際に完了した深さ */
} SearchResult;

/*
 * 中盤〜序盤探索: 反復深化 + negamax + αβ枝刈り + 置換表。
 * time_limit_ms ミリ秒以内で探索を打ち切り、その時点で分かっている最善手を返す。
 * （FPGA版は CPU のサイクルカウンタで時間を測る）
 * max_depth は深さの上限（安全弁。時間切れが起きなければここまで読む）。
 * 残り空きマス数が endgame_threshold 以下になったら自動的に終盤完全読みに切り替える。
 */
SearchResult find_best_move(Bitboard black, Bitboard white, int player_is_black,
                             int max_depth, long time_limit_ms, int endgame_threshold);

/*
 * 終盤完全読み: 評価関数を使わず、ゲーム終了までの石差を正確に読み切って最善手を返す。
 * まず持ち時間の1/6で通常の探索をして手を確保し、残り時間で完全読みを試みる。
 * 時間内に読み切れなかった場合は通常探索の手を返す（持ち時間は必ず守る）。
 */
SearchResult endgame_search(Bitboard black, Bitboard white, int player_is_black, long time_limit_ms);

#endif
