// ==============================================================================
// Module: ahb_to_apb_bridge
// Description: AHB-Lite to APB4 Bridge with integrated address decoding
// ==============================================================================

module ahb_to_apb_bridge (
    input  wire        hclk,
    input  wire        hreset_n,

    // AHB-Lite Slave Interface
    input  wire        hsel,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [31:0] hwdata,
    output reg  [31:0] hrdata,
    output reg         hready,
    output wire        hresp,

    // APB4 Master Interface to Peripherals
    output reg  [31:0] paddr,
    output reg  [31:0] pwdata,
    output reg         pwrite,
    output reg  [2:0]  pprot,
    output reg  [3:0]  pstrb,
    output reg         penable,

    // Peripheral Selects
    output wire        psel_uart,  // 0x4000_0000 - 0x4000_0FFF
    output wire        psel_spi,   // 0x4000_1000 - 0x4000_1FFF
    output wire        psel_gpio,  // 0x4000_2000 - 0x4000_2FFF

    // Peripheral Inputs
    input  wire [31:0] prdata_uart,
    input  wire        pready_uart,
    input  wire        pslverr_uart,

    input  wire [31:0] prdata_spi,
    input  wire        pready_spi,
    input  wire        pslverr_spi,

    input  wire [31:0] prdata_gpio,
    input  wire        pready_gpio,
    input  wire        pslverr_gpio
);

    localparam HTRANS_IDLE   = 2'b00;
    localparam HTRANS_NONSEQ = 2'b10;
    localparam HTRANS_SEQ    = 2'b11;

    typedef enum logic [1:0] {
        ST_IDLE   = 2'b00,
        ST_SETUP  = 2'b01,
        ST_ACCESS = 2'b10
    } state_t;

    state_t state, state_next;

    // Registered AHB transfer info
    reg [31:0] haddr_reg;
    reg        hwrite_reg;
    reg [2:0]  hsize_reg;
    reg        ahb_valid;

    // Address decode
    wire sel_uart_raw = (haddr_reg[15:12] == 4'h0); // 0x4000_0xxx
    wire sel_spi_raw  = (haddr_reg[15:12] == 4'h1); // 0x4000_1xxx
    wire sel_gpio_raw = (haddr_reg[15:12] == 4'h2); // 0x4000_2xxx

    wire apb_active = (state == ST_SETUP) || (state == ST_ACCESS);

    assign psel_uart = apb_active && sel_uart_raw;
    assign psel_spi  = apb_active && sel_spi_raw;
    assign psel_gpio = apb_active && sel_gpio_raw;

    // Multiplex selected APB slave responses
    wire        selected_pready  = sel_uart_raw ? pready_uart  : (sel_spi_raw ? pready_spi  : (sel_gpio_raw ? pready_gpio  : 1'b1));
    wire [31:0] selected_prdata  = sel_uart_raw ? prdata_uart  : (sel_spi_raw ? prdata_spi  : (sel_gpio_raw ? prdata_gpio  : 32'h0));
    wire        selected_pslverr = sel_uart_raw ? pslverr_uart : (sel_spi_raw ? pslverr_spi : (sel_gpio_raw ? pslverr_gpio : 1'b0));

    assign hresp = selected_pslverr;

    // State machine
    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            state <= ST_IDLE;
        end else begin
            state <= state_next;
        end
    end

    always @(*) begin
        state_next = state;
        case (state)
            ST_IDLE: begin
                if (hsel && (htrans == HTRANS_NONSEQ || htrans == HTRANS_SEQ)) begin
                    state_next = ST_SETUP;
                end
            end
            ST_SETUP: begin
                state_next = ST_ACCESS;
            end
            ST_ACCESS: begin
                if (selected_pready) begin
                    state_next = ST_IDLE;
                end
            end
            default: state_next = ST_IDLE;
        endcase
    end

    // AHB Address / control latching
    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            haddr_reg  <= 32'h0;
            hwrite_reg <= 1'b0;
            hsize_reg  <= 3'b0;
        end else if (hsel && (htrans == HTRANS_NONSEQ || htrans == HTRANS_SEQ) && (state == ST_IDLE)) begin
            haddr_reg  <= haddr;
            hwrite_reg <= hwrite;
            hsize_reg  <= hsize;
        end
    end

    // APB output generation
    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            paddr   <= 32'h0;
            pwdata  <= 32'h0;
            pwrite  <= 1'b0;
            pprot   <= 3'b0;
            pstrb   <= 4'b1111;
            penable <= 1'b0;
            hrdata  <= 32'h0;
            hready  <= 1'b1;
        end else begin
            case (state_next)
                ST_IDLE: begin
                    penable <= 1'b0;
                    hready  <= 1'b1;
                end
                ST_SETUP: begin
                    paddr   <= haddr_reg;
                    pwdata  <= hwdata;
                    pwrite  <= hwrite_reg;
                    pprot   <= 3'b000;
                    pstrb   <= 4'b1111;
                    penable <= 1'b0;
                    hready  <= 1'b0; // Hold AHB master while APB transaction runs
                end
                ST_ACCESS: begin
                    penable <= 1'b1;
                    if (selected_pready) begin
                        hrdata <= selected_prdata;
                        hready <= 1'b1;
                    end else begin
                        hready <= 1'b0;
                    end
                end
            endcase
        end
    end

endmodule
