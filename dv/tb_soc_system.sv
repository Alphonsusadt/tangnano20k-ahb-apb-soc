// ==============================================================================
// Testbench: tb_soc_system
// Description: Self-checking system regression for soc_top without a CPU. A pipelined
//              AHB-Lite master is forced onto the undriven cpu_* nets, so every access
//              goes through the real interconnect, bridge, and peripherals, and is
//              checked at the chip pins where possible. Expected values come from
//              docs/memory_map.md and the AHB-Lite and APB4 protocols.
// ==============================================================================

`timescale 1ns / 1ps

module tb_soc_system;

    localparam [2:0] SIZE_BYTE = 3'b000;
    localparam [2:0] SIZE_HALF = 3'b001;
    localparam [2:0] SIZE_WORD = 3'b010;

    localparam [1:0] TRANS_IDLE   = 2'b00;
    localparam [1:0] TRANS_NONSEQ = 2'b10;

    localparam [31:0] ROM_BASE  = 32'h0000_0000;
    localparam [31:0] SRAM_BASE = 32'h2000_0000;
    localparam [31:0] UART_BASE = 32'h4000_0000;
    localparam [31:0] SPI_BASE  = 32'h4000_1000;
    localparam [31:0] GPIO_BASE = 32'h4000_2000;

    localparam [31:0] UART_DATA   = UART_BASE + 32'h00;
    localparam [31:0] UART_STATUS = UART_BASE + 32'h04;
    localparam [31:0] UART_CTRL   = UART_BASE + 32'h08;
    localparam [31:0] UART_BAUD   = UART_BASE + 32'h0C;

    localparam [31:0] SPI_CR     = SPI_BASE + 32'h00;
    localparam [31:0] SPI_SR     = SPI_BASE + 32'h04;
    localparam [31:0] SPI_TXDATA = SPI_BASE + 32'h08;
    localparam [31:0] SPI_RXDATA = SPI_BASE + 32'h0C;
    localparam [31:0] SPI_CS     = SPI_BASE + 32'h10;

    localparam [31:0] GPIO_OUT = GPIO_BASE + 32'h00;
    localparam [31:0] GPIO_IN  = GPIO_BASE + 32'h04;
    localparam [31:0] GPIO_DIR = GPIO_BASE + 32'h08;

    localparam [31:0] UNMAPPED = 32'h1000_0000;
    localparam [31:0] RESERVED = 32'h4000_3000;
    localparam [31:0] GARBAGE  = 32'hDEAD_BEEF;

    localparam integer UART_DIV    = 15;
    localparam integer UART_PERIOD = UART_DIV + 1;
    localparam integer POLL_LIMIT  = 5000;
    localparam integer RANDOM_OPS  = 6000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic btn_s2 = 1'b1;
    logic uart_rx = 1'b1;

    wire       uart_tx;
    wire       spi_sck;
    wire       spi_mosi;
    wire [7:0] spi_cs_n;
    wire [5:0] led;

    // Master signals, forced onto the undriven cpu_* nets in soc_top.
    logic [31:0] haddr  = 32'h0;
    logic [1:0]  htrans = TRANS_IDLE;
    logic        hwrite = 1'b0;
    logic [2:0]  hsize  = SIZE_WORD;
    logic [31:0] hwdata = GARBAGE;

    wire         hready = u_dut.cpu_hready;
    wire [31:0]  hrdata = u_dut.cpu_hrdata;
    wire         hresp  = u_dut.cpu_hresp;

    logic        prev_write = 1'b0;
    logic [31:0] prev_wdata = GARBAGE;
    logic [31:0] last_rdata = 32'h0;

    // Set by any ERROR on the bus. Tests clear it before the access they check.
    logic saw_error = 1'b0;

    integer checks = 0;
    integer failures = 0;
    integer group_checks = 0;
    integer group_failures = 0;
    integer seed = 32'h50C5_1234;

    always #18.518 clk = ~clk;

    // The slave answers with inverted MOSI, so RX cannot pass by keeping old data.
    soc_top u_dut (
        .clk_27m  (clk),
        .rst_n    (rst_n),
        .btn_s2   (btn_s2),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (~spi_mosi),
        .spi_cs_n (spi_cs_n),
        .led      (led)
    );

    initial begin
        force u_dut.cpu_haddr  = haddr;
        force u_dut.cpu_htrans = htrans;
        force u_dut.cpu_hwrite = hwrite;
        force u_dut.cpu_hsize  = hsize;
        force u_dut.cpu_hwdata = hwdata;
    end

    always @(posedge clk) begin
        if (hresp === 1'b1) saw_error = 1'b1;
    end

    // SPI pin monitor. Modes 0 and 3 both sample on the rising edge of SCK.
    logic       spi_mon_on = 1'b0;
    logic       spi_mon_lsb = 1'b0;
    logic [7:0] spi_mon_data = 8'h00;
    logic [7:0] spi_mon_cs = 8'hFF;
    integer     spi_mon_bits = 0;

    always @(posedge spi_sck) begin
        if (spi_mon_on) begin
            spi_mon_data = spi_mon_lsb ? {spi_mosi, spi_mon_data[7:1]}
                                       : {spi_mon_data[6:0], spi_mosi};
            spi_mon_bits = spi_mon_bits + 1;
            spi_mon_cs   = spi_cs_n;
        end
    end

    task automatic check_eq(input [31:0] got, input [31:0] want, input string what);
        checks = checks + 1;
        group_checks = group_checks + 1;
        if (got !== want) begin
            failures = failures + 1;
            group_failures = group_failures + 1;
            $display("FAIL @ %0t: %s: got %08h, want %08h", $time, what, got, want);
        end
    endtask

    task automatic begin_group;
        group_checks = 0;
        group_failures = 0;
    endtask

    task automatic end_group(input string name);
        $display("GROUP %-28s %0d checks, %0d failures", name, group_checks, group_failures);
    endtask

    // Present one address phase. The previous transfer's data phase runs at the
    // same time, so HWDATA here belongs to the previous transfer, not this one.
    task automatic xfer(input [31:0] addr, input logic write, input [2:0] size,
                        input [31:0] wdata);
        haddr  <= addr;
        htrans <= TRANS_NONSEQ;
        hwrite <= write;
        hsize  <= size;
        hwdata <= prev_write ? prev_wdata : GARBAGE;
        @(posedge clk);
        while (hready !== 1'b1) @(posedge clk);
        last_rdata = hrdata;
        prev_write = write;
        prev_wdata = wdata;
    endtask

    // Go idle and let the last data phase finish.
    task automatic flush;
        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        hwdata <= prev_write ? prev_wdata : GARBAGE;
        @(posedge clk);
        while (hready !== 1'b1) @(posedge clk);
        last_rdata = hrdata;
        prev_write = 1'b0;
        hwdata <= GARBAGE;
    endtask

    task automatic write(input [31:0] addr, input [2:0] size, input [31:0] wdata);
        xfer(addr, 1'b1, size, wdata);
        flush;
    endtask

    task automatic read(input [31:0] addr, output [31:0] rdata);
        xfer(addr, 1'b0, SIZE_WORD, 32'h0);
        flush;
        rdata = last_rdata;
    endtask

    task automatic check_read(input [31:0] addr, input [31:0] want, input string what);
        logic [31:0] val;
        read(addr, val);
        check_eq(val, want, what);
    endtask

    // ---------------------------------------------------------------------------
    // Reset values from docs/memory_map.md. SPI_SR compares only BUSY and TX_EMPTY.
    // ---------------------------------------------------------------------------
    task automatic test_reset_values;
        logic [31:0] val;
        begin_group;
        check_read(GPIO_OUT, 32'h3F, "GPIO_OUT reset value");
        check_read(GPIO_DIR, 32'h3F, "GPIO_DIR reset value");
        check_eq({26'h0, led}, 32'h3F, "LEDs are off after reset");
        check_read(UART_STATUS, 32'h02, "UART_STATUS reset value");
        check_read(UART_CTRL, 32'h03, "UART_CTRL reset value");
        check_read(UART_BAUD, 32'hEA, "UART_BAUD reset value");
        check_eq({31'h0, uart_tx}, 32'h1, "UART TX idles high");
        check_read(SPI_CR, 32'h00, "SPI_CR reset value");
        read(SPI_SR, val);
        check_eq(val & 32'h3, 32'h2, "SPI_SR idle bits");
        check_read(SPI_CS, 32'hFF, "SPI_CS reset value");
        check_eq({24'h0, spi_cs_n}, 32'hFF, "SPI chip selects are idle");
        end_group("reset values");
    endtask

    // ---------------------------------------------------------------------------
    // GPIO, from bus transfer to chip pin and back.
    // ---------------------------------------------------------------------------
    task automatic test_gpio_pins;
        logic [31:0] val;
        begin_group;
        write(GPIO_OUT, SIZE_WORD, 32'h0000_0015);
        check_eq({26'h0, led}, 32'h15, "GPIO_OUT word write reaches the LEDs");
        write(GPIO_OUT, SIZE_BYTE, 32'hFFFF_FF2A);
        check_eq({26'h0, led}, 32'h2A, "GPIO_OUT byte write reaches the LEDs");
        write(GPIO_OUT, SIZE_WORD, 32'h0000_003F);

        btn_s2 <= 1'b0;
        repeat (2) @(posedge clk);
        read(GPIO_IN, val);
        check_eq(val & 32'h2, 32'h0, "button S2 pressed");
        btn_s2 <= 1'b1;
        repeat (2) @(posedge clk);
        read(GPIO_IN, val);
        check_eq(val & 32'h2, 32'h2, "button S2 released");
        end_group("GPIO pins");
    endtask

    // ---------------------------------------------------------------------------
    // UART transmit, decoded from the pin by a model receiver.
    // ---------------------------------------------------------------------------
    task automatic capture_uart(input integer period, input [7:0] want, input string what);
        logic [7:0] got;
        integer n;
        integer i;
        n = 0;
        while (uart_tx !== 1'b0 && n < POLL_LIMIT) begin
            @(posedge clk);
            n = n + 1;
        end
        check_eq({31'h0, uart_tx}, 32'h0, {what, ": start bit"});
        repeat (period / 2) @(posedge clk);
        check_eq({31'h0, uart_tx}, 32'h0, {what, ": start bit holds to mid-bit"});
        for (i = 0; i < 8; i = i + 1) begin
            repeat (period) @(posedge clk);
            got[i] = uart_tx;
        end
        repeat (period) @(posedge clk);
        check_eq({31'h0, uart_tx}, 32'h1, {what, ": stop bit"});
        check_eq({24'h0, got}, {24'h0, want}, {what, ": data bits"});
    endtask

    task automatic wait_uart_idle;
        logic [31:0] val;
        integer n;
        n = 0;
        read(UART_STATUS, val);
        while (!val[1] && n < POLL_LIMIT) begin
            read(UART_STATUS, val);
            n = n + 1;
        end
        repeat (2 * 235) @(posedge clk);
    endtask

    task automatic test_uart_tx;
        begin_group;
        write(UART_DATA, SIZE_WORD, 32'hFFFF_FF5A);
        capture_uart(235, 8'h5A, "TX at the reset baud");
        wait_uart_idle;

        write(UART_BAUD, SIZE_WORD, UART_DIV);
        check_read(UART_BAUD, UART_DIV, "UART_BAUD programmed");
        write(UART_DATA, SIZE_WORD, 32'h0000_00A5);
        capture_uart(UART_PERIOD, 8'hA5, "TX 0xA5");
        wait_uart_idle;
        write(UART_DATA, SIZE_BYTE, 32'h0000_003C);
        capture_uart(UART_PERIOD, 8'h3C, "TX 0x3C with a byte write");
        wait_uart_idle;
        write(UART_DATA, SIZE_WORD, 32'h0000_0000);
        capture_uart(UART_PERIOD, 8'h00, "TX 0x00");
        wait_uart_idle;
        write(UART_DATA, SIZE_WORD, 32'h0000_00FF);
        capture_uart(UART_PERIOD, 8'hFF, "TX 0xFF");
        wait_uart_idle;

        write(UART_CTRL, SIZE_WORD, 32'h0000_0002);
        write(UART_DATA, SIZE_WORD, 32'h0000_0055);
        repeat (4 * UART_PERIOD) @(posedge clk);
        check_eq({31'h0, uart_tx}, 32'h1, "TX stays idle when TX_EN is low");
        write(UART_CTRL, SIZE_WORD, 32'h0000_0003);
        end_group("UART transmit");
    endtask

    // ---------------------------------------------------------------------------
    // UART receive, driven at the pin by a model transmitter.
    // ---------------------------------------------------------------------------
    task automatic send_uart(input [7:0] data, input logic stop);
        integer i;
        uart_rx <= 1'b0;
        repeat (UART_PERIOD) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            uart_rx <= data[i];
            repeat (UART_PERIOD) @(posedge clk);
        end
        uart_rx <= stop;
        repeat (UART_PERIOD) @(posedge clk);
        uart_rx <= 1'b1;
        repeat (UART_PERIOD) @(posedge clk);
    endtask

    task automatic test_uart_rx;
        logic [31:0] val;
        begin_group;
        send_uart(8'hC3, 1'b1);
        read(UART_STATUS, val);
        check_eq(val & 32'h9, 32'h1, "RX_VALID after one byte");
        check_read(UART_DATA, 32'hC3, "RX data");
        read(UART_STATUS, val);
        check_eq(val & 32'h9, 32'h0, "RX_VALID clears after the read");

        send_uart(8'h11, 1'b1);
        send_uart(8'h22, 1'b1);
        read(UART_STATUS, val);
        check_eq(val & 32'h9, 32'h9, "RX_OVERFLOW after an unread byte");
        check_read(UART_DATA, 32'h22, "newest byte is kept");
        read(UART_STATUS, val);
        check_eq(val & 32'h9, 32'h0, "flags clear after the read");

        send_uart(8'h77, 1'b0);
        repeat (2 * UART_PERIOD) @(posedge clk);
        read(UART_STATUS, val);
        check_eq(val & 32'h1, 32'h0, "framing error drops the byte");
        end_group("UART receive");
    endtask

    // ---------------------------------------------------------------------------
    // SPI, checked at the pins.
    // ---------------------------------------------------------------------------
    task automatic wait_spi_idle;
        logic [31:0] val;
        integer n;
        n = 0;
        read(SPI_SR, val);
        while (val[0] && n < POLL_LIMIT) begin
            read(SPI_SR, val);
            n = n + 1;
        end
    endtask

    task automatic spi_transfer(input [31:0] cr, input logic lsb, input [7:0] data,
                                input string what);
        write(SPI_CR, SIZE_WORD, cr);
        repeat (4) @(posedge clk);
        spi_mon_lsb  = lsb;
        spi_mon_bits = 0;
        spi_mon_data = 8'h00;
        spi_mon_on   = 1'b1;
        write(SPI_TXDATA, SIZE_WORD, {24'hFFFFFF, data});
        wait_spi_idle;
        spi_mon_on = 1'b0;
        check_eq(spi_mon_bits, 8, {what, ": eight SCK samples"});
        check_eq({24'h0, spi_mon_data}, {24'h0, data}, {what, ": MOSI"});
        check_read(SPI_RXDATA, {24'h0, ~data}, {what, ": MISO"});
    endtask

    task automatic test_spi;
        begin_group;
        // CR: AUTO_CS[12], CLK_DIV[11:4], LSB_FIRST[3], CPOL[2], CPHA[1], EN[0].
        spi_transfer(32'h0000_0031, 1'b0, 8'hA5, "mode 0");
        spi_transfer(32'h0000_0037, 1'b0, 8'h3C, "mode 3");
        spi_transfer(32'h0000_0039, 1'b1, 8'h1E, "mode 0 LSB first");

        spi_transfer(32'h0000_1031, 1'b0, 8'h96, "auto CS");
        check_eq({24'h0, spi_mon_cs}, 32'hFE, "auto CS is low during the transfer");
        check_eq({24'h0, spi_cs_n}, 32'hFF, "auto CS is released afterwards");

        write(SPI_CR, SIZE_WORD, 32'h0000_0031);
        write(SPI_CS, SIZE_WORD, 32'h0000_00FD);
        check_eq({24'h0, spi_cs_n}, 32'hFD, "manual CS reaches the pins");
        write(SPI_CS, SIZE_WORD, 32'h0000_00FF);
        check_eq({24'h0, spi_cs_n}, 32'hFF, "manual CS is released");
        write(SPI_CR, SIZE_WORD, 32'h0000_0000);
        end_group("SPI");
    endtask

    // ---------------------------------------------------------------------------
    // An APB transfer waiting behind the default slave's ERROR. HREADY is low from
    // the interconnect, not from the bridge, so the bridge must use global HREADY.
    // ---------------------------------------------------------------------------
    task automatic error_then_waiting(input [31:0] addr, input logic write_next);
        saw_error = 1'b0;
        xfer(UNMAPPED, 1'b1, SIZE_WORD, 32'hBAD0_BAD0);
        haddr  <= addr;
        htrans <= TRANS_NONSEQ;
        hwrite <= write_next;
        hsize  <= SIZE_WORD;
        hwdata <= prev_wdata;
        @(posedge clk);
        check_eq({31'h0, hresp}, 32'h1, "first ERROR cycle: HRESP");
        check_eq({31'h0, hready}, 32'h0, "first ERROR cycle: HREADY");
    endtask

    task automatic test_transfer_behind_error;
        logic [31:0] val;
        begin_group;

        // Cancelled write: the register must not change.
        write(GPIO_OUT, SIZE_WORD, 32'h0000_0015);
        error_then_waiting(GPIO_OUT, 1'b1);
        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        hwdata <= 32'hFFFF_FF2A;
        @(posedge clk);
        check_eq({31'h0, hready}, 32'h1, "second ERROR cycle: HREADY");
        prev_write = 1'b0;
        hwdata <= GARBAGE;
        repeat (8) @(posedge clk);
        check_read(GPIO_OUT, 32'h15, "cancelled APB write does not happen");

        // Cancelled read of a register with a side effect: RX must stay valid.
        send_uart(8'h6D, 1'b1);
        error_then_waiting(UART_DATA, 1'b0);
        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        @(posedge clk);
        prev_write = 1'b0;
        hwdata <= GARBAGE;
        repeat (8) @(posedge clk);
        read(UART_STATUS, val);
        check_eq(val & 32'h1, 32'h1, "cancelled APB read does not clear RX_VALID");
        check_read(UART_DATA, 32'h6D, "RX byte survives the cancelled read");

        // Held write: accepted at the end of the ERROR, with its own data.
        write(GPIO_OUT, SIZE_WORD, 32'h0000_0015);
        error_then_waiting(GPIO_OUT, 1'b1);
        hwdata <= 32'hFFFF_FF00;
        @(posedge clk);
        check_eq({31'h0, hready}, 32'h1, "held write: second ERROR cycle");
        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        hwdata <= 32'h0000_002A;
        @(posedge clk);
        while (hready !== 1'b1) @(posedge clk);
        prev_write = 1'b0;
        hwdata <= GARBAGE;
        repeat (8) @(posedge clk);
        check_read(GPIO_OUT, 32'h2A, "held APB write uses its own data");
        end_group("APB behind default ERROR");
    endtask

    // ---------------------------------------------------------------------------
    // Addresses inside a peripheral's 4 KB block but past its registers must not act
    // on a real register, and they answer with ERROR through PSLVERR and the bridge.
    // ---------------------------------------------------------------------------
    task automatic check_offset(input [31:0] addr, input logic want_error, input string name);
        logic [31:0] val;
        saw_error = 1'b0;
        read(addr, val);
        check_eq({31'h0, saw_error}, {31'h0, want_error}, {name, " read response"});
        saw_error = 1'b0;
        write(addr, SIZE_WORD, val);
        check_eq({31'h0, saw_error}, {31'h0, want_error}, {name, " write response"});
    endtask

    task automatic test_offset_responses;
        integer bit_index;
        begin_group;
        check_offset(GPIO_BASE + 32'h008, 1'b0, "GPIO last register");
        check_offset(GPIO_BASE + 32'h00C, 1'b1, "GPIO past the registers");
        check_offset(GPIO_BASE + 32'h010, 1'b1, "GPIO +0x010");
        check_offset(GPIO_BASE + 32'hFFC, 1'b1, "GPIO last word of the block");
        check_offset(UART_BASE + 32'h00C, 1'b0, "UART last register");
        check_offset(UART_BASE + 32'h010, 1'b1, "UART past the registers");
        check_offset(UART_BASE + 32'hFFC, 1'b1, "UART last word of the block");
        check_offset(SPI_BASE + 32'h010, 1'b0, "SPI last register");
        check_offset(SPI_BASE + 32'h014, 1'b1, "SPI past the registers");
        check_offset(SPI_BASE + 32'h020, 1'b1, "SPI +0x020");
        check_offset(SPI_BASE + 32'hFFC, 1'b1, "SPI last word of the block");

        // Walking-one offsets: every offset bit must take part in the decode.
        for (bit_index = 4; bit_index < 12; bit_index = bit_index + 1) begin
            check_offset(GPIO_BASE + (32'h1 << bit_index), 1'b1,
                         $sformatf("GPIO offset bit %0d", bit_index));
            check_offset(UART_BASE + (32'h1 << bit_index), 1'b1,
                         $sformatf("UART offset bit %0d", bit_index));
            if (bit_index > 4) begin
                check_offset(SPI_BASE + (32'h1 << bit_index), 1'b1,
                             $sformatf("SPI offset bit %0d", bit_index));
            end
        end
        end_group("offset responses");
    endtask

    task automatic test_register_aliases;
        logic [31:0] val;
        begin_group;
        write(GPIO_OUT, SIZE_WORD, 32'h0000_0015);
        write(GPIO_DIR, SIZE_WORD, 32'h0000_0015);
        write(GPIO_BASE + 32'h010, SIZE_WORD, 32'h0000_002A);
        check_read(GPIO_OUT, 32'h15, "GPIO +0x010 does not write GPIO_OUT");
        write(GPIO_BASE + 32'hFF0, SIZE_WORD, 32'h0000_002A);
        check_read(GPIO_OUT, 32'h15, "GPIO +0xFF0 does not write GPIO_OUT");
        write(GPIO_BASE + 32'h018, SIZE_WORD, 32'h0000_002A);
        check_read(GPIO_DIR, 32'h15, "GPIO +0x018 does not write GPIO_DIR");
        write(GPIO_DIR, SIZE_WORD, 32'h0000_003F);
        write(GPIO_OUT, SIZE_WORD, 32'h0000_003F);

        write(UART_BASE + 32'h018, SIZE_WORD, 32'h0000_0000);
        check_read(UART_CTRL, 32'h03, "UART +0x018 does not write UART_CTRL");
        write(UART_CTRL, SIZE_WORD, 32'h0000_0003);
        write(UART_BASE + 32'h01C, SIZE_WORD, 32'h0000_0007);
        check_read(UART_BAUD, UART_DIV, "UART +0x01C does not write UART_BAUD");
        write(UART_BAUD, SIZE_WORD, UART_DIV);
        write(UART_BASE + 32'h010, SIZE_WORD, 32'h0000_0055);
        read(UART_STATUS, val);
        check_eq(val & 32'h2, 32'h2, "UART +0x010 write does not start TX");
        wait_uart_idle;

        send_uart(8'h4E, 1'b1);
        read(UART_BASE + 32'h010, val);
        read(UART_STATUS, val);
        check_eq(val & 32'h1, 32'h1, "UART +0x010 read does not clear RX_VALID");
        read(UART_DATA, val);

        write(SPI_CR, SIZE_WORD, 32'h0000_0030);
        write(SPI_BASE + 32'h020, SIZE_WORD, 32'h0000_0FFE);
        check_read(SPI_CR, 32'h30, "SPI +0x020 does not write SPI_CR");
        write(SPI_CR, SIZE_WORD, 32'h0000_0031);
        write(SPI_BASE + 32'h028, SIZE_WORD, 32'h0000_0055);
        read(SPI_SR, val);
        check_eq(val & 32'h1, 32'h0, "SPI +0x028 write does not start a transfer");
        wait_spi_idle;
        write(SPI_BASE + 32'h030, SIZE_WORD, 32'h0000_0000);
        check_read(SPI_CS, 32'hFF, "SPI +0x030 does not write SPI_CS");
        write(SPI_CS, SIZE_WORD, 32'h0000_00FF);
        write(SPI_CR, SIZE_WORD, 32'h0000_0000);
        end_group("register aliases");
    endtask

    // ---------------------------------------------------------------------------
    // Random pipelined traffic across ROM, SRAM, and APB registers, checked against
    // a reference model. With errors on, it also targets unmapped and reserved
    // addresses and randomly cancels the transfer waiting behind each ERROR.
    // ---------------------------------------------------------------------------
    logic [7:0]  sram_model [0:63];
    logic [31:0] rom_model  [0:15];
    logic [5:0]  m_gpio_out;
    logic [5:0]  m_gpio_dir;
    logic [15:0] m_uart_baud;
    logic [7:0]  m_spi_cs;

    function automatic [3:0] lane_mask(input [1:0] offset, input [2:0] size);
        case (size)
            SIZE_BYTE: lane_mask = 4'b0001 << offset;
            SIZE_HALF: lane_mask = offset[1] ? 4'b1100 : 4'b0011;
            default:   lane_mask = 4'b1111;
        endcase
    endfunction

    function automatic [31:0] byte_mask(input [3:0] mask);
        byte_mask = {{8{mask[3]}}, {8{mask[2]}}, {8{mask[1]}}, {8{mask[0]}}};
    endfunction

    // Half the SRAM pool sits at the top of memory.
    function automatic [31:0] sram_addr(input [3:0] index);
        sram_addr = SRAM_BASE + {index[3] ? 10'h3FF : 10'h000, index[2:0], 2'b00};
    endfunction

    function automatic [31:0] rom_addr(input [3:0] index);
        rom_addr = ROM_BASE + {index[3] ? 10'h3FF : 10'h000, index[2:0], 2'b00};
    endfunction

    function automatic [31:0] model_read(input [31:0] addr);
        integer i;
        logic [3:0] index;
        model_read = 32'h0;
        if (addr[31:28] == 4'h2) begin
            index = {addr[14], addr[4:2]};
            for (i = 0; i < 4; i = i + 1) begin
                model_read[8*i +: 8] = sram_model[{index, 2'b00} + i];
            end
        end else if (addr[31:28] == 4'h0) begin
            index = {addr[14], addr[4:2]};
            model_read = rom_model[index];
        end else begin
            case ({addr[31:2], 2'b00})
                GPIO_OUT:  model_read = {26'h0, m_gpio_out};
                GPIO_DIR:  model_read = {26'h0, m_gpio_dir};
                UART_BAUD: model_read = {16'h0, m_uart_baud};
                SPI_CS:    model_read = {24'h0, m_spi_cs};
                default:   model_read = 32'h0;
            endcase
        end
    endfunction

    task automatic model_write(input [31:0] addr, input [2:0] size, input [31:0] data);
        integer i;
        logic [3:0]  mask;
        logic [3:0]  index;
        logic [31:0] bits;
        mask = lane_mask(addr[1:0], size);
        bits = byte_mask(mask);
        if (addr[31:28] == 4'h2) begin
            index = {addr[14], addr[4:2]};
            for (i = 0; i < 4; i = i + 1) begin
                if (mask[i]) sram_model[{index, 2'b00} + i] = data[8*i +: 8];
            end
        end else begin
            case ({addr[31:2], 2'b00})
                GPIO_OUT:  if (mask[0]) m_gpio_out = data[5:0];
                GPIO_DIR:  if (mask[0]) m_gpio_dir = data[5:0];
                UART_BAUD: m_uart_baud = (m_uart_baud & ~bits[15:0]) | (data[15:0] & bits[15:0]);
                SPI_CS:    if (mask[0]) m_spi_cs = data[7:0];
                default: ;
            endcase
        end
    endtask

    task automatic pick_transfer(input logic with_errors, output logic valid, output logic wr,
                                 output [31:0] addr, output [2:0] size, output [31:0] wdata,
                                 output logic err);
        logic [31:0] r;
        logic [1:0]  offset;
        r      = $random(seed);
        wdata  = $random(seed);
        valid  = (r[3:0] != 4'd15);
        wr     = r[4];
        err    = 1'b0;
        offset = r[6:5];
        case (r[8:7])
            2'd0: begin size = SIZE_BYTE; end
            2'd1: begin size = SIZE_HALF; offset = {r[6], 1'b0}; end
            default: begin size = SIZE_WORD; offset = 2'b00; end
        endcase

        case (r[13:9])
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11: addr = sram_addr(r[17:14]) + offset;
            12, 13, 14: begin
                addr = rom_addr(r[17:14]) + offset;
                wr   = 1'b0;
            end
            15, 16, 17, 18: addr = GPIO_OUT + offset;
            19, 20: addr = GPIO_DIR + offset;
            21, 22: addr = UART_BAUD + offset;
            23, 24: addr = SPI_CS + offset;
            25: begin addr = GPIO_IN; wr = 1'b0; size = SIZE_WORD; valid = 1'b0; end
            default: begin
                if (with_errors) begin
                    addr = r[18] ? (UNMAPPED + {r[17:14], 2'b00}) : (RESERVED + {r[17:14], 2'b00});
                    size = SIZE_WORD;
                    err  = 1'b1;
                end else begin
                    addr = sram_addr(r[17:14]) + offset;
                end
            end
        endcase

        // Word and halfword register reads and writes must stay naturally aligned.
        if (size == SIZE_WORD) addr[1:0] = 2'b00;
        if (!valid) err = 1'b0;
    endtask

    task automatic prepare_random;
        integer i;
        for (i = 0; i < 16; i = i + 1) begin
            write(sram_addr(i[3:0]), SIZE_WORD, 32'h0);
            rom_model[i] = $random(seed);
            u_dut.rom_mem[rom_addr(i[3:0]) >> 2] = rom_model[i];
        end
        for (i = 0; i < 64; i = i + 1) sram_model[i] = 8'h00;
        m_gpio_out  = 6'h3F;
        m_gpio_dir  = 6'h3F;
        m_uart_baud = UART_DIV;
        m_spi_cs    = 8'hFF;
        write(GPIO_OUT, SIZE_WORD, {26'h0, m_gpio_out});
        write(GPIO_DIR, SIZE_WORD, {26'h0, m_gpio_dir});
        write(UART_BAUD, SIZE_WORD, {16'h0, m_uart_baud});
        write(SPI_CS, SIZE_WORD, {24'h0, m_spi_cs});
    endtask

    task automatic finish_pending(input logic p_valid, input logic p_write,
                                  input [31:0] p_addr, input [2:0] p_size,
                                  input [31:0] p_wdata, input logic p_err,
                                  input logic p_err_seen);
        logic [31:0] mask;
        logic [31:0] want;
        if (p_valid) begin
            if (p_err) begin
                check_eq({30'h0, hresp, p_err_seen}, 32'h3,
                         $sformatf("random ERROR for %08h", p_addr));
            end else begin
                check_eq({31'h0, hresp}, 32'h0, $sformatf("random OKAY for %08h", p_addr));
                if (p_write) begin
                    model_write(p_addr, p_size, p_wdata);
                end else begin
                    mask = byte_mask(lane_mask(p_addr[1:0], p_size));
                    want = model_read(p_addr);
                    check_eq(hrdata & mask, want & mask,
                             $sformatf("random read %08h size %0d", p_addr, p_size));
                end
            end
        end
    endtask

    task automatic random_traffic(input logic with_errors, input string name);
        integer n;
        logic        p_valid = 1'b0;
        logic        p_write = 1'b0;
        logic        p_err = 1'b0;
        logic [31:0] p_addr = 32'h0;
        logic [2:0]  p_size = SIZE_WORD;
        logic [31:0] p_wdata = 32'h0;
        logic        n_valid;
        logic        n_write;
        logic        n_err;
        logic [31:0] n_addr;
        logic [2:0]  n_size;
        logic [31:0] n_wdata;
        logic        done;
        logic        cancelled;
        logic        err_seen;
        logic [31:0] coin;

        begin_group;
        prepare_random;
        for (n = 0; n < RANDOM_OPS; n = n + 1) begin
            pick_transfer(with_errors, n_valid, n_write, n_addr, n_size, n_wdata, n_err);
            haddr  <= n_addr;
            htrans <= n_valid ? TRANS_NONSEQ : TRANS_IDLE;
            hwrite <= n_write;
            hsize  <= n_size;
            hwdata <= (p_valid && p_write) ? p_wdata : $random(seed);

            done = 1'b0;
            cancelled = 1'b0;
            err_seen = 1'b0;
            while (!done) begin
                @(posedge clk);
                if (hready === 1'b1) begin
                    done = 1'b1;
                end else if (hresp === 1'b1) begin
                    // First ERROR cycle: the waiting transfer may be cancelled.
                    err_seen = 1'b1;
                    coin = $random(seed);
                    if (coin[0] && n_valid) begin
                        htrans <= TRANS_IDLE;
                        hwrite <= 1'b0;
                        cancelled = 1'b1;
                    end
                end
            end

            finish_pending(p_valid, p_write, p_addr, p_size, p_wdata, p_err, err_seen);

            p_valid = n_valid && !cancelled;
            p_write = n_write;
            p_addr  = n_addr;
            p_size  = n_size;
            p_wdata = n_wdata;
            p_err   = n_err;
        end

        htrans <= TRANS_IDLE;
        hwrite <= 1'b0;
        hwdata <= (p_valid && p_write) ? p_wdata : GARBAGE;
        done = 1'b0;
        err_seen = 1'b0;
        while (!done) begin
            @(posedge clk);
            if (hready === 1'b1) done = 1'b1;
            else if (hresp === 1'b1) err_seen = 1'b1;
        end
        finish_pending(p_valid, p_write, p_addr, p_size, p_wdata, p_err, err_seen);
        prev_write = 1'b0;
        hwdata <= GARBAGE;
        repeat (4) @(posedge clk);

        // The pins must agree with the model after all the traffic.
        check_eq({26'h0, led}, {26'h0, m_gpio_out}, "LEDs match the model");
        check_eq({24'h0, spi_cs_n}, {24'h0, m_spi_cs}, "chip selects match the model");
        end_group(name);
    endtask

    initial begin
        $dumpfile("tb_soc_system.vcd");
        $dumpvars(0, tb_soc_system);

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        test_reset_values;
        test_gpio_pins;
        test_uart_tx;
        test_uart_rx;
        test_spi;
        test_transfer_behind_error;
        test_register_aliases;
        test_offset_responses;
        random_traffic(1'b0, "random traffic");
        random_traffic(1'b1, "random traffic with ERROR");

        $display("RESULT: %0d checks, %0d failures", checks, failures);
        if (failures != 0) $fatal(1, "[TB_SOC_SYSTEM] System verification failed");
        $display("PASS: SoC system tests");
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "[TB_SOC_SYSTEM] ERROR: Simulation Timeout!");
    end

endmodule
