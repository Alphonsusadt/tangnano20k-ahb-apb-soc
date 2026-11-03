// ==============================================================================
// Module: fpga_top
// Description: Tang Nano 20K board wrapper around soc_top, with the self-test
//              master standing in for the CPU.
//
// Buttons S1 and S2 are active high on this board: each connects 3V3 to a net with
// a 1 k pull-down, so an unpressed button reads 0 (schematic rev 3921).
// ==============================================================================

module fpga_top #(
    // Gowin resolves this path from the project folder, fpga/build/. A wrong path is
    // only a warning (EX3988) and leaves the ROM empty, so check the build log.
    parameter BOOT_HEX_FILE = "../selftest_rom.hex",
    parameter POR_BITS      = 16, // Power-on reset lasts 2^POR_BITS cycles
    parameter HEARTBEAT_BIT = 23
)(
    input  wire       clk_27m,
    input  wire       btn_s1,   // Reset
    input  wire       btn_s2,

    output wire       uart_tx,
    input  wire       uart_rx,

    output wire       spi_sck,
    output wire       spi_mosi,
    input  wire       spi_miso,
    output wire       spi_cs_n, // Only CS0 has a pin

    output wire [5:0] led
);

    // The board has no dedicated reset pin, so a counter provides the first reset.
    reg [POR_BITS:0] por_cnt = {(POR_BITS + 1){1'b0}};
    wire             por_done = por_cnt[POR_BITS];

    always @(posedge clk_27m) begin
        if (!por_done) begin
            por_cnt <= por_cnt + 1'b1;
        end
    end

    // Assert reset asynchronously, release it synchronously.
    wire      reset_req_n = por_done && !btn_s1;
    reg [1:0] rst_sync = 2'b00;

    always @(posedge clk_27m or negedge reset_req_n) begin
        if (!reset_req_n) begin
            rst_sync <= 2'b00;
        end else begin
            rst_sync <= {rst_sync[0], 1'b1};
        end
    end

    // S2 is asynchronous to the bus clock.
    reg [1:0] s2_sync = 2'b00;

    always @(posedge clk_27m) begin
        s2_sync <= {s2_sync[0], btn_s2};
    end

    wire [7:0] spi_cs_n_all;
    assign spi_cs_n = spi_cs_n_all[0];

    soc_top #(
        .BOOT_HEX_FILE       (BOOT_HEX_FILE),
        .USE_SELFTEST_MASTER (1),
        .HEARTBEAT_BIT       (HEARTBEAT_BIT)
    ) u_soc (
        .clk_27m  (clk_27m),
        .rst_n    (rst_sync[1]),
        .btn_s2   (s2_sync[1]),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (spi_miso),
        .spi_cs_n (spi_cs_n_all),
        .led      (led)
    );

endmodule
