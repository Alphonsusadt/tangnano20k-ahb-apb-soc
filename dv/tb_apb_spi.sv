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
    // SPI Protocol Monitor
    // Acts as an independent slave: captures MOSI on the sampling edge defined
    // by CPHA, so a transmit bug cannot be hidden by the master's own RX path.
    // --------------------------------------------------------------------------
    logic       monitor_en = 1'b0;
    logic       mon_cpha   = 1'b0;
    logic       mon_lsb    = 1'b0;
    logic [7:0] slave_rx   = 8'h00;
    integer     edge_count = 0;
    integer     cs_errors  = 0;
    integer     checks     = 0;
    integer     failures   = 0;

    always @(spi_sck) begin
        if (monitor_en) begin
            edge_count = edge_count + 1;
            if (spi_cs_n[0] !== 1'b0) cs_errors = cs_errors + 1;
            // CPHA=0 samples on odd edges (leading), CPHA=1 on even (trailing)
            if ((edge_count % 2 == 1) != mon_cpha) begin
                slave_rx = mon_lsb ? {spi_mosi, slave_rx[7:1]}
                                   : {slave_rx[6:0], spi_mosi};
            end
        end
    end

    task automatic check(input logic ok, input string what);
        checks = checks + 1;
        if (ok !== 1'b1) begin
            failures = failures + 1;
            $display("FAIL: %s", what);
        end
    endtask

    // Runs one auto-CS transfer and checks both directions of the bus.
    task automatic run_transfer(input logic cpol, input logic cpha,
                                input logic lsb, input logic [7:0] tx);
        logic [31:0] status;
        logic [31:0] rx;
        logic [31:0] cr;
        string       tag;

        cr = 32'h1 | (32'(cpha) << 1) | (32'(cpol) << 2) | (32'(lsb) << 3)
                   | (32'd4 << 4) | (32'd1 << 12);
        tag = $sformatf("CPOL=%0d CPHA=%0d LSB=%0d TX=%02h", cpol, cpha, lsb, tx);

        apb_write(ADDR_SPI_CR, cr);
        repeat (3) @(posedge pclk);
        check(spi_sck === cpol, {tag, ": SCK idle level before transfer"});

        mon_cpha   = cpha;
        mon_lsb    = lsb;
        slave_rx   = 8'h00;
        edge_count = 0;
        cs_errors  = 0;
        monitor_en = 1'b1;

        apb_write(ADDR_SPI_TXDATA, {24'h0, tx});
        status = 32'h1;
        while (status[0] == 1'b1) begin
            #50;
            apb_read(ADDR_SPI_SR, status);
        end
        monitor_en = 1'b0;
        apb_read(ADDR_SPI_RXDATA, rx);

        check(edge_count == 16,
              $sformatf("%s: expected 16 SCK edges, got %0d", tag, edge_count));
        check(slave_rx === tx,
              $sformatf("%s: slave expected %02h, got %02h", tag, tx, slave_rx));
        check(rx[7:0] === ~tx,
              $sformatf("%s: master expected %02h, got %02h", tag, ~tx, rx[7:0]));
        check(cs_errors == 0,
              $sformatf("%s: CS high on %0d SCK edges", tag, cs_errors));
        check(spi_sck === cpol, {tag, ": SCK idle level after transfer"});
    endtask

    // --------------------------------------------------------------------------
    // Main Test Stimulus
    // Sequence: reset -> read status -> configure mode 0 -> write TXDATA
    // -> poll BUSY until clear -> read and check RXDATA -> repeat.
    // Inverted loopback means RX must equal the bitwise complement of TX.
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
        if (read_val[7:0] !== 8'h5A) begin
            $fatal(1, "FAIL: TX=A5, expected RX=5A, actual RX=%02h",
                   read_val[7:0]);
        end
        $display("PASS: TX=A5, RX=5A");

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
        if (read_val[7:0] !== 8'hC3) begin
            $fatal(1, "FAIL: TX=3C, expected RX=C3, actual RX=%02h",
                   read_val[7:0]);
        end
        $display("PASS: TX=3C, RX=C3");

        // 7. All SPI modes, both bit orders. The byte set matters: 0xA5 alone
        //    hides a lost final RX bit because ~0xA5 has a zero MSB.
        for (int mode = 0; mode < 4; mode++) begin
            for (int order = 0; order < 2; order++) begin
                run_transfer(mode[1], mode[0], order[0], 8'hA5);
                run_transfer(mode[1], mode[0], order[0], 8'h3C);
                run_transfer(mode[1], mode[0], order[0], 8'h81);
                run_transfer(mode[1], mode[0], order[0], 8'h00);
            end
        end

        #500;
        $display("--------------------------------------------------");
        $display("RESULT: %0d checks, %0d failures", checks, failures);
        if (failures != 0) begin
            $fatal(1, "[TB_APB_SPI] SPI verification failed");
        end
        $display("[TB_APB_SPI] All tests PASSED successfully!");
        $display("--------------------------------------------------");
        $finish;
    end

    // Simulation watchdog timeout
    initial begin
        #500000;
        $fatal(1, "[TB_APB_SPI] ERROR: Simulation Timeout!");
    end

endmodule
