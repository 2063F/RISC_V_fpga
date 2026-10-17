// =============================================================================
// main.c - Othello vs AI, played through the 8x8 matrix keyboard, a USB
// keyboard on the Dock's USB-A port, and UART
// =============================================================================
// You always play Black; the engine (search.c) always plays White.
// Press a matrix keyboard key 1-64 to place a stone: key N corresponds to
// square N-1 (row-major, same numbering as keyboard_scan.c: sq = row*8 + col).
// A USB keyboard works at the same time: type the square as a letter a-h and
// a number 1-8, e.g. "d3" (Backspace cancels the letter). usb_keyboard.v
// reports each key as an index 0-63 (see the table at its top); read_move()
// picks out the letter and number keys from those indexes.
// Board and status are printed over UART - connect with tools/uart_monitor.ps1.
//
// Five AI levels, chosen from a menu before every game, including the first
// one after reset (key N = a1..e1 on the matrix, F1..F5 on a USB keyboard):
//   1 Settai - for kids at the school festival: picks from the worst third of
//              its moves and never takes a corner unless forced.
//   2 Easy   - plays a random legal move.
//   3 Medium - picks from the best third of its moves (1-ply evaluation).
//   4 Hard   - alpha-beta search, depth 2.
//   5 Expert - alpha-beta search, depth SEARCH_DEPTH.
// Any other key keeps the current level. Level 1 is the default after reset.
// =============================================================================
#include "othello.h"
#include "evaluate.h"
#include "search.h"
#include "uart.h"
#include <stdint.h>

#define MMIO_KBD_ROW (*(volatile uint32_t *)0x80000028u)
#define MMIO_KBD_COL (*(volatile uint32_t *)0x8000002Cu)

// USB keyboard event register (board_io.v / usb_keyboard.v).
// read: bit 9 = connected, bit 8 = event waiting, bits 5:0 = key index
// (0 = a1, 1 = b1, ... 8 = a2, ... 63 = h8). write: consume the event.
#define MMIO_USBKEY     (*(volatile uint32_t *)0x80000040u)
#define USBKEY_VALID    0x100u
#define USBKEY_INDEX    0x3Fu

// 8x8 bicolor LED matrix (Lite-On LTP-12188M-07). Black stones are shown
// green, white stones red. Hardware (led_matrix.v) scans the display on
// its own once written, so this never needs attention again after a store.
#define MMIO_LED_GREEN_LO (*(volatile uint32_t *)0x80000030u)
#define MMIO_LED_GREEN_HI (*(volatile uint32_t *)0x80000034u)
#define MMIO_LED_RED_LO   (*(volatile uint32_t *)0x80000038u)
#define MMIO_LED_RED_HI   (*(volatile uint32_t *)0x8000003Cu)

#define KBD_ROWS 8
#define KBD_COLS 8
#define KBD_IDLE 0xFFu

// AI search depth. The original PC engine used depth<=30 with a ~25MB
// transposition table and a 1.2s clock-based time limit; none of that fits
// this CPU (32KB ROM / 64KB RAM, no timer), so the search here is a plain
// fixed-depth alpha-beta walk (see search.c). Raise this if the AI feels
// too weak and the move still returns in acceptable time; lower it if a
// move takes too long.
#define SEARCH_DEPTH 4

// AI levels. depth 0 = no search, choose with find_weak_move(pick);
// otherwise find_best_move at that depth.
#define LEVEL_COUNT 5

typedef struct {
    const char *name;
    WeakPick pick;
    int depth;
} LevelDef;

static const LevelDef levels[LEVEL_COUNT] = {
    { "1 Settai (for kids)", PICK_WORST,  0 },
    { "2 Easy",              PICK_RANDOM, 0 },
    { "3 Medium",            PICK_GOOD,   0 },
    { "4 Hard",              PICK_GOOD,   2 },
    { "5 Expert",            PICK_GOOD,   SEARCH_DEPTH },
};

static int level = 0; // index into levels[]; level 1 after reset

