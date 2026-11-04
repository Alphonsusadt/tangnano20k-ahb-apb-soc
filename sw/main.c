/* ==============================================================================
 * Tang Nano 20K Ibex firmware
 * Runs a CPU and bus self-test, reports on the UART, then echoes the UART and
 * drives the LEDs. Report: "IBEX PASS\r\n" or "IBEX FAIL xx\r\n", xx = failed test.
 * LEDs (active low): [0] heartbeat, [1] pass, [2] fail, [3] S2 pressed.
 * ============================================================================== */

#include <stdint.h>

#define REG32(addr)     (*(volatile uint32_t *)(addr))

#define UART_DATA       REG32(0x40000000U)
#define UART_STATUS     REG32(0x40000004U)
#define UART_BAUD       REG32(0x4000000CU)
#define UART_RX_VALID   (1U << 0)
#define UART_TX_EMPTY   (1U << 1)

#define SPI_CR          REG32(0x40001000U)
#define SPI_SR          REG32(0x40001004U)
#define SPI_TXDATA      REG32(0x40001008U)
#define SPI_RXDATA      REG32(0x4000100CU)
#define SPI_SR_BUSY     (1U << 0)
#define SPI_CR_ENABLE   (1U << 0)
#define SPI_CR_DIV(n)   ((uint32_t)(n) << 4)
#define SPI_CR_AUTO_CS  (1U << 12)

#define GPIO_OUT        REG32(0x40002000U)
#define GPIO_IN         REG32(0x40002004U)
#define GPIO_IN_S2      (1U << 1)

/* The heartbeat toggles every 2^HEARTBEAT_BIT cycles. Simulation overrides this. */
#ifndef HEARTBEAT_BIT
#define HEARTBEAT_BIT   23
#endif

/* Startup code and the two tests below depend on these. */
static volatile uint32_t data_word = 0x12345678U;
static volatile uint32_t bss_word;
static const uint32_t rom_table[4] = {0x11111111U, 0x22222222U, 0x33333333U, 0x44444444U};
static volatile uint32_t sram_buffer[4];

static void uart_putc(char c) {
    while (!(UART_STATUS & UART_TX_EMPTY)) {
    }
    UART_DATA = (uint32_t)(uint8_t)c;
}

static void uart_puts(const char *text) {
    while (*text) {
        uart_putc(*text++);
    }
}

static char hex_char(uint32_t value) {
    return (char)((value < 10U) ? ('0' + value) : ('A' + value - 10U));
}

static uint32_t read_cycle_counter(void) {
    uint32_t value;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(value));
    return value;
}

/* Recursion exercises calls, returns, and the stack in SRAM. */
static uint32_t __attribute__((noinline)) sum_to(uint32_t n) {
    return (n == 0U) ? 0U : n + sum_to(n - 1U);
}

/* Each test returns its number when it fails, and 0 when it passes. */
static uint32_t run_self_test(void) {
    /* 1: .data was copied from ROM, and .bss was cleared. */
    if (data_word != 0x12345678U || bss_word != 0U) {
        return 1U;
    }

    /* 2: Constant data reads from ROM. */
    for (uint32_t i = 0U; i < 4U; i++) {
        if (((const volatile uint32_t *)rom_table)[i] != (i + 1U) * 0x11111111U) {
            return 2U;
        }
    }

    /* 3: Word writes to SRAM. */
    for (uint32_t i = 0U; i < 4U; i++) {
        sram_buffer[i] = 0xA5A50000U + i;
    }
    for (uint32_t i = 0U; i < 4U; i++) {
        if (sram_buffer[i] != 0xA5A50000U + i) {
            return 3U;
        }
    }

    /* 4: Byte and halfword stores and loads on every lane. */
    volatile uint8_t  *bytes  = (volatile uint8_t *)&sram_buffer[0];
    volatile uint16_t *halves = (volatile uint16_t *)&sram_buffer[1];
    sram_buffer[0] = 0U;
    sram_buffer[1] = 0U;
    bytes[0] = 0x11U;
    bytes[1] = 0x22U;
    bytes[2] = 0x33U;
    bytes[3] = 0x44U;
    halves[0] = 0xBEEFU;
    halves[1] = 0xDEADU;
    if (sram_buffer[0] != 0x44332211U || sram_buffer[1] != 0xDEADBEEFU ||
        bytes[2] != 0x33U || halves[1] != 0xDEADU) {
        return 4U;
    }

    /* 5: Multiply and divide, from values the compiler cannot fold. */
    volatile uint32_t a = 1234567U;
    volatile uint32_t b = 89U;
    if (a * b != 109876463U || a / b != 13871U || a % b != 48U) {
        return 5U;
    }

    /* 6: Calls and the stack. */
    if (sum_to(50U) != 1275U) {
        return 6U;
    }

    /* 7: APB read of a reset value. */
    if (UART_BAUD != 234U) {
        return 7U;
    }

    /* 8: One SPI byte finishes. With MOSI jumpered to MISO, it also comes back. */
    SPI_CR = SPI_CR_ENABLE | SPI_CR_AUTO_CS | SPI_CR_DIV(3);
    SPI_TXDATA = 0xA5U;
    while (SPI_SR & SPI_SR_BUSY) {
    }
#ifdef SPI_LOOPBACK
    if ((SPI_RXDATA & 0xFFU) != 0xA5U) {
        return 8U;
    }
#endif

    return 0U;
}

