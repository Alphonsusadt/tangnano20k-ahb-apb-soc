# Batch build for the Tang Nano 20K. Run from fpga/build/:
#   gw_sh ../build.tcl
set_device GW2AR-LV18QN88C8/I7 -device_version C

add_file ../../rtl/fpga/fpga_top.sv
add_file ../../rtl/fpga/ahb_selftest_master.sv
add_file ../../rtl/soc_top.sv
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

run all
