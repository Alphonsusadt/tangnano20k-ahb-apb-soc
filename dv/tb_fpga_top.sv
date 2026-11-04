// ==============================================================================
// Testbench: tb_fpga_top
// Description: Checks the FPGA image from its pins only: power-on reset, the UART
//              report, SPI waveform, LEDs, buttons, and UART echo. Faults injected
//              into the ROM and the bus prove that the self-test can report failure.
//
// Run from the repository root, because the ROM image path is relative to it.
// ==============================================================================

`timescale 1ns/1ps

module tb_fpga_top;

    localparam integer BIT_CYCLES = 234; // UART bit time from the reset divider

    logic clk = 1'b0;
    logic btn_s1 = 1'b0;
    logic btn_s2 = 1'b0;
    logic uart_rx = 1'b1;
    wire  uart_tx, spi_sck, spi_mosi, spi_cs_n;
    wire [5:0] led;

    // MISO is looped back, like a jumper between the two header pins.
    wire spi_miso = spi_mosi;

    always #18.5 clk = ~clk;

    fpga_top #(
        .BOOT_HEX_FILE ("fpga/selftest_rom.hex"),
        .USE_IBEX      (0),
        .POR_BITS      (4),
        .HEARTBEAT_BIT (10)
    ) u_dut (
        .clk_27m  (clk),
        .btn_s1   (btn_s1),
        .btn_s2   (btn_s2),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (spi_miso),
        .spi_cs_n (spi_cs_n),
        .led      (led)
    );

    integer checks = 0;
    integer failures = 0;

    task automatic check(input string name, input logic ok);
        checks++;
        if (ok !== 1'b1) begin
            failures++;
            $display("FAIL [%0t] %s", $time, name);
        end
    endtask

    // UART capture from the pin
    logic [7:0] rx_log [0:63];
    integer     rx_count = 0;

    initial begin
        forever begin
            logic [7:0] value;
            @(negedge uart_tx);
            repeat (BIT_CYCLES / 2) @(posedge clk);
            if (uart_tx === 1'b0) begin
                for (int i = 0; i < 8; i++) begin
                    repeat (BIT_CYCLES) @(posedge clk);
                    value[i] = uart_tx;
                end
                repeat (BIT_CYCLES) @(posedge clk);
                check("UART stop bit is high", uart_tx === 1'b1);
                if (rx_count < 64) rx_log[rx_count] = value;
                rx_count++;
            end
        end
    end

    // A string literal is right-aligned in the packed vector, so its length is the
    // position of its highest non-zero byte.
    function automatic logic log_matches(input [127:0] text);
        integer len = 16;
        while (len > 0 && text[8*(len-1) +: 8] == 8'h00) len--;
        if (rx_count != len) return 1'b0;
        for (int i = 0; i < len; i++) begin
            if (rx_log[i] !== text[8*(len-1-i) +: 8]) return 1'b0;
        end
        return 1'b1;
    endfunction

    task automatic print_log;
        $write("  got %0d bytes:", rx_count);
        for (int i = 0; i < rx_count && i < 64; i++) $write(" %02X", rx_log[i]);
        $display("");
    endtask

    // SPI capture from the pins
    logic [7:0] spi_byte = 8'h00;
    integer     spi_edges = 0;
    integer     spi_cs_lows = 0;
    logic       spi_edge_outside_cs = 1'b0;

    always @(posedge spi_sck) begin
        if (spi_cs_n !== 1'b0) spi_edge_outside_cs = 1'b1;
        spi_byte = {spi_byte[6:0], spi_mosi};
        spi_edges++;
    end

    always @(negedge spi_cs_n) spi_cs_lows++;

    // Master protocol monitor. It only ever issues NONSEQ or IDLE, holds its address
    // through a stalled address phase, and must not put X on the control lines.
    wire [31:0] m_haddr  = u_dut.u_soc.cpu_haddr;
    wire [1:0]  m_htrans = u_dut.u_soc.cpu_htrans;
    wire        m_hready = u_dut.u_soc.cpu_hready;
    logic [31:0] last_haddr;
    logic        stalled = 1'b0;
    integer      protocol_errors = 0;
    integer      nonseq_count = 0;

    always @(posedge clk) begin
        if (u_dut.rst_sync[1] === 1'b1) begin
            if (m_htrans !== 2'b00 && m_htrans !== 2'b10) protocol_errors++;
            if (m_hready === 1'bx) protocol_errors++;
            if (stalled && m_haddr !== last_haddr) protocol_errors++;
            if (m_htrans === 2'b10 && m_hready === 1'b1) nonseq_count++;
            stalled    = (m_htrans === 2'b10) && (m_hready === 1'b0);
            last_haddr = m_haddr;
        end else begin
            stalled = 1'b0;
        end
    end

    // Wait-state injection. No slave in this SoC stalls an address phase by itself,
    // so this lowers HREADY at the start of each address phase for two cycles.
    logic   stall_en = 1'b0;
    logic   stalled_this = 1'b0;
    integer stall_left = 0;
    integer stall_count = 0;
    wire [3:0] m_state = u_dut.u_soc.g_selftest.u_selftest.state;

    always @(negedge clk) begin
        if (stall_left > 0) begin
            stall_left--;
            if (stall_left == 0) release u_dut.u_soc.cpu_hready;
        end else if (stall_en && m_state == 4'd0 && !stalled_this) begin
            force u_dut.u_soc.cpu_hready = 1'b0;
            stall_left = 2;
            stalled_this = 1'b1;
            stall_count++;
        end
        if (m_state != 4'd0) stalled_this = 1'b0;
    end

    task automatic wait_cycles(input integer n);
        repeat (n) @(posedge clk);
    endtask

    // Waits until the report has ended with a newline, or times out.
    task automatic wait_report(input string name);
        integer guard = 0;
        while ((rx_count == 0 || rx_log[rx_count - 1] !== 8'h0A) && guard < 200000) begin
            @(posedge clk);
            guard++;
        end
        check({name, ": report arrived"}, guard < 200000);
    endtask

    task automatic press_reset;
        rx_count = 0;
        btn_s1 = 1'b1;
        wait_cycles(5);
        check("S1 holds the SoC in reset", u_dut.rst_sync[1] === 1'b0);
        check("LEDs are off while S1 is held", led === 6'b111111);
        btn_s1 = 1'b0;
    endtask

    task automatic expect_report(input string name, input [127:0] text);
        wait_report(name);
        if (!log_matches(text)) print_log;
        check({name, ": text"}, log_matches(text));
    endtask

    task automatic send_byte(input logic [7:0] value);
        uart_rx = 1'b0;
        wait_cycles(BIT_CYCLES);
        for (int i = 0; i < 8; i++) begin
            uart_rx = value[i];
            wait_cycles(BIT_CYCLES);
        end
        uart_rx = 1'b1;
        wait_cycles(BIT_CYCLES);
    endtask

    task automatic test_echo(input logic [7:0] value);
        integer guard = 0;
        rx_count = 0;
        send_byte(value);
        while (rx_count == 0 && guard < 5000) begin
            @(posedge clk);
            guard++;
        end
        check($sformatf("Echo of 0x%02X arrives", value), rx_count == 1);
        check($sformatf("Echo of 0x%02X is intact", value), rx_count > 0 && rx_log[0] === value);
    endtask

    logic [31:0] saved_word;
    integer      toggles;
    logic        previous_led;

    initial begin
        $dumpfile("tb_fpga_top.vcd");
        $dumpvars(1, tb_fpga_top);

        // ---- Power-on reset, with no button press ----
        wait_cycles(4);
        check("POR holds the SoC in reset", u_dut.rst_sync[1] === 1'b0);
        check("LEDs are off during POR", led === 6'b111111);
        check("UART idles high during POR", uart_tx === 1'b1);
        check("CS idles high during POR", spi_cs_n === 1'b1);

        // ---- Self-test passes without touching a button ----
        expect_report("Power-on", "SOC PASS\015\n");
        wait_cycles(20);
        check("SoC is out of reset with S1 not pressed", u_dut.rst_sync[1] === 1'b1);

        // ---- SPI waveform seen on the pins ----
        check("One SPI byte is sent", spi_edges == 8);
        check("SPI byte on MOSI is 0xA5", spi_byte === 8'hA5);
        check("CS falls once", spi_cs_lows == 1);
        check("Every SCK edge is inside CS", spi_edge_outside_cs === 1'b0);
        check("CS is released", spi_cs_n === 1'b1);
        check("Looped-back byte is received", u_dut.u_soc.u_spi.rx_reg === 8'hA5);

        // ---- LEDs ----
        wait_cycles(2000);
        check("PASS LED is on", led[1] === 1'b0);
        check("FAIL LED is off", led[2] === 1'b1);
        check("S2 LED is off", led[3] === 1'b1);
        check("Unused LEDs are off", led[5:4] === 2'b11);

        toggles = 0;
        previous_led = led[0];
        repeat (6000) begin
            @(posedge clk);
            if (led[0] !== previous_led) toggles++;
            previous_led = led[0];
        end
        check("Heartbeat LED toggles at the set rate", toggles >= 4 && toggles <= 7);

        // ---- S2 reaches the LED through the bus ----
        btn_s2 = 1'b1;
        wait_cycles(200);
        check("Pressing S2 turns its LED on", led[3] === 1'b0);
        btn_s2 = 1'b0;
        wait_cycles(200);
        check("Releasing S2 turns its LED off", led[3] === 1'b1);

        // ---- UART echo ----
        test_echo(8'h5A);
        test_echo(8'h00);
        test_echo(8'hFF);
        test_echo(8'hA5);

        // ---- S1 reruns the test ----
        press_reset;
        expect_report("S1 reset", "SOC PASS\015\n");

        // ---- Fault: first ROM word wrong ----
        saved_word = u_dut.u_soc.rom_mem[0];
        u_dut.u_soc.rom_mem[0] = 32'hFFFF_FFFF;
        press_reset;
        expect_report("Bad ROM word 0", "SOC FAIL 00\015\n");
        wait_cycles(200);
        check("FAIL LED is on", led[2] === 1'b0);
        check("PASS LED is off", led[1] === 1'b1);
        u_dut.u_soc.rom_mem[0] = saved_word;

        // ---- Fault: last ROM word wrong ----
        saved_word = u_dut.u_soc.rom_mem[8191];
        u_dut.u_soc.rom_mem[8191] = 32'h0;
        press_reset;
        expect_report("Bad ROM last word", "SOC FAIL 01\015\n");
        u_dut.u_soc.rom_mem[8191] = saved_word;

        // ---- Fault: bridge stops answering ERROR for a reserved address ----
        force u_dut.u_soc.bridge_hresp = 1'b0;
        press_reset;
        expect_report("Lost bridge ERROR", "SOC FAIL 0B\015\n");
        release u_dut.u_soc.bridge_hresp;

        // ---- Fault: default slave stops answering ERROR ----
        force u_dut.u_soc.cpu_hresp = 1'b0;
        press_reset;
        expect_report("Lost ERROR", "SOC FAIL 08\015\n");
        release u_dut.u_soc.cpu_hresp;

        // ---- Fault: SPI stays busy, so the poll must time out, not hang ----
        // Timing out takes 2^20 polls, so the poll counter is advanced close to its end.
        press_reset;
        wait_cycles(10);
        force u_dut.u_soc.u_spi.busy = 1'b1;
        wait (u_dut.u_soc.g_selftest.u_selftest.pc == 5'd19);
        force u_dut.u_soc.g_selftest.u_selftest.poll_cnt = 20'hFFFFF;
        expect_report("SPI stuck busy", "SOC FAIL 13\015\n");
        release u_dut.u_soc.g_selftest.u_selftest.poll_cnt;
        release u_dut.u_soc.u_spi.busy;

        // ---- Address phases stalled by HREADY must not be lost ----
        stall_en = 1'b1;
        press_reset;
        expect_report("Stalled address phases", "SOC PASS\015\n");
        stall_en = 1'b0;
        wait_cycles(10);
        check("Stalls were really injected", stall_count > 100);

        // ---- A clean run still passes after all the faults ----
        press_reset;
        expect_report("Recovery", "SOC PASS\015\n");
        wait_cycles(200);
        check("PASS LED is on after recovery", led[1] === 1'b0);

        check("Master issued real transfers", nonseq_count > 1000);
        check("Master protocol stayed legal", protocol_errors == 0);

        $display("RESULT: %0d checks, %0d failures", checks, failures);
        $finish;
    end

    initial begin
        #40ms;
        $display("RESULT: FATAL timeout, %0d checks, %0d failures", checks, failures);
        $finish;
    end

endmodule
