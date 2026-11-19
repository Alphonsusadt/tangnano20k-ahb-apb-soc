/* ==============================================================================
 * Tang Nano 20K Ibex firmware
 * Runs a CPU and bus self-test, reports on the UART, then echoes the UART and
 * drives the LEDs. After the self-test both are interrupt driven: the timer
 * interrupt toggles the heartbeat, and the UART RX interrupt echoes each byte. Report: "IBEX PASS\r\n" or "IBEX FAIL xx\r\n", xx = failed test.
 * LEDs (active low): [0] heartbeat, [1] pass, [2] fail, [3] S2 pressed.
 * ============================================================================== */

#include <stdint.h>
#include "soc_map.h"

#define REG32(addr)     (*(volatile uint32_t *)(uintptr_t)(addr))

#define UART_DATA       REG32(UART_BASE + 0x00U)
#define UART_STATUS     REG32(UART_BASE + 0x04U)
#define UART_CTRL       REG32(UART_BASE + 0x08U)
#define UART_BAUD       REG32(UART_BASE + 0x0CU)
#define UART_RX_VALID   (1U << 0)
#define UART_TX_EMPTY   (1U << 1)
#define UART_CTRL_TX_EN     (1U << 0)
#define UART_CTRL_RX_EN     (1U << 1)
#define UART_CTRL_RX_IRQ_EN (1U << 3)

#define MTIME_LO        REG32(TIMER_BASE + 0x00U)
#define MTIME_HI        REG32(TIMER_BASE + 0x04U)
#define MTIMECMP_LO     REG32(TIMER_BASE + 0x08U)
#define MTIMECMP_HI     REG32(TIMER_BASE + 0x0CU)
#define TIMER_CTRL      REG32(TIMER_BASE + 0x10U)
#define TIMER_CTRL_EN   (1U << 0)

#define MIE_MTIE        (1U << 7)      /* Machine timer interrupt enable */
#define MIE_FAST0       (1U << 16)     /* Ibex fast interrupt 0: the UART */
#define MSTATUS_MIE     (1U << 3)
#define MCAUSE_TIMER    0x80000007U
#define MCAUSE_UART     0x80000010U

#define SPI_CR          REG32(SPI_BASE + 0x00U)
#define SPI_SR          REG32(SPI_BASE + 0x04U)
#define SPI_TXDATA      REG32(SPI_BASE + 0x08U)
#define SPI_RXDATA      REG32(SPI_BASE + 0x0CU)
#define SPI_SR_BUSY     (1U << 0)
#define SPI_CR_ENABLE   (1U << 0)
#define SPI_CR_DIV(n)   ((uint32_t)(n) << 4)
#define SPI_CR_AUTO_CS  (1U << 12)

#define GPIO_OUT        REG32(GPIO_BASE + 0x00U)
#define GPIO_IN         REG32(GPIO_BASE + 0x04U)
#define GPIO_IN_S2      (1U << 1)

/* The heartbeat toggles every 2^HEARTBEAT_BIT cycles. Simulation overrides this. */
#ifndef HEARTBEAT_BIT
#define HEARTBEAT_BIT   23
#endif

/* Written by the interrupt handlers, read by the main loop and the self-test. */
static volatile uint32_t heartbeat;
static volatile uint32_t timer_ticks;
static volatile uint32_t timer_mcause;
static volatile uint32_t uart_irqs;

/* Reads the 64-bit mtime: HI, LO, HI again, and retries if a carry moved HI. */
static uint64_t mtime_read(void) {
    uint32_t hi, lo;
    do {
        hi = MTIME_HI;
        lo = MTIME_LO;
    } while (MTIME_HI != hi);
    return ((uint64_t)hi << 32) | lo;
}

/* Writes the 64-bit mtimecmp so that no intermediate value is below mtime:
 * LO to its maximum first, then HI, then the real LO. */
static void mtimecmp_write(uint64_t value) {
    MTIMECMP_LO = 0xFFFFFFFFU;
    MTIMECMP_HI = (uint32_t)(value >> 32);
    MTIMECMP_LO = (uint32_t)value;
}

static uint64_t mtimecmp_read(void) {
    return ((uint64_t)MTIMECMP_HI << 32) | MTIMECMP_LO;
}

/* Machine timer, mcause 7. The interrupt is a level, so it is cleared by moving
 * mtimecmp one heartbeat period further; adding to mtimecmp rather than to mtime
 * keeps the period exact however late the handler runs. */
void __attribute__((interrupt)) timer_isr(void) {
    uint32_t cause;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    timer_mcause = cause;
    timer_ticks++;
    heartbeat ^= 1U;
    mtimecmp_write(mtimecmp_read() + (1ULL << HEARTBEAT_BIT));
}

