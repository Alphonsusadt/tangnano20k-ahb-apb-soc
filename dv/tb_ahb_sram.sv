// ==============================================================================
// Testbench: tb_ahb_sram
// Description: Self-checking unit regression for ahb_sram: address bits, write
//              sizes and lanes, ignored transfers, HREADY stalls, cancelled
//              transfers, read-after-write forwarding, and a random pipeline
//              checked against a model.
// ==============================================================================

`timescale 1ns / 1ps

module tb_ahb_sram;

    localparam [2:0] SIZE_BYTE = 3'b000;
    localparam [2:0] SIZE_HALF = 3'b001;
    localparam [2:0] SIZE_WORD = 3'b010;
    localparam [2:0] SIZE_DWRD = 3'b011;

    localparam [1:0] TRANS_IDLE   = 2'b00;
    localparam [1:0] TRANS_BUSY   = 2'b01;
    localparam [1:0] TRANS_NONSEQ = 2'b10;
    localparam [1:0] TRANS_SEQ    = 2'b11;

    localparam [31:0] GARBAGE    = 32'hDEAD_BEEF;
    localparam [31:0] LAST_WORD  = 32'h0000_7FFC;
    localparam integer RANDOM_OPS = 20000;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        hsel = 1'b0;
    logic [31:0] haddr = 32'h0;
    logic [1:0]  htrans = TRANS_IDLE;
    logic        hwrite = 1'b0;
    logic [2:0]  hsize = SIZE_WORD;
    logic [31:0] hwdata = GARBAGE;
    logic        hready = 1'b1;
    wire  [31:0] hrdata;
    wire         hreadyout;
    wire         hresp;

    logic        prev_write = 1'b0;
    logic [31:0] prev_wdata = GARBAGE;
    logic [31:0] last_rdata = 32'h0;

    integer checks = 0;
    integer failures = 0;
    integer seed = 32'h5EED_1234;

    always #18.518 clk = ~clk;

    ahb_sram u_dut (
        .hclk      (clk),
        .hreset_n  (rst_n),
        .hsel      (hsel),
        .haddr     (haddr),
        .htrans    (htrans),
        .hwrite    (hwrite),
        .hsize     (hsize),
        .hwdata    (hwdata),
        .hready    (hready),
        .hrdata    (hrdata),
        .hreadyout (hreadyout),
        .hresp     (hresp)
    );

    task automatic check_eq(input [31:0] got, input [31:0] want, input string what);
        checks = checks + 1;
        if (got !== want) begin
            failures = failures + 1;
            $display("FAIL @ %0t: %s: got %08h, want %08h", $time, what, got, want);
        end
    endtask

    // Present one address phase while the previous transfer's data phase runs.
    task automatic xfer(input [31:0] addr, input logic write, input [2:0] size,
                        input [31:0] wdata);
        hsel   <= 1'b1;
        haddr  <= addr;
        htrans <= TRANS_NONSEQ;
        hwrite <= write;
        hsize  <= size;
        hwdata <= prev_write ? prev_wdata : GARBAGE;
        @(posedge clk);
        last_rdata = hrdata;
        prev_write = write;
        prev_wdata = wdata;
    endtask

    task automatic flush;
        hsel   <= 1'b0;
        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        hwdata <= prev_write ? prev_wdata : GARBAGE;
        @(posedge clk);
        last_rdata = hrdata;
        prev_write = 1'b0;
        hwdata <= GARBAGE;
    endtask

    task automatic write(input [31:0] addr, input [2:0] size, input [31:0] wdata);
        xfer(addr, 1'b1, size, wdata);
        flush;
    endtask

    task automatic read_word(input [31:0] addr, output [31:0] rdata);
        xfer(addr, 1'b0, SIZE_WORD, 32'h0);
        flush;
        rdata = last_rdata;
    endtask

    // Drive a write that the SRAM must ignore, with poison on the data phase.
    task automatic ignored_write(input logic sel, input [1:0] trans, input [2:0] size,
                                 input [31:0] addr);
        hsel   <= sel;
        haddr  <= addr;
        htrans <= trans;
        hwrite <= 1'b1;
        hsize  <= size;
        @(posedge clk);
        hsel   <= 1'b0;
        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        hwdata <= 32'hBAD0_BAD0;
        @(posedge clk);
        hwdata <= GARBAGE;
    endtask

    // Random pipeline state and a byte-accurate reference model.
    logic [7:0]  model [0:32767];
    logic        p_valid = 1'b0;
    logic        p_write = 1'b0;
    logic [14:0] p_addr  = 15'h0;
    logic [2:0]  p_size  = SIZE_WORD;
    logic [31:0] p_wdata = 32'h0;

    function automatic [3:0] lane_mask(input [1:0] offset, input [2:0] size);
        case (size)
            SIZE_BYTE: lane_mask = 4'b0001 << offset;
            SIZE_HALF: lane_mask = offset[1] ? 4'b1100 : 4'b0011;
            default:   lane_mask = 4'b1111;
        endcase
    endfunction

    task automatic complete_pending;
        logic [3:0]  mask;
        logic [12:0] word;
        logic [31:0] want;
        logic [31:0] got;
        integer      i;
        if (p_valid) begin
            mask = lane_mask(p_addr[1:0], p_size);
            word = p_addr[14:2];
            got  = hrdata;
            for (i = 0; i < 4; i = i + 1) begin
                if (p_write) begin
                    if (mask[i]) model[{word, 2'b00} + i] = p_wdata[8*i +: 8];
                end else begin
                    want[8*i +: 8] = model[{word, 2'b00} + i];
                    if (!mask[i]) begin
                        want[8*i +: 8] = 8'h00;
                        got[8*i +: 8]  = 8'h00;
                    end
                end
            end
            if (!p_write) begin
                check_eq(got, want, $sformatf("random read %04h size %0d", p_addr, p_size));
            end
        end
    endtask

    // Half the pool sits at the top of memory, and each word is hit often enough
    // that write-then-read collisions occur.
    function automatic [14:0] pool_word(input [3:0] index);
        pool_word = {index[3] ? 10'h3FF : 10'h000, index[2:0], 2'b00};
    endfunction

    task automatic random_test;
        integer      n;
        integer      kind;
        integer      stall;
        logic [31:0] r;
        logic [14:0] addr;
        logic [2:0]  size;
        logic [31:0] wdata;
        logic        sel;
        logic        valid;
        logic        wr;

        for (n = 0; n < 16; n = n + 1) begin
            write({17'h0, pool_word(n[3:0])}, SIZE_WORD, 32'h0);
            model[pool_word(n[3:0]) + 0] = 8'h00;
            model[pool_word(n[3:0]) + 1] = 8'h00;
            model[pool_word(n[3:0]) + 2] = 8'h00;
            model[pool_word(n[3:0]) + 3] = 8'h00;
        end

        for (n = 0; n < RANDOM_OPS; n = n + 1) begin
            r     = $random(seed);
            kind  = r[3:0];
            addr  = pool_word(r[7:4]);
            wdata = $random(seed);
            case (r[9:8])
                2'd0: begin size = SIZE_BYTE; addr[1:0] = r[11:10]; end
                2'd1: begin size = SIZE_HALF; addr[1:0] = {r[10], 1'b0}; end
                default: size = SIZE_WORD;
            endcase

            valid = (kind != 15);
            sel   = (kind != 14); // Kind 14 is a transfer to another slave.
            wr    = (kind < 7);

            hsel   <= sel;
            haddr  <= {17'h0, addr};
            htrans <= valid ? (r[12] ? TRANS_SEQ : TRANS_NONSEQ) : TRANS_IDLE;
            hwrite <= wr;
            hsize  <= size;
            hwdata <= (p_valid && p_write) ? p_wdata : $random(seed);

            // Another slave can stall only when this SRAM has no data phase.
            stall = (!p_valid && r[14:13] == 2'd0) ? r[17:15] : 0;
            hready <= (stall == 0);
            repeat (stall) begin
                @(posedge clk);
                hwdata <= $random(seed);
            end
            hready <= 1'b1;

            @(posedge clk);
            complete_pending;

            p_valid = valid && sel;
            p_write = wr;
            p_addr  = addr;
            p_size  = size;
            p_wdata = wdata;
        end

        hsel   <= 1'b0;
        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        hwdata <= p_wdata;
        @(posedge clk);
        complete_pending;
        p_valid = 1'b0;
        hwdata <= GARBAGE;
    endtask

    logic [31:0] val;
    integer lane;
    integer addr_bit;

    initial begin
        $dumpfile("tb_ahb_sram.vcd");
        $dumpvars(0, tb_ahb_sram);

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        check_eq({31'h0, hreadyout}, 32'h1, "HREADYOUT is always high");
        check_eq({31'h0, hresp}, 32'h0, "HRESP is always OKAY");

        // Word round trip, and first and last words stay independent.
        write(32'h0000_0000, SIZE_WORD, 32'h1234_5678);
        write(LAST_WORD, SIZE_WORD, 32'h89AB_CDEF);
        read_word(32'h0000_0000, val);
        check_eq(val, 32'h1234_5678, "first word");
        read_word(LAST_WORD, val);
        check_eq(val, 32'h89AB_CDEF, "last word");

        // The base address offset is ignored: 0x2000_0000 is the same word.
        read_word(32'h2000_0000, val);
        check_eq(val, 32'h1234_5678, "upper address bits ignored");

        // Bytes: every lane, and the neighbouring words stay untouched.
        write(32'h0000_0FC, SIZE_WORD, 32'h1111_1111);
        write(32'h0000_100, SIZE_WORD, 32'h2222_2222);
        write(32'h0000_104, SIZE_WORD, 32'h3333_3333);
        for (lane = 0; lane < 4; lane = lane + 1) begin
            write(32'h0000_100, SIZE_WORD, 32'hAABB_CCDD);
            write(32'h0000_100 + lane, SIZE_BYTE, 32'h5A5A_5A5A);
            read_word(32'h0000_100, val);
            check_eq(val, (32'hAABB_CCDD & ~(32'hFF << (8*lane))) | (32'h5A << (8*lane)),
                     $sformatf("byte lane %0d", lane));
        end
        read_word(32'h0000_0FC, val);
        check_eq(val, 32'h1111_1111, "word below is unchanged");
        read_word(32'h0000_104, val);
        check_eq(val, 32'h3333_3333, "word above is unchanged");

        // Halfwords: lower and upper.
        write(32'h0000_200, SIZE_WORD, 32'hAABB_CCDD);
        write(32'h0000_200, SIZE_HALF, 32'h5A5A_1122);
        read_word(32'h0000_200, val);
        check_eq(val, 32'hAABB_1122, "halfword lower");
        write(32'h0000_202, SIZE_HALF, 32'h3344_5A5A);
        read_word(32'h0000_200, val);
        check_eq(val, 32'h3344_1122, "halfword upper");

        // Transfers that must not write.
        write(32'h0000_300, SIZE_WORD, 32'hC0DE_C0DE);
        ignored_write(1'b1, TRANS_IDLE,   SIZE_WORD, 32'h0000_300);
        read_word(32'h0000_300, val);
        check_eq(val, 32'hC0DE_C0DE, "IDLE does not write");
        ignored_write(1'b1, TRANS_BUSY,   SIZE_WORD, 32'h0000_300);
        read_word(32'h0000_300, val);
        check_eq(val, 32'hC0DE_C0DE, "BUSY does not write");
        ignored_write(1'b0, TRANS_NONSEQ, SIZE_WORD, 32'h0000_300);
        read_word(32'h0000_300, val);
        check_eq(val, 32'hC0DE_C0DE, "HSEL low does not write");
        ignored_write(1'b1, TRANS_NONSEQ, SIZE_DWRD, 32'h0000_300);
        read_word(32'h0000_300, val);
        check_eq(val, 32'hC0DE_C0DE, "size wider than the bus does not write");

        // A stalled write commits once, with data from its own data phase.
        write(32'h0000_400, SIZE_WORD, 32'h0BAD_F00D);
        hsel   <= 1'b1;
        haddr  <= 32'h0000_400;
        htrans <= TRANS_NONSEQ;
        hwrite <= 1'b1;
        hsize  <= SIZE_WORD;
        hready <= 1'b0;
        hwdata <= 32'h1111_0000;
        repeat (3) @(posedge clk);
        hready <= 1'b1;
        hwdata <= 32'h2222_0000;
        @(posedge clk);
        hsel   <= 1'b0;
        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        hwdata <= 32'h7E57_DA7A;
        @(posedge clk);
        hwdata <= GARBAGE;
        read_word(32'h0000_400, val);
        check_eq(val, 32'h7E57_DA7A, "stalled write uses its own data phase");

        // During a two-cycle ERROR the master may cancel a waiting transfer by
        // changing HTRANS to IDLE. HREADY is low, so nothing may be written.
        write(32'h0000_404, SIZE_WORD, 32'h600D_600D);
        hsel   <= 1'b1;
        haddr  <= 32'h0000_404;
        htrans <= TRANS_NONSEQ;
        hwrite <= 1'b1;
        hsize  <= SIZE_WORD;
        hready <= 1'b0;
        hwdata <= 32'hBAD0_BAD0;
        @(posedge clk);
        hsel   <= 1'b0;
        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        hready <= 1'b1;
        @(posedge clk);
        hwdata <= GARBAGE;
        read_word(32'h0000_404, val);
        check_eq(val, 32'h600D_600D, "cancelled write leaves memory unchanged");

        // A stalled read returns the right word after the stall.
        write(32'h0000_408, SIZE_WORD, 32'hFACE_B00C);
        write(32'h0000_40C, SIZE_WORD, 32'h0000_0000);
        read_word(32'h0000_40C, val);
        hsel   <= 1'b1;
        haddr  <= 32'h0000_408;
        htrans <= TRANS_NONSEQ;
        hwrite <= 1'b0;
        hsize  <= SIZE_WORD;
        hready <= 1'b0;
        repeat (3) @(posedge clk);
        hready <= 1'b1;
        @(posedge clk);
        hsel   <= 1'b0;
        htrans <= TRANS_IDLE;
        @(posedge clk);
        check_eq(hrdata, 32'hFACE_B00C, "read after a stalled address phase");

        // Forwarding: same word, word write.
        xfer(32'h0000_500, 1'b1, SIZE_WORD, 32'hCAFE_F00D);
        xfer(32'h0000_500, 1'b0, SIZE_WORD, 32'h0);
        flush;
        check_eq(last_rdata, 32'hCAFE_F00D, "forward word write");

        // Forwarding: each byte merges with the old data in memory.
        for (lane = 0; lane < 4; lane = lane + 1) begin
            write(32'h0000_500, SIZE_WORD, 32'hAABB_CCDD);
            xfer(32'h0000_500 + lane, 1'b1, SIZE_BYTE, 32'h5A5A_5A5A);
            xfer(32'h0000_500, 1'b0, SIZE_WORD, 32'h0);
            flush;
            check_eq(last_rdata, (32'hAABB_CCDD & ~(32'hFF << (8*lane))) | (32'h5A << (8*lane)),
                     $sformatf("forward byte lane %0d", lane));
        end

        // No forwarding when the words differ.
        write(32'h0000_510, SIZE_WORD, 32'h0102_0304);
        xfer(32'h0000_514, 1'b1, SIZE_WORD, 32'hFFFF_FFFF);
        xfer(32'h0000_510, 1'b0, SIZE_WORD, 32'h0);
        flush;
        check_eq(last_rdata, 32'h0102_0304, "different word is not forwarded");

        // Two reads after a write: the second must not reuse forwarded data.
        write(32'h0000_520, SIZE_WORD, 32'h1010_1010);
        write(32'h0000_524, SIZE_WORD, 32'h2020_2020);
        xfer(32'h0000_520, 1'b1, SIZE_WORD, 32'h3030_3030);
        xfer(32'h0000_520, 1'b0, SIZE_WORD, 32'h0);
        xfer(32'h0000_524, 1'b0, SIZE_WORD, 32'h0);
        check_eq(last_rdata, 32'h3030_3030, "first read is forwarded");
        flush;
        check_eq(last_rdata, 32'h2020_2020, "next read uses memory");

        // A read followed by a write: read data must not change with HWDATA.
        write(32'h0000_530, SIZE_WORD, 32'h4040_4040);
        xfer(32'h0000_530, 1'b0, SIZE_WORD, 32'h0);
        xfer(32'h0000_530, 1'b1, SIZE_WORD, 32'h5050_5050);
        check_eq(last_rdata, 32'h4040_4040, "read before a write gets old data");
        flush;
        read_word(32'h0000_530, val);
        check_eq(val, 32'h5050_5050, "write after a read commits");

        // Walking-one address test: every word address bit must select a distinct
        // word. The random pool below cannot see these aliases, because bits 14:5
        // only ever take all-zero or all-one values there.
        write(32'h0000_0000, SIZE_WORD, 32'hA000_0000);
        for (addr_bit = 2; addr_bit < 15; addr_bit = addr_bit + 1) begin
            write(32'h1 << addr_bit, SIZE_WORD, 32'hA000_0000 + addr_bit);
        end
        read_word(32'h0000_0000, val);
        check_eq(val, 32'hA000_0000, "walking address: word 0");
        for (addr_bit = 2; addr_bit < 15; addr_bit = addr_bit + 1) begin
            read_word(32'h1 << addr_bit, val);
            check_eq(val, 32'hA000_0000 + addr_bit,
                     $sformatf("walking address: bit %0d", addr_bit));
        end

        // Random pipeline against the reference model.
        random_test;

        check_eq({31'h0, hresp}, 32'h0, "HRESP stays OKAY");

        $display("RESULT: %0d checks, %0d failures", checks, failures);
        if (failures != 0) $fatal(1, "[TB_AHB_SRAM] SRAM verification failed");
        $display("PASS: AHB SRAM directed and random tests");
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "[TB_AHB_SRAM] ERROR: Simulation Timeout!");
    end

endmodule
