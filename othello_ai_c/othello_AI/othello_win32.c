/*
 * オセロAI 対戦ソフト（Windows ネイティブGUI版）。
 *
 * Python/tkinter不要・追加インストール不要で動く単一の .exe になるように、
 * Win32 API だけでウィンドウとボタン・盤面を描画する。
 * 盤面判定・評価関数・探索は othello.c / evaluate.c / search.c を
 * そのまま直接リンクして呼び出す（別プロセスを起動しないので
 * engine_cli.exe も不要）。ロジックは othello_gui.py（tkinter版）と同じ。
 */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <windowsx.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#include "othello.h"
#include "search.h"

/* ---- AIの強さ設定（othello_gui.py と同じ値） ---- */
#define AI_MAX_DEPTH 30
#define AI_TIME_MS 1200
#define ENDGAME_THRESHOLD 16

/* ---- 画面レイアウト ---- */
#define CELL 56
#define MARGIN 28
#define BOARD_PX (CELL * 8)
#define BOARD_SIZE (BOARD_PX + MARGIN * 2)
#define BOARD_X 20
#define BOARD_Y 80
#define STATUS_Y 42
#define KIFU_Y (BOARD_Y + BOARD_SIZE + 14)
#define CLIENT_W (BOARD_X * 2 + BOARD_SIZE)
#define CLIENT_H (KIFU_Y + 44)

#define ID_COMBO_COLOR 101
#define ID_BTN_NEWGAME 102
#define ID_STATIC_STATUS 103
#define ID_EDIT_KIFU 104
#define ID_BTN_COPY 105

/* ---- ゲーム状態 ---- */
static HINSTANCE g_hInst;
static HFONT g_hFont;
static HWND g_hCombo, g_hStatus, g_hKifu;

static Bitboard g_black, g_white;
static int g_current_is_black; /* 1=黒番 0=白番 */
static int g_human_is_black;   /* 1=人間が黒 0=人間が白 */
static int g_game_over;
static char g_kifu_moves[4096]; /* "f5d6..." のように着手を連結した文字列（先頭記号なし） */

static void NewGame(HWND hwnd);
static void ProcessTurns(HWND hwnd);
static void UpdateStatus(const char *suffix);
static void UpdateKifuDisplay(void);
static void AppendMove(int sq);
static void FinishGame(HWND hwnd);
static void CopyKifu(HWND hwnd);
static void DrawBoard(HDC hdc);
static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);

/* UTF-8(ソースコード中の日本語リテラル)を Windows の Wide文字列に変換 */
static void Utf8ToWide(const char *s, WCHAR *out, int outCap) {
    if (outCap <= 0) return;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, out, outCap);
    if (n == 0) out[0] = 0;
}

static HFONT CreateUiFont(void) {
    NONCLIENTMETRICSW ncm;
    ncm.cbSize = sizeof(ncm);
    if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0)) {
        return CreateFontIndirectW(&ncm.lfMessageFont);
    }
    return (HFONT)GetStockObject(DEFAULT_GUI_FONT);
}

/* ============ 盤面描画 ============ */

static void DrawStone(HDC hdc, int x0, int y0, COLORREF color) {
    HBRUSH br = CreateSolidBrush(color);
    HPEN pen = CreatePen(PS_SOLID, 1, RGB(128, 128, 128));
    HGDIOBJ oldBr = SelectObject(hdc, br);
    HGDIOBJ oldPen = SelectObject(hdc, pen);
    Ellipse(hdc, x0 + 4, y0 + 4, x0 + CELL - 4, y0 + CELL - 4);
    SelectObject(hdc, oldBr);
    SelectObject(hdc, oldPen);
    DeleteObject(br);
    DeleteObject(pen);
}

static void DrawHint(HDC hdc, int x0, int y0) {
    HBRUSH br = CreateSolidBrush(RGB(255, 213, 74));
    HGDIOBJ oldBr = SelectObject(hdc, br);
    HGDIOBJ oldPen = SelectObject(hdc, GetStockObject(NULL_PEN));
    int cx = x0 + CELL / 2, cy = y0 + CELL / 2;
    Ellipse(hdc, cx - 5, cy - 5, cx + 5, cy + 5);
    SelectObject(hdc, oldBr);
    SelectObject(hdc, oldPen);
    DeleteObject(br);
}

