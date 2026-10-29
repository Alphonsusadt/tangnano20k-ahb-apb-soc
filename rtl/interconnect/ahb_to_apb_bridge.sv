`timescale 1ns/1ps
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

    // One outstanding transfer. DATA captures AHB write data before APB SETUP.
    typedef enum logic [2:0] {
        ST_IDLE, ST_DATA, ST_SETUP, ST_ACCESS, ST_RESPONSE, ST_ERROR1, ST_ERROR2
    } state_t;
    state_t state;
    reg invalid_transfer;
    wire sel_uart_raw = (paddr[31:12] == 20'h40000);
    wire sel_spi_raw  = (paddr[31:12] == 20'h40001);
    wire sel_gpio_raw = (paddr[31:12] == 20'h40002);
    wire apb_active = hreset_n && ((state == ST_SETUP) || (state == ST_ACCESS));
    assign psel_uart = apb_active && sel_uart_raw;
    assign psel_spi  = apb_active && sel_spi_raw;
    assign psel_gpio = apb_active && sel_gpio_raw;
    wire selected_pready = sel_uart_raw ? pready_uart :
                           sel_spi_raw ? pready_spi : pready_gpio;
    wire [31:0] selected_prdata = sel_uart_raw ? prdata_uart :
                                 sel_spi_raw ? prdata_spi : prdata_gpio;
    wire selected_pslverr = sel_uart_raw ? pslverr_uart :
                            sel_spi_raw ? pslverr_spi : pslverr_gpio;
    assign hresp = hreset_n && ((state == ST_ERROR1) || (state == ST_ERROR2));
    always @* begin
        hready = !hreset_n || (state == ST_IDLE) ||
                 (state == ST_RESPONSE) || (state == ST_ERROR2);
        penable = hreset_n && (state == ST_ACCESS);
    end

    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            state <= ST_IDLE;
            paddr <= 0;
            pwrite <= 0;
            pwdata <= 0;
            pprot <= 0;
            pstrb <= 0;
            hrdata <= 0;
            invalid_transfer <= 0;
        end else begin
            case (state)
                ST_IDLE, ST_RESPONSE, ST_ERROR2: begin
                    // Also accept the next address at the preceding response edge.
                    if (hsel && htrans[1]) begin
                        paddr <= haddr;
                        pwrite <= hwrite;
                        pprot <= 0; // This interface has no HPROT input.
                        invalid_transfer <=
                            !((haddr[31:12] == 20'h40000) ||
                              (haddr[31:12] == 20'h40001) ||
                              (haddr[31:12] == 20'h40002)) ||
                            (hsize > 2) ||
                            ((hsize == 1) && haddr[0]) ||
                            ((hsize == 2) && (haddr[1:0] != 0));
                        if (!hwrite) pstrb <= 0;
                        else case (hsize)
                            0: pstrb <= 4'b0001 << haddr[1:0];
                            1: pstrb <= 4'b0011 << haddr[1:0];
                            2: pstrb <= 4'b1111;
                            default: pstrb <= 0;
                        endcase
                        state <= ST_DATA;
                    end else state <= ST_IDLE;
                end
                ST_DATA: begin
                    pwdata <= hwdata;
                    if (invalid_transfer) state <= ST_ERROR1;
                    else state <= ST_SETUP;
                end
                ST_SETUP: state <= ST_ACCESS;
                ST_ACCESS: if (selected_pready) begin
                    hrdata <= selected_prdata;
                    if (selected_pslverr) state <= ST_ERROR1;
                    else state <= ST_RESPONSE;
                end
                ST_ERROR1: state <= ST_ERROR2;
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
