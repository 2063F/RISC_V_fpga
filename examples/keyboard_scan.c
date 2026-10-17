// =============================================================================
// keyboard_scan.c - 8x8 matrix keyboard scan (16 GPIO -> key code 1-64)
// =============================================================================
// Hardware assumption (not yet implemented in board_io.v):
//   0x8000_0028 : ROW output register, bits [7:0]
//                 - active-low: write 0 to the bit of the row being scanned,
//                   1 to all other bits (idle = 0xFF)
//   0x8000_002C : COL input register, bits [7:0]
//                 - active-low: a pressed key pulls its column bit to 0
//                   (columns pulled up when idle)
// =============================================================================
#include "uart.h"
#include <stdint.h>

#define MMIO_KBD_ROW (*(volatile uint32_t *)0x80000028u)
#define MMIO_KBD_COL (*(volatile uint32_t *)0x8000002Cu)

#define KBD_ROWS 8
#define KBD_COLS 8
#define KBD_IDLE 0xFFu

static void delay(volatile uint32_t cycles)
{
    while (cycles-- > 0u) {
        /* busy wait: let the row line settle before reading columns */
    }
}

// Scans the matrix once. Returns the pressed key as 1-64 (row-major:
// key = row*8 + col + 1), or 0 if no key is pressed. When multiple keys
// are pressed simultaneously, the first one found (lowest row/col) wins.
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

// Debounced scan: a new key value is only reported once it is read
// identically on two consecutive scans.
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

int main(void)
{
    uart_print("8x8 matrix keyboard scan test\n");

    uint32_t prev_key = 0;

    while (1) {
        uint32_t key = keyboard_scan_debounced();

        if (key != prev_key) {
            if (key != 0) {
                printf("Key pressed: %d (row=%d, col=%d)\n",
                       key, (key - 1) / KBD_COLS, (key - 1) % KBD_COLS);
            } else {
                uart_print("Key released\n");
            }
            prev_key = key;
        }
    }

    return 0;
}
