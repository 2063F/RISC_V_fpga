/*
 * RISC-V ソフトCPU (RV32IM, Tang Primer 25K) 上で動かすオセロAI。
 * UART (115200bps 8N1) で PC と対話する。
 *
 * 起動するとメニューを表示し、1行ずつコマンドを受け付ける
 * （入力文字はボード側でエコーバックするので、端末のローカルエコーは不要）。
 *
 *   b                 : 対局開始（あなた=黒(先手) / AI=白）
 *   w                 : 対局開始（あなた=白(後手) / AI=黒）
 *   BESTMOVE <black_hex16> <white_hex16> <b|w> <max_depth> <time_ms> <endgame_threshold>
 *                     : engine_cli と同じプロトコル。1行で
 *                       MOVE <square|PASS> <score> <depth> <nodes>
 *                       を返す（othello_gui.py --serial から使う）
 *   help              : メニュー再表示
 *
 * 対局中は "f5" のように着手を入力する。"q" で対局を中断してメニューへ戻る。
 *
 * 思考時間は CPU のサイクルカウンタ (MMIO 0x8000_0020) で測り、time_ms で打ち切る。
 * 打ち切りから応答1文字目までの遅れは約3ms。コマンド受信(約5ms)・応答送信(約2ms)の
 * 時間は含まないので、大会の持ち時間に対しては余裕を持った time_ms を渡すこと。
 *
 * ビルド方法は ../README_FPGA.md を参照。
 * OTHELLO_HOST_TEST を定義すると PC 上で標準入出力を UART 代わりにして動く（動作確認用）。
 */
#include <stdint.h>
#include "othello.h"
#include "evaluate.h"
#include "search.h"

#ifdef OTHELLO_HOST_TEST
#include <stdio.h>
#include <stdlib.h>
static void uart_putchar(char c) { putchar(c); }
static char uart_getchar(void) {
    int c = getchar();
    if (c == EOF) { fflush(stdout); exit(0); }
    return (char)c;
}
#else
#include "uart.h"
#endif

/* 対局モードの AI 設定。50MHz の RV32IM で 1 手数秒程度になるよう調整した値 */
#define AI_MAX_DEPTH      60   /* 実際の深さは時間で決まる */
#define AI_TIME_MS        250  /* 1手 0.309 秒の大会規定に通信分の余裕を持たせた値 */
#define ENDGAME_THRESHOLD 14   /* 残り14マス以下で完全読みを試みる（時間内に読み切れなければ通常探索の手） */

#define LINE_MAX 128

/* ---------------------------------------------------------------- 出力 */

static void put_str(const char *s) {
    while (*s) {
        if (*s == '\n') uart_putchar('\r');
        uart_putchar(*s++);
    }
}

