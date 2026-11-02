// ==============================================================================
// Module: ahb_sram
// Description: Zero-wait-state AHB-Lite SRAM with byte and halfword writes.
//
// Timing:
//   - The address phase is captured when HSEL, HTRANS[1], and HREADY are high.
//   - A write commits one cycle later, in its data phase, when HWDATA is valid.
//   - A read samples memory in its address phase, so data is ready next cycle.
//
// A write's data phase can overlap the next read's address phase, so the memory
// uses separate read and write addresses. If both hit the same word, the written
// bytes are forwarded because the memory output still holds the old data.
//
// The master must issue aligned transfers. AHB-Lite does not allow unaligned ones.
// ==============================================================================

module ahb_sram #(
    parameter ADDR_WIDTH = 15 // Byte address bits: 15 = 32 KB
)(
    input  wire        hclk,
    input  wire        hreset_n,

    input  wire        hsel,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [31:0] hwdata,
    input  wire        hready,     // Global bus HREADY from the interconnect

    output wire [31:0] hrdata,
    output wire        hreadyout,
    output wire        hresp
);

    localparam INDEX_WIDTH = ADDR_WIDTH - 2;
    localparam DEPTH       = 2 ** INDEX_WIDTH;

    assign hreadyout = 1'b1;
    assign hresp     = 1'b0;

    // Without HREADY, a transfer waiting behind a slower slave would be accepted
    // early, even though the master may still cancel it after an ERROR response.
    wire                   access    = hsel && htrans[1] && hready;
    wire [INDEX_WIDTH-1:0] addr_word = haddr[ADDR_WIDTH-1:2];

    // Sizes wider than this 32-bit bus write nothing. A continuous assignment is
    // evaluated at time 0, unlike always @(*) when its inputs never change.
    wire [3:0] addr_strb = (hsize == 3'b000) ? (4'b0001 << haddr[1:0]) :
                           (hsize == 3'b001) ? (haddr[1] ? 4'b1100 : 4'b0011) :
                           (hsize == 3'b010) ? 4'b1111 : 4'b0000;

    // Address phase state, used by the following data phase.
    reg [3:0]             wr_strb_q;
    reg [INDEX_WIDTH-1:0] wr_word_q;

    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            wr_strb_q <= 4'b0000;
            wr_word_q <= {INDEX_WIDTH{1'b0}};
        end else begin
            wr_strb_q <= (access && hwrite) ? addr_strb : 4'b0000;
            wr_word_q <= addr_word; // Used only while wr_strb_q is non-zero
        end
    end

    // Read-after-write forwarding. The result is used only in the read's data
    // phase, which is always the next cycle because this slave never stalls.
    wire       read_en = access && !hwrite;
    reg [3:0]  fwd_strb_q;
    reg [31:0] fwd_data_q;

    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            fwd_strb_q <= 4'b0000;
            fwd_data_q <= 32'h0;
        end else begin
            fwd_strb_q <= (wr_word_q == addr_word) ? wr_strb_q : 4'b0000;
            fwd_data_q <= hwdata;
        end
    end

    // One 8-bit memory per byte lane, so each lane has its own write enable.
    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_lane
            reg [7:0] mem [0:DEPTH-1];
            reg [7:0] rdata_q;

            always @(posedge hclk) begin
                if (wr_strb_q[lane]) begin
                    mem[wr_word_q] <= hwdata[8*lane +: 8];
                end
                if (read_en) begin
                    rdata_q <= mem[addr_word];
                end
            end

            assign hrdata[8*lane +: 8] = fwd_strb_q[lane] ? fwd_data_q[8*lane +: 8]
                                                          : rdata_q;
        end
    endgenerate

endmodule
