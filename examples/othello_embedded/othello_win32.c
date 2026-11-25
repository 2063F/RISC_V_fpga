/*
 * othello_win32.c - オセロ対戦ソフト (Windows ネイティブ GUI 版)
 *
 * FPGA 版 (main.c) と同じエンジン (othello.c / evaluate.c / search.c) と
 * 同じ遊び方を、Win32 API だけで作ったウィンドウで遊べるようにしたもの。
 * 追加のインストールは要らない (単一の .exe)。
 *
 *   - 対戦: AI レベル 1-6 (FPGA 版と同じ) または 二人対戦
 *   - 先手 / 後手、色の呼び名 (赤・緑 / 黒・白)、持ち時間 (レベル 5, 6)
 *   - 置ける場所 (黄色の点)、直前の手 (赤 / 白の点)、AI の読んだ深さと時間
 *   - ハート 1 の代わりにスレッドを 1 本使い、レベル 4, 5 は 2 スレッドで読む
 *
 * ビルド (MinGW-w64, リポジトリのルートで):
 *   gcc -O2 -std=c11 -mwindows -I examples -DSEARCH_HART_IDLE=search_hart_idle
 *       examples/othello_embedded/othello_win32.c
 *       examples/othello_embedded/{othello,evaluate,search}.c -o othello.exe
 * (othello_ai_c/othello_AI/build.bat がこれを実行する)
 */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <windowsx.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "othello.h"
#include "search.h"
#include "eval_weights_int.h"   /* EVAL_SCALE */

/* ---- AI レベル (main.c の levels[] と同じ) ---- */
#define TIMED (-1)
#define MAX_SEARCH_DEPTH 60     /* PC はスタックに余裕があるので終局まで読める */

typedef struct {
    const char *name;
    WeakPick pick;
    int depth;      /* 0: 探索しない (find_weak_move)、TIMED: 持ち時間制 */
    int harts;
} LevelDef;

static const LevelDef levels[] = {
    { "レベル1 接待 (子ども向け)",     PICK_WORST,  0,     1 },
    { "レベル2 かんたん",              PICK_RANDOM, 0,     1 },
    { "レベル3 ふつう",                PICK_GOOD,   0,     1 },
    { "レベル4 むずかしい",            PICK_GOOD,   2,     2 },
    { "レベル5 エキスパート",          PICK_GOOD,   TIMED, 2 },
    { "レベル6 エキスパート (1スレッド)", PICK_GOOD, TIMED, 1 },
};
#define LEVEL_COUNT (int)(sizeof levels / sizeof levels[0])
#define MODE_TWO_PLAYERS LEVEL_COUNT    /* 対戦コンボの最後の項目 */

static const int think_choices[] = { 1, 3, 10, 30, 50 };
#define THINK_CHOICES (int)(sizeof think_choices / sizeof think_choices[0])

/* ---- 画面レイアウト ---- */
#define CELL 56
#define MARGIN 28
#define BOARD_PX (CELL * 8)
#define BOARD_SIZE (BOARD_PX + MARGIN * 2)
#define BOARD_X 20
#define ROW1_Y 10
#define ROW2_Y 44
#define STATUS_Y 80
#define INFO_Y 104
#define BOARD_Y 132
#define KIFU_Y (BOARD_Y + BOARD_SIZE + 14)
#define CLIENT_W (BOARD_X * 2 + BOARD_SIZE)
#define CLIENT_H (KIFU_Y + 44)

#define ID_COMBO_MODE 101
#define ID_COMBO_ORDER 102
#define ID_COMBO_NAMES 103
#define ID_COMBO_THINK 104
#define ID_BTN_NEWGAME 105
#define ID_BTN_COPY 106

#define WM_APP_AI_DONE (WM_APP + 1)

/* ---- 設定と対局の状態 ---- */
static HINSTANCE g_hInst;
static HFONT g_hFont;
static HWND g_hwnd, g_hMode, g_hOrder, g_hNames, g_hThink, g_hNew, g_hStatus, g_hInfo, g_hKifu;

static int g_mode = 0;          /* 0-5: AI レベル、MODE_TWO_PLAYERS: 二人対戦 */
static int g_human_black = 1;   /* AI 戦: 1 = あなたが先手 */
static int g_black_white = 0;   /* 0: 赤・緑、1: 黒・白 */
static int g_think_idx = 1;     /* 3 秒 */