// Random numbers for levels 1-3. There is no timer, so entropy comes from
// how long the player takes to press each key (see wait_key_press). The state
// lives in .noinit so it also carries over across resets.
static uint32_t rng_state __attribute__((section(".noinit")));

static void rng_mix(uint32_t v)
{
    rng_state = (rng_state ^ v) * 0x9E3779B1u + 0x7F4A7C15u;
}

static uint32_t rng_next(void)
{
    uint32_t x = rng_state;
    if (x == 0u) {
        x = 0x2545F491u;
    }
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

static void delay(volatile uint32_t cycles)
{
    while (cycles-- > 0u) {
        /* busy wait: let the row line settle before reading columns */
    }
}

// Scans the matrix once. Returns the pressed key as 1-64, or 0 if none.
static uint32_t keyboard_scan(void)
{
    uint32_t key = 0;

    for (uint32_t row = 0; row < KBD_ROWS; row++) {
        MMIO_KBD_ROW = (~(1u << row)) & KBD_IDLE;
        delay(50u);

        uint32_t col = MMIO_KBD_COL & KBD_IDLE;
        if (col != KBD_IDLE) {
            for (uint32_t c = 0; c < KBD_COLS; c++) {
                if ((col & (1u << c)) == 0u) {
                    key = row * KBD_COLS + c + 1u;
                    break;
                }
            }
            break;
        }
    }

    MMIO_KBD_ROW = KBD_IDLE;
    return key;
}

static uint32_t keyboard_scan_debounced(void)
{
    static uint32_t last_key = 0;
    uint32_t key = keyboard_scan();

    if (key == last_key) {
        return key;
    }

    delay(3000u);
    if (keyboard_scan() == key) {
        last_key = key;
        return key;
    }

    return last_key;
}

// Takes one pending USB keyboard event and returns it as key index + 1
// (1-64), or 0 if none is waiting. The hardware already turns each press into
// exactly one event, so no debouncing is needed here.
static uint32_t usb_key_take(void)
{
    uint32_t ev = MMIO_USBKEY;
    if ((ev & USBKEY_VALID) == 0u) {
        return 0;
    }
    MMIO_USBKEY = 0u;

    return (ev & USBKEY_INDEX) + 1u;
}

// Drops USB key presses made while the AI was thinking or the board was
// being printed, so they aren't taken as the next move. Called once per turn
// (not per key), so the second letter of a typed square isn't lost.
static void usb_key_flush(void)
{
    while (usb_key_take() != 0u) {
    }
}

// usb_keyboard.v key indexes of the keys used to type a square like "d3".
#define USBIDX_DIGIT1    12 // keys 1..8 are indexes 12..19
#define USBIDX_BACKSPACE 25

// Column 0-7 for letter keys A-H, else -1.
static int usb_letter_col(int idx)
{
    switch (idx) {
    case 38: return 0; // A
    case 54: return 1; // B
    case 52: return 2; // C
    case 40: return 3; // D
    case 28: return 4; // E
    case 41: return 5; // F
    case 42: return 6; // G
    case 43: return 7; // H
    default: return -1;
    }
}

// Row 0-7 for number keys 1-8, else -1.
static int usb_digit_row(int idx)
{
    if (idx >= USBIDX_DIGIT1 && idx < USBIDX_DIGIT1 + 8) {
        return idx - USBIDX_DIGIT1;
    }
    return -1;
}

// Blocks until a key transitions from "released" to "pressed" on the matrix
// keyboard, or a key is pressed on the USB keyboard, then returns it (1-64):
// a matrix key number, or a USB key index + 1 (*from_usb tells which).
// Used for turn input so a held key isn't read twice.
// The number of polls until the press feeds the random number generator.
static int wait_key_press(int *from_usb)
{
    uint32_t spins = 0;
    uint32_t prev = keyboard_scan_debounced();
    for (;;) {
        spins++;
        uint32_t usb = usb_key_take();
        if (usb != 0u) {
            rng_mix(spins ^ (usb << 24));
            *from_usb = 1;
            return (int)usb;
        }
        uint32_t key = keyboard_scan_debounced();
        if (key != 0 && prev == 0) {
            rng_mix(spins ^ (key << 24));
            *from_usb = 0;
            return (int)key;
        }
        prev = key;
    }
}

// Stones only: legal moves are shown on UART, not here. Lighting both colors
// of one dot for orange came out too faint with the 1/64-duty scan.
static void update_led_matrix(Bitboard black, Bitboard white)
{
    MMIO_LED_GREEN_LO = (uint32_t)(black & 0xFFFFFFFFu);
    MMIO_LED_GREEN_HI = (uint32_t)(black >> 32);
    MMIO_LED_RED_LO   = (uint32_t)(white & 0xFFFFFFFFu);
    MMIO_LED_RED_HI   = (uint32_t)(white >> 32);
}

// Running totals of finished games per level (you = Red/black). Kept in .noinit, which
// crt0.S doesn't clear, so the totals survive a reset (S1 or holding Space)
// as long as the board stays powered. At power-up the RAM holds zeros or
// leftovers, so the magic word and check value decide whether it is valid.
#define STATS_MAGIC 0x0751A75Cu

typedef struct {
    uint32_t wins;
    uint32_t losses;
    uint32_t draws;
} LevelStats;

typedef struct {
    uint32_t magic;
    LevelStats lv[LEVEL_COUNT];
    uint32_t check;
} GameStats;

static GameStats stats __attribute__((section(".noinit")));

static uint32_t stats_check(void)
{
    uint32_t c = STATS_MAGIC;
    for (int i = 0; i < LEVEL_COUNT; i++) {
        c = ((c << 7) | (c >> 25)) ^ stats.lv[i].wins ^ (stats.lv[i].losses << 10)
            ^ (stats.lv[i].draws << 20);
    }
    return c;
}

static void stats_init(void)
{
    if (stats.magic != STATS_MAGIC || stats.check != stats_check()) {
        stats.magic = STATS_MAGIC;
        for (int i = 0; i < LEVEL_COUNT; i++) {
            stats.lv[i].wins   = 0;
            stats.lv[i].losses = 0;
            stats.lv[i].draws  = 0;
        }
        stats.check = stats_check();
    }
}

static void print_result(Bitboard black, Bitboard white)
{
    LevelStats *st = &stats.lv[level];
    int bc = popcount(black), wc = popcount(white);
    printf("\n=== Game over ===\n");
    printf("Red: %d  Green: %d\n", bc, wc);
    if (bc > wc) {
        uart_print("Red wins!\n");
        st->wins++;
    } else if (wc > bc) {
        uart_print("Green wins!\n");
        st->losses++;
    } else {
        uart_print("Draw.\n");
        st->draws++;
    }
    stats.check = stats_check();

    // Win rate in tenths of a percent, rounded; draws count as games, not wins.
    uint32_t games = st->wins + st->losses + st->draws;
    uint32_t rate10 = (st->wins * 1000u + games / 2u) / games;
    printf("%s total: %d games  Win %d / Lose %d / Draw %d  Win rate: %d.%d%%\n",
           levels[level].name, (int)games, (int)st->wins, (int)st->losses,
           (int)st->draws, (int)(rate10 / 10u), (int)(rate10 % 10u));
}

// Shows the level menu and waits for a key. Keys 1-5 choose that level; any
// other key starts with the current one. Called before every game.
static void select_level(void)
{
    uart_print("\nChoose the level with keys 1-5 / F1-F5:\n");
    for (int i = 0; i < LEVEL_COUNT; i++) {
        printf("  %s\n", levels[i].name);
    }
    printf("(other keys: keep level %s)\n", levels[level].name);

    // USB F1-F5 are key indexes 0-4, so both keyboards give 1-5 here.
    int from_usb;
    usb_key_flush();
    int key = wait_key_press(&from_usb);
    if (key >= 1 && key <= LEVEL_COUNT) {
        level = key - 1;
    }
    printf("Level %s\n", levels[level].name);
}

// Reads the player's move and returns a legal square. Matrix keyboard: one
// key per square (key N = square N-1). USB keyboard: type the square as a
// letter a-h then a number 1-8, e.g. "d3"; Backspace cancels the letter.
static int read_move(Bitboard moves)
{
    int pending_col = -1; // letter typed on the USB keyboard, waiting for a number

    usb_key_flush();
    for (;;) {
        int from_usb;
        int key = wait_key_press(&from_usb);
        int sq;

        if (!from_usb) {
            pending_col = -1;
            sq = key - 1;
            if (!(moves & (1ULL << (unsigned)sq))) {
                printf("Key %d is not a legal move. Try again.\n", key);
                continue;
            }
            return sq;
        }

        int idx = key - 1;
        int col = usb_letter_col(idx);
        int row = usb_digit_row(idx);
        if (col >= 0) {
            pending_col = col; // a second letter replaces the first
            printf("> %c_\n", 'a' + col);
            continue;
        }
        if (idx == USBIDX_BACKSPACE) {
            if (pending_col >= 0) {
                pending_col = -1;
                uart_print("> _\n");
            }
            continue;
        }
        if (row < 0 || pending_col < 0) {
            uart_print("Type a letter a-h, then a number 1-8 (e.g. d3).\n");
            continue;
        }

        sq = row * 8 + pending_col;
        pending_col = -1;
        char buf[3];
        square_to_str(sq, buf);
        if (!(moves & (1ULL << (unsigned)sq))) {
            printf("%s is not a legal move. Try again.\n", buf);
            continue;
        }
        return sq;
    }
}

int main(void)
{
    stats_init();
    uart_print("Othello AI (8x8 matrix keyboard edition)\n");
    uart_print("You are Red. Press a key (1-64) or type a square like d3 to place a stone.\n");

    for (;;) {
        select_level();
        Bitboard black = INIT_BLACK;
        Bitboard white = INIT_WHITE;
        int current_is_black = 1;

        for (;;) {
            Bitboard P = current_is_black ? black : white;
            Bitboard O = current_is_black ? white : black;
            Bitboard moves = get_moves(P, O);

            if (moves == 0) {
                current_is_black = !current_is_black;
                Bitboard NP = current_is_black ? black : white;
                Bitboard NO = current_is_black ? white : black;
                if (get_moves(NP, NO) == 0) {
                    break; /* neither side can move: game over */
                }
                printf("%s has no legal move. Pass.\n", current_is_black ? "Green" : "Red");
                continue;
            }

            // Show the player's legal moves; none while the AI is to move
            Bitboard hints = current_is_black ? moves : 0;
            print_board(black, white, hints);
            update_led_matrix(black, white);
            printf("Red: %d  Green: %d\n", popcount(black), popcount(white));

            if (current_is_black) {
                uart_print("Your move (Red). Press a key (1-64) or type a square (e.g. d3).\n");
                int sq = read_move(moves);
                Bitboard newP, newO;
                apply_move(P, O, sq, &newP, &newO);
                black = current_is_black ? newP : newO;
                white = current_is_black ? newO : newP;
                char buf[3];
                square_to_str(sq, buf);
                printf("You played %s\n", buf);
            } else {
                uart_print("AI (Green) is thinking...\n");
                const LevelDef *lv = &levels[level];
                SearchResult res = (lv->depth == 0)
                    ? find_weak_move(black, white, current_is_black, lv->pick, rng_next())
                    : find_best_move(black, white, current_is_black, lv->depth);
                if (res.square >= 0) {
                    Bitboard newP, newO;
                    apply_move(P, O, res.square, &newP, &newO);
                    black = current_is_black ? newP : newO;
                    white = current_is_black ? newO : newP;
                    char buf[3];
                    square_to_str(res.square, buf);
                    printf("AI played %s (nodes=%d)\n", buf, (int)res.nodes);
                }
            }

            current_is_black = !current_is_black;
        }

        print_board(black, white, 0);
        update_led_matrix(black, white);
        print_result(black, white);
    }

    return 0;
}
