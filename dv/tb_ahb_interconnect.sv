// ==============================================================================
// Testbench: tb_ahb_interconnect
// Description: Self-checking unit regression for ahb_interconnect, driven by a
//              pipelined AHB-Lite master and three scripted slaves. Expected values
//              come from docs/memory_map.md and the AHB-Lite protocol, not from the
//              RTL: decode boundaries, signal fan-out, data-phase multiplexing,
//              wait states, ERROR responses, and transfers to unmapped addresses.
//
// Timing: signals change just after a rising edge and are checked at the falling
//         edge, so each check sees one settled bus cycle.
// ==============================================================================

`timescale 1ns / 1ps

module tb_ahb_interconnect;

    localparam [1:0] TRANS_IDLE   = 2'b00;
    localparam [1:0] TRANS_BUSY   = 2'b01;
    localparam [1:0] TRANS_NONSEQ = 2'b10;

    localparam [2:0] SIZE_WORD = 3'b010;

    localparam [2:0] NO_SLAVE = 3'b000;
    localparam [2:0] ROM      = 3'b001;
    localparam [2:0] SRAM     = 3'b010;
    localparam [2:0] BRIDGE   = 3'b100;

    localparam [31:0] RDATA_ROM    = 32'hA0A0_0000;
    localparam [31:0] RDATA_SRAM   = 32'hB1B1_1111;
    localparam [31:0] RDATA_BRIDGE = 32'hC2C2_2222;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    // Master.
    logic [31:0] haddr  = 32'h0;
    logic [1:0]  htrans = TRANS_IDLE;
    logic        hwrite = 1'b0;
    logic [2:0]  hsize  = SIZE_WORD;
    logic [2:0]  hburst = 3'b000;
    logic [3:0]  hprot  = 4'b0011;
    logic [31:0] hwdata = 32'h0;

    wire [31:0] s_hrdata;
    wire        s_hready;
    wire        s_hresp;

    // Scripted slave responses, one bit per slave: {bridge, sram, rom}.
    logic [2:0] slave_ready = 3'b111;
    logic [2:0] slave_resp  = 3'b000;

    wire        m0_hsel, m1_hsel, m2_hsel;
    wire [31:0] m0_haddr, m1_haddr, m2_haddr;
    wire [1:0]  m0_htrans, m1_htrans, m2_htrans;
    wire        m0_hwrite, m1_hwrite, m2_hwrite;
    wire [2:0]  m0_hsize, m1_hsize, m2_hsize;
    wire [31:0] m0_hwdata, m1_hwdata, m2_hwdata;

    integer checks = 0;
    integer failures = 0;
    integer group_checks = 0;
    integer group_failures = 0;

    always #18.518 clk = ~clk;

    ahb_interconnect u_dut (
        .hclk      (clk),
        .hreset_n  (rst_n),
        .s_haddr   (haddr),
        .s_htrans  (htrans),
        .s_hwrite  (hwrite),
        .s_hsize   (hsize),
        .s_hburst  (hburst),
        .s_hprot   (hprot),
        .s_hwdata  (hwdata),
        .s_hrdata  (s_hrdata),
        .s_hready  (s_hready),
        .s_hresp   (s_hresp),
        .m0_hsel   (m0_hsel),
        .m0_haddr  (m0_haddr),
        .m0_htrans (m0_htrans),
        .m0_hwrite (m0_hwrite),
        .m0_hsize  (m0_hsize),
        .m0_hwdata (m0_hwdata),
        .m0_hrdata (RDATA_ROM),
        .m0_hready (slave_ready[0]),
        .m0_hresp  (slave_resp[0]),
        .m1_hsel   (m1_hsel),
        .m1_haddr  (m1_haddr),
        .m1_htrans (m1_htrans),
        .m1_hwrite (m1_hwrite),
        .m1_hsize  (m1_hsize),
        .m1_hwdata (m1_hwdata),
        .m1_hrdata (RDATA_SRAM),
        .m1_hready (slave_ready[1]),
        .m1_hresp  (slave_resp[1]),
        .m2_hsel   (m2_hsel),
        .m2_haddr  (m2_haddr),
        .m2_htrans (m2_htrans),
        .m2_hwrite (m2_hwrite),
        .m2_hsize  (m2_hsize),
        .m2_hwdata (m2_hwdata),
        .m2_hrdata (RDATA_BRIDGE),
        .m2_hready (slave_ready[2]),
        .m2_hresp  (slave_resp[2])
    );

    task automatic check_eq(input [31:0] got, input [31:0] want, input string what);
        checks = checks + 1;
        group_checks = group_checks + 1;
        if (got !== want) begin
            failures = failures + 1;
            group_failures = group_failures + 1;
            $display("FAIL @ %0t: %s: got %08h, want %08h", $time, what, got, want);
        end
    endtask

    task automatic begin_group;
        group_checks = 0;
        group_failures = 0;
    endtask

    task automatic end_group(input string name);
        $display("GROUP %-24s %0d checks, %0d failures", name, group_checks, group_failures);
    endtask

    function automatic [31:0] slave_addr(input integer i);
        case (i)
            0:       slave_addr = 32'h0000_0100;
            1:       slave_addr = 32'h2000_0100;
            default: slave_addr = 32'h4000_0100;
        endcase
    endfunction

    function automatic [31:0] slave_rdata(input integer i);
        case (i)
            0:       slave_rdata = RDATA_ROM;
            1:       slave_rdata = RDATA_SRAM;
            default: slave_rdata = RDATA_BRIDGE;
        endcase
    endfunction

    function automatic [2:0] slave_bit(input integer i);
        slave_bit = 3'b001 << i;
    endfunction

    // Present an address phase. Call just after a rising edge.
    task automatic drive(input [31:0] addr, input [1:0] trans);
        haddr  <= addr;
        htrans <= trans;
    endtask

    // End any transfer in progress and return to a clean idle bus.
    task automatic to_idle;
        drive(32'h0, TRANS_IDLE);
        hwrite      <= 1'b0;
        slave_ready <= 3'b111;
        slave_resp  <= 3'b000;
        repeat (2) @(posedge clk);
    endtask

    task automatic check_response(input logic ready, input logic resp, input string what);
        check_eq({31'h0, s_hready}, {31'h0, ready}, $sformatf("%s: HREADY", what));
        check_eq({31'h0, s_hresp},  {31'h0, resp},  $sformatf("%s: HRESP", what));
    endtask

    // --------------------------------------------------------------------------
    // Address decoding, from docs/memory_map.md.
    // --------------------------------------------------------------------------
    task automatic check_decode(input [31:0] addr, input [2:0] want);
        drive(addr, TRANS_NONSEQ);
        @(negedge clk);
        check_eq({29'h0, m2_hsel, m1_hsel, m0_hsel}, {29'h0, want},
                 $sformatf("decode %08h", addr));
        @(posedge clk);
    endtask

    task automatic test_decode;
        begin_group;
        check_decode(32'h0000_0000, ROM);
        check_decode(32'h0000_7FFC, ROM);
        check_decode(32'h0000_8000, NO_SLAVE);
        check_decode(32'h0000_FFFC, NO_SLAVE);
        check_decode(32'h0001_0000, NO_SLAVE);
        check_decode(32'h1FFF_FFFC, NO_SLAVE);
        check_decode(32'h2000_0000, SRAM);
        check_decode(32'h2000_7FFC, SRAM);
        check_decode(32'h2000_8000, NO_SLAVE);
        check_decode(32'h2000_FFFC, NO_SLAVE);
        check_decode(32'h2001_0000, NO_SLAVE);
        check_decode(32'h3FFF_FFFC, NO_SLAVE);
        check_decode(32'h4000_0000, BRIDGE);
        check_decode(32'h4000_2FFC, BRIDGE);
        check_decode(32'h4000_3000, BRIDGE); // Reserved: the bridge answers ERROR.
        check_decode(32'h4FFF_FFFC, BRIDGE);
        check_decode(32'h5000_0000, NO_SLAVE);
        check_decode(32'hFFFF_FFFC, NO_SLAVE);
        to_idle;
        end_group("decode");
    endtask

    // --------------------------------------------------------------------------
    // Master signals reach every slave unchanged.
    // --------------------------------------------------------------------------
    task automatic check_fanout(input [31:0] addr, input [1:0] trans, input logic write,
                                input [2:0] size, input [31:0] wdata);
        haddr  <= addr;
        htrans <= trans;
        hwrite <= write;
        hsize  <= size;
        hwdata <= wdata;
        @(negedge clk);
        check_eq(m0_haddr, addr, "fan-out m0 HADDR");
        check_eq(m1_haddr, addr, "fan-out m1 HADDR");
        check_eq(m2_haddr, addr, "fan-out m2 HADDR");
        check_eq({30'h0, m0_htrans}, {30'h0, trans}, "fan-out m0 HTRANS");
        check_eq({30'h0, m1_htrans}, {30'h0, trans}, "fan-out m1 HTRANS");
        check_eq({30'h0, m2_htrans}, {30'h0, trans}, "fan-out m2 HTRANS");
        check_eq({31'h0, m0_hwrite}, {31'h0, write}, "fan-out m0 HWRITE");
        check_eq({31'h0, m1_hwrite}, {31'h0, write}, "fan-out m1 HWRITE");
        check_eq({31'h0, m2_hwrite}, {31'h0, write}, "fan-out m2 HWRITE");
        check_eq({29'h0, m0_hsize}, {29'h0, size}, "fan-out m0 HSIZE");
        check_eq({29'h0, m1_hsize}, {29'h0, size}, "fan-out m1 HSIZE");
        check_eq({29'h0, m2_hsize}, {29'h0, size}, "fan-out m2 HSIZE");
        check_eq(m0_hwdata, wdata, "fan-out m0 HWDATA");
        check_eq(m1_hwdata, wdata, "fan-out m1 HWDATA");
        check_eq(m2_hwdata, wdata, "fan-out m2 HWDATA");
        @(posedge clk);
    endtask

    // Two opposite vectors, so a slave input tied to a constant cannot pass.
    task automatic test_fanout;
        begin_group;
        check_fanout(32'h2000_1234, TRANS_NONSEQ, 1'b1, 3'b001, 32'h5A5A_C3C3);
        check_fanout(32'h4000_EDC8, TRANS_BUSY,   1'b0, 3'b000, 32'hA5A5_3C3C);
        hsize  <= SIZE_WORD;
        hwdata <= 32'h0;
        to_idle;
        end_group("fan-out");
    endtask

    // --------------------------------------------------------------------------
    // The response comes from the slave of the data phase, while the address
    // phase already points at the next slave. Every ordered slave pair.
    // --------------------------------------------------------------------------
    task automatic test_data_phase_mux;
        integer i, j;
        begin_group;
        for (i = 0; i < 3; i = i + 1) begin
            for (j = 0; j < 3; j = j + 1) begin
                to_idle;
                drive(slave_addr(i), TRANS_NONSEQ);
                @(posedge clk);

                // Only slave i answers correctly. A leak from the others is visible.
                drive(slave_addr(j), TRANS_NONSEQ);
                slave_ready <= slave_bit(i);
                slave_resp  <= ~slave_bit(i);
                @(negedge clk);
                check_eq(s_hrdata, slave_rdata(i), $sformatf("data phase %0d then %0d", i, j));
                check_response(1'b1, 1'b0, $sformatf("data phase %0d then %0d", i, j));
                @(posedge clk);

                drive(32'h0, TRANS_IDLE);
                slave_ready <= slave_bit(j);
                slave_resp  <= ~slave_bit(j);
                @(negedge clk);
                check_eq(s_hrdata, slave_rdata(j), $sformatf("next data phase %0d then %0d", i, j));
                check_response(1'b1, 1'b0, $sformatf("next data phase %0d then %0d", i, j));
                @(posedge clk);
            end
        end
        to_idle;
        end_group("data-phase mux");
    endtask

    // --------------------------------------------------------------------------
    // A slave stalls while the next address waits on the bus. The selection must
    // stay on the stalled slave, even though the next slave is ready.
    // --------------------------------------------------------------------------
    task automatic test_wait_states;
        integer i, j, n;
        begin_group;
        for (i = 0; i < 3; i = i + 1) begin
            for (j = 0; j < 3; j = j + 1) begin
                to_idle;
                drive(slave_addr(i), TRANS_NONSEQ);
                @(posedge clk);

                drive(slave_addr(j), TRANS_NONSEQ);
                slave_ready <= ~slave_bit(i);
                for (n = 0; n < 3; n = n + 1) begin
                    @(negedge clk);
                    check_eq({31'h0, s_hready}, 32'h0,
                             $sformatf("stall %0d then %0d, cycle %0d: HREADY", i, j, n));
                    check_eq(s_hrdata, slave_rdata(i),
                             $sformatf("stall %0d then %0d, cycle %0d: HRDATA", i, j, n));
                    @(posedge clk);
                end

                slave_ready <= 3'b111;
                @(negedge clk);
                check_eq(s_hrdata, slave_rdata(i), $sformatf("stall %0d then %0d: release", i, j));
                check_response(1'b1, 1'b0, $sformatf("stall %0d then %0d: release", i, j));
                @(posedge clk);

                drive(32'h0, TRANS_IDLE);
                slave_ready <= ~slave_bit(i);
                @(negedge clk);
                if (i != j) begin
                    check_eq(s_hrdata, slave_rdata(j), $sformatf("stall %0d then %0d: next", i, j));
                    check_response(1'b1, 1'b0, $sformatf("stall %0d then %0d: next", i, j));
                end
                @(posedge clk);
            end
        end
        to_idle;
        end_group("wait states");
    endtask

    // --------------------------------------------------------------------------
    // A slave's two-cycle ERROR reaches the master, and the master can cancel the
    // waiting transfer.
    // --------------------------------------------------------------------------
    task automatic test_slave_error;
        integer i, j;
        begin_group;
        for (i = 0; i < 3; i = i + 1) begin
            j = (i + 1) % 3;
            to_idle;
            drive(slave_addr(i), TRANS_NONSEQ);
            @(posedge clk);

            drive(slave_addr(j), TRANS_NONSEQ);
            slave_ready <= ~slave_bit(i);
            slave_resp  <= slave_bit(i);
            @(negedge clk);
            check_response(1'b0, 1'b1, $sformatf("slave %0d ERROR first cycle", i));
            @(posedge clk);

            drive(32'h0, TRANS_IDLE);
            slave_ready <= 3'b111;
            @(negedge clk);
            check_response(1'b1, 1'b1, $sformatf("slave %0d ERROR second cycle", i));
            @(posedge clk);

            slave_resp <= 3'b000;
            @(negedge clk);
            check_response(1'b1, 1'b0, $sformatf("slave %0d after ERROR", i));
            @(posedge clk);
        end
        to_idle;
        end_group("slave ERROR");
    endtask

    // --------------------------------------------------------------------------
    // IDLE and BUSY need a zero-wait OKAY, even at an unmapped address.
    // --------------------------------------------------------------------------
    task automatic test_unmapped_idle;
        integer i;
        begin_group;

        // A valid transfer must not leave an ERROR behind for the idle cycles that
        // follow it, when the selection has moved away from the slave.
        for (i = 0; i < 3; i = i + 1) begin
            to_idle;
            drive(slave_addr(i), TRANS_NONSEQ);
            @(posedge clk);
            drive(32'h1000_0000, TRANS_IDLE);
            @(negedge clk);
            check_response(1'b1, 1'b0, $sformatf("slave %0d data phase before idle", i));
            @(posedge clk);
            @(negedge clk);
            check_response(1'b1, 1'b0, $sformatf("slave %0d then idle at unmapped", i));
            @(posedge clk);
        end

        to_idle;
        drive(32'h1000_0000, TRANS_IDLE);
        @(posedge clk);
        @(negedge clk);
        check_response(1'b1, 1'b0, "IDLE at unmapped address");
        @(posedge clk);
        drive(32'h1000_0000, TRANS_BUSY);
        @(posedge clk);
        drive(32'h1000_0000, TRANS_IDLE);
        @(negedge clk);
        check_response(1'b1, 1'b0, "BUSY at unmapped address");
        @(posedge clk);
        to_idle;
        end_group("unmapped IDLE/BUSY");
    endtask

    // --------------------------------------------------------------------------
    // A real transfer to an unmapped address must not look successful: AHB-Lite
    // expects a two-cycle ERROR, so a firmware bug raises a bus fault.
    // --------------------------------------------------------------------------
    task automatic check_unmapped(input [31:0] addr, input logic write);
        string what;
        what = $sformatf("unmapped %s %08h", write ? "write" : "read", addr);
        to_idle;
        hwrite <= write;
        drive(addr, TRANS_NONSEQ);
        @(posedge clk);

        drive(32'h0, TRANS_IDLE);
        hwrite <= 1'b0;
        @(negedge clk);
        check_response(1'b0, 1'b1, {what, " first cycle"});
        @(posedge clk);
        @(negedge clk);
        check_response(1'b1, 1'b1, {what, " second cycle"});
        @(posedge clk);
        @(negedge clk);
        check_response(1'b1, 1'b0, {what, " after ERROR"});
        @(posedge clk);
    endtask

    task automatic test_unmapped_error;
        begin_group;
        check_unmapped(32'h1000_0000, 1'b0);
        check_unmapped(32'h1000_0000, 1'b1);
        check_unmapped(32'h0000_8000, 1'b0);
        check_unmapped(32'h2000_8000, 1'b1);
        check_unmapped(32'h5000_0000, 1'b0);
        to_idle;
        end_group("unmapped ERROR");
    endtask

    // An unmapped address waiting behind a stall is not accepted yet, so its ERROR
    // must not start until the stall ends. Two in a row each get a full ERROR.
    task automatic test_unmapped_sequencing;
        integer n;
        begin_group;
        to_idle;
        drive(slave_addr(2), TRANS_NONSEQ);
        @(posedge clk);

        drive(32'h1000_0000, TRANS_NONSEQ);
        slave_ready <= 3'b011;
        for (n = 0; n < 2; n = n + 1) begin
            @(negedge clk);
            check_response(1'b0, 1'b0, $sformatf("behind stall, cycle %0d", n));
            @(posedge clk);
        end
        slave_ready <= 3'b111;
        @(negedge clk);
        check_response(1'b1, 1'b0, "behind stall: release");
        @(posedge clk);

        drive(32'h0, TRANS_IDLE);
        @(negedge clk);
        check_response(1'b0, 1'b1, "behind stall: first ERROR cycle");
        @(posedge clk);
        @(negedge clk);
        check_response(1'b1, 1'b1, "behind stall: second ERROR cycle");
        @(posedge clk);
        @(negedge clk);
        check_response(1'b1, 1'b0, "behind stall: after ERROR");
        @(posedge clk);

        to_idle;
        drive(32'h1000_0000, TRANS_NONSEQ);
        @(posedge clk);
        drive(32'h5000_0000, TRANS_NONSEQ);
        @(negedge clk);
        check_response(1'b0, 1'b1, "consecutive: A first cycle");
        @(posedge clk);
        @(negedge clk);
        check_response(1'b1, 1'b1, "consecutive: A second cycle");
        @(posedge clk);

        drive(32'h0, TRANS_IDLE);
        @(negedge clk);
        check_response(1'b0, 1'b1, "consecutive: B first cycle");
        @(posedge clk);
        @(negedge clk);
        check_response(1'b1, 1'b1, "consecutive: B second cycle");
        @(posedge clk);
        @(negedge clk);
        check_response(1'b1, 1'b0, "consecutive: after ERROR");
        @(posedge clk);
        to_idle;
        end_group("unmapped sequencing");
    endtask

    // A valid transfer waiting behind the ERROR must still work afterwards.
    task automatic test_recovery_after_unmapped;
        begin_group;
        to_idle;
        drive(32'h1000_0000, TRANS_NONSEQ);
        @(posedge clk);

        drive(slave_addr(1), TRANS_NONSEQ);
        @(negedge clk);
        check_response(1'b0, 1'b1, "recovery: first ERROR cycle");
        @(posedge clk);
        @(negedge clk);
        check_response(1'b1, 1'b1, "recovery: second ERROR cycle");
        @(posedge clk);

        drive(32'h0, TRANS_IDLE);
        @(negedge clk);
        check_eq(s_hrdata, RDATA_SRAM, "recovery: read after ERROR");
        check_response(1'b1, 1'b0, "recovery: read after ERROR");
        @(posedge clk);
        to_idle;
        end_group("recovery after unmapped");
    endtask

    // --------------------------------------------------------------------------
    // Reset releases the bus, even in the middle of a stalled transfer.
    // --------------------------------------------------------------------------
    task automatic test_reset;
        begin_group;
        to_idle;
        drive(slave_addr(2), TRANS_NONSEQ);
        @(posedge clk);
        drive(32'h0, TRANS_IDLE);
        slave_ready <= 3'b011;
        @(negedge clk);
        check_eq({31'h0, s_hready}, 32'h0, "bridge stalls before reset");
        rst_n = 1'b0;
        #1;
        check_response(1'b1, 1'b0, "reset releases a stalled bus");
        @(posedge clk);
        rst_n <= 1'b1;
        to_idle;
        end_group("reset");
    endtask

    initial begin
        $dumpfile("tb_ahb_interconnect.vcd");
        $dumpvars(0, tb_ahb_interconnect);

        repeat (3) @(posedge clk);
        @(negedge clk);
        begin_group;
        check_response(1'b1, 1'b0, "during reset");
        end_group("during reset");
        @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        test_decode;
        test_fanout;
        test_data_phase_mux;
        test_wait_states;
        test_slave_error;
        test_unmapped_idle;
        test_unmapped_error;
        test_unmapped_sequencing;
        test_recovery_after_unmapped;
        test_reset;

        $display("RESULT: %0d checks, %0d failures", checks, failures);
        if (failures != 0) $fatal(1, "[TB_AHB_INTERCONNECT] Interconnect verification failed");
        $display("PASS: AHB interconnect directed tests");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "[TB_AHB_INTERCONNECT] ERROR: Simulation Timeout!");
    end

endmodule
