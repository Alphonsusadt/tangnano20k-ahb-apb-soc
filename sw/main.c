/* ==============================================================================
 * Tang Nano 20K lowRISC Ibex SoC Firmware
 * Main C Program: Mengontrol SPI Master, UART Serial Console, dan GPIO LED
 * ============================================================================== */

#include <stdint.h>

// ------------------------------------------------------------------------------
// Peta Alamat Register Periferal (Merujuk ke docs/memory_map.md)
// ------------------------------------------------------------------------------
#define UART_BASE       0x40000000U
#define SPI_BASE        0x40001000U
#define GPIO_BASE       0x40002000U

// Register UART
#define UART_DATA       (*(volatile uint32_t *)(UART_BASE + 0x00U))
#define UART_STATUS     (*(volatile uint32_t *)(UART_BASE + 0x04U))
#define UART_CTRL       (*(volatile uint32_t *)(UART_BASE + 0x08U))
#define UART_BAUD       (*(volatile uint32_t *)(UART_BASE + 0x0CU))

#define UART_STATUS_TX_EMPTY (1U << 1)
#define UART_STATUS_RX_VALID (1U << 0)

// Register SPI Master
#define SPI_CR          (*(volatile uint32_t *)(SPI_BASE + 0x00U))
#define SPI_SR          (*(volatile uint32_t *)(SPI_BASE + 0x04U))
#define SPI_TXDATA      (*(volatile uint32_t *)(SPI_BASE + 0x08U))
#define SPI_RXDATA      (*(volatile uint32_t *)(SPI_BASE + 0x0CU))
#define SPI_CS          (*(volatile uint32_t *)(SPI_BASE + 0x10U))

#define SPI_SR_BUSY     (1U << 0)
#define SPI_SR_TX_EMPTY (1U << 1)

// Register GPIO
#define GPIO_OUT        (*(volatile uint32_t *)(GPIO_BASE + 0x00U))
#define GPIO_IN         (*(volatile uint32_t *)(GPIO_BASE + 0x04U))
#define GPIO_DIR        (*(volatile uint32_t *)(GPIO_BASE + 0x08U))

// ------------------------------------------------------------------------------
// Bare-metal Startup & Entry Point (_start)
// ------------------------------------------------------------------------------
extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _stack_top;

void __attribute__((naked, section(".text.init"))) _start(void) {
    __asm__ volatile (
        ".option push          \n"
        ".option norelax       \n"
        "la gp, __global_pointer$\n"
        ".option pop           \n"
        "la sp, _stack_top     \n"
    );

    // Salin section .data dari ROM ke RAM
    uint32_t *src = &_sidata;
    uint32_t *dst = &_sdata;
    while (dst < &_edata) {
        *dst++ = *src++;
    }

    // Nol-kan section .bss
    dst = &_sbss;
    while (dst < &_ebss) {
        *dst++ = 0U;
    }

    // Panggil fungsi utama
    main();

    // Trap bila program selesai
    while (1) {
        __asm__ volatile ("wfi");
    }
}

// ------------------------------------------------------------------------------
// Driver Fungsi Delay & UART
// ------------------------------------------------------------------------------
static void delay_cycles(volatile uint32_t cycles) {
    while (cycles--) {
        __asm__ volatile ("nop");
    }
}

static void uart_init(uint32_t baud_div) {
    UART_BAUD = baud_div;
    UART_CTRL = 0x03; // Enable TX & RX
}

static void uart_putc(char c) {
    while (!(UART_STATUS & UART_STATUS_TX_EMPTY));
    UART_DATA = (uint32_t)(uint8_t)c;
}

static void uart_puts(const char *str) {
    while (*str) {
        if (*str == '\n') {
            uart_putc('\r');
        }
        uart_putc(*str++);
    }
}

static void uart_print_hex(uint32_t val, uint8_t digits) {
    const char hex_chars[] = "0123456789ABCDEF";
    for (int i = (digits - 1) * 4; i >= 0; i -= 4) {
        uart_putc(hex_chars[(val >> i) & 0xFU]);
    }
}

// ------------------------------------------------------------------------------
// Driver Fungsi SPI Master
// ------------------------------------------------------------------------------
static void spi_init(uint8_t clk_divider) {
    // Mode 0: CPOL=0, CPHA=0, MSB first
    // Bit 0 = 1 (Enable), Bit [11:4] = clk_divider, Bit 12 = 0 (Manual CS)
    SPI_CR = (1U << 0) | ((uint32_t)clk_divider << 4);
    SPI_CS = 0xFF; // Chip Select Idle (High)
}

static void spi_select(uint8_t cs_index) {
    SPI_CS = ~(1U << cs_index); // Active Low
}

static void spi_deselect(void) {
    SPI_CS = 0xFF; // Semua CS High (Non-aktif)
}

static uint8_t spi_transfer(uint8_t tx_byte) {
    // Tulis byte ke buffer TX (memulai pengiriman)
    SPI_TXDATA = (uint32_t)tx_byte;

    // Tunggu transmisi serial selesai
    while (SPI_SR & SPI_SR_BUSY);

    // Ambil byte yang diterima dari register RX
    return (uint8_t)(SPI_RXDATA & 0xFFU);
}

// ------------------------------------------------------------------------------
// Main Program
// ------------------------------------------------------------------------------
int main(void) {
    // Inisialisasi UART (27 MHz / 115200 ≈ 234)
    uart_init(234);

    // Inisialisasi SPI Master (Clock divisor = 4)
    spi_init(4);

    // Inisialisasi GPIO (LED Tang Nano 20K active low)
    GPIO_DIR = 0x3F;  // 6 LED output
    GPIO_OUT = 0x3F;  // Matikan semua LED

    uart_puts("\n========================================\n");
    uart_puts(" Tang Nano 20K RISC-V SoC (Ibex Core)   \n");
    uart_puts(" APB SPI Master & UART Controller Test  \n");
    uart_puts("========================================\n\n");

    // Pengujian Komunikasi SPI
    uart_puts("[SPI] Memulai pengujian transmisi SPI Master...\n");

    uint8_t test_payload[4] = {0x9F, 0x00, 0x00, 0x00}; // JEDEC ID Command
    uint8_t rx_payload[4];

    spi_select(0); // Aktifkan Slave SPI #0

    for (int i = 0; i < 4; i++) {
        rx_payload[i] = spi_transfer(test_payload[i]);
        uart_puts("  TX: 0x");
        uart_print_hex(test_payload[i], 2);
        uart_puts(" -> RX: 0x");
        uart_print_hex(rx_payload[i], 2);
        uart_puts("\n");
    }

    spi_deselect(); // Non-aktifkan Slave SPI #0
    uart_puts("[SPI] Pengujian selesai.\n\n");

    // Main Loop: Berkedip LED (Heartbeat) dan kirim status periodik
    uint8_t counter = 0;
    while (1) {
        // Toggle LED
        GPIO_OUT = ~(1U << (counter % 6));

        uart_puts("[SoC Heartbeat] Siklus ke: 0x");
        uart_print_hex(counter, 2);
        uart_puts("\n");

        // Kirim byte status lewat SPI
        spi_select(0);
        uint8_t ret = spi_transfer(counter);
        spi_deselect();

        uart_puts("  SPI Echo: 0x");
        uart_print_hex(ret, 2);
        uart_puts("\n");

        counter++;
        delay_cycles(500000);
    }

    return 0;
}
