// ==============================================================================
// Testbench: tb_soc_sram
// Description: Self-checking SRAM access through soc_top's real AHB fabric.
//              soc_top has no CPU yet, so this bench forces the undriven cpu_*
//              master signals and behaves as a pipelined AHB-Lite master.
// ==============================================================================

`timescale 1ns / 1ps

module tb_soc_sram;

    localparam [2:0] SIZE_BYTE = 3'b000;
    localparam [2:0] SIZE_HALF = 3'b001;
    localparam [2:0] SIZE_WORD = 3'b010;

    localparam [31:0] SRAM_BASE = 32'h2000_0000;
    localparam [31:0] GPIO_OUT  = 32'h4000_2000;
    localparam [31:0] GARBAGE   = 32'hDEAD_BEEF;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    wire       uart_tx;
    wire       spi_sck;
    wire       spi_mosi;
    wire [7:0] spi_cs_n;
    wire [5:0] led;

    // Master signals, forced onto the undriven cpu_* nets in soc_top.
    logic [31:0] haddr  = 32'h0;
    logic [1:0]  htrans = 2'b00;
    logic        hwrite = 1'b0;
    logic [2:0]  hsize  = SIZE_WORD;
    logic [31:0] hwdata = GARBAGE;

    wire         hready = u_dut.cpu_hready;
    wire [31:0]  hrdata = u_dut.cpu_hrdata;
    wire         hresp  = u_dut.cpu_hresp;

    logic        prev_write = 1'b0;
    logic [31:0] prev_wdata = GARBAGE;
    logic [31:0] last_rdata = 32'h0;

    integer checks = 0;
    integer failures = 0;

    always #18.518 clk = ~clk;

    soc_top u_dut (
        .clk_27m  (clk),
        .rst_n    (rst_n),
        .btn_s2   (1'b1),
        .uart_tx  (uart_tx),
        .uart_rx  (1'b1),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (1'b0),
        .spi_cs_n (spi_cs_n),
        .led      (led)
    );

    initial begin
        force u_dut.cpu_haddr  = haddr;
        force u_dut.cpu_htrans = htrans;
        force u_dut.cpu_hwrite = hwrite;
        force u_dut.cpu_hsize  = hsize;
        force u_dut.cpu_hwdata = hwdata;
    end

    task automatic check_eq(input [31:0] got, input [31:0] want, input string what);
        checks = checks + 1;
        if (got !== want) begin
            failures = failures + 1;
            $display("FAIL @ %0t: %s: got %08h, want %08h", $time, what, got, want);
        end
    endtask

    // Present one address phase. The previous transfer's data phase runs at the
    // same time, so HWDATA here belongs to the previous transfer, not this one.
    task automatic xfer(input [31:0] addr, input logic write, input [2:0] size,
                        input [31:0] wdata);
        haddr  <= addr;
        htrans <= 2'b10;
        hwrite <= write;
        hsize  <= size;
        hwdata <= prev_write ? prev_wdata : GARBAGE;
        @(posedge clk);
        while (hready !== 1'b1) @(posedge clk);
        last_rdata = hrdata;
        prev_write = write;
        prev_wdata = wdata;
    endtask

    // Go idle and let the last data phase finish.
    task automatic flush;
        htrans <= 2'b00;
        hwrite <= 1'b0;
        hwdata <= prev_write ? prev_wdata : GARBAGE;
        @(posedge clk);
        while (hready !== 1'b1) @(posedge clk);
        last_rdata = hrdata;
        prev_write = 1'b0;
        hwdata <= GARBAGE;
    endtask

    task automatic write(input [31:0] addr, input [2:0] size, input [31:0] wdata);
        xfer(addr, 1'b1, size, wdata);
        flush;
    endtask

    task automatic read(input [31:0] addr, input [2:0] size, output [31:0] rdata);
        xfer(addr, 1'b0, size, 32'h0);
        flush;
        rdata = last_rdata;
    endtask

    logic [31:0] val;

    initial begin
        $dumpfile("tb_soc_sram.vcd");
        $dumpvars(0, tb_soc_sram);

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // Word write, then read back with an idle cycle in between.
        write(SRAM_BASE + 32'h00, SIZE_WORD, 32'h1234_5678);
        read(SRAM_BASE + 32'h00, SIZE_WORD, val);
        check_eq(val, 32'h1234_5678, "word round trip");

        // One byte in each lane must leave the other three lanes alone.
        write(SRAM_BASE + 32'h10, SIZE_WORD, 32'hAABB_CCDD);
        write(SRAM_BASE + 32'h10, SIZE_BYTE, 32'h0000_0011);
        read(SRAM_BASE + 32'h10, SIZE_WORD, val);
        check_eq(val, 32'hAABB_CC11, "byte lane 0");
        write(SRAM_BASE + 32'h11, SIZE_BYTE, 32'h0000_2200);
        read(SRAM_BASE + 32'h10, SIZE_WORD, val);
        check_eq(val, 32'hAABB_2211, "byte lane 1");
        write(SRAM_BASE + 32'h12, SIZE_BYTE, 32'h0033_0000);
        read(SRAM_BASE + 32'h10, SIZE_WORD, val);
        check_eq(val, 32'hAA33_2211, "byte lane 2");
        write(SRAM_BASE + 32'h13, SIZE_BYTE, 32'h4400_0000);
        read(SRAM_BASE + 32'h10, SIZE_WORD, val);
        check_eq(val, 32'h4433_2211, "byte lane 3");

        // Halfwords: lower then upper.
        write(SRAM_BASE + 32'h20, SIZE_WORD, 32'hAABB_CCDD);
        write(SRAM_BASE + 32'h20, SIZE_HALF, 32'h0000_1122);
        read(SRAM_BASE + 32'h20, SIZE_WORD, val);
        check_eq(val, 32'hAABB_1122, "halfword lower");
        write(SRAM_BASE + 32'h22, SIZE_HALF, 32'h3344_0000);
        read(SRAM_BASE + 32'h20, SIZE_WORD, val);
        check_eq(val, 32'h3344_1122, "halfword upper");

        // Back-to-back: the read's address phase overlaps the write's data phase.
        xfer(SRAM_BASE + 32'h30, 1'b1, SIZE_WORD, 32'hCAFE_F00D);
        xfer(SRAM_BASE + 32'h30, 1'b0, SIZE_WORD, 32'h0);
        flush;
        check_eq(last_rdata, 32'hCAFE_F00D, "read immediately after word write");

        // A back-to-back byte write must merge with the existing word.
        xfer(SRAM_BASE + 32'h31, 1'b1, SIZE_BYTE, 32'h0000_5A00);
        xfer(SRAM_BASE + 32'h30, 1'b0, SIZE_WORD, 32'h0);
        flush;
        check_eq(last_rdata, 32'hCAFE_5A0D, "read immediately after byte write");

        // The bridge stalls HREADY during the APB data phase, and the SRAM write's
        // address phase waits during that stall with the APB data on HWDATA.
        write(SRAM_BASE + 32'h44, SIZE_WORD, 32'h5555_5555);
        xfer(GPIO_OUT, 1'b1, SIZE_WORD, 32'h0000_002A);
        xfer(SRAM_BASE + 32'h40, 1'b1, SIZE_WORD, 32'h7777_8888);
        flush;
        read(SRAM_BASE + 32'h40, SIZE_WORD, val);
        check_eq(val, 32'h7777_8888, "SRAM write after APB stall");
        read(SRAM_BASE + 32'h44, SIZE_WORD, val);
        check_eq(val, 32'h5555_5555, "neighbour word after APB stall");
        read(GPIO_OUT, SIZE_WORD, val);
        check_eq(val, 32'h0000_002A, "GPIO write in the same pipeline");

        // SRAM write followed at once by an APB transfer.
        xfer(SRAM_BASE + 32'h50, 1'b1, SIZE_WORD, 32'h9999_AAAA);
        xfer(GPIO_OUT, 1'b0, SIZE_WORD, 32'h0);
        flush;
        check_eq(last_rdata, 32'h0000_002A, "GPIO read after SRAM write");
        read(SRAM_BASE + 32'h50, SIZE_WORD, val);
        check_eq(val, 32'h9999_AAAA, "SRAM write before APB transfer");

        // Reserved APB address: the bridge answers with a two-cycle ERROR. The
        // waiting SRAM write is cancelled during the first cycle, while HREADY is
        // low, so it must not reach memory. This needs HREADY wired to the SRAM.
        write(SRAM_BASE + 32'h60, SIZE_WORD, 32'h600D_600D);
        xfer(32'h4000_3000, 1'b1, SIZE_WORD, 32'hBAD0_BAD0);
        haddr  <= SRAM_BASE + 32'h60;
        htrans <= 2'b10;
        hwrite <= 1'b1;
        hsize  <= SIZE_WORD;
        hwdata <= prev_wdata;
        @(posedge clk);
        while (hresp !== 1'b1) @(posedge clk);
        check_eq({31'h0, hready}, 32'h0, "HREADY is low in the first ERROR cycle");
        htrans <= 2'b00;
        hwrite <= 1'b0;
        @(posedge clk);
        check_eq({31'h0, hresp}, 32'h1, "HRESP is ERROR in the second cycle");
        check_eq({31'h0, hready}, 32'h1, "HREADY is high in the second ERROR cycle");
        prev_write = 1'b0;
        hwdata <= GARBAGE;
        read(SRAM_BASE + 32'h60, SIZE_WORD, val);
        check_eq(val, 32'h600D_600D, "write cancelled after ERROR");

        checks = checks + 1;
        if (hresp !== 1'b0) begin
            failures = failures + 1;
            $display("FAIL: HRESP is not OKAY at the end of the test");
        end

        $display("RESULT: %0d checks, %0d failures", checks, failures);
        if (failures != 0) $fatal(1, "[TB_SOC_SRAM] SRAM integration failed");
        $display("PASS: SoC SRAM integration tests");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "[TB_SOC_SRAM] ERROR: Simulation Timeout!");
    end

endmodule
