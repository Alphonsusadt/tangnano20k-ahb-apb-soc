# Batch build of the SPI demo image. Run from fpga/build/, after building the firmware:
#   make -C sw firmware_spi_demo.hex NAME=firmware_spi_demo CFLAGS_EXTRA=-DSPI_DEMO
#   gw_sh ../build_spi_demo.tcl
# The bitstream is impl/pnr/tangnano20k_spi_demo.fs.
set spi_demo 1
source ../build.tcl
