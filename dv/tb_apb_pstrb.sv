// ==============================================================================
// Testbench: tb_apb_pstrb
// Description: Self-checking regression for APB4 write strobes in apb_gpio, apb_uart,
//              and apb_spi. PSTRB[n] marks PWDATA[8n+7:8n] as valid, so a register
//              byte may change only when its strobe is set. Unselected lanes carry
//              poison, because the master does not guarantee their value. Writes
//              that start a transfer must start it only when the data byte is valid.
// ==============================================================================

`timescale 1ns / 1ps

module tb_apb_pstrb;

    localparam integer GPIO = 0;
    localparam integer UART = 1;
    localparam integer SPI  = 2;

    localparam [31:0] GPIO_OUT = 32'h00;
    localparam [31:0] GPIO_DIR = 32'h08;

    localparam [31:0] UART_DATA   = 32'h00;
    localparam [31:0] UART_STATUS = 32'h04;
    localparam [31:0] UART_CTRL   = 32'h08;
    localparam [31:0] UART_BAUD   = 32'h0C;

    localparam [31:0] SPI_CR     = 32'h00;
    localparam [31:0] SPI_SR     = 32'h04;
    localparam [31:0] SPI_TXDATA = 32'h08;
    localparam [31:0] SPI_RXDATA = 32'h0C;
    localparam [31:0] SPI_CS     = 32'h10;

    localparam integer POLL_LIMIT = 2000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [2:0]  psel = 3'b000;
    logic        penable = 1'b0;
    logic        pwrite = 1'b0;
    logic [31:0] paddr = 32'h0;
    logic [31:0] pwdata = 32'h0;
    logic [3:0]  pstrb = 4'b0000;

    wire [31:0] prdata_gpio, prdata_uart, prdata_spi;
    wire        pready_gpio, pready_uart, pready_spi;
    wire        pslverr_gpio, pslverr_uart, pslverr_spi;

    wire [5:0] gpio_out;
    wire       uart_tx;
    wire       uart_irq;
    wire       spi_sck;
    wire       spi_mosi;
    wire [7:0] spi_cs_n;

    integer checks = 0;
    integer failures = 0;
    integer group_checks = 0;
    integer group_failures = 0;

    always #18.518 clk = ~clk;

    apb_gpio u_gpio (
        .pclk     (clk),
        .preset_n (rst_n),
        .psel     (psel[GPIO]),
        .penable  (penable),
        .pwrite   (pwrite),
        .paddr    (paddr),
        .pwdata   (pwdata),
        .pstrb    (pstrb),
        .prdata   (prdata_gpio),
        .pready   (pready_gpio),
        .pslverr  (pslverr_gpio),
        .gpio_out (gpio_out),
        .gpio_in  (2'b11)
    );

    // TX loops back to RX, and MOSI to MISO, so the data byte can be read back.
    apb_uart u_uart (
        .pclk     (clk),
        .preset_n (rst_n),
        .psel     (psel[UART]),
        .penable  (penable),
        .pwrite   (pwrite),
        .paddr    (paddr),
        .pwdata   (pwdata),
        .pstrb    (pstrb),
        .prdata   (prdata_uart),
        .pready   (pready_uart),
        .pslverr  (pslverr_uart),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_tx),
        .uart_irq (uart_irq)
    );

    apb_spi u_spi (
        .pclk     (clk),
        .preset_n (rst_n),
        .psel     (psel[SPI]),
        .penable  (penable),
        .pwrite   (pwrite),
        .paddr    (paddr),
        .pwdata   (pwdata),
        .pstrb    (pstrb),
        .prdata   (prdata_spi),
        .pready   (pready_spi),
        .pslverr  (pslverr_spi),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (spi_mosi),
        .spi_cs_n (spi_cs_n)
    );

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
        $display("GROUP %-24s %0d checks, %0d failures", name, group_checks, group_failures);
    endtask

    // One APB write. Call just after a rising edge.
    task automatic apb_write(input integer target, input [31:0] addr, input [31:0] data,
                             input [3:0] strb);
        psel    <= 3'b001 << target;
        penable <= 1'b0;
        pwrite  <= 1'b1;
        paddr   <= addr;
        pwdata  <= data;
        pstrb   <= strb;
        @(posedge clk);
        penable <= 1'b1;
        @(posedge clk);
        psel    <= 3'b000;
        penable <= 1'b0;
        pwrite  <= 1'b0;
        pstrb   <= 4'b0000;
    endtask

    // One APB read. APB4 requires PSTRB low during reads.
    task automatic apb_read(input integer target, input [31:0] addr, output [31:0] data);
        psel    <= 3'b001 << target;
        penable <= 1'b0;
        pwrite  <= 1'b0;
        paddr   <= addr;
        pstrb   <= 4'b0000;
        @(posedge clk);
        penable <= 1'b1;
        @(posedge clk);
        case (target)
            GPIO:    data = prdata_gpio;
            UART:    data = prdata_uart;
            default: data = prdata_spi;
        endcase
        psel    <= 3'b000;
        penable <= 1'b0;
    endtask

    task automatic check_reg(input integer target, input [31:0] addr, input [31:0] want,
                             input string what);
        logic [31:0] val;
        apb_read(target, addr, val);
        check_eq(val, want, what);
    endtask

    // Write with the given strobes, then require the register to hold the given value.
    task automatic write_check(input integer target, input [31:0] addr, input [31:0] data,
                               input [3:0] strb, input [31:0] want, input string name);
        apb_write(target, addr, data, strb);
        check_reg(target, addr, want, $sformatf("%s, PSTRB=%04b", name, strb));
    endtask

    // A register that uses only lane 0.
    task automatic test_lane0_reg(input integer target, input [31:0] addr, input [31:0] mask,
                                  input [31:0] start, input [31:0] other, input string name);
        write_check(target, addr, start, 4'b1111, start, {name, " full write"});
        write_check(target, addr, ~start, 4'b0000, start, {name, " no strobes"});
        write_check(target, addr, ~start, 4'b0010, start, {name, " lane 1 only"});
        write_check(target, addr, ~start, 4'b0100, start, {name, " lane 2 only"});
        write_check(target, addr, ~start, 4'b1000, start, {name, " lane 3 only"});
        write_check(target, addr, ~start, 4'b1110, start, {name, " upper lanes"});
        write_check(target, addr, (32'hFFFF_FFFF & ~mask) | other, 4'b0001, other,
                    {name, " lane 0 only"});
        write_check(target, addr, start, 4'b1111, start, {name, " restore"});
    endtask

    task automatic test_gpio;
        begin_group;
        test_lane0_reg(GPIO, GPIO_OUT, 32'h3F, 32'h15, 32'h2A, "GPIO_OUT");
        check_eq({26'h0, gpio_out}, 32'h15, "GPIO_OUT reaches the pins");
        test_lane0_reg(GPIO, GPIO_DIR, 32'h3F, 32'h15, 32'h2A, "GPIO_DIR");
        end_group("GPIO registers");
    endtask

    task automatic test_uart_regs;
        begin_group;
        test_lane0_reg(UART, UART_CTRL, 32'h0F, 32'h03, 32'h0C, "UART_CTRL");
        write_check(UART, UART_CTRL, 32'h03, 4'b1111, 32'h03, "UART_CTRL enable");

        // UART_BAUD uses lanes 0 and 1 independently.
        write_check(UART, UART_BAUD, 32'h0000_1234, 4'b1111, 32'h1234, "UART_BAUD full write");
        write_check(UART, UART_BAUD, 32'hFFFF_FFFF, 4'b0000, 32'h1234, "UART_BAUD no strobes");
        write_check(UART, UART_BAUD, 32'hFFFF_FFFF, 4'b1100, 32'h1234, "UART_BAUD upper half");
        write_check(UART, UART_BAUD, 32'hFFFF_FFAB, 4'b0001, 32'h12AB, "UART_BAUD lane 0");
        write_check(UART, UART_BAUD, 32'hFFFF_CDFF, 4'b0010, 32'hCDAB, "UART_BAUD lane 1");
        write_check(UART, UART_BAUD, 32'hFFFF_5678, 4'b0011, 32'h5678, "UART_BAUD lower half");
        write_check(UART, UART_BAUD, 32'h0000_0004, 4'b1111, 32'h0004, "UART_BAUD fast rate");
        end_group("UART registers");
    endtask

    // UART_DATA starts a transmission, so an invalid data byte must not start one.
    task automatic check_uart_no_start(input [31:0] data, input [3:0] strb);
        logic [31:0] status;
        integer n;
        apb_write(UART, UART_DATA, data, strb);
        apb_read(UART, UART_STATUS, status);
        check_eq({31'h0, status[1]}, 32'h1, $sformatf("UART no TX start, PSTRB=%04b", strb));
        n = 0;
        while (!status[1] && n < POLL_LIMIT) begin
            apb_read(UART, UART_STATUS, status);
            n = n + 1;
        end
        // A wrongly started frame loops back into RX. Let it end, then clear it.
        repeat (120) @(posedge clk);
        apb_read(UART, UART_DATA, status);
    endtask

    task automatic test_uart_data;
        logic [31:0] status;
        integer n;
        begin_group;
        check_uart_no_start(32'hFFFF_A500, 4'b0000);
        check_uart_no_start(32'hFFFF_A500, 4'b0010);
        check_uart_no_start(32'hFFFF_A500, 4'b1110);

        apb_write(UART, UART_DATA, 32'hFFFF_FF55, 4'b0001);
        apb_read(UART, UART_STATUS, status);
        check_eq({31'h0, status[1]}, 32'h0, "UART TX starts with lane 0 strobe");
        n = 0;
        while (!status[0] && n < POLL_LIMIT) begin
            apb_read(UART, UART_STATUS, status);
            n = n + 1;
        end
        check_eq({31'h0, status[0]}, 32'h1, "UART loopback byte arrives");
        check_reg(UART, UART_DATA, 32'h55, "UART sends lane 0");
        end_group("UART_DATA");
    endtask

    task automatic test_spi_regs;
        begin_group;
        check_eq({24'h0, spi_cs_n}, 32'hFF, "SPI_CS reset value at the pins");
        test_lane0_reg(SPI, SPI_CS, 32'hFF, 32'hA5, 32'h5A, "SPI_CS");
        check_eq({24'h0, spi_cs_n}, 32'hA5, "SPI_CS reaches the pins");
        write_check(SPI, SPI_CS, 32'hFF, 4'b0001, 32'hFF, "SPI_CS release");

        // SPI_CR uses lanes 0 and 1 independently. EN stays low here.
        write_check(SPI, SPI_CR, 32'h0000_0A50, 4'b1111, 32'h0A50, "SPI_CR full write");
        write_check(SPI, SPI_CR, 32'hFFFF_FFFF, 4'b0000, 32'h0A50, "SPI_CR no strobes");
        write_check(SPI, SPI_CR, 32'hFFFF_FFFF, 4'b1100, 32'h0A50, "SPI_CR upper half");
        write_check(SPI, SPI_CR, 32'hFFFF_FF3C, 4'b0001, 32'h0A3C, "SPI_CR lane 0");
        write_check(SPI, SPI_CR, 32'hFFFF_15FE, 4'b0010, 32'h153C, "SPI_CR lane 1");
        write_check(SPI, SPI_CR, 32'h0000_0010, 4'b0011, 32'h0010, "SPI_CR lower half");
        end_group("SPI registers");
    endtask

    task automatic wait_spi_idle;
        logic [31:0] status;
        integer n;
        n = 0;
        apb_read(SPI, SPI_SR, status);
        while (status[0] && n < POLL_LIMIT) begin
            apb_read(SPI, SPI_SR, status);
            n = n + 1;
        end
    endtask

    // SPI_TXDATA starts a transfer, so an invalid data byte must not start one.
    task automatic check_spi_no_start(input [31:0] data, input [3:0] strb);
        logic [31:0] status;
        apb_write(SPI, SPI_TXDATA, data, strb);
        apb_read(SPI, SPI_SR, status);
        check_eq({31'h0, status[0]}, 32'h0, $sformatf("SPI no start, PSTRB=%04b", strb));
        wait_spi_idle;
    endtask

    task automatic test_spi_tx;
        logic [31:0] status;
        begin_group;
        write_check(SPI, SPI_CR, 32'h0000_0011, 4'b1111, 32'h0011, "SPI_CR enable");
        check_spi_no_start(32'hFFFF_A500, 4'b0000);
        check_spi_no_start(32'hFFFF_A500, 4'b0010);
        check_spi_no_start(32'hFFFF_A500, 4'b1110);

        apb_write(SPI, SPI_TXDATA, 32'hFFFF_FF3C, 4'b0001);
        apb_read(SPI, SPI_SR, status);
        check_eq({31'h0, status[0]}, 32'h1, "SPI starts with lane 0 strobe");
        wait_spi_idle;
        check_reg(SPI, SPI_RXDATA, 32'h3C, "SPI sends lane 0");
        end_group("SPI_TXDATA");
    endtask

    initial begin
        $dumpfile("tb_apb_pstrb.vcd");
        $dumpvars(0, tb_apb_pstrb);

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        test_gpio;
        test_uart_regs;
        test_uart_data;
        test_spi_regs;
        test_spi_tx;

        $display("RESULT: %0d checks, %0d failures", checks, failures);
        if (failures != 0) $fatal(1, "[TB_APB_PSTRB] Write strobe verification failed");
        $display("PASS: APB write strobe tests");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "[TB_APB_PSTRB] ERROR: Simulation Timeout!");
    end

endmodule
