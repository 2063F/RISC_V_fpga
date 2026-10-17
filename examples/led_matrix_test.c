// =============================================================================
// led_matrix_test.c - Standalone test patterns for the 8x8 bicolor LED
// matrix, independent of the Othello game logic. Cycles through patterns
// over UART so we can see which one is on screen.
// =============================================================================
#include "uart.h"
#include <stdint.h>

#define MMIO_LED_GREEN_LO (*(volatile uint32_t *)0x80000030u)
#define MMIO_LED_GREEN_HI (*(volatile uint32_t *)0x80000034u)
#define MMIO_LED_RED_LO   (*(volatile uint32_t *)0x80000038u)
#define MMIO_LED_RED_HI   (*(volatile uint32_t *)0x8000003Cu)

static void delay(volatile uint32_t cycles)
{
    while (cycles-- > 0u) {
        /* busy wait */
    }
}

static void set_leds(uint64_t green, uint64_t red)
{
    MMIO_LED_GREEN_LO = (uint32_t)(green & 0xFFFFFFFFu);
    MMIO_LED_GREEN_HI = (uint32_t)(green >> 32);
    MMIO_LED_RED_LO   = (uint32_t)(red & 0xFFFFFFFFu);
    MMIO_LED_RED_HI   = (uint32_t)(red >> 32);
}

#define HOLD_CYCLES 15000000u /* ~a few hundred ms busy-wait */

int main(void)
{
    uart_print("LED matrix test\n");

    for (;;) {
        uart_print("1: all dark\n");
        set_leds(0, 0);
        delay(HOLD_CYCLES);

        uart_print("2: all GREEN\n");
        set_leds(0xFFFFFFFFFFFFFFFFULL, 0);
        delay(HOLD_CYCLES);

        uart_print("3: all RED\n");
        set_leds(0, 0xFFFFFFFFFFFFFFFFULL);
        delay(HOLD_CYCLES);

        uart_print("4: sq0 (row0,col0) GREEN only\n");
        set_leds(1ULL << 0, 0);
        delay(HOLD_CYCLES);

        uart_print("5: sq7 (row0,col7) GREEN only\n");
        set_leds(1ULL << 7, 0);
        delay(HOLD_CYCLES);

        uart_print("6: sq56 (row7,col0) GREEN only\n");
        set_leds(1ULL << 56, 0);
        delay(HOLD_CYCLES);

        uart_print("7: sq63 (row7,col7) GREEN only\n");
        set_leds(1ULL << 63, 0);
        delay(HOLD_CYCLES);

        uart_print("8: row0 all GREEN (sq0-7)\n");
        set_leds(0x00000000000000FFULL, 0);
        delay(HOLD_CYCLES);

        uart_print("9: col0 all GREEN (sq0,8,16,...,56)\n");
        set_leds(0x0101010101010101ULL, 0);
        delay(HOLD_CYCLES);

        uart_print("10: center 4 (Othello start) green=black white=red\n");
        set_leds((1ULL << 28) | (1ULL << 35), (1ULL << 27) | (1ULL << 36));
        delay(HOLD_CYCLES);
    }

    return 0;
}