static Bitboard g_black, g_white;
static int g_current_is_black;
static int g_game_over;
static int g_last_move = -1;
static int g_thinking;          /* AI のスレッドが読んでいる */
static char g_pass_note[64];    /* 直前のパス */
static char g_kifu_moves[200];

/* AI のスレッドに渡すもの / 返すもの */
static SearchResult g_ai_result;
static DWORD g_ai_ms;
static volatile LONG g_searching;   /* 探索中は 1: ハート 1 のスレッドを起こしておく */

static uint32_t g_rng;

static void ProcessTurns(void);

/* ============ 探索エンジンとの接続 ============ */

uint32_t search_time_us(void) {
    static LARGE_INTEGER freq;
    LARGE_INTEGER now;
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&now);
    unsigned long long q = (unsigned long long)now.QuadPart, f = (unsigned long long)freq.QuadPart;
    return (uint32_t)(q / f * 1000000ull + q % f * 1000000ull / f);
}

/* ハート 1 の待ちループから呼ばれる (search.c の SEARCH_HART_IDLE)。
   探索していない間は眠らせ、CPU を使い続けないようにする */
void search_hart_idle(void) {
    if (g_searching) YieldProcessor();
    else Sleep(5);
}

static DWORD WINAPI Hart1Thread(LPVOID arg) {
    (void)arg;
    search_hart_main();
    return 0;
}

static uint32_t rng_next(void) {
    uint32_t x = g_rng ? g_rng : 0x2545F491u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    g_rng = x;
    return x;
}

typedef struct {
    Bitboard black, white;
    int is_black, mode, think_s;
    uint32_t rnd;
} AiJob;
static AiJob g_job;

static DWORD WINAPI AiThread(LPVOID arg) {
    (void)arg;
    const LevelDef *lv = &levels[g_job.mode];
    InterlockedExchange(&g_searching, 1);
    DWORD t0 = GetTickCount();
    SearchResult res;
    if (lv->depth == 0)
        res = find_weak_move(g_job.black, g_job.white, g_job.is_black, lv->pick, g_job.rnd);
    else if (lv->depth == TIMED)
        res = find_best_move_timed(g_job.black, g_job.white, g_job.is_black,
                                   (uint32_t)g_job.think_s * 1000000u, MAX_SEARCH_DEPTH, lv->harts);
    else
        res = find_best_move(g_job.black, g_job.white, g_job.is_black, lv->depth, lv->harts);
    g_ai_ms = GetTickCount() - t0;
    InterlockedExchange(&g_searching, 0);
    g_ai_result = res;
    PostMessageW(g_hwnd, WM_APP_AI_DONE, 0, 0);
    return 0;
}

/* ============ 文字列 ============ */

static void SetTextUtf8(HWND h, const char *s) {
    WCHAR w[512];
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, 512) == 0) w[0] = 0;
    SetWindowTextW(h, w);
}

static HWND MakeChild(const WCHAR *cls, const char *text, DWORD style, int x, int y, int w, int h, int id) {
    WCHAR wt[128];
    if (MultiByteToWideChar(CP_UTF8, 0, text, -1, wt, 128) == 0) wt[0] = 0;
    HWND c = CreateWindowW(cls, wt, WS_CHILD | WS_VISIBLE | style, x, y, w, h,
                           g_hwnd, (HMENU)(INT_PTR)id, g_hInst, NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)g_hFont, TRUE);
    return c;
}

static void ComboAdd(HWND combo, const char *s) {
    WCHAR w[128];
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, 128) == 0) w[0] = 0;
    SendMessageW(combo, CB_ADDSTRING, 0, (LPARAM)w);
}

static const char *SideName(int is_black) {
    if (g_black_white) return is_black ? "黒" : "白";
    return is_black ? "赤" : "緑";
}

static int TwoPlayers(void) { return g_mode == MODE_TWO_PLAYERS; }

static int HumanToMove(void) {
    return !g_game_over && !g_thinking && (TwoPlayers() || g_current_is_black == g_human_black);
}

/* ============ 盤面描画 ============ */

static void DrawDisc(HDC hdc, int x0, int y0, COLORREF fill, COLORREF edge) {
    HBRUSH br = CreateSolidBrush(fill);
    HPEN pen = CreatePen(PS_SOLID, 2, edge);
    HGDIOBJ ob = SelectObject(hdc, br), op = SelectObject(hdc, pen);
    Ellipse(hdc, x0 + 5, y0 + 5, x0 + CELL - 4, y0 + CELL - 4);
    SelectObject(hdc, ob);
    SelectObject(hdc, op);
    DeleteObject(br);
    DeleteObject(pen);
}

