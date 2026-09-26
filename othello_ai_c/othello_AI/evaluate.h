#ifndef EVALUATE_H
#define EVALUATE_H

#include "othello.h"

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
double evaluate_position(Bitboard black, Bitboard white, int player_is_black);

#endif
