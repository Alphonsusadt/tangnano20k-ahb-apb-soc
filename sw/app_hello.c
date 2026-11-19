/* ==============================================================================
 * Example application that runs from SRAM. It is linked with link_ram.ld and
 * crt_ram.S, sent by the bootloader, and started at _start.
 * Prints "APP HELLO", then echoes the UART and blinks LED 4 from the cycle counter.
 * ============================================================================== */

#include <stdint.h>
#include "soc_map.h"

#define REG32(addr)     (*(volatile uint32_t *)(uintptr_t)(addr))
#define UART_DATA       REG32(UART_BASE + 0x00U)
#define UART_STATUS     REG32(UART_BASE + 0x04U)
#define UART_RX_VALID   (1U << 0)
#define UART_TX_EMPTY   (1U << 1)
#define GPIO_OUT        REG32(GPIO_BASE + 0x00U)

#ifndef BLINK_BIT
#define BLINK_BIT       22
#endif

static void uart_putc(char c) {
    while (!(UART_STATUS & UART_TX_EMPTY)) {
    }
    UART_DATA = (uint32_t)(uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) {
        uart_putc(*s++);
    }
}

static uint32_t cycles(void) {
    uint32_t v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

int main(void) {
    uart_puts("APP HELLO\r\n");
    while (1) {
        if (UART_STATUS & UART_RX_VALID) {
            uart_putc((char)(UART_DATA & 0xFFU));
        }
        /* LEDs are active low: only LED 4 blinks, the rest stay off. */
        uint32_t on = (cycles() >> BLINK_BIT) & 1U;
        GPIO_OUT = ~(on << 4) & 0x3FU;
    }
}