static void DrawDot(HDC hdc, int x0, int y0, int r, COLORREF color) {
    HBRUSH br = CreateSolidBrush(color);
    HGDIOBJ ob = SelectObject(hdc, br), op = SelectObject(hdc, GetStockObject(NULL_PEN));
    int cx = x0 + CELL / 2, cy = y0 + CELL / 2;
    Ellipse(hdc, cx - r, cy - r, cx + r + 1, cy + r + 1);
    SelectObject(hdc, ob);
    SelectObject(hdc, op);
    DeleteObject(br);
}

static void DrawBoard(HDC hdc) {
    RECT boardRect = {BOARD_X, BOARD_Y, BOARD_X + BOARD_SIZE, BOARD_Y + BOARD_SIZE};
    HBRUSH bg = CreateSolidBrush(RGB(10, 92, 42));
    FillRect(hdc, &boardRect, bg);
    DeleteObject(bg);

    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, RGB(255, 255, 255));
    HGDIOBJ oldFont = SelectObject(hdc, g_hFont);
    for (int i = 0; i < 8; i++) {
        char colLabel[2] = {(char)('a' + i), 0};
        char rowLabel[2] = {(char)('1' + i), 0};
        RECT rc1 = {BOARD_X + MARGIN + i * CELL, BOARD_Y,
                    BOARD_X + MARGIN + (i + 1) * CELL, BOARD_Y + MARGIN};
        DrawTextA(hdc, colLabel, -1, &rc1, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        RECT rc2 = {BOARD_X, BOARD_Y + MARGIN + i * CELL,
                    BOARD_X + MARGIN, BOARD_Y + MARGIN + (i + 1) * CELL};
        DrawTextA(hdc, rowLabel, -1, &rc2, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
    SelectObject(hdc, oldFont);

    Bitboard hints = 0;
    if (HumanToMove()) {
        Bitboard P = g_current_is_black ? g_black : g_white;
        Bitboard O = g_current_is_black ? g_white : g_black;
        hints = get_moves(P, O);
    }

    /* 赤・緑: 赤と緑の石、直前の手は白い点。黒・白: 黒と白の石、直前の手は赤い点 */
    COLORREF black_fill = g_black_white ? RGB(0, 0, 0) : RGB(220, 40, 40);
    COLORREF white_fill = g_black_white ? RGB(255, 255, 255) : RGB(110, 230, 90);
    COLORREF black_edge = g_black_white ? RGB(128, 128, 128) : RGB(120, 0, 0);
    COLORREF white_edge = g_black_white ? RGB(128, 128, 128) : RGB(0, 90, 0);
    COLORREF last_dot = g_black_white ? RGB(230, 30, 30) : RGB(255, 255, 255);

    /* 1 行目 (a1-h1) を上に描く (FPGA 版の盤面表示と同じ向き) */
    HPEN gridPen = CreatePen(PS_SOLID, 1, RGB(0, 0, 0));
    HGDIOBJ oldPen = SelectObject(hdc, gridPen);
    HGDIOBJ oldBrush = SelectObject(hdc, GetStockObject(NULL_BRUSH));
    for (int r = 0; r < 8; r++) {
        for (int c = 0; c < 8; c++) {
            int x0 = BOARD_X + MARGIN + c * CELL;
            int y0 = BOARD_Y + MARGIN + r * CELL;
            SelectObject(hdc, gridPen);
            SelectObject(hdc, GetStockObject(NULL_BRUSH));
            Rectangle(hdc, x0, y0, x0 + CELL + 1, y0 + CELL + 1);
            int sq = sq_of(c, r);
            Bitboard bit = 1ULL << sq;
            if (g_black & bit) DrawDisc(hdc, x0, y0, black_fill, black_edge);
            else if (g_white & bit) DrawDisc(hdc, x0, y0, white_fill, white_edge);
            else if (hints & bit) DrawDot(hdc, x0, y0, 6, RGB(255, 213, 74));
            if (sq == g_last_move && ((g_black | g_white) & bit))
                DrawDot(hdc, x0, y0, 5, last_dot);
        }
    }
    SelectObject(hdc, oldPen);
    SelectObject(hdc, oldBrush);
    DeleteObject(gridPen);
}

/* ============ 表示の更新 ============ */

static void UpdateStatus(void) {
    char buf[256], turn[160];
    int bc = popcount(g_black), wc = popcount(g_white);
    const char *mover = SideName(g_current_is_black);
    if (g_game_over) {
        if (bc == wc) snprintf(turn, sizeof turn, "終局: 引き分け");
        else snprintf(turn, sizeof turn, "終局: %sの勝ち", SideName(bc > wc));
    } else if (g_thinking) {
        snprintf(turn, sizeof turn, "AI (%s) が考えています...", mover);
    } else if (TwoPlayers()) {
        snprintf(turn, sizeof turn, "%sの番です", mover);
    } else {
        snprintf(turn, sizeof turn, "あなたの番です (%s)", mover);
    }
    snprintf(buf, sizeof buf, "%s:%d  %s:%d    %s%s%s", SideName(1), bc, SideName(0), wc, turn,
             g_pass_note[0] ? "    " : "", g_pass_note);
    SetTextUtf8(g_hStatus, buf);
}

static void UpdateKifu(void) {
    char buf[220];
    snprintf(buf, sizeof buf, "%s%s", (TwoPlayers() || g_human_black) ? "F" : "S", g_kifu_moves);
    SetTextUtf8(g_hKifu, buf);
}

static void Redraw(void) {
    UpdateStatus();
    RECT rc = {BOARD_X, BOARD_Y, BOARD_X + BOARD_SIZE, BOARD_Y + BOARD_SIZE};
    InvalidateRect(g_hwnd, &rc, FALSE);
}

static void SetControlsEnabled(int on) {
    EnableWindow(g_hMode, on);
    EnableWindow(g_hOrder, on && !TwoPlayers());
    EnableWindow(g_hNew, on);
}

/* ============ 対局の進行 ============ */

static void PlayMove(int sq) {
    Bitboard P = g_current_is_black ? g_black : g_white;
    Bitboard O = g_current_is_black ? g_white : g_black;
    Bitboard nP, nO;
    apply_move(P, O, sq, &nP, &nO);
    g_black = g_current_is_black ? nP : nO;
    g_white = g_current_is_black ? nO : nP;
    g_last_move = sq;
    size_t len = strlen(g_kifu_moves);
    if (len + 3 <= sizeof g_kifu_moves) {
        square_to_str(sq, g_kifu_moves + len);
    }
    UpdateKifu();
    g_current_is_black = !g_current_is_black;
}

static void FinishGame(void) {
    g_game_over = 1;
    Redraw();
    int bc = popcount(g_black), wc = popcount(g_white);
    char buf[256];
    const char *head = bc == wc ? "引き分け" : (bc > wc ? SideName(1) : SideName(0));
    if (TwoPlayers()) {
        snprintf(buf, sizeof buf, "%s%s (%s %d - %d %s)", head, bc == wc ? "" : "の勝ち",
                 SideName(1), bc, wc, SideName(0));
    } else {
        const char *you = bc == wc ? "引き分けです"
                        : ((bc > wc) == g_human_black ? "あなたの勝ちです！" : "あなたの負けです");
        snprintf(buf, sizeof buf, "%s%s (%s %d - %d %s)\n%s",
                 head, bc == wc ? "" : "の勝ち", SideName(1), bc, wc, SideName(0), you);
    }
    WCHAR w[256];
    MultiByteToWideChar(CP_UTF8, 0, buf, -1, w, 256);
    MessageBoxW(g_hwnd, w, L"対局終了", MB_OK | MB_ICONINFORMATION);
}

static void StartAi(void) {
    g_job.black = g_black;
    g_job.white = g_white;
    g_job.is_black = g_current_is_black;
    g_job.mode = g_mode;
    g_job.think_s = think_choices[g_think_idx];
    g_job.rnd = rng_next();
    g_thinking = 1;
    SetControlsEnabled(0);
    Redraw();
    HANDLE h = CreateThread(NULL, 4u << 20, AiThread, NULL, 0, NULL);
    if (h) CloseHandle(h);
}

/* パスを片付け、AI の番なら読ませる。人の番か終局で戻る */
static void ProcessTurns(void) {
    if (g_game_over || g_thinking) return;
    Bitboard P = g_current_is_black ? g_black : g_white;
    Bitboard O = g_current_is_black ? g_white : g_black;
    if (get_moves(P, O) == 0) {
        if (get_moves(O, P) == 0) {
            FinishGame();
            return;
        }
        snprintf(g_pass_note, sizeof g_pass_note, "(%sはパス)", SideName(g_current_is_black));
        g_current_is_black = !g_current_is_black;
    }
    if (!TwoPlayers() && g_current_is_black != g_human_black) {
        StartAi();
        return;
    }
    Redraw();
}

static void NewGame(void) {
    if (g_thinking) return;
    g_black = INIT_BLACK;
    g_white = INIT_WHITE;
    g_current_is_black = 1;
    g_game_over = 0;
    g_last_move = -1;
    g_pass_note[0] = 0;
    g_kifu_moves[0] = 0;
    UpdateKifu();
    SetTextUtf8(g_hInfo, "");
    SetControlsEnabled(1);
    InvalidateRect(g_hwnd, NULL, TRUE);
    ProcessTurns();
}

static void OnAiDone(void) {
    g_thinking = 0;
    SetControlsEnabled(1);
    SearchResult *r = &g_ai_result;
    if (r->square >= 0) {
        char sq[3], info[256];
        square_to_str(r->square, sq);
        const LevelDef *lv = &levels[g_job.mode];
        if (lv->depth == 0) {
            snprintf(info, sizeof info, "AI (%s): %s", SideName(g_current_is_black), sq);
        } else {
            int s10 = r->score * 10 / EVAL_SCALE;     /* 石差の 10 倍 (AI から見て) */
            snprintf(info, sizeof info, "AI (%s): %s   深さ %d%s / %ld ノード / %lu.%02lu 秒 / 評価 %c%d.%d",
                     SideName(g_current_is_black), sq, r->depth_reached, r->partial ? "+" : "",
                     r->nodes, (unsigned long)(g_ai_ms / 1000), (unsigned long)(g_ai_ms % 1000 / 10),
                     s10 < 0 ? '-' : '+', abs(s10) / 10, abs(s10) % 10);
        }
        SetTextUtf8(g_hInfo, info);
        PlayMove(r->square);
    } else {
        g_current_is_black = !g_current_is_black;
    }
    ProcessTurns();
    Redraw();
}

static void CopyKifu(void) {
    int len = GetWindowTextLengthW(g_hKifu);
    if (!OpenClipboard(g_hwnd)) return;
    EmptyClipboard();
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)(len + 1) * sizeof(WCHAR));
    if (hMem) {
        WCHAR *p = (WCHAR *)GlobalLock(hMem);
        GetWindowTextW(g_hKifu, p, len + 1);
        GlobalUnlock(hMem);
        SetClipboardData(CF_UNICODETEXT, hMem);
    }
    CloseClipboard();
    snprintf(g_pass_note, sizeof g_pass_note, "(棋譜をコピーしました)");
    UpdateStatus();
}

