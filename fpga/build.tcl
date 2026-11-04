# Batch build for the Tang Nano 20K. Run from fpga/build/, after building sw/firmware.hex:
#   gw_sh ../build.tcl
# Check the log for warning EX3988, which means the ROM image was not found.
set ibex ../../third_party/ibex ;# lowRISC Ibex at commit f4515520

set_device GW2AR-LV18QN88C8/I7 -device_version C

add_file ../../rtl/fpga/synthesis_defines.sv
add_file $ibex/rtl/ibex_pkg.sv
add_file $ibex/rtl/ibex_cheriot_pkg.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_util_pkg.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_pkg.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_mubi_pkg.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_cipher_pkg.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_count_pkg.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_ram_1p_pkg.sv
add_file $ibex/rtl/ibex_top.sv
add_file $ibex/rtl/ibex_core.sv
add_file $ibex/rtl/ibex_alu.sv
add_file $ibex/rtl/ibex_branch_predict.sv
add_file $ibex/rtl/ibex_cheriot_ex.sv
add_file $ibex/rtl/ibex_compressed_decoder.sv
add_file $ibex/rtl/ibex_controller.sv
add_file $ibex/rtl/ibex_counter.sv
add_file $ibex/rtl/ibex_cs_registers.sv
add_file $ibex/rtl/ibex_csr.sv
add_file $ibex/rtl/ibex_decoder.sv
add_file $ibex/rtl/ibex_dummy_instr.sv
add_file $ibex/rtl/ibex_ex_block.sv
add_file $ibex/rtl/ibex_fetch_fifo.sv
add_file $ibex/rtl/ibex_icache.sv
add_file $ibex/rtl/ibex_id_stage.sv
add_file $ibex/rtl/ibex_if_stage.sv
add_file $ibex/rtl/ibex_lockstep.sv
add_file $ibex/rtl/ibex_load_store_unit.sv
add_file $ibex/rtl/ibex_multdiv_fast.sv
add_file $ibex/rtl/ibex_multdiv_slow.sv
add_file $ibex/rtl/ibex_pmp.sv
add_file $ibex/rtl/ibex_prefetch_buffer.sv
add_file $ibex/rtl/ibex_register_file_ff.sv
add_file $ibex/rtl/ibex_wb_stage.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_enc.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_dec.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_64_57_enc.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_64_57_dec.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_lfsr.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_count.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_buf.sv
add_file $ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_flop.sv

add_file ../../rtl/core/prim_clock_gating.sv
add_file ../../rtl/core/ibex_ahb_cpu.sv
add_file ../../rtl/fpga/fpga_top.sv
add_file ../../rtl/fpga/ahb_selftest_master.sv
add_file ../../rtl/soc_top.sv
add_file ../../rtl/interconnect/obi_to_ahb_adapter.sv
add_file ../../rtl/interconnect/ahb_interconnect.sv
add_file ../../rtl/interconnect/ahb_to_apb_bridge.sv
add_file ../../rtl/memory/ahb_sram.sv
add_file ../../rtl/peripherals/apb_uart.v
add_file ../../rtl/peripherals/apb_spi.v
add_file ../../rtl/peripherals/apb_gpio.v
add_file ../tangnano20k.cst
add_file ../tangnano20k.sdc

set_option -output_base_name tangnano20k_soc
set_option -top_module fpga_top
set_option -verilog_std sysv2017
set_option -include_path "$ibex/vendor/lowrisc_ip/ip/prim/rtl;$ibex/rtl;$ibex/vendor/lowrisc_ip/dv/sv/dv_utils"

run all
