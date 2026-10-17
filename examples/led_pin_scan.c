// =============================================================================
// led_pin_scan.c - Lights one dot at a time, cycling through all 8 row
// indices (col fixed at 0) and then all 8 column indices (row fixed at 0),
// to empirically map logical row/col index -> physical LED position.
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

#define HOLD_CYCLES 25000000u /* a bit under a second, busy-wait */

int main(void)
{
    uart_print("LED pin scan\n");

    for (;;) {
        for (int r = 0; r < 8; r++) {
            printf("ROW %d (col=0) GREEN\n", r);
            set_leds(1ULL << (r * 8 + 0), 0);
            delay(HOLD_CYCLES);
        }

        set_leds(0, 0);
        delay(HOLD_CYCLES / 2);

        for (int c = 0; c < 8; c++) {
            printf("COL %d (row=0) GREEN\n", c);
            set_leds(1ULL << (0 * 8 + c), 0);
            delay(HOLD_CYCLES);
        }

        set_leds(0, 0);
        delay(HOLD_CYCLES / 2);

        for (int c = 0; c < 8; c++) {
            printf("COL %d (row=0) RED\n", c);
            set_leds(0, 1ULL << (0 * 8 + c));
            delay(HOLD_CYCLES);
        }

        set_leds(0, 0);
        delay(HOLD_CYCLES / 2);
    }

    return 0;
}
