# Peta Memori & Arsitektur Register (SoC Memory Map)

Dokumen ini mendefinisikan pemetaan memori sistem (System Memory Map) dan spesifikasi register untuk periferal pada arsitektur SoC berbasis **lowRISC Ibex** (RV32IMC) pada FPGA Tang Nano 20K.

---

## 1. Ikhtisar Alamat Global (System Address Map)

Sistem menggunakan bus **AHB-Lite 32-bit** sebagai interkoneksi utama untuk CPU, ROM, dan SRAM, serta **AHB-to-APB Bridge** untuk periferal berkecepatan rendah.

| Base Address | End Address | Ukuran | Bus | Modul / Fungsi | Akses |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `0x0000_0000` | `0x0000_7FFF` | 32 KB | AHB | **Instruction ROM (Bootloader)** | R / X |
| `0x2000_0000` | `0x2000_7FFF` | 32 KB | AHB | **Data SRAM (Scratchpad / Stack)** | R / W |
| `0x4000_0000` | `0x4000_0FFF` | 4 KB | APB | **APB UART Controller** | R / W |
| `0x4000_1000` | `0x4000_1FFF` | 4 KB | APB | **APB SPI Master Controller** | R / W |
| `0x4000_2000` | `0x4000_2FFF` | 4 KB | APB | **APB GPIO (LED & Key Button)** | R / W |
| `0x4000_3000` | `0x4FFF_FFFF` | - | APB | *Reserved / Ekstensi Masa Depan* | - |

---

## 2. Register Periferal APB UART (`0x4000_0000`)

Modul APB UART menyediakan komunikasi serial asinkron 8-N-1 default ke chip antarmuka USB host BL702 pada Tang Nano 20K.

### Ringkasan Register UART
| Offset | Nama Register | Akses | Reset Value | Deskripsi |
| :--- | :--- | :--- | :--- | :--- |
| `0x00` | `UART_DATA` | R/W | `0x00000000` | Write: Data Transmisi (TX). Read: Data Diterima (RX). |
| `0x04` | `UART_STATUS` | RO | `0x00000002` | Status buffer TX dan RX. |
| `0x08` | `UART_CTRL` | R/W | `0x00000003` | Kontrol enable TX/RX dan interrupt. |
| `0x0C` | `UART_BAUD` | R/W | `0x000000EA` | Pembagi clock baudrate: `div = F_CLK / (16 * Baud)`. |

### Deskripsi Bit `UART_STATUS` (`0x04`)
- **Bit [0]** (`RX_VALID`): Bernilai `1` jika ada data yang tersedia di buffer penerima (RX FIFO tidak kosong).
- **Bit [1]** (`TX_EMPTY`): Bernilai `1` jika buffer transmisi kosong dan siap menerima byte berikutnya.
- **Bit [2]** (`TX_FULL`): Bernilai `1` jika FIFO transmisi penuh.
- **Bit [3]** (`RX_OVERFLOW`): Error flag bila buffer RX terisi saat sudah penuh.

### Deskripsi Bit `UART_CTRL` (`0x08`)
- **Bit [0]** (`TX_EN`): `1` = Aktifkan transmiter UART.
- **Bit [1]** (`RX_EN`): `1` = Aktifkan receiver UART.
- **Bit [2]** (`TX_IRQ_EN`): `1` = Bangkitkan interrupt saat TX kosong.
- **Bit [3]** (`RX_IRQ_EN`): `1` = Bangkitkan interrupt saat RX menerima byte baru.

---

## 3. Register Periferal APB SPI Master (`0x4000_1000`)

Modul APB SPI Master digunakan untuk mengontrol perangkat SPI eksternal (Flash, OLED, Sensor, dll.).

### Ringkasan Register SPI
| Offset | Nama Register | Akses | Reset Value | Deskripsi |
| :--- | :--- | :--- | :--- | :--- |
| `0x00` | `SPI_CR` | R/W | `0x00000000` | SPI Control Register (Enable, Mode, Clock Divider). |
| `0x04` | `SPI_SR` | RO | `0x00000002` | SPI Status Register (Busy, FIFO Status). |
| `0x08` | `SPI_TXDATA`| WO | `0x00000000` | Transmit Data FIFO (Byte yang akan dikirim). |
| `0x0C` | `SPI_RXDATA`| RO | `0x00000000` | Receive Data FIFO (Byte yang diterima). |
| `0x10` | `SPI_CS` | R/W | `0x000000FF` | Chip Select Control (Active-LOW per bit). |

### Deskripsi Bit `SPI_CR` (`0x00`)
- **Bit [0]** (`SPI_EN`): `1` = Aktifkan modul SPI Master, `0` = Disable.
- **Bit [1]** (`CPHA`): Clock Phase (`0` = Sampel pada edge pertama, `1` = Sampel pada edge kedua).
- **Bit [2]** (`CPOL`): Clock Polarity (`0` = SCK idle low, `1` = SCK idle high).
- **Bit [3]** (`LSB_FIRST`): `0` = Transmisi MSB first (standar), `1` = LSB first.
- **Bit [11:4]** (`CLK_DIV`): Nilai pembagi clock SPI: `F_SCK = F_SYS / (2 * (CLK_DIV + 1))`.
- **Bit [12]** (`AUTO_CS`): `1` = CS diturunkan otomatis selama transfer, `0` = Manual software control.

### Deskripsi Bit `SPI_SR` (`0x04`)
- **Bit [0]** (`BUSY`): `1` = SPI sedang melakukan transfer bit pada bus serial.
- **Bit [1]** (`TX_EMPTY`): `1` = TX FIFO kosong.
- **Bit [2]** (`TX_FULL`): `1` = TX FIFO penuh.
- **Bit [3]** (`RX_EMPTY`): `1` = RX FIFO kosong.
- **Bit [4]** (`RX_FULL`): `1` = RX FIFO penuh.

### Deskripsi Bit `SPI_CS` (`0x10`)
- **Bit [7:0]** (`CS_N`): Bitmask kontrol pin Chip Select (Active Low).
  - Bit 0 = 0 -> Pin `spi_cs_n[0]` ditarik LOW (device aktif).
  - Bit 0 = 1 -> Pin `spi_cs_n[0]` ditarik HIGH (device idle).

---

## 4. Register Periferal APB GPIO (`0x4000_2000`)

Mengontrol LED onboard Tang Nano 20K dan membaca tombol (keys).

| Offset | Nama Register | Akses | Reset Value | Deskripsi |
| :--- | :--- | :--- | :--- | :--- |
| `0x00` | `GPIO_OUT` | R/W | `0x0000003F` | Bit [5:0] mengontrol status 6 LED onboard (Active Low). |
| `0x04` | `GPIO_IN` | RO | `0x00000003` | Bit [1:0] membaca status tombol S1 (PIN 88) dan S2 (PIN 87). |
| `0x08` | `GPIO_DIR` | R/W | `0x0000003F` | `1` = Output (untuk LED), `0` = Input. |
