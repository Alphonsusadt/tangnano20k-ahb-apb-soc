// ==============================================================================
// Module: ahb_interconnect
// Description: AHB-Lite Address Decoder & Multiplexer
// ==============================================================================

module ahb_interconnect (
    input  wire        hclk,
    input  wire        hreset_n,

    // AHB-Lite Master Interface (From CPU)
    input  wire [31:0] s_haddr,
    input  wire [1:0]  s_htrans,
    input  wire        s_hwrite,
    input  wire [2:0]  s_hsize,
    input  wire [2:0]  s_hburst,
    input  wire [3:0]  s_hprot,
    input  wire [31:0] s_hwdata,
    output reg  [31:0] s_hrdata,
    output reg         s_hready,
    output reg         s_hresp,

    // AHB Slave 0: Instruction ROM (0x0000_0000 - 0x0000_7FFF)
    output wire        m0_hsel,
    output wire [31:0] m0_haddr,
    output wire [1:0]  m0_htrans,
    output wire        m0_hwrite,
    output wire [2:0]  m0_hsize,
    output wire [31:0] m0_hwdata,
    input  wire [31:0] m0_hrdata,
    input  wire        m0_hready,
    input  wire        m0_hresp,

    // AHB Slave 1: Data SRAM (0x2000_0000 - 0x2000_7FFF)
    output wire        m1_hsel,
    output wire [31:0] m1_haddr,
    output wire [1:0]  m1_htrans,
    output wire        m1_hwrite,
    output wire [2:0]  m1_hsize,
    output wire [31:0] m1_hwdata,
    input  wire [31:0] m1_hrdata,
    input  wire        m1_hready,
    input  wire        m1_hresp,

    // AHB Slave 2: AHB-to-APB Bridge (0x4000_0000 - 0x4FFF_FFFF)
    output wire        m2_hsel,
    output wire [31:0] m2_haddr,
    output wire [1:0]  m2_htrans,
    output wire        m2_hwrite,
    output wire [2:0]  m2_hsize,
    output wire [31:0] m2_hwdata,
    input  wire [31:0] m2_hrdata,
    input  wire        m2_hready,
    input  wire        m2_hresp
);

    // Address phase decoding
    wire sel_imem = (s_haddr[31:16] == 16'h0000); // 0x0000_xxxx
    wire sel_dmem = (s_haddr[31:16] == 16'h2000); // 0x2000_xxxx
    wire sel_apb  = (s_haddr[31:28] == 4'h4);     // 0x4xxx_xxxx

    assign m0_hsel = sel_imem;
    assign m1_hsel = sel_dmem;
    assign m2_hsel = sel_apb;

    // Shared signals to slaves
    assign m0_haddr  = s_haddr;
    assign m0_htrans = s_htrans;
    assign m0_hwrite = s_hwrite;
    assign m0_hsize  = s_hsize;
    assign m0_hwdata = s_hwdata;

    assign m1_haddr  = s_haddr;
    assign m1_htrans = s_htrans;
    assign m1_hwrite = s_hwrite;
    assign m1_hsize  = s_hsize;
    assign m1_hwdata = s_hwdata;

    assign m2_haddr  = s_haddr;
    assign m2_htrans = s_htrans;
    assign m2_hwrite = s_hwrite;
    assign m2_hsize  = s_hsize;
    assign m2_hwdata = s_hwdata;

    // Registered slave select for data phase multiplexing
    reg [2:0] sel_q;
    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            sel_q <= 3'b000;
        end else if (s_hready) begin
            sel_q <= {sel_apb, sel_dmem, sel_imem};
        end
    end

    // Read Data and Ready multiplexing
    always @(*) begin
        case (sel_q)
            3'b001: begin
                s_hrdata = m0_hrdata;
                s_hready = m0_hready;
                s_hresp  = m0_hresp;
            end
            3'b010: begin
                s_hrdata = m1_hrdata;
                s_hready = m1_hready;
                s_hresp  = m1_hresp;
            end
            3'b100: begin
                s_hrdata = m2_hrdata;
                s_hready = m2_hready;
                s_hresp  = m2_hresp;
            end
            default: begin
                s_hrdata = 32'h0;
                s_hready = 1'b1;
                s_hresp  = 1'b0;
            end
        endcase
    end

endmodule
