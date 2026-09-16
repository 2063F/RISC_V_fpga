#include "uart.h"

// Test BSS clear. These should be initialized to 0.
int bss_test_val1;
int bss_test_val2 = 0;

int main(void) {
    uart_print("Hello from C program with expanded memory!\n");
    
    // Check if BSS clear worked
    if (bss_test_val1 == 0 && bss_test_val2 == 0) {
        uart_print("BSS cleared successfully!\n");
    } else {
        uart_print("ERROR: BSS was not cleared!\n");
    }

    uart_print("Entering echo loop...\n");

    while (1) {
        char c = uart_getchar();
        // Echo back
        uart_putchar(c);
    }

    return 0;
}
