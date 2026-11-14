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
    output logic  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // Serial Pins
    output logic         uart_tx,
    input  wire        uart_rx,
    output wire        uart_irq
);

    assign pready  = 1'b1;
    // Offsets past the registers answer with an error instead of aliasing onto them.
    wire reg_valid = (paddr[11:4] == 8'h00);

    // Registers
    logic [7:0]  tx_data_reg;
    logic [7:0]  rx_data_reg;
    logic [3:0]  ctrl_reg;       // [0]=tx_en, [1]=rx_en, [2]=tx_irq_en, [3]=rx_irq_en
    logic [15:0] baud_div_reg;

    logic        rx_valid;
    logic        rx_overflow;
    logic        tx_busy;
    logic        tx_start_req;

    wire tx_en     = ctrl_reg[0];
    wire rx_en     = ctrl_reg[1];
    wire tx_empty  = ~tx_busy;
    wire tx_full   = tx_busy;

    // A byte written while the transmitter is busy has nowhere to go. It is refused
    // with PSLVERR, so the CPU sees a bus fault instead of a byte lost in silence.
    // tx_start_req covers the cycle between the accepted write and tx_busy rising.
    wire tx_refuse = pwrite && (paddr[3:2] == 2'b00) && pstrb[0] && (tx_busy || tx_start_req);
    assign pslverr = psel && penable && (!reg_valid || tx_refuse);

    assign uart_irq = (ctrl_reg[2] && tx_empty) || (ctrl_reg[3] && rx_valid);

    // APB Read
    always_comb begin
        case (paddr[3:2])
            2'b00: prdata = {24'h0, rx_data_reg};
            2'b01: prdata = {28'h0, rx_overflow, tx_full, tx_empty, rx_valid};
            2'b10: prdata = {28'h0, ctrl_reg};
            2'b11: prdata = {16'h0, baud_div_reg};
        endcase
    end

    // APB Write
    wire apb_write = psel && penable && pwrite && reg_valid;
    wire apb_read  = psel && penable && !pwrite && reg_valid;

    // Receiver handshake: rx_shift holds the completed byte while rx_done is high.
    logic        rx_done;
    logic  [7:0] rx_shift;

    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            ctrl_reg     <= 4'b0011; // TX and RX enabled by default
            baud_div_reg <= DEFAULT_BAUD_DIV;
            tx_data_reg  <= 8'h00;
            tx_start_req <= 1'b0;
            rx_data_reg  <= 8'h00;
            rx_valid     <= 1'b0;
            rx_overflow  <= 1'b0;
        end else begin
            tx_start_req <= 1'b0;

            // Clear rx_valid when reading UART_DATA
            if (apb_read && (paddr[3:2] == 2'b00)) begin
                rx_valid    <= 1'b0;
                rx_overflow <= 1'b0;
            end

            // A new byte wins over a same-cycle read clear. That read returned the
            // previous byte, so this one is still unread and is not an overflow.
            if (rx_done) begin
                rx_data_reg <= rx_shift;
                rx_valid    <= 1'b1;
                if (rx_valid && !(apb_read && (paddr[3:2] == 2'b00))) begin
                    rx_overflow <= 1'b1;
                end
            end

            if (apb_write) begin
                case (paddr[3:2])
                    // Without a valid data byte there is nothing to send.
                    2'b00: if (pstrb[0] && !tx_refuse) begin
                        tx_data_reg  <= pwdata[7:0];
                        if (tx_en && !tx_busy) begin
                            tx_start_req <= 1'b1;
                        end
                    end
                    // UART_STATUS is read-only: a write is accepted on the bus and ignored.
                    2'b01: ;
                    2'b10: if (pstrb[0]) ctrl_reg <= pwdata[3:0];
                    2'b11: begin
                        if (pstrb[0]) baud_div_reg[7:0]  <= pwdata[7:0];
                        if (pstrb[1]) baud_div_reg[15:8] <= pwdata[15:8];
                    end
                endcase
            end
        end
    end

    // --------------------------------------------------------------------------
    // UART Transmitter
    // --------------------------------------------------------------------------
    logic [15:0] tx_clk_cnt;
    logic [3:0]  tx_bit_cnt;
    logic [9:0]  tx_shift; // {1'b1 (stop), data[7:0], 1'b0 (start)}

    always_ff @(posedge pclk or negedge preset_n) begin
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
    logic [1:0]  rx_sync;
    logic [15:0] rx_clk_cnt;
    logic [3:0]  rx_bit_cnt;     // 9 = start check, 8..1 = data bits, 0 = stop bit
    logic        rx_busy;

    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            rx_sync <= 2'b11;
        end else begin
            rx_sync <= {rx_sync[0], uart_rx};
        end
    end

    wire rx_in = rx_sync[1];

    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            rx_busy     <= 1'b0;
            rx_clk_cnt  <= 16'd0;
            rx_bit_cnt  <= 4'd0;
            rx_shift    <= 8'd0;
            rx_done     <= 1'b0;
        end else begin
            rx_done <= 1'b0;
            if (rx_en) begin
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
                        end else begin
                            // Stop bit: a low line is a framing error, so drop the byte.
                            rx_busy <= 1'b0;
                            rx_done <= rx_in;
                        end
                    end else begin
                        rx_clk_cnt <= rx_clk_cnt - 1'b1;
                    end
                end
            end else begin
                // RX disabled: drop any frame in progress, so enabling RX again starts
                // from a clean idle receiver instead of the middle of an old frame.
                rx_busy <= 1'b0;
            end
        end
    end

endmodule
