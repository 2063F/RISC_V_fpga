#include "uart.h"

// Test BSS variables (must be zero-initialized by crt0.S)
int bss_val1;
int bss_val2 = 0;

int main(void) {
    printf("=== Phase 3: Minimal C Runtime & printf Demo ===\n");

    // Check .bss initialization
    if (bss_val1 == 0 && bss_val2 == 0) {
        printf("[PASS] .bss section initialized to 0 successfully.\n");
    } else {
        printf("[FAIL] .bss section initialization error!\n");
    }

    // Test formatting features
    printf("Char: %c\n", 'A');
    printf("String: %s\n", "Hello RISC-V!");
    printf("Integer: %d (neg: %d)\n", 12345, -9876);
    printf("Hex: 0x%x (upper: 0x%X)\n", 0xDEADBEEF, 0xCAFEBABE);

    printf("Entering Echo Test (Press key)...\n");
    char input = uart_getchar();
    printf("Received char: '%c' (0x%x)\n", input, (unsigned int)input);

    printf("Done!\n");
    return 0;
}