/* UART RX, fast interrupt 0. Reading UART_DATA clears RX_VALID, which clears the
 * interrupt, so the handler drains every received byte and echoes it. */
void __attribute__((interrupt)) uart_isr(void) {
    uart_irqs++;
    while (UART_STATUS & UART_RX_VALID) {
        uint32_t c = UART_DATA & 0xFFU;
        while (!(UART_STATUS & UART_TX_EMPTY)) {
        }
        UART_DATA = c;
    }
}

/* Starts the timer with the first interrupt `delay` cycles from now. */
static void timer_start(uint32_t delay) {
    TIMER_CTRL = 0U;
    mtimecmp_write(mtime_read() + delay);
    TIMER_CTRL = TIMER_CTRL_EN;
    __asm__ volatile ("csrs mie, %0" : : "r"(MIE_MTIE));
    __asm__ volatile ("csrs mstatus, %0" : : "r"(MSTATUS_MIE));
}

/* Startup code and the two tests below depend on these. */
static volatile uint32_t data_word = 0x12345678U;
static volatile uint32_t bss_word;
static const uint32_t rom_table[4] = {0x11111111U, 0x22222222U, 0x33333333U, 0x44444444U};
static volatile uint32_t sram_buffer[4];

/* Machine code for test 10, copied into SRAM and run from there:
 * a0 = a0 * 2 + 1. Plain RV32I words, so they do not depend on where they run. */
static const uint32_t sram_code_image[3] = {
    0x00151513U,    /* slli a0, a0, 1 */
    0x00150513U,    /* addi a0, a0, 1 */
    0x00008067U,    /* ret            */
};
static volatile uint32_t sram_code[3] __attribute__((aligned(4)));

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

static uint32_t __attribute__((unused)) read_cycle_counter(void) {
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

    /* 9: The timer interrupt arrives, through the vector for mcause 7. */
    timer_start(200U);
    for (uint32_t i = 0U; i < 2000U && timer_ticks == 0U; i++) {
    }
    if (timer_ticks == 0U || timer_mcause != MCAUSE_TIMER) {
        return 9U;
    }

    /* 10: Code runs from SRAM. The words are written as data, fence.i makes the
     * fetch path see them, and the call fetches them from 0x2000_xxxx. fence.i is
     * written as its encoding, because this compiler's -march has no Zifencei. */
    for (uint32_t i = 0U; i < 3U; i++) {
        sram_code[i] = sram_code_image[i];
    }
    __asm__ volatile (".word 0x0000100f" ::: "memory");     /* fence.i */
    uint32_t (*sram_fn)(uint32_t) = (uint32_t (*)(uint32_t))(uintptr_t)sram_code;
    if (sram_fn(20U) != 41U) {
        return 10U;
    }

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
    __asm__ volatile ("sw %0, 1(%1)" : : "r"(0xFFFFFFFFU), "r"(SRAM_BASE + 0x100U));
#endif
#ifdef FORCE_ROM_STORE
    /* The ROM answers this store with ERROR, so it traps and nothing after it runs. */
    __asm__ volatile ("sw %0, 0(%1)" : : "r"(0xFFFFFFFFU), "r"(ROM_BASE + 0x100U));
#endif
#ifdef FORCE_UNMAPPED_STORE
    /* The default slave answers this store with ERROR, so it traps and nothing after it runs. */
    __asm__ volatile ("sw %0, 0(%1)" : : "r"(0xFFFFFFFFU), "r"(UNMAPPED_ADDR));
#endif
#ifdef FORCE_APB_SLVERR
    /* UART + 0x010 is past the last UART register, so the UART answers PSLVERR and
     * the bridge turns it into ERROR. The store traps and nothing after it runs. */
    __asm__ volatile ("sw %0, 0(%1)" : : "r"(0xFFFFFFFFU), "r"(UART_BASE + 0x010U));
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

    /* The heartbeat runs even if the self-test stopped before test 9. */
    if (!(TIMER_CTRL & TIMER_CTRL_EN)) {
        timer_start(1U << HEARTBEAT_BIT);
    }

    /* Echo through the UART RX interrupt instead of polling. */
    UART_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN | UART_CTRL_RX_IRQ_EN;
    __asm__ volatile ("csrs mie, %0" : : "r"(MIE_FAST0));

    while (1) {
        uint32_t lit = heartbeat & 1U;
        lit |= (failed == 0U) ? (1U << 1) : (1U << 2);
        if (GPIO_IN & GPIO_IN_S2) {
            lit |= 1U << 3;
        }
        GPIO_OUT = ~lit & 0x3FU;
    }
}
