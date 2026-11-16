// ==============================================================================
// Testbench: tb_apb_timer
// Description: Unit test for rtl/peripherals/apb_timer.sv against docs/memory_map.md
//              section 5: reset values, counting only while EN is set, the carry from
//              MTIME_LO into MTIME_HI, a level interrupt that stays high until
//              software raises MTIMECMP or clears EN, the safe 64-bit MTIMECMP write
//              order, byte writes with PSTRB, and PSLVERR past the last register.
//              Drives and samples at negedge, so both simulators agree.
// ==============================================================================

`timescale 1ns/1ps

module tb_apb_timer;

    localparam [31:0] MTIME_LO = 32'h00, MTIME_HI = 32'h04;
    localparam [31:0] CMP_LO   = 32'h08, CMP_HI   = 32'h0C;
    localparam [31:0] CTRL     = 32'h10;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic        psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
    logic [31:0] paddr = '0, pwdata = '0;
    logic [3:0]  pstrb = 4'h0;
    wire  [31:0] prdata;
    wire         pready, pslverr, irq;

    apb_timer u_dut (
        .pclk      (clk),
        .preset_n  (rst_n),
        .psel      (psel),
        .penable   (penable),
        .pwrite    (pwrite),
        .paddr     (paddr),
        .pwdata    (pwdata),
        .pstrb     (pstrb),
        .prdata    (prdata),
        .pready    (pready),
        .pslverr   (pslverr),
        .irq_timer (irq)
    );

    integer checks = 0, failures = 0;

    task automatic check_eq(input [31:0] got, input [31:0] want, input string what);
        checks++;
        if (got !== want) begin
            failures++;
            $display("FAIL @ %0t: %s: got %08h, want %08h", $time, what, got, want);
        end
    endtask

    logic last_err;

    // SETUP and ACCESS, one cycle each; PREADY is always high.
    task automatic apb(input logic wr, input [31:0] addr, input [31:0] data,
                       input [3:0] strb, output [31:0] rdata);
        psel = 1'b1; penable = 1'b0; pwrite = wr; paddr = addr; pwdata = data;
        pstrb = wr ? strb : 4'h0;
        @(negedge clk);
        penable = 1'b1;
        #1;                              // Let PRDATA and PSLVERR settle
        rdata = prdata;
        last_err = pslverr;
        @(negedge clk);
        psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
    endtask

    task automatic write(input [31:0] addr, input [31:0] data);
        logic [31:0] unused;
        apb(1'b1, addr, data, 4'hF, unused);
    endtask

    task automatic read(input [31:0] addr, output [31:0] data);
        apb(1'b0, addr, 32'h0, 4'h0, data);
    endtask

    logic [31:0] v, v2;
    integer i;

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // Reset values.
        read(MTIME_LO, v);  check_eq(v, 32'h0, "MTIME_LO reset");
        read(MTIME_HI, v);  check_eq(v, 32'h0, "MTIME_HI reset");
        read(CMP_LO, v);    check_eq(v, 32'hFFFF_FFFF, "MTIMECMP_LO reset");
        read(CMP_HI, v);    check_eq(v, 32'hFFFF_FFFF, "MTIMECMP_HI reset");
        read(CTRL, v);      check_eq(v, 32'h0, "TIMER_CTRL reset");
        check_eq({31'h0, irq}, 32'h0, "no interrupt after reset");

        // Disabled: mtime does not move.
        repeat (20) @(negedge clk);
        read(MTIME_LO, v);  check_eq(v, 32'h0, "MTIME_LO holds while EN is 0");

        // Enabled: one tick per clock. Two reads 10 cycles apart differ by the
        // cycles between their ACCESS samples.
        write(CTRL, 32'h1);
        read(MTIME_LO, v);
        repeat (8) @(negedge clk);
        read(MTIME_LO, v2);
        check_eq(v2 - v, 32'd10, "MTIME_LO advances one tick per clock");

        // Carry from LO into HI.
        write(CTRL, 32'h0);
        write(MTIME_HI, 32'h0000_0007);
        write(MTIME_LO, 32'hFFFF_FFF8);
        write(CTRL, 32'h1);
        repeat (20) @(negedge clk);
        write(CTRL, 32'h0);
        read(MTIME_HI, v);  check_eq(v, 32'h0000_0008, "carry reaches MTIME_HI");
        read(MTIME_LO, v);
        check_eq({31'h0, (v < 32'd40)}, 32'h1, "MTIME_LO wrapped past zero");

        // Level interrupt: high once mtime >= mtimecmp, and it stays high.
        write(MTIME_HI, 32'h0);
        write(MTIME_LO, 32'h0);
        write(CMP_LO, 32'hFFFF_FFFF);       // Safe order: LO to max, then HI, then LO
        write(CMP_HI, 32'h0);
        write(CMP_LO, 32'd30);
        check_eq({31'h0, irq}, 32'h0, "EN=0: no interrupt even with mtime below mtimecmp");
        write(CTRL, 32'h1);
        check_eq({31'h0, irq}, 32'h0, "no interrupt before mtime reaches mtimecmp");
        repeat (40) @(negedge clk);
        check_eq({31'h0, irq}, 32'h1, "interrupt once mtime >= mtimecmp");
        repeat (100) @(negedge clk);
        check_eq({31'h0, irq}, 32'h1, "interrupt stays high until software acts");
        read(CTRL, v);      check_eq(v, 32'h3, "TIMER_CTRL shows EN and IRQ");

        // Raising mtimecmp clears it.
        read(MTIME_LO, v);
        write(CMP_LO, v + 32'd200);
        check_eq({31'h0, irq}, 32'h0, "raising MTIMECMP clears the interrupt");
        // Clearing EN also clears it.
        repeat (250) @(negedge clk);
        check_eq({31'h0, irq}, 32'h1, "interrupt again at the new MTIMECMP");
        write(CTRL, 32'h0);
        check_eq({31'h0, irq}, 32'h0, "EN=0 clears the interrupt");

        // A 64-bit compare: HI decides when LO alone would say "reached".
        write(MTIME_HI, 32'h0);
        write(MTIME_LO, 32'h0000_1000);
        write(CMP_LO, 32'hFFFF_FFFF);
        write(CMP_HI, 32'h0000_0001);
        write(CMP_LO, 32'h0000_0010);
        write(CTRL, 32'h1);
        check_eq({31'h0, irq}, 32'h0, "MTIMECMP_HI above MTIME_HI: no interrupt");
        write(CTRL, 32'h0);

        // Byte writes follow PSTRB.
        write(CMP_LO, 32'h1122_3344);
        apb(1'b1, CMP_LO, 32'hAABB_CCDD, 4'b0100, v);
        read(CMP_LO, v);    check_eq(v, 32'h11BB_3344, "MTIMECMP_LO byte lane 2 only");
        apb(1'b1, CMP_LO, 32'hAABB_CCDD, 4'b0000, v);
        read(CMP_LO, v);    check_eq(v, 32'h11BB_3344, "MTIMECMP_LO no strobes");
        apb(1'b1, CTRL, 32'h0000_0001, 4'b1110, v);
        read(CTRL, v);      check_eq(v & 32'h1, 32'h0, "TIMER_CTRL EN needs PSTRB[0]");

        // Offsets past TIMER_CTRL answer PSLVERR and change nothing.
        write(CMP_HI, 32'h0000_0055);
        apb(1'b1, 32'h14, 32'h0, 4'hF, v);
        check_eq({31'h0, last_err}, 32'h1, "write to 0x14 answers PSLVERR");
        apb(1'b0, 32'hFFC, 32'h0, 4'h0, v);
        check_eq({31'h0, last_err}, 32'h1, "read of 0xFFC answers PSLVERR");
        apb(1'b0, CMP_HI, 32'h0, 4'h0, v);
        check_eq({31'h0, last_err}, 32'h0, "valid read answers OKAY");
        check_eq(v, 32'h0000_0055, "registers unchanged by the refused write");

        $display("RESULT: %0d checks, %0d failures", checks, failures);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout");
        $display("RESULT: %0d checks, %0d failures", checks, failures + 1);
        $finish;
    end

endmodule
