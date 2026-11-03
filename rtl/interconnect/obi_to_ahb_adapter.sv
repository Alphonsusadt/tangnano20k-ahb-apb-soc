// ==============================================================================
// Module: obi_to_ahb_adapter
// Description: Connects the Ibex instruction and data OBI ports to one AHB-Lite
//              master port. The data port has priority.
//
// A grant is the accepted AHB address phase, and rvalid is the completed data phase.
// Once an address phase stalls on HREADY the owner is locked, because AHB requires
// the address to stay stable until the slave accepts it.
//
// Reads are always aligned word reads, and the core selects its own byte lanes.
// Writes map byte enables onto HSIZE and the low address bits. AHB-Lite has no byte
// strobes, so a write that is not one aligned byte, halfword, or word cannot be
// expressed. It gets an error response and never reaches the bus.
// ==============================================================================

module obi_to_ahb_adapter (
    input  wire        hclk,
    input  wire        hreset_n,

    // Instruction port
    input  wire        instr_req_i,
    output wire        instr_gnt_o,
    output wire        instr_rvalid_o,
    input  wire [31:0] instr_addr_i,
    output wire [31:0] instr_rdata_o,
    output wire        instr_err_o,

    // Data port
    input  wire        data_req_i,
    output wire        data_gnt_o,
    output wire        data_rvalid_o,
    input  wire        data_we_i,
    input  wire [3:0]  data_be_i,
    input  wire [31:0] data_addr_i,
    input  wire [31:0] data_wdata_i,
    output wire [31:0] data_rdata_o,
    output wire        data_err_o,

    // AHB-Lite master port
    output wire [31:0] haddr,
    output wire [1:0]  htrans,
    output wire        hwrite,
    output wire [2:0]  hsize,
    output wire [31:0] hwdata,
    input  wire [31:0] hrdata,
    input  wire        hready,
    input  wire        hresp
);

    localparam [1:0] TRANS_IDLE = 2'b00, TRANS_NONSEQ = 2'b10;
    localparam [2:0] SIZE_BYTE = 3'b000, SIZE_HALF = 3'b001, SIZE_WORD = 3'b010;

    // Registered state
    reg        addr_stalled_q; // The last address phase was not accepted
    reg        owner_data_q;   // Owner of that address phase
    reg        dp_valid_q;     // A request is in its data phase
    reg        dp_data_q;      // That request belongs to the data port
    reg        dp_local_err_q; // That request was refused here, with no AHB transfer
    reg [31:0] hwdata_q;

    // Arbitration
    wire owner_data = addr_stalled_q ? owner_data_q : data_req_i;
    wire owner_req  = owner_data ? data_req_i : instr_req_i;

    // Write byte enables
    reg       write_legal;
    reg [1:0] write_offset;
    reg [2:0] write_size;

    always @(*) begin
        write_legal  = 1'b1;
        write_offset = 2'd0;
        write_size   = SIZE_WORD;
        case (data_be_i)
            4'b0001: begin write_offset = 2'd0; write_size = SIZE_BYTE; end
            4'b0010: begin write_offset = 2'd1; write_size = SIZE_BYTE; end
            4'b0100: begin write_offset = 2'd2; write_size = SIZE_BYTE; end
            4'b1000: begin write_offset = 2'd3; write_size = SIZE_BYTE; end
            4'b0011: begin write_offset = 2'd0; write_size = SIZE_HALF; end
            4'b1100: begin write_offset = 2'd2; write_size = SIZE_HALF; end
            4'b1111: begin write_offset = 2'd0; write_size = SIZE_WORD; end
            default: write_legal = 1'b0;
        endcase
    end

    wire is_data_write = owner_data && data_we_i;
    wire refuse_write  = is_data_write && !write_legal;
    wire accept        = owner_req && hready;

    // Address phase
    assign htrans = (owner_req && !refuse_write) ? TRANS_NONSEQ : TRANS_IDLE;
    assign hwrite = is_data_write;
    assign hsize  = is_data_write ? write_size : SIZE_WORD;
    assign haddr  = !owner_data    ? {instr_addr_i[31:2], 2'b00} :
                    is_data_write  ? {data_addr_i[31:2], write_offset} :
                                     {data_addr_i[31:2], 2'b00};

    assign instr_gnt_o = accept && !owner_data;
    assign data_gnt_o  = accept && owner_data;

    // Data phase
    wire dp_done = dp_valid_q && hready;
    wire dp_err  = dp_local_err_q || hresp;

    assign hwdata = hwdata_q;

    assign instr_rvalid_o = dp_done && !dp_data_q;
    assign instr_rdata_o  = hrdata;
    assign instr_err_o    = dp_err;

    assign data_rvalid_o  = dp_done && dp_data_q;
    assign data_rdata_o   = hrdata;
    assign data_err_o     = dp_err;

    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            addr_stalled_q <= 1'b0;
            owner_data_q   <= 1'b0;
            dp_valid_q     <= 1'b0;
            dp_data_q      <= 1'b0;
            dp_local_err_q <= 1'b0;
            hwdata_q       <= 32'h0;
        end else begin
            addr_stalled_q <= (htrans == TRANS_NONSEQ) && !hready;
            owner_data_q   <= owner_data;

            if (hready) begin
                dp_valid_q     <= accept;
                dp_data_q      <= owner_data;
                dp_local_err_q <= refuse_write;
                hwdata_q       <= data_wdata_i;
            end
        end
    end

endmodule
