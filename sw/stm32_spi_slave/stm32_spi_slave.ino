/* ==============================================================================
 * STM32F407G-DISC1 SPI slave for the Ibex SPI demo image
 * SPI2, mode 0, MSB first, 8 bits, hardware NSS:
 *   PB12 NSS, PB13 SCK, PB14 MISO, PB15 MOSI
 * Answers each byte in upper case during the next transfer, like the slave model
 * in dv/tb_soc_ibex.sv. The first reply is 0x00.
 * Board: Arduino core "STM32 MCU based boards", Discovery, STM32F407G-DISC1.
 * Serial: 115200 on PA2/PA3. PD15 blinks while running, PD12 toggles on each byte.
 * ============================================================================== */

static const uint32_t SPI_PINS_MASK2 = (3U << 24) | (3U << 26) | (3U << 28) | (3U << 30);
static const uint32_t SPI_PINS_AF    = (2U << 24) | (2U << 26) | (2U << 28) | (2U << 30);
static const uint32_t SPI_PINS_AF5   = (5U << 16) | (5U << 20) | (5U << 24) | (5U << 28);

static uint32_t byte_count = 0;

static uint8_t to_upper(uint8_t c) {
  return (c >= 'a' && c <= 'z') ? c - 0x20U : c;
}

static void spi2_slave_init(void) {
  RCC->AHB1ENR |= RCC_AHB1ENR_GPIOBEN;
  RCC->APB1ENR |= RCC_APB1ENR_SPI2EN;
  (void)RCC->APB1ENR;

  // Idle levels for mode 0, so an unprogrammed FPGA cannot clock in false bits.
  GPIOB->PUPDR = (GPIOB->PUPDR & ~SPI_PINS_MASK2) | (1U << 24) | (2U << 26) | (2U << 30);
  GPIOB->AFR[1] = (GPIOB->AFR[1] & 0x0000FFFFU) | SPI_PINS_AF5;
  GPIOB->MODER = (GPIOB->MODER & ~SPI_PINS_MASK2) | SPI_PINS_AF;

  SPI2->CR2 = 0U;
  SPI2->CR1 = 0U;  // Slave, CPOL 0, CPHA 0, MSB first, 8 bits, NSS from the pin.
  SPI2->CR1 |= SPI_CR1_SPE;
  SPI2->DR = 0x00U;  // The reply to the first byte.
}

void setup() {
  pinMode(PD12, OUTPUT);
  pinMode(PD15, OUTPUT);
  Serial.begin(115200);
  spi2_slave_init();
  Serial.println("STM32 SPI SLAVE READY");
}

void loop() {
  uint32_t status = SPI2->SR;

  if (status & SPI_SR_OVR) {
    (void)SPI2->DR;  // Reading DR and then SR clears the overrun.
    (void)SPI2->SR;
    Serial.println("SPI OVERRUN");
  } else if (status & SPI_SR_RXNE) {
    uint8_t rx = (uint8_t)SPI2->DR;
    uint8_t reply = to_upper(rx);
    SPI2->DR = reply;

    byte_count++;
    digitalWrite(PD12, byte_count & 1U);
    Serial.printf("RX %02X NEXT %02X COUNT %lu\r\n", rx, reply, (unsigned long)byte_count);
  }

  digitalWrite(PD15, (millis() >> 9) & 1U);
}