static void DrawBoard(HDC hdc) {
    RECT boardRect = {BOARD_X, BOARD_Y, BOARD_X + BOARD_SIZE, BOARD_Y + BOARD_SIZE};
    HBRUSH bg = CreateSolidBrush(RGB(10, 92, 42));
    FillRect(hdc, &boardRect, bg);
    DeleteObject(bg);

    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, RGB(255, 255, 255));
    HFONT oldFont = (HFONT)SelectObject(hdc, g_hFont);
    for (int i = 0; i < 8; i++) {
        char colLabel[2] = {(char)('a' + i), 0};
        char rowLabel[4];
        snprintf(rowLabel, sizeof(rowLabel), "%d", 8 - i);
        RECT rc1 = {BOARD_X + MARGIN + i * CELL, BOARD_Y,
                    BOARD_X + MARGIN + (i + 1) * CELL, BOARD_Y + MARGIN};
        DrawTextA(hdc, colLabel, -1, &rc1, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        RECT rc2 = {BOARD_X, BOARD_Y + MARGIN + i * CELL,
                    BOARD_X + MARGIN, BOARD_Y + MARGIN + (i + 1) * CELL};
        DrawTextA(hdc, rowLabel, -1, &rc2, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
    SelectObject(hdc, oldFont);

    int is_human_turn = (!g_game_over) && (g_current_is_black == g_human_is_black);
    Bitboard legal = 0;
    if (is_human_turn) {
        Bitboard CP = g_current_is_black ? g_black : g_white;
        Bitboard CO = g_current_is_black ? g_white : g_black;
        legal = get_moves(CP, CO);
    }

    HPEN gridPen = CreatePen(PS_SOLID, 1, RGB(0, 0, 0));
    HGDIOBJ oldPen = SelectObject(hdc, gridPen);
    HGDIOBJ oldBrush = SelectObject(hdc, GetStockObject(NULL_BRUSH));

    for (int r = 0; r < 8; r++) {
        for (int c = 0; c < 8; c++) {
            int rs = 7 - r, cs = c;
            int x0 = BOARD_X + MARGIN + cs * CELL;
            int y0 = BOARD_Y + MARGIN + rs * CELL;
            Rectangle(hdc, x0, y0, x0 + CELL, y0 + CELL);
            int sq = sq_of(c, r);
            Bitboard bit = 1ULL << sq;
            if (g_black & bit) {
                DrawStone(hdc, x0, y0, RGB(0, 0, 0));
            } else if (g_white & bit) {
                DrawStone(hdc, x0, y0, RGB(255, 255, 255));
            } else if (legal & bit) {
                DrawHint(hdc, x0, y0);
            }
        }
    }
    SelectObject(hdc, oldPen);
    SelectObject(hdc, oldBrush);
    DeleteObject(gridPen);
}

/* ============ ゲーム進行 ============ */

static void UpdateStatus(const char *suffix) {
    char buf[256];
    int bc = popcount(g_black), wc = popcount(g_white);
    snprintf(buf, sizeof(buf), "黒:%d  白:%d   %s", bc, wc, suffix ? suffix : "");
    WCHAR wbuf[256];
    Utf8ToWide(buf, wbuf, 256);
    SetWindowTextW(g_hStatus, wbuf);
}

static void UpdateKifuDisplay(void) {
    char buf[4100];
    snprintf(buf, sizeof(buf), "%s%s", g_human_is_black ? "F" : "S", g_kifu_moves);
    WCHAR wbuf[4100];
    Utf8ToWide(buf, wbuf, 4100);
    SetWindowTextW(g_hKifu, wbuf);
}

static void AppendMove(int sq) {
    size_t len = strlen(g_kifu_moves);
    if (len + 3 < sizeof(g_kifu_moves)) {
        g_kifu_moves[len] = (char)('a' + col_of(sq));
        g_kifu_moves[len + 1] = (char)('1' + row_of(sq));
        g_kifu_moves[len + 2] = '\0';
    }
    UpdateKifuDisplay();
}

static void NewGame(HWND hwnd) {
    g_black = INIT_BLACK;
    g_white = INIT_WHITE;
    g_current_is_black = 1;
    g_game_over = 0;
    g_kifu_moves[0] = '\0';
    UpdateKifuDisplay();
    UpdateStatus("");
    InvalidateRect(hwnd, NULL, TRUE);
    ProcessTurns(hwnd);
}

static void ProcessTurns(HWND hwnd) {
    for (;;) {
        if (g_game_over) return;
        Bitboard P = g_current_is_black ? g_black : g_white;
        Bitboard O = g_current_is_black ? g_white : g_black;
        Bitboard moves = get_moves(P, O);

        if (moves == 0) {
            /* パス */
            g_current_is_black = !g_current_is_black;
            Bitboard P2 = g_current_is_black ? g_black : g_white;
            Bitboard O2 = g_current_is_black ? g_white : g_black;
            if (get_moves(P2, O2) == 0) {
                FinishGame(hwnd);
                return;
            }
            continue;
        }

        int is_human_turn = (g_current_is_black == g_human_is_black);
        if (is_human_turn) {
            UpdateStatus("あなたの番です");
            InvalidateRect(hwnd, NULL, TRUE);
            return;
        }

        /* AIの番: 思考中の表示を出してから（同期的に）探索する */
        UpdateStatus("AI思考中...");
        InvalidateRect(hwnd, NULL, TRUE);
        UpdateWindow(hwnd);

        SearchResult res = find_best_move(g_black, g_white, g_current_is_black,
                                           AI_MAX_DEPTH, AI_TIME_MS, ENDGAME_THRESHOLD);
        if (res.square >= 0) {
            Bitboard newP, newO;
            apply_move(P, O, res.square, &newP, &newO);
            if (g_current_is_black) {
                g_black = newP;
                g_white = newO;
            } else {
                g_white = newP;
                g_black = newO;
            }
            AppendMove(res.square);
        }
        g_current_is_black = !g_current_is_black;
        InvalidateRect(hwnd, NULL, TRUE);
    }
}

static void FinishGame(HWND hwnd) {
    g_game_over = 1;
    int bc = popcount(g_black), wc = popcount(g_white);
    UpdateStatus("");
    InvalidateRect(hwnd, NULL, TRUE);

    const char *winner;
    if (bc > wc) winner = "黒の勝ち";
    else if (wc > bc) winner = "白の勝ち";
    else winner = "引き分け";

    const char *you = g_human_is_black ? "黒" : "白";
    const char *result;
    if (bc == wc) result = "引き分けです";
    else if ((bc > wc) == g_human_is_black) result = "あなたの勝ちです！";
    else result = "あなたの負けです";

    char buf[256];
    snprintf(buf, sizeof(buf), "%s (%d - %d)\nあなたは%s番でした。%s",
             winner, bc, wc, you, result);
    WCHAR wbuf[256];
    Utf8ToWide(buf, wbuf, 256);
    MessageBoxW(hwnd, wbuf, L"対局終了", MB_OK | MB_ICONINFORMATION);
}

static void CopyKifu(HWND hwnd) {
    int len = GetWindowTextLengthW(g_hKifu);
    WCHAR *buf = (WCHAR *)malloc((size_t)(len + 1) * sizeof(WCHAR));
    if (!buf) return;
    GetWindowTextW(g_hKifu, buf, len + 1);

    if (OpenClipboard(hwnd)) {
        EmptyClipboard();
        HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)(len + 1) * sizeof(WCHAR));
        if (hMem) {
            WCHAR *p = (WCHAR *)GlobalLock(hMem);
            memcpy(p, buf, (size_t)(len + 1) * sizeof(WCHAR));
            GlobalUnlock(hMem);
            SetClipboardData(CF_UNICODETEXT, hMem);
        }
        CloseClipboard();
    }
    free(buf);

    WCHAR cur[300];
    GetWindowTextW(g_hStatus, cur, 300);
    wcsncat(cur, L"  (棋譜をコピーしました)", 299 - wcslen(cur));
    SetWindowTextW(g_hStatus, cur);
}

