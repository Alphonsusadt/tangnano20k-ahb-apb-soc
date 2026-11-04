# Peta Memori & Arsitektur Register (SoC Memory Map)

Dokumen ini mendefinisikan pemetaan memori sistem (System Memory Map) dan spesifikasi register untuk periferal pada arsitektur SoC berbasis **lowRISC Ibex** (RV32IMC) pada FPGA Tang Nano 20K. Dokumen ini mengikuti perilaku RTL di `rtl/`.

---

## 1. Ikhtisar Alamat Global (System Address Map)

Sistem menggunakan bus **AHB-Lite 32-bit** sebagai interkoneksi utama untuk CPU, ROM, dan SRAM, serta **AHB-to-APB Bridge** untuk periferal berkecepatan rendah.

| Base Address | End Address | Ukuran | Bus | Modul / Fungsi | Akses |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `0x0000_0000` | `0x0000_7FFF` | 32 KB | AHB | **Instruction ROM (image firmware)**. Vektor trap di `0x00`, reset Ibex di `0x80` | R / X |
| `0x2000_0000` | `0x2000_7FFF` | 32 KB | AHB | **Data SRAM (data dan stack)** | R / W |
| `0x4000_0000` | `0x4000_0FFF` | 4 KB | APB | **APB UART Controller** | R / W |
| `0x4000_1000` | `0x4000_1FFF` | 4 KB | APB | **APB SPI Master Controller** | R / W |
| `0x4000_2000` | `0x4000_2FFF` | 4 KB | APB | **APB GPIO (LED & tombol)** | R / W |
| `0x4000_3000` | `0x4FFF_FFFF` | - | APB | *Reserved / Ekstensi Masa Depan* | - |

Transfer ke alamat di luar tabel ini dijawab oleh default slave di `ahb_interconnect` dengan `ERROR` dua siklus. Rentang *Reserved* dijawab `ERROR` oleh AHB-to-APB bridge.

Tulis ke ROM tidak mengubah isinya dan dijawab `ERROR` dua siklus, untuk semua ukuran transfer. CPU menerimanya sebagai store fault.

Offset di dalam blok 4 KB periferal yang melewati daftar registernya dijawab `PSLVERR`, yang diteruskan bridge sebagai `ERROR`, dan tidak menyentuh register apa pun.

Tulis ke register yang hanya bisa dibaca (RO) diabaikan dan dijawab `OKAY`.

Tulis byte dan halfword ke register APB mengikuti `PSTRB`: satu byte register hanya berubah kalau strobe-nya aktif. `UART_DATA` dan `SPI_TXDATA` hanya memulai pengiriman kalau `PSTRB[0]` aktif. Transfer APB yang tidak sejajar (misaligned) dijawab `ERROR` oleh bridge.

Periferal tidak memiliki FIFO. UART dan SPI masing-masing hanya menampung satu byte.

Sinyal interrupt `uart_irq` ada di `apb_uart`, tetapi belum tersambung ke CPU.

---

## 2. Register Periferal APB UART (`0x4000_0000`)

Modul APB UART menyediakan komunikasi serial asinkron dengan format tetap 8-N-1 ke chip antarmuka USB host BL616 pada Tang Nano 20K.

### Ringkasan Register UART
| Offset | Nama Register | Akses | Reset Value | Deskripsi |
| :--- | :--- | :--- | :--- | :--- |
| `0x00` | `UART_DATA` | R/W | `0x00000000` | Write: byte yang dikirim (TX). Read: byte terakhir yang diterima (RX). |
| `0x04` | `UART_STATUS` | RO | `0x00000002` | Status TX dan RX. |
| `0x08` | `UART_CTRL` | R/W | `0x00000003` | Kontrol enable TX/RX dan interrupt. |
| `0x0C` | `UART_BAUD` | R/W | `0x000000EA` | Jumlah clock per bit dikurangi satu: `Baud = F_CLK / (UART_BAUD + 1)`. |

Dengan nilai reset 234 dan clock 27 MHz, satu bit berlangsung 235 clock, yaitu sekitar 114.894 baud (0,27% di bawah 115.200).

### Perilaku `UART_DATA` (`0x00`)
- Tulis saat `TX_EMPTY` = `0` atau `TX_EN` = `0` tidak mengirim byte tersebut, jadi periksa `TX_EMPTY` lebih dulu.
- Baca mengembalikan byte terakhir dan menghapus `RX_VALID` serta `RX_OVERFLOW`.
- Byte dengan stop bit yang salah (framing error) dibuang tanpa flag.

### Deskripsi Bit `UART_STATUS` (`0x04`)
- **Bit [0]** (`RX_VALID`): `1` jika ada byte diterima yang belum dibaca.
- **Bit [1]** (`TX_EMPTY`): `1` jika transmitter idle dan siap menerima byte berikutnya.
- **Bit [2]** (`TX_FULL`): `1` jika transmitter sedang mengirim. Selalu kebalikan dari `TX_EMPTY`.
- **Bit [3]** (`RX_OVERFLOW`): `1` jika byte baru menimpa byte yang belum dibaca.

