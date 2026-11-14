// ==============================================================================
// Module: apb_spi
// Description: APB4 SPI Master Controller
// Features: Configurable Clock Divisor, CPOL/CPHA Modes, Manual/Auto CS
// ==============================================================================

module apb_spi (
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

    // External SPI Pins
    output logic         spi_sck,
    output logic         spi_mosi,
    input  wire        spi_miso,
    output logic  [7:0]  spi_cs_n
);

    assign pready  = 1'b1; // Single-cycle APB response
    // Offsets past the registers answer with an error instead of aliasing onto them.
    wire reg_valid = (paddr[11:5] == 7'h00) && (paddr[4:2] <= 3'b100);

    // Register offsets are decoded from paddr[4:2] below: 0x00 CR, 0x04 SR, 0x08 TXDATA,
    // 0x0C RXDATA, 0x10 CS. See docs/memory_map.md.

    // Registers
    logic [12:0] cr_reg;      // [0]=EN, [1]=CPHA, [2]=CPOL, [3]=LSB_FIRST, [11:4]=CLK_DIV, [12]=AUTO_CS
    logic [7:0]  tx_reg;
    logic [7:0]  rx_reg;
    logic [7:0]  cs_reg;
    logic        busy;

    wire spi_en     = cr_reg[0];
    wire spi_cpha   = cr_reg[1];
    wire spi_cpol   = cr_reg[2];
    wire spi_lsb    = cr_reg[3];
    wire [7:0] clk_div = cr_reg[11:4];
    wire auto_cs    = cr_reg[12];

    // SPI Engine State Machine
    logic [7:0]  clk_cnt;
    logic [3:0]  edge_cnt;    // SCK edge index in a byte: 0..15, even = leading edge
    logic [7:0]  tx_shift;
    logic [7:0]  rx_shift;
    logic        sck_internal;
    logic        transfer_start;

    // Configuration of the byte in flight, copied from SPI_CR when it starts. A write
    // to SPI_CR during a transfer is stored and read back, but only applies from the
    // next byte, so it cannot change the mode, bit order, clock, or CS of this one.
    logic        xfer_cpha;
    logic        xfer_cpol;
    logic        xfer_lsb;
    logic [7:0]  xfer_div;
    logic        xfer_auto_cs;

    // CPHA=0 samples on leading edges (even index), CPHA=1 on trailing (odd).
    wire sample_edge = edge_cnt[0] == xfer_cpha;
    // The first bit is already on MOSI, so CPHA=1 must not shift on edge 0.
    // The last edge never shifts because the byte is complete.
    wire shift_edge  = !sample_edge && (edge_cnt != 4'd0) && (edge_cnt != 4'd15);

    // A byte written while one is in flight is refused with PSLVERR and SPI_TXDATA keeps
    // the byte in flight. transfer_start covers the cycle before busy rises.
    wire tx_refuse = pwrite && (paddr[4:2] == 3'b010) && pstrb[0] && (busy || transfer_start);
    assign pslverr = psel && penable && (!reg_valid || tx_refuse);

    // Status bits
    wire sr_busy     = busy;
    wire sr_tx_empty = ~busy;
    wire sr_tx_full  = busy;

    // There is no RX FIFO, so the old RX_EMPTY/RX_FULL bits [4:3] were constants. They
    // are reserved and read 0; SPI_RXDATA is valid once BUSY returns to 0.
    wire [31:0] sr_val = {29'h0, sr_tx_full, sr_tx_empty, sr_busy};

    // APB Register Read
    always_comb begin
        case (paddr[4:2])
            3'b000: prdata = {19'h0, cr_reg};
            3'b001: prdata = sr_val;
            3'b010: prdata = {24'h0, tx_reg};
            3'b011: prdata = {24'h0, rx_reg};
            3'b100: prdata = {24'h0, cs_reg};
            default: prdata = 32'h0;
        endcase
    end

    // APB Register Write
    wire apb_write_pulse = psel && penable && pwrite && reg_valid;

    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            cr_reg         <= 13'h0000;
            tx_reg         <= 8'h00;
            cs_reg         <= 8'hFF;
            transfer_start <= 1'b0;
        end else begin
            transfer_start <= 1'b0;
            if (apb_write_pulse) begin
                case (paddr[4:2])
                    3'b000: begin
                        if (pstrb[0]) cr_reg[7:0]  <= pwdata[7:0];
                        if (pstrb[1]) cr_reg[12:8] <= pwdata[12:8];
                    end
                    // Without a valid data byte there is nothing to send.
                    3'b010: if (pstrb[0] && !tx_refuse) begin
                        tx_reg         <= pwdata[7:0];
                        if (spi_en && !busy) begin
                            transfer_start <= 1'b1;
                        end
                    end
                    3'b100: if (pstrb[0]) cs_reg <= pwdata[7:0];
                    default: ;
                endcase
            end
        end
    end

    // Chip Select Output
    always_comb begin
        if (xfer_auto_cs && busy) begin
            spi_cs_n = 8'hFE; // Assert CS0 active low
        end else begin
            spi_cs_n = cs_reg;
        end
    end

    // SPI Bit Transmission Engine
    typedef enum logic [1:0] {
        IDLE,
        TRANSFER,
        FINISH
    } spi_state_t;

    spi_state_t spi_state;

    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            spi_state    <= IDLE;
            busy         <= 1'b0;
            spi_sck      <= 1'b0;
            spi_mosi     <= 1'b0;
            clk_cnt      <= 8'h0;
            edge_cnt     <= 4'h0;
            tx_shift     <= 8'h00;
            rx_shift     <= 8'h00;
            rx_reg       <= 8'h00;
            sck_internal <= 1'b0;
            xfer_cpha    <= 1'b0;
            xfer_cpol    <= 1'b0;
            xfer_lsb     <= 1'b0;
            xfer_div     <= 8'h0;
            xfer_auto_cs <= 1'b0;
        end else begin
            case (spi_state)
                IDLE: begin
                    busy         <= 1'b0;
                    spi_sck      <= spi_cpol;
                    sck_internal <= spi_cpol;
                    if (transfer_start) begin
                        busy         <= 1'b1;
                        tx_shift     <= tx_reg;
                        rx_shift     <= 8'h00;
                        edge_cnt     <= 4'd0;
                        clk_cnt      <= clk_div;
                        spi_state    <= TRANSFER;
                        spi_mosi     <= spi_lsb ? tx_reg[0] : tx_reg[7];
                        xfer_cpha    <= spi_cpha;
                        xfer_cpol    <= spi_cpol;
                        xfer_lsb     <= spi_lsb;
                        xfer_div     <= clk_div;
                        xfer_auto_cs <= auto_cs;
                    end
                end

                TRANSFER: begin
                    if (clk_cnt == 8'd0) begin
                        clk_cnt <= xfer_div;
                        sck_internal <= ~sck_internal;
                        spi_sck      <= ~sck_internal;
                        edge_cnt     <= edge_cnt + 1'b1;

                        if (sample_edge) begin
                            rx_shift <= xfer_lsb ? {spi_miso, rx_shift[7:1]} : {rx_shift[6:0], spi_miso};
                        end

                        if (shift_edge) begin
                            if (xfer_lsb) begin
                                tx_shift <= {1'b0, tx_shift[7:1]};
                                spi_mosi <= tx_shift[1];
                            end else begin
                                tx_shift <= {tx_shift[6:0], 1'b0};
                                spi_mosi <= tx_shift[6];
                            end
                        end

                        // Every byte is exactly 16 edges, so RX has all 8 samples here.
                        if (edge_cnt == 4'd15) begin
                            spi_state <= FINISH;
                        end
                    end else begin
                        clk_cnt <= clk_cnt - 1'b1;
                    end
                end

                FINISH: begin
                    if (clk_cnt == 8'd0) begin
                        spi_sck   <= xfer_cpol;
                        rx_reg    <= rx_shift;
                        busy      <= 1'b0;
                        spi_state <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt - 1'b1;
                    end
                end

                default: spi_state <= IDLE;
            endcase
        end
    end

endmodule
