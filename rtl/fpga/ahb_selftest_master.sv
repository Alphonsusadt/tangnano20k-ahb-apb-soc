// ==============================================================================
// Module: ahb_selftest_master
// Description: Synthesizable stand-in for the CPU. Runs a fixed bus self-test,
//              reports the result on the UART, then keeps exercising the UART,
//              GPIO, and LEDs so the whole bus path stays in the FPGA build.
//
// Report: "SOC PASS\r\n" or "SOC FAIL xx\r\n", where xx is the failed step in hex.
// LEDs (active low): [0] heartbeat, [1] pass, [2] fail, [3] S2 pressed.
//
// Each transfer is an address phase followed by an IDLE data phase, so the master
// never has a second transfer to cancel when a slave answers ERROR.
// ==============================================================================

module ahb_selftest_master #(
    parameter HEARTBEAT_BIT = 23 // Heartbeat toggles every 2^HEARTBEAT_BIT cycles
)(
    input  wire        hclk,
    input  wire        hreset_n,

    output reg  [31:0] haddr,
    output reg  [1:0]  htrans,
    output reg         hwrite,
    output reg  [2:0]  hsize,
    output reg  [31:0] hwdata,
    input  wire [31:0] hrdata,
    input  wire        hready,
    input  wire        hresp
);

    localparam [1:0] TRANS_IDLE = 2'b00, TRANS_NONSEQ = 2'b10;
    localparam [2:0] SIZE_BYTE = 3'b000, SIZE_WORD = 3'b010;

    // Memory map, from docs/memory_map.md
    localparam [31:0] ROM_TOP     = 32'h0000_7FFC;
    localparam [31:0] SRAM_BASE   = 32'h2000_0000;
    localparam [31:0] SRAM_TOP    = 32'h2000_7FFC;
    localparam [31:0] UART_DATA   = 32'h4000_0000;
    localparam [31:0] UART_STATUS = 32'h4000_0004;
    localparam [31:0] UART_BAUD   = 32'h4000_000C;
    localparam [31:0] SPI_CR      = 32'h4000_1000;
    localparam [31:0] SPI_SR      = 32'h4000_1004;
    localparam [31:0] SPI_TXDATA  = 32'h4000_1008;
    localparam [31:0] GPIO_OUT    = 32'h4000_2000;
    localparam [31:0] GPIO_IN     = 32'h4000_2004;

    // Self-test script
    localparam [2:0] OP_WRITE     = 3'd0; // Write, expect OKAY
    localparam [2:0] OP_READ      = 3'd1; // Read, expect OKAY and (rdata & mask) == data
    localparam [2:0] OP_POLL      = 3'd2; // Repeat a read until (rdata & mask) == data
    localparam [2:0] OP_WRITE_ERR = 3'd3; // Write, expect ERROR
    localparam [2:0] OP_READ_ERR  = 3'd4; // Read, expect ERROR

    localparam [4:0]  LAST_STEP = 5'd19;
    localparam [31:0] ALL = 32'hFFFF_FFFF;

    function automatic [101:0] step_rom(input [4:0] step);
        case (step)
            // ROM, including the last word, so the image and full depth are proven.
            5'd0:  step_rom = {OP_READ,      SIZE_WORD, 32'h0000_0000,        32'h534F_4331, ALL};
            5'd1:  step_rom = {OP_READ,      SIZE_WORD, ROM_TOP,              32'hA5C3_5A3C, ALL};
            // SRAM first and last word, then a byte write on lane 1.
            5'd2:  step_rom = {OP_WRITE,     SIZE_WORD, SRAM_BASE,            32'hDEAD_BEEF, ALL};
            5'd3:  step_rom = {OP_WRITE,     SIZE_WORD, SRAM_TOP,             32'h1234_5678, ALL};
            5'd4:  step_rom = {OP_READ,      SIZE_WORD, SRAM_BASE,            32'hDEAD_BEEF, ALL};
            5'd5:  step_rom = {OP_READ,      SIZE_WORD, SRAM_TOP,             32'h1234_5678, ALL};
            5'd6:  step_rom = {OP_WRITE,     SIZE_BYTE, SRAM_BASE + 32'h1,    32'h0000_AA00, ALL};
            5'd7:  step_rom = {OP_READ,      SIZE_WORD, SRAM_BASE,            32'hDEAD_AAEF, ALL};
            // One past SRAM must answer ERROR and must not alias onto word 0.
            5'd8:  step_rom = {OP_WRITE_ERR, SIZE_WORD, SRAM_BASE + 32'h8000, 32'h0BAD_0BAD, ALL};
            5'd9:  step_rom = {OP_READ,      SIZE_WORD, SRAM_BASE,            32'hDEAD_AAEF, ALL};
            // ERROR from each source: default slave, bridge, and peripheral.
            5'd10: step_rom = {OP_READ_ERR,  SIZE_WORD, 32'h1000_0000,        32'h0,         ALL};
            5'd11: step_rom = {OP_READ_ERR,  SIZE_WORD, 32'h4000_3000,        32'h0,         ALL};
            5'd12: step_rom = {OP_READ_ERR,  SIZE_WORD, UART_DATA + 32'h10,   32'h0,         ALL};
            // APB reads and writes reach the registers.
            5'd13: step_rom = {OP_READ,      SIZE_WORD, UART_BAUD,            32'h0000_00EA, ALL};
            5'd14: step_rom = {OP_READ,      SIZE_WORD, GPIO_OUT,             32'h0000_003F, ALL};
            5'd15: step_rom = {OP_WRITE,     SIZE_WORD, GPIO_OUT,             32'h0000_002A, ALL};
            5'd16: step_rom = {OP_READ,      SIZE_WORD, GPIO_OUT,             32'h0000_002A, ALL};
            // One SPI byte with automatic CS, CLK_DIV = 3.
            5'd17: step_rom = {OP_WRITE,     SIZE_WORD, SPI_CR,               32'h0000_1031, ALL};
            5'd18: step_rom = {OP_WRITE,     SIZE_WORD, SPI_TXDATA,           32'h0000_00A5, ALL};
            5'd19: step_rom = {OP_POLL,      SIZE_WORD, SPI_SR,               32'h0,         32'h1};
            default: step_rom = {OP_READ,    SIZE_WORD, 32'h0,                32'h0,         32'h0};
        endcase
    endfunction

    // Report text
    function automatic [7:0] hex_char(input [3:0] n);
        hex_char = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction

    function automatic [7:0] msg_char(input is_fail, input [3:0] idx, input [4:0] step);
        case (idx)
            4'd0:  msg_char = 8'h53;                     // S
            4'd1:  msg_char = 8'h4F;                     // O
            4'd2:  msg_char = 8'h43;                     // C
            4'd3:  msg_char = 8'h20;                     // space
            4'd4:  msg_char = is_fail ? 8'h46 : 8'h50;   // F or P
            4'd5:  msg_char = 8'h41;                     // A
            4'd6:  msg_char = is_fail ? 8'h49 : 8'h53;   // I or S
            4'd7:  msg_char = is_fail ? 8'h4C : 8'h53;   // L or S
            4'd8:  msg_char = is_fail ? 8'h20 : 8'h0D;   // space or CR
            4'd9:  msg_char = is_fail ? hex_char({3'b000, step[4]}) : 8'h0A;
            4'd10: msg_char = hex_char(step[3:0]);
            4'd11: msg_char = 8'h0D;
            default: msg_char = 8'h0A;
        endcase
    endfunction

    // Sequencer
    localparam [3:0] ST_ADDR     = 4'd0;  // Address phase
    localparam [3:0] ST_DATA     = 4'd1;  // Data phase
    localparam [3:0] ST_STEP     = 4'd2;  // Start the current script step
    localparam [3:0] ST_CHECK    = 4'd3;  // Judge the current script step
    localparam [3:0] ST_MSG_POLL = 4'd4;  // Read the transmitter status
    localparam [3:0] ST_MSG_SEND = 4'd5;  // Send one report character when it is free
    localparam [3:0] ST_MSG_NEXT = 4'd6;
    localparam [3:0] ST_RUN_STAT = 4'd7;  // Read UART status
    localparam [3:0] ST_RUN_RX   = 4'd8;  // Read a received byte, if there is one
    localparam [3:0] ST_RUN_ECHO = 4'd9;  // Send it back
    localparam [3:0] ST_RUN_GPIO = 4'd10; // Read the buttons
    localparam [3:0] ST_RUN_LED  = 4'd11; // Update the LEDs

    reg [3:0]  state, ret_state;
    reg [31:0] wdata_q, rdata_q;
    reg        err_q;
    reg [4:0]  pc;
    reg [19:0] poll_cnt;
    reg        failed;
    reg [4:0]  fail_step;
    reg [3:0]  msg_idx;
    reg [HEARTBEAT_BIT:0] hb_cnt;

    wire [101:0] step_word = step_rom(pc);
    wire [2:0]   step_op   = step_word[101:99];
    wire [2:0]   step_size = step_word[98:96];
    wire [31:0]  step_addr = step_word[95:64];
    wire [31:0]  step_data = step_word[63:32];
    wire [31:0]  step_mask = step_word[31:0];

    wire         read_ok   = !err_q && ((rdata_q & step_mask) == step_data);
    wire [3:0]   msg_last  = failed ? 4'd12 : 4'd9;

    task automatic start(input [31:0] addr, input is_write, input [2:0] size,
                         input [31:0] data, input [3:0] ret);
        begin
            haddr     <= addr;
            hwrite    <= is_write;
            hsize     <= size;
            wdata_q   <= data;
            htrans    <= TRANS_NONSEQ;
            ret_state <= ret;
            state     <= ST_ADDR;
        end
    endtask

    task automatic finish_step(input ok);
        begin
            if (!ok) begin
                failed    <= 1'b1;
                fail_step <= pc;
                state     <= ST_MSG_POLL;
            end else if (pc == LAST_STEP) begin
                state     <= ST_MSG_POLL;
            end else begin
                pc        <= pc + 5'd1;
                state     <= ST_STEP;
            end
        end
    endtask

    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            state     <= ST_STEP;
            ret_state <= ST_STEP;
            haddr     <= 32'h0;
            htrans    <= TRANS_IDLE;
            hwrite    <= 1'b0;
            hsize     <= SIZE_WORD;
            hwdata    <= 32'h0;
            wdata_q   <= 32'h0;
            rdata_q   <= 32'h0;
            err_q     <= 1'b0;
            pc        <= 5'd0;
            poll_cnt  <= 20'd0;
            failed    <= 1'b0;
            fail_step <= 5'd0;
            msg_idx   <= 4'd0;
            hb_cnt    <= {(HEARTBEAT_BIT + 1){1'b0}};
        end else begin
            hb_cnt <= hb_cnt + 1'b1;

            case (state)
                ST_ADDR: if (hready) begin
                    htrans <= TRANS_IDLE;
                    hwdata <= wdata_q;
                    state  <= ST_DATA;
                end

                ST_DATA: if (hready) begin
                    rdata_q <= hrdata;
                    err_q   <= hresp;
                    state   <= ret_state;
                end

                ST_STEP: begin
                    start(step_addr,
                          (step_op == OP_WRITE) || (step_op == OP_WRITE_ERR),
                          step_size, step_data, ST_CHECK);
                end

                ST_CHECK: begin
                    case (step_op)
                        OP_WRITE: finish_step(!err_q);
                        OP_READ:  finish_step(read_ok);
                        OP_POLL: begin
                            if (read_ok) begin
                                finish_step(1'b1);
                            end else if (err_q || (&poll_cnt)) begin
                                finish_step(1'b0);
                            end else begin
                                poll_cnt <= poll_cnt + 20'd1;
                                state    <= ST_STEP;
                            end
                        end
                        default: finish_step(err_q); // OP_WRITE_ERR, OP_READ_ERR
                    endcase
                end

                ST_MSG_POLL: start(UART_STATUS, 1'b0, SIZE_WORD, 32'h0, ST_MSG_SEND);

                ST_MSG_SEND: begin
                    if (rdata_q[1]) begin
                        start(UART_DATA, 1'b1, SIZE_WORD,
                              {24'h0, msg_char(failed, msg_idx, fail_step)}, ST_MSG_NEXT);
                    end else begin
                        state <= ST_MSG_POLL;
                    end
                end

                ST_MSG_NEXT: begin
                    msg_idx <= msg_idx + 4'd1;
                    state   <= (msg_idx == msg_last) ? ST_RUN_STAT : ST_MSG_POLL;
                end

                ST_RUN_STAT: start(UART_STATUS, 1'b0, SIZE_WORD, 32'h0, ST_RUN_RX);

                // Echo only when the transmitter is free, so no byte is dropped.
                ST_RUN_RX: begin
                    if (rdata_q[0] && rdata_q[1]) begin
                        start(UART_DATA, 1'b0, SIZE_WORD, 32'h0, ST_RUN_ECHO);
                    end else begin
                        state <= ST_RUN_GPIO;
                    end
                end

                ST_RUN_ECHO: start(UART_DATA, 1'b1, SIZE_WORD, rdata_q, ST_RUN_GPIO);

                ST_RUN_GPIO: start(GPIO_IN, 1'b0, SIZE_WORD, 32'h0, ST_RUN_LED);

                ST_RUN_LED: begin
                    start(GPIO_OUT, 1'b1, SIZE_WORD,
                          {26'h0, 2'b11, ~rdata_q[1], ~failed, failed, ~hb_cnt[HEARTBEAT_BIT]},
                          ST_RUN_STAT);
                end

                default: state <= ST_STEP;
            endcase
        end
    end

endmodule
