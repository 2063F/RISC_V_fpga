#include <stdint.h>

#define MMIO_LED_CTRL (*(volatile uint32_t *)0x80000020u)
#define MMIO_BUTTON   (*(volatile uint32_t *)0x80000024u)

static void delay(volatile uint32_t cycles)
{
    while (cycles-- > 0u) {
        /* busy wait */
    }
}

int main(void)
{
    uint32_t led_state = 0;

    MMIO_LED_CTRL = 0;

    while (1) {
        if ((MMIO_BUTTON & 1u) != 0u) {
            led_state ^= 1u;
            MMIO_LED_CTRL = led_state;

            delay(50000u);

            while ((MMIO_BUTTON & 1u) != 0u) {
                /* wait for button release */
            }
        }
    }

    return 0;
}