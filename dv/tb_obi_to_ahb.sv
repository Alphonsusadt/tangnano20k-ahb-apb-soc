// ==============================================================================
// Testbench: tb_obi_to_ahb
// Description: Random traffic on both OBI ports against an AHB-Lite slave model with
//              wait states and two-cycle ERROR responses. A reference memory, updated
//              in grant order, predicts every response. A monitor checks AHB address
//              stability, data port priority, and response ordering.
// ==============================================================================

`timescale 1ns/1ps

module tb_obi_to_ahb;

    localparam int MEM_WORDS  = 256;
    localparam int ERR_WORD   = 240; // Word indexes from here up answer ERROR
    localparam int FIFO_DEPTH = 16;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    // Instruction port
    logic        instr_req = 1'b0;
    logic [31:0] instr_addr = 32'h0;
    wire         instr_gnt, instr_rvalid, instr_err;
    wire [31:0]  instr_rdata;

    // Data port
    logic        data_req = 1'b0;
    logic        data_we = 1'b0;
    logic [3:0]  data_be = 4'h0;
    logic [31:0] data_addr = 32'h0;
    logic [31:0] data_wdata = 32'h0;
    wire         data_gnt, data_rvalid, data_err;
    wire [31:0]  data_rdata;

    // AHB
    wire [31:0]  haddr, hwdata;
    wire [1:0]   htrans;
    wire         hwrite;
    wire [2:0]   hsize;
    reg  [31:0]  hrdata;
    reg          hready;
    reg          hresp;

    obi_to_ahb_adapter u_dut (
        .hclk           (clk),
        .hreset_n       (rst_n),
        .instr_req_i    (instr_req),
        .instr_gnt_o    (instr_gnt),
        .instr_rvalid_o (instr_rvalid),
        .instr_addr_i   (instr_addr),
        .instr_rdata_o  (instr_rdata),
        .instr_err_o    (instr_err),
        .data_req_i     (data_req),
        .data_gnt_o     (data_gnt),
        .data_rvalid_o  (data_rvalid),
        .data_we_i      (data_we),
        .data_be_i      (data_be),
        .data_addr_i    (data_addr),
        .data_wdata_i   (data_wdata),
        .data_rdata_o   (data_rdata),
        .data_err_o     (data_err),
        .haddr          (haddr),
        .htrans         (htrans),
        .hwrite         (hwrite),
        .hsize          (hsize),
        .hwdata         (hwdata),
        .hrdata         (hrdata),
        .hready         (hready),
        .hresp          (hresp)
    );

    integer checks = 0;
    integer failures = 0;

    task automatic check(input string name, input logic ok);
        checks++;
        if (ok !== 1'b1) begin
            failures++;
            if (failures <= 20) $display("FAIL [%0t] %s", $time, name);
        end
    endtask

    // Test settings, changed between phases
    integer max_wait = 0;
    integer zero_wait_pct = 100;
    integer req_pct = 100;
    integer target = 0;

    // --------------------------------------------------------------------------
    // AHB-Lite slave model
    // --------------------------------------------------------------------------
    logic [31:0] mem [0:MEM_WORDS-1];
    logic        dp_valid = 1'b0;
    logic        dp_write = 1'b0;
    logic [31:0] dp_addr = 32'h0;
    logic [2:0]  dp_size = 3'b0;
    integer      dp_wait = 0;
    logic        dp_err_second = 1'b0;

    function automatic integer word_index(input [31:0] addr);
        return addr[9:2];
    endfunction

    wire dp_is_err = dp_valid && (word_index(dp_addr) >= ERR_WORD);

    always @(*) begin
        hready = 1'b1;
        hresp  = 1'b0;
        hrdata = 32'hxxxx_xxxx;
        if (dp_valid) begin
            if (dp_wait > 0) begin
                hready = 1'b0;
            end else if (dp_is_err) begin
                hresp  = 1'b1;
                hready = dp_err_second;
            end else if (!dp_write) begin
                hrdata = mem[word_index(dp_addr)];
            end
        end
    end

    function automatic [3:0] size_strobes(input [2:0] size, input [1:0] offset);
        case (size)
            3'b000:  return 4'b0001 << offset;
            3'b001:  return 4'b0011 << offset;
            default: return 4'b1111;
        endcase
    endfunction

    function automatic integer pick_wait();
        if (max_wait == 0 || ($urandom % 100) < zero_wait_pct) return 0;
        return 1 + ($urandom % max_wait);
    endfunction

    always @(posedge clk) begin
        if (dp_valid && !hready) begin
            if (dp_wait > 0) dp_wait <= dp_wait - 1;
            else if (dp_is_err) dp_err_second <= 1'b1;
        end

        if (hready) begin
            // Complete the current data phase, using only the lanes HSIZE selects.
            if (dp_valid && dp_write && !dp_is_err) begin
                logic [3:0] strb;
                strb = size_strobes(dp_size, dp_addr[1:0]);
                for (int i = 0; i < 4; i++) begin
                    if (strb[i]) mem[word_index(dp_addr)][8*i +: 8] <= hwdata[8*i +: 8];
                end
            end
            // Accept the next address phase.
            dp_valid      <= (htrans == 2'b10);
            dp_write      <= hwrite;
            dp_addr       <= haddr;
            dp_size       <= hsize;
            dp_wait       <= (htrans == 2'b10) ? pick_wait() : 0;
            dp_err_second <= 1'b0;
        end
    end

    // --------------------------------------------------------------------------
    // Reference model and scoreboards
    // --------------------------------------------------------------------------
    logic [31:0] ref_mem [0:MEM_WORDS-1];

    logic [31:0] i_exp_data [0:FIFO_DEPTH-1];
    logic        i_exp_err  [0:FIFO_DEPTH-1];
    integer      i_head = 0, i_tail = 0, i_sent = 0;

    logic [31:0] d_exp_data [0:FIFO_DEPTH-1];
    logic [3:0]  d_exp_mask [0:FIFO_DEPTH-1];
    logic        d_exp_err  [0:FIFO_DEPTH-1];
    logic        d_exp_rd   [0:FIFO_DEPTH-1];
    integer      d_head = 0, d_tail = 0, d_sent = 0;

    function automatic logic legal_be(input [3:0] be);
        case (be)
            4'b0001, 4'b0010, 4'b0100, 4'b1000, 4'b0011, 4'b1100, 4'b1111: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    function automatic [31:0] random_addr();
        // Mostly valid words, sometimes in the ERROR region.
        integer word;
        word = (($urandom % 100) < 8) ? ERR_WORD + ($urandom % (MEM_WORDS - ERR_WORD))
                                      : ($urandom % ERR_WORD);
        return 32'h1000_0000 + (word << 2);
    endfunction

    function automatic [3:0] random_be(input logic write);
        integer pick;
        pick = $urandom % 100;
        if (!write) return 1 + ($urandom % 15);
        if (pick < 8) return 4'b0110 + ($urandom % 2) * 4'b1000; // 0110 or 1110
        if (pick < 12) return 4'b0111;
        if (pick < 14) return 4'b0000;
        case ($urandom % 7)
            0: return 4'b0001;
            1: return 4'b0010;
            2: return 4'b0100;
            3: return 4'b1000;
            4: return 4'b0011;
            5: return 4'b1100;
            default: return 4'b1111;
        endcase
    endfunction

    // Coverage counters, so a quiet test cannot pass by never reaching a case.
    integer cov_refused = 0, cov_ahb_err = 0, cov_i_err = 0, cov_lock_preempt = 0;
    integer cov_both_req = 0, cov_stalled = 0, cov_writes = 0, cov_reads = 0;

    // Instruction master
    always @(posedge clk) begin
        if (rst_n) begin
            if (instr_rvalid) begin
                check("Instruction response has a request", i_head != i_tail);
                if (i_head != i_tail) begin
                    check("Instruction error flag", instr_err === i_exp_err[i_head % FIFO_DEPTH]);
                    if (!i_exp_err[i_head % FIFO_DEPTH]) begin
                        check("Instruction data", instr_rdata === i_exp_data[i_head % FIFO_DEPTH]);
                    end else begin
                        cov_i_err++;
                    end
                    i_head++;
                end
            end

            if (instr_req && instr_gnt) begin
                integer w;
                w = word_index(instr_addr);
                i_exp_err[i_tail % FIFO_DEPTH]  = (w >= ERR_WORD);
                i_exp_data[i_tail % FIFO_DEPTH] = ref_mem[w];
                i_tail++;
                i_sent++;
            end

            if (!instr_req || instr_gnt) begin
                if (i_sent < target && (i_tail - i_head) < FIFO_DEPTH - 1 && ($urandom % 100) < req_pct) begin
                    instr_req  <= 1'b1;
                    instr_addr <= random_addr();
                end else begin
                    instr_req  <= 1'b0;
                end
            end
        end
    end

    // Data master
    always @(posedge clk) begin
        if (rst_n) begin
            if (data_rvalid) begin
                check("Data response has a request", d_head != d_tail);
                if (d_head != d_tail) begin
                    integer h;
                    h = d_head % FIFO_DEPTH;
                    check("Data error flag", data_err === d_exp_err[h]);
                    if (!d_exp_err[h] && d_exp_rd[h]) begin
                        for (int i = 0; i < 4; i++) begin
                            if (d_exp_mask[h][i]) begin
                                check("Data read lane", data_rdata[8*i +: 8] === d_exp_data[h][8*i +: 8]);
                            end
                        end
                    end
                    d_head++;
                end
            end

            if (data_req && data_gnt) begin
                integer w, t;
                logic   refused;
                w = word_index(data_addr);
                t = d_tail % FIFO_DEPTH;
                refused = data_we && !legal_be(data_be);
                d_exp_err[t]  = refused || (w >= ERR_WORD);
                d_exp_rd[t]   = !data_we;
                d_exp_mask[t] = data_be;
                d_exp_data[t] = ref_mem[w];
                if (refused) cov_refused++;
                if (w >= ERR_WORD && !refused) cov_ahb_err++;
                if (data_we) cov_writes++; else cov_reads++;
                if (data_we && !refused && w < ERR_WORD) begin
                    for (int i = 0; i < 4; i++) begin
                        if (data_be[i]) ref_mem[w][8*i +: 8] = data_wdata[8*i +: 8];
                    end
                end
                d_tail++;
                d_sent++;
            end

            if (!data_req || data_gnt) begin
                if (d_sent < target && (d_tail - d_head) < FIFO_DEPTH - 1 && ($urandom % 100) < req_pct) begin
                    logic we;
                    we = $urandom % 2;
                    data_req   <= 1'b1;
                    data_we    <= we;
                    data_be    <= random_be(we);
                    data_addr  <= random_addr();
                    data_wdata <= $urandom; // Disabled lanes carry junk on purpose.
                end else begin
                    data_req   <= 1'b0;
                end
            end
        end
    end

    // --------------------------------------------------------------------------
    // Protocol monitor
    // --------------------------------------------------------------------------
    logic        prev_stalled = 1'b0;
    logic [31:0] prev_haddr;
    logic [1:0]  prev_htrans;
    logic        prev_hwrite;
    logic [2:0]  prev_hsize;
    logic        prev_owner_data;

    always @(posedge clk) begin
        if (rst_n) begin
            check("HTRANS is IDLE or NONSEQ", htrans === 2'b00 || htrans === 2'b10);
            check("At most one grant", !(instr_gnt && data_gnt));
            check("Instruction grant needs a request", !instr_gnt || instr_req);
            check("Data grant needs a request", !data_gnt || data_req);
            check("Grant needs HREADY", !(instr_gnt || data_gnt) || hready);
            check("At most one response", !(instr_rvalid && data_rvalid));

            if (htrans === 2'b10) begin
                check("HSIZE is byte, halfword, or word", hsize <= 3'b010);
                check("Address is aligned to HSIZE",
                      (hsize == 3'b000) ||
                      (hsize == 3'b001 && haddr[0] == 1'b0) ||
                      (hsize == 3'b010 && haddr[1:0] == 2'b00));
            end

            if (prev_stalled) begin
                cov_stalled++;
                check("Stalled HTRANS stays", htrans === prev_htrans);
                check("Stalled HADDR stays", haddr === prev_haddr);
                check("Stalled HWRITE stays", hwrite === prev_hwrite);
                check("Stalled HSIZE stays", hsize === prev_hsize);
                if (!prev_owner_data && data_req) cov_lock_preempt++;
            end

            if (!prev_stalled && instr_req && data_req && hready) begin
                cov_both_req++;
                check("Data port wins arbitration", data_gnt && !instr_gnt);
            end

            prev_stalled    = (htrans === 2'b10) && (hready === 1'b0);
            prev_haddr      = haddr;
            prev_htrans     = htrans;
            prev_hwrite     = hwrite;
            prev_hsize      = hsize;
            prev_owner_data = u_dut.owner_data;
        end
    end

    // --------------------------------------------------------------------------
    // Test sequence
    // --------------------------------------------------------------------------
    task automatic run_phase(input string name, input integer count, input integer wait_max,
                             input integer zero_pct, input integer req);
        integer guard = 0;
        max_wait      = wait_max;
        zero_wait_pct = zero_pct;
        req_pct       = req;
        i_sent        = 0;
        d_sent        = 0;
        target        = count;
        while ((i_sent < count || d_sent < count || i_head != i_tail || d_head != d_tail ||
                instr_req || data_req) && guard < count * 60) begin
            @(posedge clk);
            guard++;
        end
        check({name, ": all requests finished"}, guard < count * 60);
        target = 0;
        repeat (20) @(posedge clk);
        check({name, ": bus is idle"}, htrans === 2'b00);
    endtask

    integer mem_mismatches = 0;

    initial begin
        for (int i = 0; i < MEM_WORDS; i++) begin
            mem[i]     = 32'hA5A5_0000 ^ (i * 32'h0101_0101);
            ref_mem[i] = mem[i];
        end

        repeat (5) @(posedge clk);
        check("HTRANS is IDLE in reset", htrans === 2'b00);
        check("No response in reset", instr_rvalid === 1'b0 && data_rvalid === 1'b0);
        @(negedge clk);
        rst_n = 1'b1;

        run_phase("No wait, full load",     5000, 0,   0, 100);
        run_phase("No wait, light load",    5000, 0,   0,  40);
        run_phase("Short waits, full load", 5000, 2,  50, 100);
        run_phase("Long waits, full load",  5000, 7,  30, 100);
        run_phase("Long waits, light load", 5000, 7,  30,  30);

        for (int i = 0; i < ERR_WORD; i++) begin
            if (mem[i] !== ref_mem[i]) mem_mismatches++;
        end
        check("Slave memory matches the reference", mem_mismatches == 0);

        // A test that never reached these cases proves nothing about them.
        check("Covered: refused writes", cov_refused > 100);
        check("Covered: AHB errors on data", cov_ahb_err > 100);
        check("Covered: AHB errors on instructions", cov_i_err > 100);
        check("Covered: data request during a stalled instruction", cov_lock_preempt > 100);
        check("Covered: both ports requesting", cov_both_req > 100);
        check("Covered: stalled address phases", cov_stalled > 100);
        check("Covered: reads and writes", cov_reads > 1000 && cov_writes > 1000);

        $display("Coverage: refused=%0d ahb_err=%0d instr_err=%0d lock_preempt=%0d both=%0d stalled=%0d reads=%0d writes=%0d",
                 cov_refused, cov_ahb_err, cov_i_err, cov_lock_preempt, cov_both_req, cov_stalled,
                 cov_reads, cov_writes);
        $display("RESULT: %0d checks, %0d failures", checks, failures);
        $finish;
    end

    initial begin
        #50ms;
        $display("RESULT: FATAL timeout, %0d checks, %0d failures", checks, failures);
        $finish;
    end

endmodule