#ifdef SPI_DEMO
/* 27 MHz / (2 * (26 + 1)) = 500 kHz, slow enough for jumper wires. */
#define SPI_DEMO_DIV    26U

static void uart_put_hex(uint32_t value) {
    uart_putc(hex_char((value >> 4) & 0xFU));
    uart_putc(hex_char(value & 0xFU));
}

static uint32_t spi_transfer(uint32_t tx) {
    SPI_TXDATA = tx;
    while (SPI_SR & SPI_SR_BUSY) {
    }
    return SPI_RXDATA & 0xFFU;
}

/* Sends each character typed on the UART over SPI, and reports both directions. A
 * slave answers during the next transfer, so RX is its reply to the previous byte. */
static void spi_demo(void) {
    SPI_CR = SPI_CR_ENABLE | SPI_CR_AUTO_CS | SPI_CR_DIV(SPI_DEMO_DIV);
    uart_puts("IBEX SPI DEMO\r\n");

    while (1) {
        if (UART_STATUS & UART_RX_VALID) {
            uint32_t tx = UART_DATA & 0xFFU;
            uint32_t rx = spi_transfer(tx);
            uart_puts("SPI TX ");
            uart_put_hex(tx);
            uart_puts(" RX ");
            uart_put_hex(rx);
            uart_puts("\r\n");
        }
        GPIO_OUT = ~((read_cycle_counter() >> HEARTBEAT_BIT) & 1U) & 0x3FU;
    }
}
#endif

int main(void) {
#ifdef SPI_DEMO
    spi_demo();
#endif
#ifdef FORCE_MISALIGNED_STORE
    /* A direct sw, because -mstrict-align turns a C store into safe byte stores.
     * The adapter must refuse it, so this store traps and nothing after it runs. */
    __asm__ volatile ("sw %0, 1(%1)" : : "r"(0xFFFFFFFFU), "r"(0x20000100U));
#endif
#ifdef FORCE_ROM_STORE
    /* The ROM answers this store with ERROR, so it traps and nothing after it runs. */
    __asm__ volatile ("sw %0, 0(%1)" : : "r"(0xFFFFFFFFU), "r"(0x00000100U));
#endif
#ifdef FORCE_UNMAPPED_STORE
    /* The default slave answers this store with ERROR, so it traps and nothing after it runs. */
    __asm__ volatile ("sw %0, 0(%1)" : : "r"(0xFFFFFFFFU), "r"(0x60000000U));
#endif

    uint32_t failed = run_self_test();

    if (failed == 0U) {
        uart_puts("IBEX PASS\r\n");
    } else {
        uart_puts("IBEX FAIL ");
        uart_putc(hex_char((failed >> 4) & 0xFU));
        uart_putc(hex_char(failed & 0xFU));
        uart_puts("\r\n");
    }

    while (1) {
        uint32_t status = UART_STATUS;
        if ((status & UART_RX_VALID) && (status & UART_TX_EMPTY)) {
            UART_DATA = UART_DATA;
        }

        uint32_t lit = (read_cycle_counter() >> HEARTBEAT_BIT) & 1U;
        lit |= (failed == 0U) ? (1U << 1) : (1U << 2);
        if (GPIO_IN & GPIO_IN_S2) {
            lit |= 1U << 3;
        }
        GPIO_OUT = ~lit & 0x3FU;
    }
}
