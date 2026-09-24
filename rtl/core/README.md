# lowRISC Ibex Core Integration

Direktori ini diperuntukkan bagi sumber RTL core **lowRISC Ibex** (RISC-V 32-bit RV32IMC).

## Cara Menambahkan lowRISC Ibex

Anda dapat menambahkan repositori resmi lowRISC Ibex melalui git submodule:

```bash
git submodule add https://github.com/lowRISC/ibex.git rtl/core/ibex
```

Atau menggunakan vendoring script / generator fusesoc:
```bash
fusesoc --cores-root=. run --target=synth lowrisc:ibex:top_artya7
```

## Parameter Rekomendasi untuk Tang Nano 20K
- **RV32M**: `ibex_pkg::RV32MFast` atau `RV32MSlow` (menghemat LUT)
- **RV32B**: `ibex_pkg::RV32BNone`
- **BranchTargetALU**: `1'b1`
- **MultiplierImplementation**: `ibex_pkg::MultiplierFast`
- **ICache**: Opsional (Direct-mapped atau 2-way)
