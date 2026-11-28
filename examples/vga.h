// vga.h - Text, hint and last-move overlay of the VGA board (vga_board.v)
//
// The screen is 80 x 30 characters (8 x 16 pixels) of text, with the 8x8
// Othello board on top of it while it is shown: the board covers rows 1-28,
// columns 12-67, so row 0, row 29 and the 12 columns on either side stay
// visible. With the board hidden (vga_show_board(0, ...)) the whole screen is text.
// Characters are ASCII 32-126; VGA_YELLOW draws one yellow instead of white.
// See board_io.v for the registers.
#ifndef VGA_H
#define VGA_H

#include <stdint.h>

#define VGA_HINT_LO (*(volatile uint32_t *)0x80000044u)
#define VGA_HINT_HI (*(volatile uint32_t *)0x80000048u)
#define VGA_CTRL    (*(volatile uint32_t *)0x8000004Cu)
#define VGA_LAST    (*(volatile uint32_t *)0x80000050u)
#define VGA_TEXT    ((volatile uint8_t *)0x80001000u)

// Called from many places: kept out of line so each call is a call, not a
// copy of the loop (static functions a program does not use are dropped).
#define VGA_FN static __attribute__((noinline, unused))

#define VGA_COLS   80
#define VGA_ROWS   30
#define VGA_YELLOW 0x80

VGA_FN void vga_putc(int col, int row, char c, int attr)
{
    if (col >= 0 && col < VGA_COLS && row >= 0 && row < VGA_ROWS)
        VGA_TEXT[row * 128 + col] = (uint8_t)((c & 0x7F) | attr);
}

// Writes s from (col, row) on, cut at the right edge; returns the next column
VGA_FN int vga_puts(int col, int row, const char *s, int attr)
{
    while (*s && col < VGA_COLS)
        vga_putc(col++, row, *s++, attr);
    return col;
}

// Blanks n characters from (col, row)
VGA_FN void vga_blank(int col, int row, int n)
{
    while (n-- > 0)
        vga_putc(col++, row, ' ', 0);
}

VGA_FN void vga_clear(void)
{
    for (int row = 0; row < VGA_ROWS; row++)
        vga_blank(0, row, VGA_COLS);
}

// on: the board over the text. red_green: its stones red and green (on a
// blue board) instead of black and white
static inline void vga_show_board(int on, int red_green)
{
    VGA_CTRL = (on ? 1u : 0u) | (red_green ? 2u : 0u);
}

// Squares to mark with a yellow dot (same numbering as the stone bitmaps)
static inline void vga_hints(uint64_t squares)
{
    VGA_HINT_LO = (uint32_t)squares;
    VGA_HINT_HI = (uint32_t)(squares >> 32);
}

// The stone to mark with a red dot, or -1 for none
static inline void vga_last_move(int sq)
{
    VGA_LAST = (sq >= 0) ? (0x40u | (uint32_t)sq) : 0u;
}

#endif // VGA_H