### Deskripsi Bit `UART_CTRL` (`0x08`)
- **Bit [0]** (`TX_EN`): `1` = Aktifkan transmitter UART.
- **Bit [1]** (`RX_EN`): `1` = Aktifkan receiver UART.
- **Bit [2]** (`TX_IRQ_EN`): `1` = `uart_irq` aktif saat TX kosong. Belum tersambung ke CPU.
- **Bit [3]** (`RX_IRQ_EN`): `1` = `uart_irq` aktif saat `RX_VALID` = `1`. Belum tersambung ke CPU.

---

## 3. Register Periferal APB SPI Master (`0x4000_1000`)

Modul APB SPI Master digunakan untuk mengontrol perangkat SPI eksternal (Flash, OLED, Sensor, dll.).

### Ringkasan Register SPI
| Offset | Nama Register | Akses | Reset Value | Deskripsi |
| :--- | :--- | :--- | :--- | :--- |
| `0x00` | `SPI_CR` | R/W | `0x00000000` | SPI Control Register (Enable, Mode, Clock Divider). |
| `0x04` | `SPI_SR` | RO | `0x00000012` | SPI Status Register. |
| `0x08` | `SPI_TXDATA`| R/W | `0x00000000` | Write: byte yang dikirim, dan memulai transfer. Read: byte terakhir yang ditulis. |
| `0x0C` | `SPI_RXDATA`| RO | `0x00000000` | Byte yang diterima pada transfer terakhir. Valid setelah `BUSY` kembali `0`. |
| `0x10` | `SPI_CS` | R/W | `0x000000FF` | Chip Select Control (Active-LOW per bit). |

Tulis ke `SPI_TXDATA` saat `SPI_EN` = `0` atau `BUSY` = `1` tidak memulai transfer, jadi tunggu `BUSY` = `0` lebih dulu.

### Deskripsi Bit `SPI_CR` (`0x00`)
- **Bit [0]** (`SPI_EN`): `1` = Aktifkan modul SPI Master, `0` = Disable.
- **Bit [1]** (`CPHA`): Clock Phase (`0` = Sampel pada edge pertama, `1` = Sampel pada edge kedua).
- **Bit [2]** (`CPOL`): Clock Polarity (`0` = SCK idle low, `1` = SCK idle high).
- **Bit [3]** (`LSB_FIRST`): `0` = Transmisi MSB first (standar), `1` = LSB first.
- **Bit [11:4]** (`CLK_DIV`): Nilai pembagi clock SPI: `F_SCK = F_SYS / (2 * (CLK_DIV + 1))`.
- **Bit [12]** (`AUTO_CS`): `1` = Selama `BUSY`, `spi_cs_n` dipaksa `0xFE` (hanya CS0 aktif) dan mengabaikan `SPI_CS`. `0` = Kontrol manual lewat `SPI_CS`.

### Deskripsi Bit `SPI_SR` (`0x04`)
- **Bit [0]** (`BUSY`): `1` = Transfer sedang berjalan. Pakai bit ini untuk menunggu transfer selesai.
- **Bit [1]** (`TX_EMPTY`): Kebalikan dari `BUSY`.
- **Bit [2]** (`TX_FULL`): Sama dengan `BUSY`.
- **Bit [3]** (`RX_EMPTY`): Selalu `0`. Tidak membawa informasi.
- **Bit [4]** (`RX_FULL`): Selalu `1`. Tidak membawa informasi.

### Deskripsi Bit `SPI_CS` (`0x10`)
- **Bit [7:0]** (`CS_N`): Bitmask kontrol pin Chip Select (Active Low).
  - Bit 0 = 0 -> Pin `spi_cs_n[0]` ditarik LOW (device aktif).
  - Bit 0 = 1 -> Pin `spi_cs_n[0]` ditarik HIGH (device idle).

`soc_top` memiliki 8 jalur CS, tetapi di board hanya CS0 yang tersambung ke pin.

---

## 4. Register Periferal APB GPIO (`0x4000_2000`)

Mengontrol LED onboard Tang Nano 20K dan membaca tombol.

| Offset | Nama Register | Akses | Reset Value | Deskripsi |
| :--- | :--- | :--- | :--- | :--- |
| `0x00` | `GPIO_OUT` | R/W | `0x0000003F` | Bit [5:0] mengontrol status 6 LED onboard (Active Low). |
| `0x04` | `GPIO_IN` | RO | `0x00000001` | Bit [1]: tombol S2 (PIN 87), `1` = ditekan. Bit [0]: reset internal, selalu `1` saat SoC berjalan, karena S1 (PIN 88) dipakai sebagai reset. |
| `0x08` | `GPIO_DIR` | R/W | `0x0000003F` | Register penyimpan saja. Nilainya bisa dibaca kembali, tetapi tidak memengaruhi pin LED, yang selalu berupa output. |
