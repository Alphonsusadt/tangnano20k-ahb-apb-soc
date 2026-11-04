#!/usr/bin/env bash
# Builds the firmware and simulates Ibex in soc_top with Verilator.
# Run from the repository root on Linux or WSL:
#   bash dv/run_ibex_sim.sh
# Tested with Ibex f4515520, Verilator 5.024, and riscv64-unknown-elf-gcc 10.2.

set -euo pipefail

IBEX_DIR=third_party/ibex
OBJ_DIR="${OBJ_DIR:-/tmp/tangnano_ibex_obj}"
PATH="$HOME/.local/bin:$PATH"

PRIM="$IBEX_DIR/vendor/lowrisc_ip/ip/prim/rtl"
PRIM_GENERIC="$IBEX_DIR/vendor/lowrisc_ip/ip/prim_generic/rtl"

# The heartbeat is sped up so simulation can watch it. MISO is looped back in the
# testbench, so the firmware also checks the received SPI byte.
make -C sw clean NAME=firmware_sim > /dev/null
make -C sw firmware_sim.hex NAME=firmware_sim CFLAGS_EXTRA="-DHEARTBEAT_BIT=12 -DSPI_LOOPBACK"
make -C sw clean NAME=firmware_trap > /dev/null
make -C sw firmware_trap.hex NAME=firmware_trap CFLAGS_EXTRA="-DFORCE_MISALIGNED_STORE"
make -C sw clean NAME=firmware_rom_fault > /dev/null
make -C sw firmware_rom_fault.hex NAME=firmware_rom_fault CFLAGS_EXTRA="-DFORCE_ROM_STORE"
make -C sw clean NAME=firmware_spi_demo > /dev/null
make -C sw firmware_spi_demo.hex NAME=firmware_spi_demo CFLAGS_EXTRA="-DSPI_DEMO"
make -C sw clean NAME=firmware_unmapped > /dev/null
make -C sw firmware_unmapped.hex NAME=firmware_unmapped CFLAGS_EXTRA="-DFORCE_UNMAPPED_STORE"

SOURCES=(
    "$IBEX_DIR/rtl/ibex_pkg.sv"
    "$IBEX_DIR/rtl/ibex_cheriot_pkg.sv"
    "$PRIM/prim_util_pkg.sv"
    "$PRIM/prim_secded_pkg.sv"
    "$PRIM/prim_mubi_pkg.sv"
    "$PRIM/prim_cipher_pkg.sv"
    "$PRIM/prim_count_pkg.sv"
    "$PRIM_GENERIC/prim_ram_1p_pkg.sv"
    "$IBEX_DIR/rtl/ibex_top.sv"
    "$IBEX_DIR/rtl/ibex_core.sv"
    "$IBEX_DIR/rtl/ibex_alu.sv"
    "$IBEX_DIR/rtl/ibex_branch_predict.sv"
    "$IBEX_DIR/rtl/ibex_cheriot_ex.sv"
    "$IBEX_DIR/rtl/ibex_compressed_decoder.sv"
    "$IBEX_DIR/rtl/ibex_controller.sv"
    "$IBEX_DIR/rtl/ibex_counter.sv"
    "$IBEX_DIR/rtl/ibex_cs_registers.sv"
    "$IBEX_DIR/rtl/ibex_csr.sv"
    "$IBEX_DIR/rtl/ibex_decoder.sv"
    "$IBEX_DIR/rtl/ibex_dummy_instr.sv"
    "$IBEX_DIR/rtl/ibex_ex_block.sv"
    "$IBEX_DIR/rtl/ibex_fetch_fifo.sv"
    "$IBEX_DIR/rtl/ibex_icache.sv"
    "$IBEX_DIR/rtl/ibex_id_stage.sv"
    "$IBEX_DIR/rtl/ibex_if_stage.sv"
    "$IBEX_DIR/rtl/ibex_load_store_unit.sv"
    "$IBEX_DIR/rtl/ibex_multdiv_fast.sv"
    "$IBEX_DIR/rtl/ibex_multdiv_slow.sv"
    "$IBEX_DIR/rtl/ibex_pmp.sv"
    "$IBEX_DIR/rtl/ibex_prefetch_buffer.sv"
    "$IBEX_DIR/rtl/ibex_register_file_ff.sv"
    "$IBEX_DIR/rtl/ibex_wb_stage.sv"
    "$PRIM/prim_secded_inv_39_32_enc.sv"
    "$PRIM/prim_secded_inv_39_32_dec.sv"
    "$PRIM/prim_secded_inv_64_57_enc.sv"
    "$PRIM/prim_secded_inv_64_57_dec.sv"
    "$PRIM_GENERIC/prim_buf.sv"
    "$PRIM_GENERIC/prim_flop.sv"
    rtl/core/prim_clock_gating.sv
    rtl/core/ibex_ahb_cpu.sv
    rtl/interconnect/obi_to_ahb_adapter.sv
    rtl/soc_top.sv
    rtl/memory/ahb_sram.sv
    rtl/interconnect/ahb_interconnect.sv
    rtl/interconnect/ahb_to_apb_bridge.sv
    rtl/peripherals/apb_gpio.v
    rtl/peripherals/apb_spi.v
    rtl/peripherals/apb_uart.v
    dv/sva/ahb_lite_checks.sv
    dv/sva/soc_top_checks_bind.sv
    dv/tb_soc_ibex.sv
)

# The .v peripherals use SystemVerilog, so the language is set for every file.
verilator --binary --timing --assert -j 0 -Wno-fatal -Wno-lint -Wno-style \
    --default-language 1800-2017 \
    --top-module tb_soc_ibex --Mdir "$OBJ_DIR" -o sim \
    "+incdir+$PRIM" "+incdir+$IBEX_DIR/rtl" \
    "+incdir+$IBEX_DIR/vendor/lowrisc_ip/dv/sv/dv_utils" \
    "${SOURCES[@]}" > "$OBJ_DIR.build.log" 2>&1 || {
        tail -30 "$OBJ_DIR.build.log"
        exit 1
    }

echo "--- Firmware run"
"$OBJ_DIR/sim"
echo "--- Misaligned store run"
"$OBJ_DIR/sim" +image=sw/firmware_trap.hex +expect_trap
echo "--- ROM store run"
"$OBJ_DIR/sim" +image=sw/firmware_rom_fault.hex +expect_rom_fault
echo "--- Unmapped store run"
"$OBJ_DIR/sim" +image=sw/firmware_unmapped.hex +expect_unmapped_fault
echo "--- SPI demo run, with a model of the external slave"
"$OBJ_DIR/sim" +image=sw/firmware_spi_demo.hex +spi_demo
