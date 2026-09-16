#ifndef UART_H
#define UART_H

#include <stdarg.h>

#define UART_TX_DATA   ((volatile char *)0x80000010)
#define UART_TX_STAT   ((volatile char *)0x80000014)
#define UART_RX_DATA   ((volatile char *)0x80000018)
#define UART_RX_STAT   ((volatile char *)0x8000001C)

static inline void uart_putchar(char c) {
    // Wait for transmitter to be ready (busy flag == 0)
    while (*UART_TX_STAT & 1);
    *UART_TX_DATA = c;
}

static inline char uart_getchar(void) {
    // Wait for receiver to have data (ready flag == 1)
    while (!(*UART_RX_STAT & 1));
    return *UART_RX_DATA;
}

static inline void uart_print(const char *str) {
    while (*str) {
        if (*str == '\n') {
            uart_putchar('\r');
        }
        uart_putchar(*str++);
    }
}

// Helper: print unsigned integer with base (10 or 16)
static inline void _uart_print_num(unsigned int num, int base, int is_upper) {
    char buf[16];
    int i = 0;
    const char *hex_digits = is_upper ? "0123456789ABCDEF" : "0123456789abcdef";

    if (num == 0) {
        uart_putchar('0');
        return;
    }

    while (num > 0) {
        buf[i++] = hex_digits[num % base];
        num /= base;
    }

    while (i > 0) {
        uart_putchar(buf[--i]);
    }
}

// Helper: print signed integer
static inline void _uart_print_int(int num) {
    if (num < 0) {
        uart_putchar('-');
        num = -num;
    }
    _uart_print_num((unsigned int)num, 10, 0);
}

// Lightweight printf implementation
static inline int mini_printf(const char *format, ...) {
    va_list args;
    va_start(args, format);

    while (*format) {
        if (*format == '%') {
            format++;
            if (*format == '\0') break;

            switch (*format) {
                case 'c': {
                    char c = (char)va_arg(args, int);
                    uart_putchar(c);
                    break;
                }
                case 's': {
                    const char *s = va_arg(args, const char *);
                    if (!s) s = "(null)";
                    uart_print(s);
                    break;
                }
                case 'd':
                case 'i': {
                    int val = va_arg(args, int);
                    _uart_print_int(val);
                    break;
                }
                case 'u': {
                    unsigned int val = va_arg(args, unsigned int);
                    _uart_print_num(val, 10, 0);
                    break;
                }
                case 'x': {
                    unsigned int val = va_arg(args, unsigned int);
                    _uart_print_num(val, 16, 0);
                    break;
                }
                case 'X': {
                    unsigned int val = va_arg(args, unsigned int);
                    _uart_print_num(val, 16, 1);
                    break;
                }
                case 'p': {
                    void *ptr = va_arg(args, void *);
                    uart_print("0x");
                    _uart_print_num((unsigned int)(unsigned long)ptr, 16, 0);
                    break;
                }
                case '%': {
                    uart_putchar('%');
                    break;
                }
                default: {
                    uart_putchar('%');
                    uart_putchar(*format);
                    break;
                }
            }
        } else {
            if (*format == '\n') {
                uart_putchar('\r');
            }
            uart_putchar(*format);
        }
        format++;
    }

    va_end(args);
    return 0;
}

#ifndef printf
#define printf mini_printf
#endif

#endif // UART_H