/* ============ ウィンドウ ============ */

static void CreateControls(void) {
    MakeChild(L"STATIC", "対戦:", 0, 20, ROW1_Y + 4, 40, 20, 0);
    g_hMode = MakeChild(L"COMBOBOX", "", CBS_DROPDOWNLIST | WS_VSCROLL, 62, ROW1_Y, 236, 300, ID_COMBO_MODE);
    for (int i = 0; i < LEVEL_COUNT; i++) ComboAdd(g_hMode, levels[i].name);
    ComboAdd(g_hMode, "二人対戦");
    SendMessageW(g_hMode, CB_SETCURSEL, (WPARAM)g_mode, 0);

    MakeChild(L"STATIC", "あなた:", 0, 310, ROW1_Y + 4, 50, 20, 0);
    g_hOrder = MakeChild(L"COMBOBOX", "", CBS_DROPDOWNLIST, 362, ROW1_Y, 70, 200, ID_COMBO_ORDER);
    ComboAdd(g_hOrder, "先手");
    ComboAdd(g_hOrder, "後手");
    SendMessageW(g_hOrder, CB_SETCURSEL, g_human_black ? 0 : 1, 0);

    g_hNew = MakeChild(L"BUTTON", "新しい対局", 0, 440, ROW1_Y - 1, 84, 28, ID_BTN_NEWGAME);

    MakeChild(L"STATIC", "色:", 0, 20, ROW2_Y + 4, 40, 20, 0);
    g_hNames = MakeChild(L"COMBOBOX", "", CBS_DROPDOWNLIST, 62, ROW2_Y, 100, 200, ID_COMBO_NAMES);
    ComboAdd(g_hNames, "赤・緑");
    ComboAdd(g_hNames, "黒・白");
    SendMessageW(g_hNames, CB_SETCURSEL, (WPARAM)g_black_white, 0);

    MakeChild(L"STATIC", "持ち時間 (レベル5,6):", 0, 180, ROW2_Y + 4, 140, 20, 0);
    g_hThink = MakeChild(L"COMBOBOX", "", CBS_DROPDOWNLIST, 322, ROW2_Y, 80, 200, ID_COMBO_THINK);
    for (int i = 0; i < THINK_CHOICES; i++) {
        char s[16];
        snprintf(s, sizeof s, "%d 秒", think_choices[i]);
        ComboAdd(g_hThink, s);
    }
    SendMessageW(g_hThink, CB_SETCURSEL, (WPARAM)g_think_idx, 0);

    g_hStatus = MakeChild(L"STATIC", "", 0, 20, STATUS_Y, CLIENT_W - 40, 22, 0);
    g_hInfo = MakeChild(L"STATIC", "", 0, 20, INFO_Y, CLIENT_W - 40, 22, 0);

    MakeChild(L"STATIC", "棋譜:", 0, 20, KIFU_Y + 5, 40, 20, 0);
    g_hKifu = MakeChild(L"EDIT", "", WS_BORDER | ES_READONLY | ES_AUTOHSCROLL,
                        62, KIFU_Y, CLIENT_W - 62 - 110 - 12, 26, 0);
    MakeChild(L"BUTTON", "棋譜をコピー", 0, CLIENT_W - 110, KIFU_Y - 2, 90, 30, ID_BTN_COPY);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        g_hwnd = hwnd;
        NONCLIENTMETRICSW ncm;
        ncm.cbSize = sizeof ncm;
        g_hFont = SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof ncm, &ncm, 0)
                      ? CreateFontIndirectW(&ncm.lfMessageFont)
                      : (HFONT)GetStockObject(DEFAULT_GUI_FONT);
        CreateControls();
        NewGame();
        return 0;
    }
    case WM_LBUTTONDOWN: {
        if (!HumanToMove()) break;
        int x = GET_X_LPARAM(lParam), y = GET_Y_LPARAM(lParam);
        if (x < BOARD_X + MARGIN || y < BOARD_Y + MARGIN) break;
        int c = (x - BOARD_X - MARGIN) / CELL, r = (y - BOARD_Y - MARGIN) / CELL;
        if (c > 7 || r > 7) break;
        int sq = sq_of(c, r);
        Bitboard P = g_current_is_black ? g_black : g_white;
        Bitboard O = g_current_is_black ? g_white : g_black;
        if (!((get_moves(P, O) >> sq) & 1u)) break;
        g_rng ^= (uint32_t)GetTickCount() * 0x9E3779B1u;    /* 低レベルの乱数を混ぜる */
        g_pass_note[0] = 0;
        PlayMove(sq);
        ProcessTurns();
        Redraw();
        break;
    }
    case WM_APP_AI_DONE:
        OnAiDone();
        return 0;
    case WM_COMMAND: {
        int id = LOWORD(wParam), code = HIWORD(wParam);
        if (id == ID_BTN_NEWGAME && code == BN_CLICKED) {
            NewGame();
        } else if (id == ID_BTN_COPY && code == BN_CLICKED) {
            CopyKifu();
        } else if (code == CBN_SELCHANGE) {
            int idx = (int)SendMessageW((HWND)lParam, CB_GETCURSEL, 0, 0);
            if (id == ID_COMBO_MODE) { g_mode = idx; NewGame(); }
            else if (id == ID_COMBO_ORDER) { g_human_black = (idx == 0); NewGame(); }
            else if (id == ID_COMBO_NAMES) { g_black_white = idx; Redraw(); }
            else if (id == ID_COMBO_THINK) { g_think_idx = idx; }
        }
        break;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        DrawBoard(hdc);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
    (void)hPrevInstance;
    (void)lpCmdLine;
    g_hInst = hInstance;
    g_rng = (uint32_t)GetTickCount() ^ search_time_us();

    /* ハート 1 の代わり。find_best_move は動き出すまで 1 スレッドで読む */
    HANDLE h1 = CreateThread(NULL, 4u << 20, Hart1Thread, NULL, 0, NULL);
    if (h1) CloseHandle(h1);

    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = L"OthelloWin32Class";
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    RegisterClassExW(&wc);

    RECT rect = {0, 0, CLIENT_W, CLIENT_H};
    DWORD style = WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    AdjustWindowRect(&rect, style, FALSE);
    HWND hwnd = CreateWindowExW(0, L"OthelloWin32Class", L"オセロAI対戦", style,
                                CW_USEDEFAULT, CW_USEDEFAULT,
                                rect.right - rect.left, rect.bottom - rect.top,
                                NULL, NULL, hInstance, NULL);
    if (!hwnd) return 0;
    ShowWindow(hwnd, nCmdShow);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}
