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
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // External SPI Pins
    output reg         spi_sck,
    output reg         spi_mosi,
    input  wire        spi_miso,
    output reg  [7:0]  spi_cs_n
);

    assign pready  = 1'b1; // Single-cycle APB response
    assign pslverr = 1'b0;

    // Register Offsets
    localparam REG_CR     = 4'h0; // 0x00: Control Register
    localparam REG_SR     = 4'h4; // 0x04: Status Register
    localparam REG_TXDATA = 4'h8; // 0x08: Transmit Data
    localparam REG_RXDATA = 4'hC; // 0x0C: Receive Data
    localparam REG_CS     = 4'h0; // 0x10 (paddr[4]=1, paddr[3:0]=0x0)

    // Registers
    reg [12:0] cr_reg;      // [0]=EN, [1]=CPHA, [2]=CPOL, [3]=LSB_FIRST, [11:4]=CLK_DIV, [12]=AUTO_CS
    reg [7:0]  tx_reg;
    reg [7:0]  rx_reg;
    reg [7:0]  cs_reg;
    reg        busy;

    wire spi_en     = cr_reg[0];
    wire spi_cpha   = cr_reg[1];
    wire spi_cpol   = cr_reg[2];
    wire spi_lsb    = cr_reg[3];
    wire [7:0] clk_div = cr_reg[11:4];
    wire auto_cs    = cr_reg[12];

    // SPI Engine State Machine
    reg [7:0]  clk_cnt;
    reg [3:0]  bit_cnt;
    reg [7:0]  tx_shift;
    reg [7:0]  rx_shift;
    reg        sck_internal;
    reg        transfer_start;

    // Status bits
    wire sr_busy     = busy;
    wire sr_tx_empty = ~busy;
    wire sr_tx_full  = busy;
    wire sr_rx_empty = 1'b0;
    wire sr_rx_full  = 1'b1;

    wire [31:0] sr_val = {27'h0, sr_rx_full, sr_rx_empty, sr_tx_full, sr_tx_empty, sr_busy};

    // APB Register Read
    always @(*) begin
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
    wire apb_write_pulse = psel && penable && pwrite;

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            cr_reg         <= 13'h0000;
            tx_reg         <= 8'h00;
            cs_reg         <= 8'hFF;
            transfer_start <= 1'b0;
        end else begin
            transfer_start <= 1'b0;
            if (apb_write_pulse) begin
                case (paddr[4:2])
                    3'b000: cr_reg <= pwdata[12:0];
                    3'b010: begin
                        tx_reg         <= pwdata[7:0];
                        if (spi_en && !busy) begin
                            transfer_start <= 1'b1;
                        end
                    end
                    3'b100: cs_reg <= pwdata[7:0];
                    default: ;
                endcase
            end
        end
    end

    // Chip Select Output
    always @(*) begin
        if (auto_cs && busy) begin
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

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            spi_state    <= IDLE;
            busy         <= 1'b0;
            spi_sck      <= 1'b0;
            spi_mosi     <= 1'b0;
            clk_cnt      <= 8'h0;
            bit_cnt      <= 4'h0;
            tx_shift     <= 8'h00;
            rx_shift     <= 8'h00;
            rx_reg       <= 8'h00;
            sck_internal <= 1'b0;
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
                        bit_cnt      <= 4'd8;
                        clk_cnt      <= clk_div;
                        spi_state    <= TRANSFER;
                        spi_mosi     <= spi_lsb ? tx_reg[0] : tx_reg[7];
                    end
                end

                TRANSFER: begin
                    if (clk_cnt == 8'd0) begin
                        clk_cnt <= clk_div;
                        sck_internal <= ~sck_internal;
                        spi_sck      <= ~sck_internal;

                        // Sample or Shift depending on CPHA and edge
                        if ((sck_internal == spi_cpol) ^ spi_cpha) begin
                            // Sampling Edge
                            rx_shift <= spi_lsb ? {spi_miso, rx_shift[7:1]} : {rx_shift[6:0], spi_miso};
                        end else begin
                            // Shifting Edge
                            bit_cnt <= bit_cnt - 1'b1;
                            if (bit_cnt == 4'd1) begin
                                spi_state <= FINISH;
                            end else begin
                                if (spi_lsb) begin
                                    tx_shift <= {1'b0, tx_shift[7:1]};
                                    spi_mosi <= tx_shift[1];
                                end else begin
                                    tx_shift <= {tx_shift[6:0], 1'b0};
                                    spi_mosi <= tx_shift[6];
                                end
                            end
                        end
                    end else begin
                        clk_cnt <= clk_cnt - 1'b1;
                    end
                end

                FINISH: begin
                    if (clk_cnt == 8'd0) begin
                        spi_sck   <= spi_cpol;
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
