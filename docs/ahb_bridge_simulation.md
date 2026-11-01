# Simulasi AHB-to-APB dengan Icarus Verilog

Testbench: `dv/tb_ahb_to_apb_bridge.sv`.
DUT: `rtl/interconnect/ahb_to_apb_bridge.sv`.

Jalankan dari direktori utama proyek menggunakan PowerShell:

```powershell
New-Item -ItemType Directory -Force work | Out-Null
iverilog -g2012 -Wall -s tb_ahb_to_apb_bridge -o work/ahb_bridge.vvp dv/tb_ahb_to_apb_bridge.sv rtl/interconnect/ahb_to_apb_bridge.sv
if ($LASTEXITCODE -ne 0) { throw 'Kompilasi gagal' }
vvp work/ahb_bridge.vvp
```

`iverilog` mengompilasi RTL dan testbench menjadi program simulasi `.vvp`;
`vvp` menjalankannya. Ini bukan proses mengubah testbench menjadi RTL atau
bitstream FPGA. Opsi `-g2012` mengaktifkan SystemVerilog dan `-s` memilih top
testbench agar modul lain tidak ikut menjadi top simulasi.

Untuk melihat waveform, jika GTKWave sudah terpasang:

```powershell
gtkwave tb_ahb_to_apb_bridge.vcd
```

Tambahkan sinyal `hclk`, `hreset_n`, `hsel`, `htrans`, `haddr`, `hwrite`,
`hwdata`, `hready`, `hrdata`, `paddr`, `pwrite`, `pwdata`, `penable`,
`psel_uart`, `psel_spi`, `psel_gpio`, dan `ready`.

## Cakupan regresi terbaru

- Reset awal; HTRANS IDLE/BUSY dan HSEL rendah diabaikan.
- Read/write word, byte pada keempat lane, dan halfword pada kedua posisi aligned,
  untuk UART, SPI, dan GPIO; termasuk byte terakhir setiap wilayah 4 KB.
- NONSEQ dan SEQ, serta transaksi berurutan tanpa reset. Alamat berikutnya
  diberikan pada siklus respons transaksi sebelumnya.
- PREADY rendah maupun tinggi saat SETUP; ACCESS dengan 0 sampai 3 wait-state.
- Monitor pada sampling edge memeriksa one-hot PSEL, SETUP sebelum ACCESS,
  dan kestabilan PADDR/PWRITE/PWDATA/PSTRB/PPROT/PSEL sejak SETUP hingga completion.
- Data tulis fase alamat sengaja salah; data yang benar baru muncul pada fase data.
  Alamat dan kontrol masukan diubah setelah diterima untuk memeriksa penyimpanan konteks.
- PRDATA hanya benar pada siklus completion, berbeda untuk setiap peripheral.
- Peripheral yang tidak dipilih selalu ready dan dapat memberikan error;
  responsnya tidak boleh menyelesaikan atau menggagalkan transaksi aktif.
- PSTRB sesuai ukuran dan lane write, serta nol pada read.
- PSLVERR read/write pada setiap peripheral menghasilkan dua siklus AHB ERROR:
  HRESP=1/HREADY=0, lalu HRESP=1/HREADY=1.
- Alamat di luar map, alias alamat dengan bit atas berbeda, ukuran lebih dari word,
  dan alamat tidak aligned menghasilkan ERROR tanpa transaksi APB.
- Reset asinkron saat DATA, SETUP, dan stalled ACCESS; transaksi dibatalkan,
  tidak ada completion tambahan, dan transaksi berikutnya berhasil.
- Jumlah completion APB dan latensi respons diperiksa; timeout lokal dan watchdog global.

## Perbaikan RTL

Alur sukses sekarang adalah IDLE -> DATA -> SETUP -> ACCESS -> RESPONSE.
DATA menangkap HWDATA satu siklus setelah alamat diterima. PSEL baru aktif pada
SETUP, sehingga PWDATA sudah stabil sebelum ACCESS. ACCESS menangkap PRDATA
serta PSLVERR hanya ketika peripheral yang dipilih siap. Respons sukses disimpan
satu siklus; respons error memakai ERROR1 dan ERROR2. RESPONSE/ERROR2 juga dapat
menerima alamat berikutnya pada edge penyelesaian AHB.

Decode menggunakan alamat penuh tiga wilayah 4 KB, bukan hanya bit [15:12].
Byte/halfword memakai lane AHB apa adanya: bridge tidak menggeser HWDATA/PRDATA;
PSTRB menentukan byte write yang aktif. Read memakai PSTRB=0. PPROT tetap nol
karena antarmuka bridge ini belum menyediakan HPROT.

## Hasil

Regresi terbaru: **1828 checks, 0 failures**, tanpa FAIL/FATAL, dengan pesan:

```text
PASS: AHB bridge directed tests
```

Log tersedia di `work/ahb_bridge.log` dan waveform di
`tb_ahb_to_apb_bridge.vcd`. Sebagai kontrol negatif, testbench baru dijalankan
terhadap RTL versi HEAD sebelum perubahan lokal: **1032 checks, 317 failures**
dan FATAL. Jumlah checks berbeda karena jalur waktu pada RTL lama berbeda.

Riwayat: testbench awal menghasilkan 87 checks/15 failures; perbaikan timing
pertama menghasilkan 87 checks/0 failures, tetapi belum memeriksa kestabilan
PWDATA dari SETUP ke ACCESS. Regresi terbaru menutup celah tersebut.

## Batas verifikasi

Ini directed regression untuk satu transaksi outstanding dengan clock AHB/APB
sama, bukan bukti formal atau coverage lengkap. Belum menguji address decoder
AHB eksternal, core Ibex, peripheral sebenarnya, maupun top-level SoC.
Antarmuka hanya memiliki keluaran HREADY (tidak ada masukan HREADY global);
sebelum integrasi dengan slave AHB lain, penerimaan alamat harus ditinjau agar
dikualifikasi oleh HREADY global. Testbench saat ini menggunakan kesiapan lokal
bridge dan tidak memodelkan stall dari slave AHB lain.

Referensi protokol: [Arm AMBA APB Protocol Specification](https://documentation-service.arm.com/static/63fe2c1356ea36189d4e79f3)
dan [Arm System-on-Chip Design Reference, Chapter 3](https://armkeil.blob.core.windows.net/developer/Files/pdf/ebook/system-on-chip-design-reference.pdf).
