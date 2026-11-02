// ==============================================================================
// Testbench: tb_apb_uart
// Description: Self-checking APB UART regression for registers, TX framing,
//              RX framing, baud tolerance, and overflow behavior.
// ==============================================================================

`timescale 1ns / 1ps

module tb_apb_uart;

    localparam ADDR_DATA   = 32'h00;
    localparam ADDR_STATUS = 32'h04;
    localparam ADDR_CTRL   = 32'h08;
    localparam ADDR_BAUD   = 32'h0C;

    localparam STATUS_RX_VALID    = 0;
    localparam STATUS_TX_EMPTY    = 1;
    localparam STATUS_RX_OVERFLOW = 3;

    localparam real CLK_PERIOD = 37.036;
    localparam int  BAUD_DIV   = 234;
    // The baud counter reloads with DIV and counts to zero: DIV + 1 cycles per bit.
    localparam real BIT_NS     = (BAUD_DIV + 1) * CLK_PERIOD;

    logic        pclk = 1'b0;
    logic        preset_n = 1'b0;
    logic        psel = 1'b0;
    logic        penable = 1'b0;
    logic        pwrite = 1'b0;
    logic [31:0] paddr = 32'h0;
    logic [31:0] pwdata = 32'h0;
    wire  [31:0] prdata;
    wire         pready;
    wire         pslverr;
    wire         uart_tx;
    logic        uart_rx = 1'b1;
    wire         uart_irq;

    integer checks = 0;
    integer failures = 0;

    always #(CLK_PERIOD / 2.0) pclk = ~pclk;

    apb_uart u_dut (
        .pclk     (pclk),
        .preset_n (preset_n),
        .psel     (psel),
        .penable  (penable),
        .pwrite   (pwrite),
        .paddr    (paddr),
        .pwdata   (pwdata),
        .pstrb    (4'b1111),
        .prdata   (prdata),
        .pready   (pready),
        .pslverr  (pslverr),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),
        .uart_irq (uart_irq)
    );

    task automatic check(input logic ok, input string what);
        checks = checks + 1;
        if (ok !== 1'b1) begin
            failures = failures + 1;
            $display("FAIL @ %0t: %s", $time, what);
        end
    endtask

    task automatic apb_write(input [31:0] addr, input [31:0] data);
        @(posedge pclk);
        paddr   <= addr;
        pwdata  <= data;
        pwrite  <= 1'b1;
        psel    <= 1'b1;
        penable <= 1'b0;
        @(posedge pclk);
        penable <= 1'b1;
        @(posedge pclk);
        psel    <= 1'b0;
        penable <= 1'b0;
        pwrite  <= 1'b0;
    endtask

    task automatic apb_read(input [31:0] addr, output [31:0] data);
        @(posedge pclk);
        paddr   <= addr;
        pwrite  <= 1'b0;
        psel    <= 1'b1;
        penable <= 1'b0;
        @(posedge pclk);
        penable <= 1'b1;
        @(posedge pclk);
        data = prdata;
        psel    <= 1'b0;
        penable <= 1'b0;
    endtask

    // --------------------------------------------------------------------------
    // TX line monitor: decodes frames at mid-bit and records framing errors.
    // --------------------------------------------------------------------------
    logic [7:0] tx_got [0:31];
    integer     tx_count = 0;
    integer     tx_framing_errors = 0;

    always begin
        logic [7:0] value;
        @(negedge uart_tx);
        #(BIT_NS / 2.0);
        if (uart_tx !== 1'b0) tx_framing_errors = tx_framing_errors + 1;
        for (int i = 0; i < 8; i++) begin
            #(BIT_NS);
            value[i] = uart_tx;
        end
        #(BIT_NS);
        if (uart_tx !== 1'b1) tx_framing_errors = tx_framing_errors + 1;
        tx_got[tx_count] = value;
        tx_count = tx_count + 1;
    end

    task automatic send_tx(input logic [7:0] data);
        logic [31:0] status;
        status = 32'h0;
        while (!status[STATUS_TX_EMPTY]) apb_read(ADDR_STATUS, status);
        apb_write(ADDR_DATA, {24'h0, data});
        // Allow the start request to reach tx_busy before polling again.
        repeat (3) @(posedge pclk);
    endtask

    // --------------------------------------------------------------------------
    // RX line driver. `scale` above 1.0 models a slower external transmitter.
    // --------------------------------------------------------------------------
    task automatic drive_rx(input logic [7:0] data, input real scale);
        real bit_time;
        bit_time = BIT_NS * scale;
        uart_rx = 1'b0;
        #(bit_time);
        for (int i = 0; i < 8; i++) begin
            uart_rx = data[i];
            #(bit_time);
        end
        uart_rx = 1'b1;
        #(bit_time);
    endtask

    task automatic expect_rx(input logic [7:0] expected, input string what);
        logic [31:0] status;
        logic [31:0] value;
        apb_read(ADDR_STATUS, status);
        check(status[STATUS_RX_VALID] === 1'b1,
              $sformatf("%s: RX_VALID set for %02h", what, expected));
        check(status[STATUS_RX_OVERFLOW] === 1'b0,
              $sformatf("%s: no overflow for %02h", what, expected));
        apb_read(ADDR_DATA, value);
        check(value[7:0] === expected,
              $sformatf("%s: expected %02h, got %02h", what, expected, value[7:0]));
        apb_read(ADDR_STATUS, status);
        check(status[STATUS_RX_VALID] === 1'b0,
              $sformatf("%s: RX_VALID cleared after reading %02h", what, expected));
    endtask

    task automatic expect_rx_idle(input string what);
        logic [31:0] status;
        #(BIT_NS * 24);
        apb_read(ADDR_STATUS, status);
        check(status[STATUS_RX_VALID] === 1'b0,
              $sformatf("%s: no spurious byte after the line goes idle", what));
    endtask

    // Sends bytes with a zero MSB: the final data bit looks like a new start bit
    // if the receiver stops waiting before the stop bit.
    task automatic rx_at_scale(input real scale, input string what);
        drive_rx(8'h41, scale);
        expect_rx(8'h41, what);
        drive_rx(8'h00, scale);
        expect_rx(8'h00, what);
        drive_rx(8'hFF, scale);
        expect_rx(8'hFF, what);
        expect_rx_idle(what);
    endtask

    logic [31:0] val;
    logic [7:0]  tx_pattern [0:4];

    initial begin
        $dumpfile("tb_apb_uart.vcd");
        $dumpvars(0, tb_apb_uart);

        #100;
        @(posedge pclk);
        preset_n = 1'b1;
        #100;

        // 1. Reset values
        apb_read(ADDR_STATUS, val);
        check(val === 32'h0000_0002, $sformatf("STATUS reset value, got %08h", val));
        apb_read(ADDR_CTRL, val);
        check(val === 32'h0000_0003, $sformatf("CTRL reset value, got %08h", val));
        apb_read(ADDR_BAUD, val);
        check(val === 32'(BAUD_DIV), $sformatf("BAUD reset value, got %08h", val));
        check(pready === 1'b1, "PREADY is high");
        check(pslverr === 1'b0, "PSLVERR is low");

        // 2. TX framing and consecutive bytes
        tx_pattern[0] = 8'h55;
        tx_pattern[1] = 8'h3C;
        tx_pattern[2] = 8'h00;
        tx_pattern[3] = 8'hFF;
        tx_pattern[4] = 8'h41;
        for (int i = 0; i < 5; i++) send_tx(tx_pattern[i]);
        #(BIT_NS * 13);
        check(tx_count == 5, $sformatf("TX frame count, got %0d", tx_count));
        check(tx_framing_errors == 0,
              $sformatf("TX framing errors, got %0d", tx_framing_errors));
        for (int i = 0; i < 5; i++) begin
            check(tx_got[i] === tx_pattern[i],
                  $sformatf("TX byte %0d: expected %02h, got %02h",
                            i, tx_pattern[i], tx_got[i]));
        end

        // 3. RX at nominal baud and at +/-2 percent
        rx_at_scale(1.00, "RX nominal");
        rx_at_scale(1.02, "RX 2% slow");
        rx_at_scale(0.98, "RX 2% fast");

        // 4. Overflow: the newest byte is kept and reading clears both flags
        drive_rx(8'h11, 1.0);
        drive_rx(8'h22, 1.0);
        apb_read(ADDR_STATUS, val);
        check(val[STATUS_RX_VALID] === 1'b1, "overflow: RX_VALID stays set");
        check(val[STATUS_RX_OVERFLOW] === 1'b1, "overflow: RX_OVERFLOW set");
        apb_read(ADDR_DATA, val);
        check(val[7:0] === 8'h22, $sformatf("overflow: newest byte kept, got %02h", val[7:0]));
        apb_read(ADDR_STATUS, val);
        check(val[STATUS_RX_VALID] === 1'b0, "overflow: RX_VALID cleared by read");
        check(val[STATUS_RX_OVERFLOW] === 1'b0, "overflow: RX_OVERFLOW cleared by read");

        // 5. A byte received while RX is disabled is ignored
        apb_write(ADDR_CTRL, 32'h1);
        drive_rx(8'h77, 1.0);
        apb_read(ADDR_STATUS, val);
        check(val[STATUS_RX_VALID] === 1'b0, "RX disabled: byte ignored");
        apb_write(ADDR_CTRL, 32'h3);

        // 6. Framing error: a low stop bit must not produce a byte
        uart_rx = 1'b0;
        #(BIT_NS * 10);
        uart_rx = 1'b1;
        #(BIT_NS * 2);
        apb_read(ADDR_STATUS, val);
        check(val[STATUS_RX_VALID] === 1'b0, "framing error: byte dropped");

        // 7. A read in the same cycle as a new byte returns the old byte and
        //    leaves the new byte valid, without reporting an overflow.
        drive_rx(8'h31, 1.0);
        fork
            drive_rx(8'h32, 1.0);
            begin
                @(posedge u_dut.rx_done);
                paddr   = ADDR_DATA;
                pwrite  = 1'b0;
                psel    = 1'b1;
                penable = 1'b1;
                @(posedge pclk);
                val = prdata;
                psel    <= 1'b0;
                penable <= 1'b0;
            end
        join
        check(val[7:0] === 8'h31, $sformatf("same-cycle read: old byte, got %02h", val[7:0]));
        apb_read(ADDR_STATUS, val);
        check(val[STATUS_RX_VALID] === 1'b1, "same-cycle read: new byte valid");
        check(val[STATUS_RX_OVERFLOW] === 1'b0, "same-cycle read: no overflow");
        apb_read(ADDR_DATA, val);
        check(val[7:0] === 8'h32, $sformatf("same-cycle read: new byte, got %02h", val[7:0]));

        #1000;
        $display("RESULT: %0d checks, %0d failures", checks, failures);
        if (failures != 0) $fatal(1, "[TB_APB_UART] UART verification failed");
        $display("PASS: APB UART directed tests");
        $finish;
    end

    initial begin
        #30000000;
        $fatal(1, "[TB_APB_UART] ERROR: Simulation Timeout!");
    end

endmodule
