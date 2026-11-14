// ==============================================================================
// Module: ahb_rom
// Description: Zero-wait-state AHB-Lite instruction ROM, loaded from a hex image.
//
// Timing:
//   - A read is accepted when HSEL, HTRANS[1], and HREADY are high, and its word is
//     ready in the next cycle. Reads have no side effects, so sampling the address
//     only on acceptance is not needed for correctness; it is done so the ROM
//     follows the same rule as the SRAM and never reacts to a transfer the master
//     may still cancel behind a stalled slave.
//   - An accepted write answers with a two-cycle ERROR and leaves the contents
//     alone, for every HSIZE. The CPU takes it as a store fault.
// ==============================================================================

module ahb_rom #(
    parameter ADDR_WIDTH = 15,     // Byte address bits: 15 = 32 KB
    parameter HEX_FILE   = ""      // $readmemh image, one 32-bit word per line
)(
    input  wire        hclk,
    input  wire        hreset_n,

    input  wire        hsel,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire        hready,     // Global bus HREADY from the interconnect

    output logic [31:0] hrdata,
    output wire         hreadyout,
    output wire         hresp
);

    localparam INDEX_WIDTH = ADDR_WIDTH - 2;
    localparam DEPTH       = 2 ** INDEX_WIDTH;

    logic [31:0] mem [0:DEPTH-1];
    initial begin
        if (HEX_FILE != "") begin
            $readmemh(HEX_FILE, mem);
        end
    end

    wire access = hsel && htrans[1] && hready;

    always_ff @(posedge hclk) begin
        if (access && !hwrite) begin
            hrdata <= mem[haddr[ADDR_WIDTH-1:2]];
        end
    end

    // First ERROR cycle holds HREADY low so the master can cancel the transfer it has
    // already placed on the bus; the second cycle ends the failed write.
    logic err_first_q;
    logic err_second_q;

    always_ff @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            err_first_q  <= 1'b0;
            err_second_q <= 1'b0;
        end else begin
            err_first_q  <= access && hwrite;
            err_second_q <= err_first_q;
        end
    end

    assign hreadyout = !err_first_q;
    assign hresp     = err_first_q || err_second_q;

endmodule
