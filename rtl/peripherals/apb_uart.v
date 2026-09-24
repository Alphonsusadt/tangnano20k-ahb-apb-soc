// ==============================================================================
// Module: apb_uart
// Description: APB4 UART Controller (TX & RX, 8-N-1 format)
// ==============================================================================

module apb_uart #(
    parameter DEFAULT_BAUD_DIV = 16'd234 // 27 MHz / 115200 ≈ 234
)(
    input  wire        pclk,
    input  wire        preset_n,

    // APB4 Slave Interface
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    input  wire [3:0]  pstrb,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // Serial Pins
    output reg         uart_tx,
    input  wire        uart_rx,
    output wire        uart_irq
);

    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    // Registers
    reg [7:0]  tx_data_reg;
    reg [7:0]  rx_data_reg;
    reg [3:0]  ctrl_reg;       // [0]=tx_en, [1]=rx_en, [2]=tx_irq_en, [3]=rx_irq_en
    reg [15:0] baud_div_reg;

    reg        rx_valid;
    reg        rx_overflow;
    reg        tx_busy;

    wire tx_en     = ctrl_reg[0];
    wire rx_en     = ctrl_reg[1];
    wire tx_empty  = ~tx_busy;
    wire tx_full   = tx_busy;

    assign uart_irq = (ctrl_reg[2] && tx_empty) || (ctrl_reg[3] && rx_valid);

    // APB Read
    always @(*) begin
        case (paddr[3:2])
            2'b00: prdata = {24'h0, rx_data_reg};
            2'b01: prdata = {28'h0, rx_overflow, tx_full, tx_empty, rx_valid};
            2'b10: prdata = {28'h0, ctrl_reg};
            2'b11: prdata = {16'h0, baud_div_reg};
        endcase
    end

    // APB Write
    wire apb_write = psel && penable && pwrite;
    wire apb_read  = psel && penable && !pwrite;
    reg  tx_start_req;

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            ctrl_reg     <= 4'b0011; // TX and RX enabled by default
            baud_div_reg <= DEFAULT_BAUD_DIV;
            tx_data_reg  <= 8'h00;
            tx_start_req <= 1'b0;
            rx_valid     <= 1'b0;
            rx_overflow  <= 1'b0;
        end else begin
            tx_start_req <= 1'b0;

            // Clear rx_valid when reading UART_DATA
            if (apb_read && (paddr[3:2] == 2'b00)) begin
                rx_valid    <= 1'b0;
                rx_overflow <= 1'b0;
            end

            if (apb_write) begin
                case (paddr[3:2])
                    2'b00: begin
                        tx_data_reg  <= pwdata[7:0];
                        if (tx_en && !tx_busy) begin
                            tx_start_req <= 1'b1;
                        end
                    end
                    2'b01: begin
                        // Write 1 to clear status bits if desired
                    end
                    2'b10: ctrl_reg     <= pwdata[3:0];
                    2'b11: baud_div_reg <= pwdata[15:0];
                endcase
            end
        end
    end

    // --------------------------------------------------------------------------
    // UART Transmitter
    // --------------------------------------------------------------------------
    reg [15:0] tx_clk_cnt;
    reg [3:0]  tx_bit_cnt;
    reg [9:0]  tx_shift; // {1'b1 (stop), data[7:0], 1'b0 (start)}

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            uart_tx    <= 1'b1;
            tx_busy    <= 1'b0;
            tx_clk_cnt <= 16'd0;
            tx_bit_cnt <= 4'd0;
            tx_shift   <= 10'h3FF;
        end else begin
            if (!tx_busy) begin
                uart_tx <= 1'b1;
                if (tx_start_req) begin
                    tx_busy    <= 1'b1;
                    tx_shift   <= {1'b1, tx_data_reg, 1'b0};
                    tx_clk_cnt <= baud_div_reg;
                    tx_bit_cnt <= 4'd10;
                end
            end else begin
                if (tx_clk_cnt == 16'd0) begin
                    tx_clk_cnt <= baud_div_reg;
                    uart_tx    <= tx_shift[0];
                    tx_shift   <= {1'b1, tx_shift[9:1]};
                    tx_bit_cnt <= tx_bit_cnt - 1'b1;
                    if (tx_bit_cnt == 4'd1) begin
                        tx_busy <= 1'b0;
                    end
                end else begin
                    tx_clk_cnt <= tx_clk_cnt - 1'b1;
                end
            end
        end
    end

    // --------------------------------------------------------------------------
    // UART Receiver (Synchronizer + 8-N-1 receiver)
    // --------------------------------------------------------------------------
    reg [1:0]  rx_sync;
    reg [15:0] rx_clk_cnt;
    reg [3:0]  rx_bit_cnt;
    reg [7:0]  rx_shift;
    reg        rx_busy;

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            rx_sync <= 2'b11;
        end else begin
            rx_sync <= {rx_sync[0], uart_rx};
        end
    end

    wire rx_in = rx_sync[1];

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            rx_busy     <= 1'b0;
            rx_clk_cnt  <= 16'd0;
            rx_bit_cnt  <= 4'd0;
            rx_shift    <= 8'd0;
            rx_data_reg <= 8'd0;
        end else if (rx_en) begin
            if (!rx_busy) begin
                if (!rx_in) begin // Start bit detected
                    rx_busy    <= 1'b1;
                    rx_clk_cnt <= {1'b0, baud_div_reg[15:1]}; // Sample at mid-bit (div/2)
                    rx_bit_cnt <= 4'd9;
                end
            end else begin
                if (rx_clk_cnt == 16'd0) begin
                    rx_clk_cnt <= baud_div_reg;
                    if (rx_bit_cnt == 4'd9) begin
                        // Verify start bit is still 0
                        if (!rx_in) begin
                            rx_bit_cnt <= rx_bit_cnt - 1'b1;
                        end else begin
                            rx_busy <= 1'b0; // False start
                        end
                    end else if (rx_bit_cnt > 4'd0) begin
                        rx_shift   <= {rx_in, rx_shift[7:1]};
                        rx_bit_cnt <= rx_bit_cnt - 1'b1;
                        if (rx_bit_cnt == 4'd1) begin
                            rx_busy     <= 1'b0;
                            rx_data_reg <= {rx_in, rx_shift[7:1]};
                            if (rx_valid) begin
                                rx_overflow <= 1'b1;
                            end else begin
                                rx_valid <= 1'b1;
                            end
                        end
                    end
                end else begin
                    rx_clk_cnt <= rx_clk_cnt - 1'b1;
                end
            end
        end
    end

endmodule
