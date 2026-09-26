#ifndef EVALUATE_H
#define EVALUATE_H

#include "othello.h"

/*
 * 評価値の型。
 *   PC版        : double（従来どおり。1.0 = 石1個分）
 *   ベアメタル版: int32_t の固定小数点（SCORE_SCALE = 石1個分）。
 *                 FPU の無い RV32IM で double を使うとソフトウェア浮動小数点に
 *                 なり極端に遅いため、整数演算だけで評価・探索する。
 */
#ifdef OTHELLO_BAREMETAL
typedef int32_t Score;
#define SCORE_SCALE_BITS 10
#define SCORE_SCALE (1 << SCORE_SCALE_BITS)
#else
typedef double Score;
#define SCORE_SCALE 1
#endif

/* Pythonのextract_features_wthor.pyと全く同じ8種類の評価変数。
   並び順は eval_weights.h の EVAL_WEIGHTS の列順と一致させること。 */
typedef struct {
    int stone_diff;
    int mobility_diff;
    int corner_diff;
    int x_square_diff;
    int c_square_diff;
    int frontier_diff;
    int stable_diff;
    int edge_diff;
} Features;

/* black,white: 現在の盤面。player_is_black: 手番（1=黒,0=白）。
   手番側から見た8種類の評価変数を計算する。 */
Features extract_features(Bitboard black, Bitboard white, int player_is_black);

/* 学習済みの重み(eval_weights.h)を使って局面を評価する。
   値が大きいほど手番側に有利。empty_countが範囲外の場合は端の値で代用する。 */
Score evaluate_position(Bitboard black, Bitboard white, int player_is_black);

/* evaluate_position の手番側視点版。P=手番側, O=相手, pm/om=それぞれの合法手
   （探索側で合法手を既に求めている場合に再計算を省くため） */
Score evaluate_po(Bitboard P, Bitboard O, Bitboard pm, Bitboard om);

#endif
