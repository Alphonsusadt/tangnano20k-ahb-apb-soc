// ==============================================================================
// Testbench: tb_ahb_rom
// Description: Unit test for rtl/memory/ahb_rom.sv against docs/memory_map.md:
//              zero-wait reads, back-to-back reads, a two-cycle ERROR for every
//              write size with the contents unchanged, and no reaction to IDLE,
//              to an unselected slave, or to a transfer waiting behind HREADY low.
//              The testbench drives and samples at negedge, so both
//              simulators see the same cycles.
// ==============================================================================

`timescale 1ns/1ps

module tb_ahb_rom;

    localparam [1:0] TRANS_IDLE = 2'b00, TRANS_NONSEQ = 2'b10;
    localparam [2:0] SIZE_BYTE = 3'b000, SIZE_HALF = 3'b001, SIZE_WORD = 3'b010;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic        hsel = 1'b0;
    logic [31:0] haddr = '0;
    logic [1:0]  htrans = TRANS_IDLE;
    logic        hwrite = 1'b0;
    logic        stall = 1'b0;          // Forces global HREADY low, as another slave would
    wire  [31:0] hrdata;
    wire         hreadyout, hresp;
    wire         hready = hreadyout && !stall;

    ahb_rom #(.ADDR_WIDTH(15)) u_dut (
        .hclk      (clk),
        .hreset_n  (rst_n),
        .hsel      (hsel),
        .haddr     (haddr),
        .htrans    (htrans),
        .hwrite    (hwrite),
        .hready    (hready),
        .hrdata    (hrdata),
        .hreadyout (hreadyout),
        .hresp     (hresp)
    );

    integer checks = 0, failures = 0;

    task automatic check_eq(input [31:0] got, input [31:0] want, input string what);
        checks++;
        if (got !== want) begin
            failures++;
            $display("FAIL @ %0t: %s: got %08h, want %08h", $time, what, got, want);
        end
    endtask

    // Response seen in the current cycle, as {HRESP, HREADYOUT}.
    task automatic check_resp(input logic want_resp, input logic want_ready, input string what);
        check_eq({30'h0, hresp, hreadyout}, {30'h0, want_resp, want_ready}, what);
    endtask

    function automatic [31:0] pattern(input integer word);
        return 32'hC0DE_0000 ^ (word * 32'h0001_0101);
    endfunction

    task automatic addr_phase(input logic sel, input [31:0] addr, input [1:0] trans,
                              input logic write);
        hsel = sel; haddr = addr; htrans = trans; hwrite = write;
    endtask

    task automatic go_idle;
        hsel = 1'b0; htrans = TRANS_IDLE; hwrite = 1'b0;
    endtask

    // One write of the given size: ERROR for exactly two cycles, then OKAY.
    task automatic write_gets_error(input [31:0] addr, input string what);
        integer word;
        word = addr[14:2];
        addr_phase(1'b1, addr, TRANS_NONSEQ, 1'b1);
        check_resp(1'b0, 1'b1, {what, ": address phase is OKAY"});
        @(negedge clk);
        go_idle;
        check_resp(1'b1, 1'b0, {what, ": first ERROR cycle"});
        @(negedge clk);
        check_resp(1'b1, 1'b1, {what, ": second ERROR cycle"});
        @(negedge clk);
        check_resp(1'b0, 1'b1, {what, ": OKAY after ERROR"});
        check_eq(u_dut.mem[word], pattern(word), {what, ": contents unchanged"});
    endtask

    integer i;
    initial begin
        for (i = 0; i < 64; i++) u_dut.mem[i] = pattern(i);
        u_dut.mem[8191] = pattern(8191);

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        check_resp(1'b0, 1'b1, "Idle after reset: OKAY, ready");

        // Single reads: data is valid in the cycle after the address phase.
        for (i = 0; i < 8; i++) begin
            addr_phase(1'b1, i * 4, TRANS_NONSEQ, 1'b0);
            @(negedge clk);
            go_idle;
            check_resp(1'b0, 1'b1, $sformatf("Read %0d: zero-wait OKAY", i));
            check_eq(hrdata, pattern(i), $sformatf("Read %0d: data", i));
            @(negedge clk);
        end

        // The last word, so the index uses every address bit.
        addr_phase(1'b1, 32'h0000_7FFC, TRANS_NONSEQ, 1'b0);
        @(negedge clk);
        go_idle;
        check_eq(hrdata, pattern(8191), "Read of the last word");
        @(negedge clk);

        // Back-to-back reads: the data phase of read i is checked in the same cycle
        // that the address phase of read i+1 is placed on the bus.
        for (i = 10; i < 20; i++) begin
            addr_phase(1'b1, i * 4, TRANS_NONSEQ, 1'b0);
            @(negedge clk);
            check_resp(1'b0, 1'b1, $sformatf("Pipelined read %0d: zero-wait OKAY", i));
            check_eq(hrdata, pattern(i), $sformatf("Pipelined read %0d: data", i));
        end
        go_idle;
        @(negedge clk);

        // Every write size is refused with a two-cycle ERROR.
        write_gets_error(32'h0000_0010, "Word write");
        write_gets_error(32'h0000_0022, "Halfword write");
        write_gets_error(32'h0000_0033, "Byte write");

        // A read waiting in the address phase during ERROR is accepted at the end of it.
        addr_phase(1'b1, 32'h0000_0010, TRANS_NONSEQ, 1'b1);
        @(negedge clk);
        addr_phase(1'b1, 32'h0000_0014, TRANS_NONSEQ, 1'b0);
        check_resp(1'b1, 1'b0, "Held read: first ERROR cycle");
        @(negedge clk);
        check_resp(1'b1, 1'b1, "Held read: second ERROR cycle");
        @(negedge clk);
        go_idle;
        check_resp(1'b0, 1'b1, "Held read: OKAY");
        check_eq(hrdata, pattern(5), "Held read: data");
        @(negedge clk);

        // No ERROR without an accepted write.
        addr_phase(1'b1, 32'h0000_0010, TRANS_IDLE, 1'b1);
        @(negedge clk);
        go_idle;
        check_resp(1'b0, 1'b1, "IDLE with HWRITE high: no ERROR");
        @(negedge clk);

        addr_phase(1'b0, 32'h0000_0010, TRANS_NONSEQ, 1'b1);
        @(negedge clk);
        go_idle;
        check_resp(1'b0, 1'b1, "Write to an unselected ROM: no ERROR");
        @(negedge clk);

        // A write waiting behind another slave's wait state is not accepted yet.
        stall = 1'b1;
        addr_phase(1'b1, 32'h0000_0010, TRANS_NONSEQ, 1'b1);
        @(negedge clk);
        check_resp(1'b0, 1'b1, "Write held by HREADY low: no ERROR yet");
        @(negedge clk);
        check_resp(1'b0, 1'b1, "Still held: no ERROR yet");
        stall = 1'b0;
        @(negedge clk);
        go_idle;
        check_resp(1'b1, 1'b0, "Write accepted once HREADY is high: first ERROR cycle");
        @(negedge clk);
        check_resp(1'b1, 1'b1, "Released write: second ERROR cycle");
        @(negedge clk);
        check_resp(1'b0, 1'b1, "Released write: OKAY after ERROR");

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
