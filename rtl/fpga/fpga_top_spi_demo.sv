// ==============================================================================
// Module: fpga_top_spi_demo
// Description: fpga_top with the SPI demo firmware in its ROM. It adds no logic. Run
//              it with fpga/build_spi_demo.tcl.
// ==============================================================================

module fpga_top_spi_demo (
    input  wire       clk_27m,
    input  wire       btn_s1,
    input  wire       btn_s2,

    output wire       uart_tx,
    input  wire       uart_rx,

    output wire       spi_sck,
    output wire       spi_mosi,
    input  wire       spi_miso,
    output wire       spi_cs_n,

    output wire [5:0] led
);

    fpga_top #(
        .BOOT_HEX_FILE ("../../sw/firmware_spi_demo.hex")
    ) u_fpga_top (
        .clk_27m  (clk_27m),
        .btn_s1   (btn_s1),
        .btn_s2   (btn_s2),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (spi_miso),
        .spi_cs_n (spi_cs_n),
        .led      (led)
    );

endmodule
