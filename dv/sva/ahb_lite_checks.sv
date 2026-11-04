// ==============================================================================
// Module: ahb_lite_checks
// Description: Assertions for the AHB-Lite bus between the CPU and the interconnect.
//              dv/sva/soc_top_checks_bind.sv attaches it to soc_top, so the RTL does
//              not change. Simulation-only: the FPGA build never reads this folder.
//
// The counters show how often each rule was exercised. A rule whose condition never
// happened passes without proving anything, so the final report prints them.
// ==============================================================================

module ahb_lite_checks (
    input wire        hclk,
    input wire        hreset_n,
    input wire [31:0] haddr,
    input wire [1:0]  htrans,
    input wire        hwrite,
    input wire [2:0]  hsize,
    input wire [31:0] hwdata,
    input wire        hready,
    input wire        hresp
);

    localparam [1:0] TRANS_IDLE = 2'b00, TRANS_NONSEQ = 2'b10;
    localparam [2:0] SIZE_BYTE = 3'b000, SIZE_HALF = 3'b001, SIZE_WORD = 3'b010;

    wire active = htrans[1];
    wire accept = active && hready;

    // A transfer enters its data phase when HREADY accepts its address phase.
    reg dp_valid_q;
    reg dp_write_q;
    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            dp_valid_q <= 1'b0;
            dp_write_q <= 1'b0;
        end else if (hready) begin
            dp_valid_q <= active;
            dp_write_q <= active && hwrite;
        end
    end

    wire is_rom      = (haddr[31:15] == 17'h00000);
    wire is_sram     = (haddr[31:15] == 17'h04000);
    wire is_apb      = (haddr[31:28] == 4'h4);
    wire is_unmapped = !(is_rom || is_sram || is_apb);

    wire aligned = (hsize == SIZE_BYTE) ||
                   (hsize == SIZE_HALF && haddr[0] == 1'b0) ||
                   (hsize == SIZE_WORD && haddr[1:0] == 2'b00);

    wire addr_wait = active && !hready && !hresp;
    wire data_wait = dp_write_q && !hready;
    wire err_first = hresp && !hready;
    wire err_last  = hresp && hready;

    // ERROR takes two cycles: HREADY low, so the master can cancel the transfer already
    // in its address phase, and then HREADY high to end the failed transfer.
    a_error_first_then_last: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        err_first |=> err_last
    ) else $error("ERROR with HREADY low was not followed by ERROR with HREADY high");

    a_error_last_after_first: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        err_last |-> $past(err_first)
    ) else $error("ERROR with HREADY high had no first cycle, too late to cancel");

    // No transfer in the data phase means a zero-wait OKAY.
    a_idle_is_zero_wait_okay: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        !dp_valid_q |-> (hready && !hresp)
    ) else $error("Data phase of IDLE did not return a zero-wait OKAY");

    // A stalled address phase must hold, because the slave has not accepted it yet. The
    // first ERROR cycle is excluded, because the master may cancel there.
    a_addr_stable_in_wait: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        addr_wait |=> ($stable(haddr) && $stable(htrans) && $stable(hwrite) && $stable(hsize))
    ) else $error("Address or control changed while the address phase was stalled");

    a_wdata_stable_in_wait: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        data_wait |=> $stable(hwdata)
    ) else $error("HWDATA changed while the write data phase was stalled");

    // This master issues single transfers only, so BUSY and SEQ never appear.
    a_single_transfers_only: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        (htrans == TRANS_IDLE) || (htrans == TRANS_NONSEQ)
    ) else $error("HTRANS is BUSY or SEQ, but this master issues single transfers");

    a_size_and_alignment: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        active |-> aligned
    ) else $error("Transfer has an illegal HSIZE, or HADDR is not aligned to HSIZE");

    // Memory map rules, from docs/memory_map.md.
    a_unmapped_gets_error: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        (accept && is_unmapped) |=> err_first
    ) else $error("Accepted transfer to an unmapped address did not start ERROR");

    a_rom_write_gets_error: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        (accept && is_rom && hwrite) |=> err_first
    ) else $error("Accepted write to ROM did not start ERROR");

    // Exercise counters for the final report.
    integer n_accept = 0, n_addr_wait = 0, n_data_wait = 0, n_error = 0;
    integer n_unmapped = 0, n_rom_write = 0, n_idle = 0;
    always @(posedge hclk) begin
        if (hreset_n) begin
            if (accept)                         n_accept    <= n_accept + 1;
            if (addr_wait)                      n_addr_wait <= n_addr_wait + 1;
            if (data_wait)                      n_data_wait <= n_data_wait + 1;
            if (err_first)                      n_error     <= n_error + 1;
            if (accept && is_unmapped)          n_unmapped  <= n_unmapped + 1;
            if (accept && is_rom && hwrite)     n_rom_write <= n_rom_write + 1;
            if (!dp_valid_q)                    n_idle      <= n_idle + 1;
        end
    end

    final begin
        $display("SVA: accepted=%0d addr_wait=%0d data_wait=%0d error=%0d unmapped=%0d rom_write=%0d idle=%0d",
                 n_accept, n_addr_wait, n_data_wait, n_error, n_unmapped, n_rom_write, n_idle);
    end

endmodule
