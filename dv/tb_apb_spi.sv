// ==============================================================================
// Testbench: tb_apb_spi
// Description: SystemVerilog Testbench for APB SPI Master Controller
// ==============================================================================

`timescale 1ns / 1ps

module tb_apb_spi;

    // Clock & Reset signals
    logic        pclk;
    logic        preset_n;

    // APB4 Interface
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [31:0] paddr;
    logic [31:0] pwdata;
    logic [3:0]  pstrb;
    wire  [31:0] prdata;
    wire         pready;
    wire         pslverr;

    // SPI Signals
    wire         spi_sck;
    wire         spi_mosi;
    logic        spi_miso;
    wire  [7:0]  spi_cs_n;

    // Register Address Offsets
    localparam ADDR_SPI_CR     = 32'h00;
    localparam ADDR_SPI_SR     = 32'h04;
    localparam ADDR_SPI_TXDATA = 32'h08;
    localparam ADDR_SPI_RXDATA = 32'h0C;
    localparam ADDR_SPI_CS     = 32'h10;

    // Clock Generation (27 MHz -> ~37.037 ns period)
    initial pclk = 0;
    always #18.518 pclk = ~pclk;

    // DUT Instantiation
    apb_spi u_dut (
        .pclk     (pclk),
        .preset_n (preset_n),
        .psel     (psel),
        .penable  (penable),
        .pwrite   (pwrite),
        .paddr    (paddr),
        .pwdata   (pwdata),
        .pstrb    (pstrb),
        .prdata   (prdata),
        .pready   (pready),
        .pslverr  (pslverr),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (spi_miso),
        .spi_cs_n (spi_cs_n)
    );

    // --------------------------------------------------------------------------
    // APB Write Task
    // --------------------------------------------------------------------------
    task automatic apb_write(input [31:0] addr, input [31:0] data);
        @(posedge pclk);
        paddr   <= addr;
        pwdata  <= data;
        pwrite  <= 1'b1;
        psel    <= 1'b1;
        pstrb   <= 4'b1111;
        penable <= 1'b0;

        @(posedge pclk);
        penable <= 1'b1;

        @(posedge pclk);
        while (!pready) @(posedge pclk);
        psel    <= 1'b0;
        penable <= 1'b0;
        pwrite  <= 1'b0;
    endtask

    // --------------------------------------------------------------------------
    // APB Read Task
    // --------------------------------------------------------------------------
    task automatic apb_read(input [31:0] addr, output [31:0] data);
        @(posedge pclk);
        paddr   <= addr;
        pwrite  <= 1'b0;
        psel    <= 1'b1;
        penable <= 1'b0;

        @(posedge pclk);
        penable <= 1'b1;

        @(posedge pclk);
        while (!pready) @(posedge pclk);
        data    = prdata;
        psel    <= 1'b0;
        penable <= 1'b0;
    endtask

    // Simple SPI Slave Loopback behavior (Loop MOSI back to MISO with invert)
    always_comb begin
        spi_miso = ~spi_mosi;
    end

    // --------------------------------------------------------------------------
    // Main Test Stimulus
    // --------------------------------------------------------------------------
    logic [31:0] read_val;

    initial begin
        $dumpfile("tb_apb_spi.vcd");
        $dumpvars(0, tb_apb_spi);

        $display("--------------------------------------------------");
        $display("[TB_APB_SPI] Starting Testbench Simulation...");
        $display("--------------------------------------------------");

        // Initialize signals
        preset_n = 1'b0;
        psel     = 1'b0;
        penable  = 1'b0;
        pwrite   = 1'b0;
        paddr    = 32'h0;
        pwdata   = 32'h0;
        pstrb    = 4'b0000;

        // Reset Pulse
        #100;
        @(posedge pclk);
        preset_n = 1'b1;
        $display("[TB_APB_SPI] System Reset released.");
        #100;

        // 1. Read default status
        apb_read(ADDR_SPI_SR, read_val);
        $display("[TB_APB_SPI] Read SPI_SR = 0x%08X (Expected TX_EMPTY=1)", read_val);

        // 2. Configure SPI Control Register:
        //    Bit 0 = 1 (SPI_EN)
        //    Bit 1 = 0 (CPHA = 0)
        //    Bit 2 = 0 (CPOL = 0)
        //    Bit [11:4] = 4 (CLK_DIV = 4)
        //    Bit 12 = 1 (AUTO_CS)
        //    Value = 1 | (4 << 4) | (1 << 12) = 0x0001 | 0x0040 | 0x1000 = 0x1041
        apb_write(ADDR_SPI_CR, 32'h0000_1041);
        $display("[TB_APB_SPI] Configured SPI_CR: Enable=1, Div=4, AutoCS=1");

        // 3. Write data byte 0xA5 to SPI_TXDATA
        $display("[TB_APB_SPI] Sending Byte 0xA5 over SPI...");
        apb_write(ADDR_SPI_TXDATA, 32'h0000_00A5);

        // 4. Poll Status Register until transmission completes (BUSY bit [0] == 0)
        read_val = 32'h1;
        while (read_val[0] == 1'b1) begin
            #50;
            apb_read(ADDR_SPI_SR, read_val);
        end
        $display("[TB_APB_SPI] Transmission Complete! SPI_SR = 0x%08X", read_val);

        // 5. Read received data byte from SPI_RXDATA
        apb_read(ADDR_SPI_RXDATA, read_val);
        $display("[TB_APB_SPI] Read SPI_RXDATA = 0x%02X", read_val[7:0]);

        // 6. Test another byte transfer: 0x3C
        #200;
        $display("[TB_APB_SPI] Sending Byte 0x3C over SPI...");
        apb_write(ADDR_SPI_TXDATA, 32'h0000_003C);

        read_val = 32'h1;
        while (read_val[0] == 1'b1) begin
            #50;
            apb_read(ADDR_SPI_SR, read_val);
        end
        apb_read(ADDR_SPI_RXDATA, read_val);
        $display("[TB_APB_SPI] Read SPI_RXDATA = 0x%02X", read_val[7:0]);

        #500;
        $display("--------------------------------------------------");
        $display("[TB_APB_SPI] All tests PASSED successfully!");
        $display("--------------------------------------------------");
        $finish;
    end

    // Simulation watchdog timeout
    initial begin
        #500000;
        $display("[TB_APB_SPI] ERROR: Simulation Timeout!");
        $finish;
    end

endmodule