static void put_uint(uint32_t v) {
    char buf[12];
    int n = 0;
    do { buf[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) uart_putchar(buf[--n]);
}

static void put_int(int32_t v) {
    if (v < 0) { uart_putchar('-'); put_uint((uint32_t)(-(int64_t)v)); }
    else put_uint((uint32_t)v);
}

/* 評価値を engine_cli の "%.2f" と同じ形式で出す */
static void put_score(Score s) {
#ifdef OTHELLO_BAREMETAL
    int32_t v = s;
    if (v < 0) { uart_putchar('-'); v = -v; }
    /* 小数第2位で四捨五入: v/SCALE を 100 倍して丸める */
    uint32_t hundredths = (uint32_t)(((int64_t)v * 100 + SCORE_SCALE / 2) / SCORE_SCALE);
    put_uint(hundredths / 100);
    uart_putchar('.');
    uart_putchar((char)('0' + (hundredths / 10) % 10));
    uart_putchar((char)('0' + hundredths % 10));
#else
    char buf[32];
    snprintf(buf, sizeof(buf), "%.2f", (double)s);
    put_str(buf);
#endif
}

static void put_square(int sq) {
    char s[3];
    square_to_str(sq, s);
    put_str(s);
}

/* ---------------------------------------------------------------- 入力 */

/* 1行読む。エコーバックとバックスペース処理つき。CR / LF どちらでも行末とみなす */
static int read_line(char *buf, int max) {
    int n = 0;
    while (1) {
        char c = uart_getchar();
        if (c == '\r' || c == '\n') {
            if (n == 0) continue; /* CRLF の LF や空行は読み飛ばす */
            put_str("\n");
            buf[n] = '\0';
            return n;
        }
        if (c == 0x08 || c == 0x7F) {
            if (n > 0) { n--; put_str("\b \b"); }
            continue;
        }
        if ((unsigned char)c < 0x20) continue;
        if (n < max - 1) {
            buf[n++] = c;
            uart_putchar(c);
        }
    }
}

static const char *skip_spaces(const char *p) {
    while (*p == ' ' || *p == '\t') p++;
    return p;
}

/* 空白区切りの次のトークンを16進数として読む。失敗なら NULL */
static const char *parse_hex64(const char *p, uint64_t *out) {
    p = skip_spaces(p);
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    uint64_t v = 0;
    int digits = 0;
    while (1) {
        char c = *p;
        int d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else break;
        v = (v << 4) | (uint64_t)d;
        digits++;
        p++;
    }
    if (digits == 0 || digits > 16) return 0;
    *out = v;
    return p;
}

static const char *parse_long(const char *p, long *out) {
    p = skip_spaces(p);
    int neg = 0;
    if (*p == '-') { neg = 1; p++; }
    if (*p < '0' || *p > '9') return 0;
    long v = 0;
    while (*p >= '0' && *p <= '9') { v = v * 10 + (*p - '0'); p++; }
    *out = neg ? -v : v;
    return p;
}

static int starts_with(const char *s, const char *prefix) {
    while (*prefix) {
        if (*s++ != *prefix++) return 0;
    }
    return 1;
}

/* ------------------------------------------------------- BESTMOVE コマンド */

static void cmd_bestmove(const char *args) {
    uint64_t black, white;
    long max_depth, time_ms, endgame_threshold;
    const char *p = args;

    p = parse_hex64(p, &black);
    if (p) p = parse_hex64(p, &white);
    char player_ch = 0;
    if (p) {
        p = skip_spaces(p);
        player_ch = *p;
        if (player_ch) p++;
    }
    if (p) p = parse_long(p, &max_depth);
    if (p) p = parse_long(p, &time_ms);
    if (p) p = parse_long(p, &endgame_threshold);
    if (!p || !player_ch) {
        put_str("ERROR bad BESTMOVE args\n");
        return;
    }
    int player_is_black = (player_ch == 'b' || player_ch == 'B');

    SearchResult r = find_best_move(black, white, player_is_black,
                                     (int)max_depth, time_ms, (int)endgame_threshold);
    put_str("MOVE ");
    if (r.square < 0) put_str("PASS");
    else put_square(r.square);
    uart_putchar(' ');
    put_score(r.score);
    uart_putchar(' ');
    put_int(r.depth_reached);
    uart_putchar(' ');
    put_int((int32_t)r.nodes);
    put_str("\n");
}

/* ------------------------------------------------------------- 対局モード */

static void print_board_ui(Bitboard black, Bitboard white, Bitboard hint) {
    put_str("\n   a b c d e f g h\n");
    for (int r = 7; r >= 0; r--) {
        uart_putchar(' ');
        uart_putchar((char)('1' + r));
        uart_putchar(' ');
        for (int c = 0; c < 8; c++) {
            Bitboard bit = 1ULL << sq_of(c, r);
            char ch = '.';
            if (black & bit) ch = 'X';
            else if (white & bit) ch = 'O';
            else if (hint & bit) ch = '*';
            uart_putchar(ch);
            uart_putchar(' ');
        }
        put_str("\n");
    }
    put_str("Black(X)=");
    put_int(popcount(black));
    put_str("  White(O)=");
    put_int(popcount(white));
    put_str("\n");
}

static void play_game(int human_is_black) {
    Bitboard black = INIT_BLACK, white = INIT_WHITE;
    int player_is_black = 1;
    char line[LINE_MAX];

    put_str(human_is_black ? "\nNew game: you = Black(X), AI = White(O)\n"
                           : "\nNew game: you = White(O), AI = Black(X)\n");
    put_str("Enter a move like f5. '*' marks legal moves. 'q' quits.\n");

    while (1) {
        Bitboard P = player_is_black ? black : white;
        Bitboard O = player_is_black ? white : black;
        Bitboard moves = get_moves(P, O);
        Bitboard omoves = get_moves(O, P);
        if (moves == 0 && omoves == 0) break;

        int is_human_turn = (player_is_black == human_is_black);
        print_board_ui(black, white, is_human_turn ? moves : 0);

        if (moves == 0) {
            put_str(player_is_black ? "Black" : "White");
            put_str(" has no legal move: PASS\n");
            player_is_black = !player_is_black;
            continue;
        }

        int sq;
        if (is_human_turn) {
            put_str("Your move: ");
            read_line(line, sizeof(line));
            const char *p = skip_spaces(line);
            if (p[0] == 'q' || p[0] == 'Q') {
                put_str("Game aborted.\n");
                return;
            }
            sq = parse_square(p);
            if (sq < 0 || !(moves & (1ULL << sq))) {
                put_str("Illegal move. Try again.\n");
                continue;
            }
        } else {
            put_str("AI is thinking...\n");
            SearchResult r = find_best_move(black, white, player_is_black,
                                             AI_MAX_DEPTH, AI_TIME_MS, ENDGAME_THRESHOLD);
            sq = r.square;
            put_str("AI plays ");
            if (sq >= 0) put_square(sq); else put_str("PASS");
            put_str("  (score=");
            put_score(r.score);
            put_str(" depth=");
            put_int(r.depth_reached);
            put_str(" nodes=");
            put_int((int32_t)r.nodes);
            put_str(")\n");
            if (sq < 0) { player_is_black = !player_is_black; continue; }
        }

        Bitboard nb, nw;
        apply_move(P, O, sq, &nb, &nw);
        if (player_is_black) { black = nb; white = nw; } else { white = nb; black = nw; }
        player_is_black = !player_is_black;
    }

    print_board_ui(black, white, 0);
    int b = popcount(black), w = popcount(white);
    if (b == w) {
        put_str("Draw.\n");
    } else {
        int human_won = (b > w) == human_is_black;
        put_str(human_won ? "You win! (" : "AI wins! (");
        put_int(b > w ? b : w);
        put_str(" - ");
        put_int(b > w ? w : b);
        put_str(")\n");
    }
}

/* ---------------------------------------------------------------- main */

static void print_help(void) {
    put_str("\n=== Othello AI on RISC-V (RV32IM) ===\n");
    put_str("  b    : play as Black (first move)\n");
    put_str("  w    : play as White\n");
    put_str("  BESTMOVE <black_hex16> <white_hex16> <b|w> <depth> <time_ms> <endgame>\n");
    put_str("  help : show this menu\n");
}

int main(void) {
    char line[LINE_MAX];
    print_help();
    while (1) {
        put_str("> ");
        read_line(line, sizeof(line));
        const char *p = skip_spaces(line);
        if (starts_with(p, "BESTMOVE")) {
            cmd_bestmove(p + 8);
        } else if ((p[0] == 'b' || p[0] == 'B') && p[1] == '\0') {
            play_game(1);
        } else if ((p[0] == 'w' || p[0] == 'W') && p[1] == '\0') {
            play_game(0);
        } else if (starts_with(p, "QUIT")) {
            /* engine_cli 互換: ボード上では何もしない */
        } else {
            print_help();
        }
    }
    return 0;
}
