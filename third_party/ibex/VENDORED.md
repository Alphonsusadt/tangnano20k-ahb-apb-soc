# Vendored lowRISC Ibex

This folder holds the part of [lowRISC Ibex](https://github.com/lowRISC/ibex) that this project builds. It is third-party code, not original work from this repository.

- Source commit: `f4515520`
- License: Apache 2.0, see `LICENSE`
- Changes: none. Each file is an exact copy of the file at that commit.

Only `rtl/core/prim_clock_gating.sv`, outside this folder, replaces an Ibex primitive for the FPGA.

## Files

- `rtl/ibex_alu.sv`
- `rtl/ibex_branch_predict.sv`
- `rtl/ibex_cheriot_ex.sv`
- `rtl/ibex_cheriot_pkg.sv`
- `rtl/ibex_compressed_decoder.sv`
- `rtl/ibex_controller.sv`
- `rtl/ibex_core.sv`
- `rtl/ibex_counter.sv`
- `rtl/ibex_cs_registers.sv`
- `rtl/ibex_csr.sv`
- `rtl/ibex_decoder.sv`
- `rtl/ibex_dummy_instr.sv`
- `rtl/ibex_ex_block.sv`
- `rtl/ibex_fetch_fifo.sv`
- `rtl/ibex_icache.sv`
- `rtl/ibex_id_stage.sv`
- `rtl/ibex_if_stage.sv`
- `rtl/ibex_load_store_unit.sv`
- `rtl/ibex_lockstep.sv`
- `rtl/ibex_multdiv_fast.sv`
- `rtl/ibex_multdiv_slow.sv`
- `rtl/ibex_pkg.sv`
- `rtl/ibex_pmp.sv`
- `rtl/ibex_prefetch_buffer.sv`
- `rtl/ibex_register_file_ff.sv`
- `rtl/ibex_top.sv`
- `rtl/ibex_wb_stage.sv`
- `vendor/lowrisc_ip/dv/sv/dv_utils/dv_fcov_macros.svh`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_assert.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_assert_dummy_macros.svh`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_assert_sec_cm.svh`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_assert_standard_macros.svh`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_assert_yosys_macros.svh`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_cipher_pkg.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_count.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_count_pkg.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_flop_macros.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_lfsr.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_mubi_pkg.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_dec.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_enc.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_64_57_dec.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_64_57_enc.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_secded_pkg.sv`
- `vendor/lowrisc_ip/ip/prim/rtl/prim_util_pkg.sv`
- `vendor/lowrisc_ip/ip/prim_generic/rtl/prim_buf.sv`
- `vendor/lowrisc_ip/ip/prim_generic/rtl/prim_flop.sv`
- `vendor/lowrisc_ip/ip/prim_generic/rtl/prim_ram_1p_pkg.sv`
