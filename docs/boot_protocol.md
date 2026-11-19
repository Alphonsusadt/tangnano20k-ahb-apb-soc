# Protokol Bootloader UART (DRAF, belum disetujui)

Status: draf untuk keputusan K6. Belum ada kode yang mengikuti dokumen ini.

## Tujuan

ROM berisi bootloader kecil. Program aplikasi dikirim dari PC lewat USB-UART Tang Nano (115200 baud, 8-N-1), ditulis ke SRAM `0x2000_0000`, diperiksa CRC-nya, lalu dijalankan. Tidak perlu sintesis ulang untuk mengganti program.

## Masuk ke mode bootloader

- **Tombol S2 ditahan saat reset dilepas:** bootloader mencetak `BOOT\r\n`, lalu menunggu image tanpa batas waktu.
- **S2 tidak ditekan:** firmware bawaan di ROM langsung berjalan, sama seperti sekarang (`IBEX PASS`, echo, LED). Tidak ada jeda tambahan saat boot normal, dan tes simulasi yang ada tidak berubah.

Di board: tahan S2, tekan dan lepas S1, lepas S2, lalu jalankan program pengirim.

## Format pengiriman

Semua angka 32 bit little-endian.

| Urutan | Panjang | Isi |
| :--- | :--- | :--- |
| 1 | 4 | Magic `0x544F4F42` (byte ASCII `B`,`O`,`O`,`T`) |
| 2 | 4 | Alamat muat. Harus `0x2000_0000` sampai `0x2000_6FFC`, rata 4 |
| 3 | 4 | Panjang payload dalam byte, kelipatan 4, lebih dari 0, dan `alamat + panjang <= 0x2000_7000` |
| 4 | 4 | Alamat entry, harus di dalam rentang yang dimuat |
| 5 | panjang | Payload (isi `app.bin`) |
| 6 | 4 | CRC-32 payload (IEEE 802.3, sama dengan `zlib.crc32` di Python) |

## Balasan bootloader

| Saat | Balasan | Arti |
| :--- | :--- | :--- |
| Setelah header | `A` | Header diterima, kirim payload |
| Setelah header | `E` + 1 byte kode | Header ditolak: `1` magic salah, `2` alamat/panjang di luar rentang, `3` entry di luar rentang |
| Setelah CRC | `K` | CRC cocok. Bootloader mematikan interrupt, menjalankan `fence.i`, lalu melompat ke entry |
| Setelah CRC | `C` | CRC salah. Payload dibuang, bootloader kembali menunggu magic |
| Kapan saja | `T` | Jeda antar byte lebih dari 100 ms. Bootloader kembali menunggu magic |

Byte sebelum magic yang benar diabaikan, jadi sisa karakter di terminal tidak mengganggu.

## Kenapa tanpa FIFO tetap aman

UART hanya menampung satu byte. Pada 115200 baud, satu byte datang setiap sekitar 87 µs, atau 2343 siklus clock 27 MHz. Bootloader membaca byte, menulisnya ke SRAM, dan memperbarui CRC per byte (sekitar 100 siklus) jauh sebelum byte berikutnya selesai, jadi `RX_OVERFLOW` tidak terjadi. Bootloader tetap memeriksa `RX_OVERFLOW` dan menganggapnya CRC salah.

## Perkiraan waktu muat

Sekitar 11,5 KB per detik, jadi image 28 KB penuh butuh sekitar 2,5 detik.

## Pertanyaan untuk diputuskan (K6)

1. Pemicu S2 saat reset, atau jeda menunggu magic di setiap boot?
2. Apakah loader hardware (F6) memakai protokol yang sama? Usulan: **tidak**. Loader hardware adalah jalur debug dengan perintah baca/tulis word dan tahan/lepas CPU, jadi formatnya berbeda dan dirancang di F6.1.