/* ============ ウィンドウプロシージャ ============ */

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE: {
        g_hFont = CreateUiFont();

        HWND lbl1 = CreateWindowW(L"STATIC", L"あなたの色:", WS_CHILD | WS_VISIBLE,
                                   20, 14, 90, 20, hwnd, NULL, g_hInst, NULL);
        g_hCombo = CreateWindowW(L"COMBOBOX", NULL,
                                  WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST,
                                  112, 10, 70, 200, hwnd, (HMENU)ID_COMBO_COLOR, g_hInst, NULL);
        SendMessageW(g_hCombo, CB_ADDSTRING, 0, (LPARAM)L"黒");
        SendMessageW(g_hCombo, CB_ADDSTRING, 0, (LPARAM)L"白");
        SendMessageW(g_hCombo, CB_SETCURSEL, 0, 0);
        HWND btnNew = CreateWindowW(L"BUTTON", L"新しい対局", WS_CHILD | WS_VISIBLE,
                                     196, 8, 120, 28, hwnd, (HMENU)ID_BTN_NEWGAME, g_hInst, NULL);

        g_hStatus = CreateWindowW(L"STATIC", L"", WS_CHILD | WS_VISIBLE,
                                   20, STATUS_Y, CLIENT_W - 40, 24, hwnd,
                                   (HMENU)ID_STATIC_STATUS, g_hInst, NULL);

        HWND lbl2 = CreateWindowW(L"STATIC", L"棋譜:", WS_CHILD | WS_VISIBLE,
                                   20, KIFU_Y + 5, 40, 20, hwnd, NULL, g_hInst, NULL);
        g_hKifu = CreateWindowW(L"EDIT", L"",
                                 WS_CHILD | WS_VISIBLE | WS_BORDER | ES_READONLY | ES_AUTOHSCROLL,
                                 62, KIFU_Y, CLIENT_W - 62 - 110 - 12, 26, hwnd,
                                 (HMENU)ID_EDIT_KIFU, g_hInst, NULL);
        HWND btnCopy = CreateWindowW(L"BUTTON", L"棋譜をコピー", WS_CHILD | WS_VISIBLE,
                                      CLIENT_W - 100, KIFU_Y - 2, 90, 30, hwnd,
                                      (HMENU)ID_BTN_COPY, g_hInst, NULL);

        SendMessageW(lbl1, WM_SETFONT, (WPARAM)g_hFont, TRUE);
        SendMessageW(g_hCombo, WM_SETFONT, (WPARAM)g_hFont, TRUE);
        SendMessageW(btnNew, WM_SETFONT, (WPARAM)g_hFont, TRUE);
        SendMessageW(g_hStatus, WM_SETFONT, (WPARAM)g_hFont, TRUE);
        SendMessageW(lbl2, WM_SETFONT, (WPARAM)g_hFont, TRUE);
        SendMessageW(g_hKifu, WM_SETFONT, (WPARAM)g_hFont, TRUE);
        SendMessageW(btnCopy, WM_SETFONT, (WPARAM)g_hFont, TRUE);

        g_human_is_black = 1;
        NewGame(hwnd);
        return 0;
    }
    case WM_LBUTTONDOWN: {
        if (g_game_over) break;
        if (g_current_is_black != g_human_is_black) break;
        int x = GET_X_LPARAM(lParam);
        int y = GET_Y_LPARAM(lParam);
        int cs = (x - BOARD_X - MARGIN) / CELL;
        int rs = (y - BOARD_Y - MARGIN) / CELL;
        if (cs < 0 || cs > 7 || rs < 0 || rs > 7) break;
        if (x < BOARD_X + MARGIN || y < BOARD_Y + MARGIN) break;
        int r = 7 - rs, c = cs;
        int sq = sq_of(c, r);

        Bitboard P = g_human_is_black ? g_black : g_white;
        Bitboard O = g_human_is_black ? g_white : g_black;
        Bitboard legal = get_moves(P, O);
        if (!(legal & (1ULL << sq))) break;

        Bitboard newP, newO;
        apply_move(P, O, sq, &newP, &newO);
        if (g_human_is_black) {
            g_black = newP;
            g_white = newO;
        } else {
            g_white = newP;
            g_black = newO;
        }
        AppendMove(sq);
        g_current_is_black = !g_current_is_black;
        InvalidateRect(hwnd, NULL, TRUE);
        ProcessTurns(hwnd);
        break;
    }
    case WM_COMMAND: {
        int id = LOWORD(wParam);
        int code = HIWORD(wParam);
        if (id == ID_BTN_NEWGAME && code == BN_CLICKED) {
            NewGame(hwnd);
        } else if (id == ID_BTN_COPY && code == BN_CLICKED) {
            CopyKifu(hwnd);
        } else if (id == ID_COMBO_COLOR && code == CBN_SELCHANGE) {
            int idx = (int)SendMessageW(g_hCombo, CB_GETCURSEL, 0, 0);
            g_human_is_black = (idx == 0);
            NewGame(hwnd);
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
        if (g_hFont) DeleteObject(g_hFont);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
    (void)hPrevInstance;
    (void)lpCmdLine;
    g_hInst = hInstance;

    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
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
