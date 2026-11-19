// ==============================================================================
// Testbench: tb_soc_ibex
// Description: Runs the real firmware on Ibex inside soc_top and checks only the
//              chip pins: the UART report, UART echo, LEDs, S2, and the SPI byte.
//              With +expect_trap, the firmware does a misaligned store that the
//              adapter must refuse, so it must trap with nothing written to the bus.
//              With +expect_rom_fault, the firmware stores to the ROM. The store reaches
//              the bus, the ROM answers ERROR, and the core must trap.
//              With +expect_unmapped_fault, the same store goes to an unmapped address,
//              and the default slave answers ERROR.
//              With +expect_apb_fault, the store goes to UART + 0x010, past the last
//              UART register. The UART answers PSLVERR, the bridge must turn it into
//              ERROR, and the core must trap.
//              With +spi_demo, the demo firmware talks to a model of an external SPI
//              slave, like the STM32F407 sketch: it answers each byte in upper case
//              during the next transfer.
//              Run it through dv/run_ibex_sim.sh, which builds the firmware first.
// ==============================================================================

`timescale 1ns/1ps

module tb_soc_ibex;

    localparam integer BIT_CYCLES = 234;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic btn_s2 = 1'b0;
    logic uart_rx = 1'b1;
    wire  uart_tx, spi_sck, spi_mosi;
    wire [7:0] spi_cs_n;
    wire [5:0] led;

    // Model of an external mode 0 slave. MISO reads high when it is not selected,
    // like the pull-up on the board. The reply is ready before the next transfer.
    logic       spi_demo_mode = 1'b0;
    logic [7:0] slave_rx = 8'h00;
    logic [7:0] slave_tx = 8'h00;
    logic [7:0] slave_reply = 8'h00;
    logic [7:0] slave_log [0:15];
    integer     slave_count = 0;
    integer     slave_bit = 0;
    wire        slave_miso = spi_cs_n[0] ? 1'b1 : slave_tx[7];

    initial spi_demo_mode = $test$plusargs("spi_demo");

    always @(negedge spi_cs_n[0]) begin
        slave_tx  = slave_reply;
        slave_bit = 0;
    end

    // A real slave needs MOSI stable before the edge it samples on, so this uses the
    // value from half a clock earlier. A master that changes MOSI on the rising edge,
    // as in CPHA 1, then fails here instead of passing on simulator event order.
    logic mosi_before_edge = 1'b0;

    always @(negedge clk) mosi_before_edge = spi_mosi;

    always @(posedge spi_sck) begin
        if (!spi_cs_n[0]) begin
            slave_rx = {slave_rx[6:0], mosi_before_edge};
            slave_bit++;
        end
    end

    // MISO changes shortly after the falling edge, like a real output.
    always @(negedge spi_sck) begin
        #5;
        if (!spi_cs_n[0]) slave_tx = {slave_tx[6:0], 1'b0};
    end

    always @(posedge spi_cs_n[0]) begin
        if (slave_bit == 8 && slave_count < 16) slave_log[slave_count] = slave_rx;
        slave_count++;
        slave_reply = (slave_rx >= "a" && slave_rx <= "z") ? slave_rx - 8'h20 : slave_rx;
    end

    always #18.5 clk = ~clk;

    soc_top #(
        .BOOT_HEX_FILE ("sw/firmware_sim.hex"),
        .USE_IBEX      (1)
    ) u_dut (
        .clk_27m  (clk),
        .rst_n    (rst_n),
        .ext_haddr  (32'h0),
        .ext_htrans (2'b00),
        .ext_hwrite (1'b0),
        .ext_hsize  (3'b000),
        .ext_hwdata (32'h0),
        .btn_s2   (btn_s2),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        // Loopback, like a jumper between the header pins, or the slave model.
        .spi_miso (spi_demo_mode ? slave_miso : spi_mosi),
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
    logic [7:0] rx_log [0:255];
    integer     rx_count = 0;
    integer     bad_stop_bits = 0;
    integer     trap_chars = 0;

    initial begin
        logic [7:0] value;
        forever begin
            @(negedge uart_tx);
            repeat (BIT_CYCLES / 2) @(posedge clk);
            if (uart_tx === 1'b0) begin
                for (int i = 0; i < 8; i++) begin
                    repeat (BIT_CYCLES) @(posedge clk);
                    value[i] = uart_tx;
                end
                repeat (BIT_CYCLES) @(posedge clk);
                if (uart_tx !== 1'b1) bad_stop_bits++;
                if (value == 8'h21) trap_chars++; // '!' comes from the trap handler
                if (rx_count < 256) rx_log[rx_count] = value;
                rx_count++;
            end
        end
    end

    task automatic print_log;
        $write("  UART sent %0d bytes:", rx_count);
        for (int i = 0; i < rx_count && i < 256; i++) $write(" %02x", rx_log[i]);
        $display("");
    endtask

    function automatic logic report_is_pass();
        logic [7:0] expected [0:10];
        expected[0] = "I"; expected[1] = "B"; expected[2] = "E"; expected[3] = "X";
        expected[4] = " "; expected[5] = "P"; expected[6] = "A"; expected[7] = "S";
        expected[8] = "S"; expected[9] = 8'h0D; expected[10] = 8'h0A;
        if (rx_count != 11) return 1'b0;
        for (int i = 0; i < 11; i++) begin
            if (rx_log[i] !== expected[i]) return 1'b0;
        end
        return 1'b1;
    endfunction

    // SPI capture from the pins
    logic [7:0] spi_byte = 8'h00;
    integer     spi_edges = 0;

    always @(posedge spi_sck) begin
        check("SCK edge is inside CS0", spi_cs_n[0] === 1'b0);
        spi_byte = {spi_byte[6:0], spi_mosi};
        spi_edges++;
    end

    // Bus activity, read from the CPU port to confirm the CPU is what drives it.
    wire [31:0] cpu_haddr  = u_dut.cpu_haddr;
    wire [1:0]  cpu_htrans = u_dut.cpu_htrans;
    wire        cpu_hready = u_dut.cpu_hready;
    wire        cpu_hresp  = u_dut.cpu_hresp;
    integer     fetches = 0;
    integer     first_fetches_seen = 0;
    logic [31:0] first_fetch = 32'hxxxx_xxxx;
    integer     error_responses = 0;

    always @(posedge clk) begin
        if (rst_n === 1'b1) begin
            if (cpu_htrans === 2'b10 && cpu_hready === 1'b1) begin
                fetches++;
                if (first_fetches_seen == 0) first_fetch = cpu_haddr;
                first_fetches_seen++;
            end
            if (cpu_hresp === 1'b1 && cpu_hready === 1'b1) error_responses++;
        end
    end

    // Completed APB transfers that a peripheral answered with PSLVERR. Read inside
    // the SoC, so the APB fault test cannot pass on an ERROR from another slave.
    integer pslverr_responses = 0;

    always @(posedge clk) begin
        if (rst_n === 1'b1 && u_dut.apb_penable === 1'b1) begin
            if ((u_dut.psel_uart === 1'b1 && u_dut.pready_uart === 1'b1 && u_dut.pslverr_uart === 1'b1) ||
                (u_dut.psel_spi  === 1'b1 && u_dut.pready_spi  === 1'b1 && u_dut.pslverr_spi  === 1'b1) ||
                (u_dut.psel_gpio === 1'b1 && u_dut.pready_gpio === 1'b1 && u_dut.pslverr_gpio === 1'b1)) begin
                pslverr_responses++;
            end
        end
    end

    task automatic wait_cycles(input integer n);
        repeat (n) @(posedge clk);
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
        check($sformatf("Echo of 0x%02x arrives", value), rx_count == 1);
        check($sformatf("Echo of 0x%02x is intact", value), rx_log[0] === value);
    endtask

    // Instruction fetches the CPU's fetch port takes from SRAM. Read inside the CPU
    // wrapper, because on the shared AHB bus a fetch looks the same as a data read.
    integer sram_fetches = 0;

    always @(posedge clk) begin
        if (rst_n === 1'b1 && u_dut.g_ibex.u_cpu.instr_req === 1'b1 &&
            u_dut.g_ibex.u_cpu.instr_gnt === 1'b1 &&
            u_dut.g_ibex.u_cpu.instr_addr[31:15] === 17'h04000) begin
            sram_fetches++;
        end
    end

    // Fetches from the interrupt vectors. Ibex jumps to mtvec + 4 * cause, so a fetch
    // of 0x1C is the timer interrupt (cause 7) and 0x40 is the UART (fast 0, cause 16).
    // Nothing else reaches these entries, so each fetch is one interrupt taken.
    integer vec_timer_fetches = 0;
    integer vec_uart_fetches = 0;

    always @(posedge clk) begin
        if (rst_n === 1'b1 && cpu_htrans === 2'b10 && cpu_hready === 1'b1 &&
            u_dut.cpu_hwrite === 1'b0) begin
            if (cpu_haddr === 32'h0000_001C) vec_timer_fetches++;
            if (cpu_haddr === 32'h0000_0040) vec_uart_fetches++;
        end
    end

    // Any write to the word the misaligned store targets
    integer writes_to_target = 0;

    always @(posedge clk) begin
        if (rst_n === 1'b1 && cpu_htrans === 2'b10 && u_dut.cpu_hwrite === 1'b1 &&
            cpu_hready === 1'b1 && cpu_haddr[31:2] == 30'h0800_0040) begin
            writes_to_target++;
        end
    end

    integer guard;
    integer toggles;
    integer timer_vectors;
    integer uart_vectors;
    logic   previous_led;
    string  image;

    task automatic run_trap_test;
        @(negedge clk);
        rst_n = 1'b1;
        guard = 0;
        while (rx_count == 0 && guard < 200000) begin
            @(posedge clk);
            guard++;
        end
        wait_cycles(5000);
        if (rx_count != 1) print_log;
        check("Firmware sends only the trap character", rx_count == 1);
        check("That character is the trap marker", rx_log[0] === 8'h21);
        check("Refused store never reaches the bus", writes_to_target == 0);
        check("Refusal is not an AHB error", error_responses == 0);
        $display("RESULT: %0d checks, %0d failures", checks, failures);
        $finish;
    endtask

    task automatic run_bus_fault_test(input string target, input bit through_apb = 1'b0);
        @(negedge clk);
        rst_n = 1'b1;
        guard = 0;
        while (rx_count == 0 && guard < 200000) begin
            @(posedge clk);
            guard++;
        end
        wait_cycles(5000);
        if (rx_count != 1) print_log;
        check("Firmware sends only the trap character", rx_count == 1);
        check("That character is the trap marker", rx_log[0] === 8'h21);
        check({"The ", target, " answers the store with an AHB error"}, error_responses != 0);
        if (through_apb) begin
            check("The peripheral answers exactly one APB transfer with PSLVERR", pslverr_responses == 1);
        end else begin
            check("No peripheral answers with PSLVERR", pslverr_responses == 0);
        end
        $display("RESULT: %0d checks, %0d failures", checks, failures);
        $finish;
    endtask

    // Waits for a whole line from the UART and compares it with the expected text.
    task automatic expect_line(input string want);
        string  line = "";
        integer wait_guard = 0;
        rx_count = 0;
        while ((rx_count == 0 || rx_log[rx_count - 1] !== 8'h0A) && wait_guard < 200000) begin
            @(posedge clk);
            wait_guard++;
        end
        for (int i = 0; i < rx_count && i < 256; i++) line = {line, string'(rx_log[i])};
        if (line != {want, "\r\n"}) begin
            $display("  Got line: %s", line);
            print_log;
        end
        check({"UART line: ", want}, line == {want, "\r\n"});
    endtask

    // Sends one character and checks the report line and the byte the slave saw.
    task automatic spi_demo_exchange(input logic [7:0] tx, input logic [7:0] rx);
        integer first_index = slave_count;
        string  expected = $sformatf("SPI TX %02x RX %02x", tx, rx);
        expected = expected.toupper();
        fork
            expect_line(expected);
            send_byte(tx);
        join
        wait_cycles(20);
        check($sformatf("One SPI transfer for 0x%02x", tx), slave_count == first_index + 1);
        check($sformatf("Slave receives 0x%02x", tx), slave_log[first_index] === tx);
    endtask

    task automatic run_spi_demo_test;
        realtime sck_start;
        integer  sck_period = 0;
        @(negedge clk);
        rst_n = 1'b1;
        expect_line("IBEX SPI DEMO");
        check("CS0 idles high", spi_cs_n[0] === 1'b1);
        check("SCK idles low in mode 0", spi_sck === 1'b0);

        // The first reply is the slave's reset value, then each byte comes back
        // in upper case one transfer later. Digits and symbols stay unchanged.
        spi_demo_exchange("a", 8'h00);
        spi_demo_exchange("b", "A");
        spi_demo_exchange("z", "B");
        spi_demo_exchange("1", "Z");
        spi_demo_exchange(8'hA5, "1");
        spi_demo_exchange(8'h5A, 8'hA5);

        // 27 MHz / 54 = 500 kHz.
        fork
            begin
                @(posedge spi_sck);
                sck_start = $realtime;
                @(posedge spi_sck);
                sck_period = int'(($realtime - sck_start) / 37.0);
            end
            send_byte("x");
        join
        check($sformatf("SCK period is 54 clocks, got %0d", sck_period), sck_period == 54);
        check("No trap was taken", trap_chars == 0);
        check("No ERROR responses on the bus", error_responses == 0);
        $display("RESULT: %0d checks, %0d failures", checks, failures);
        $finish;
    endtask

    initial begin
        if ($value$plusargs("image=%s", image)) begin
            $readmemh(image, u_dut.u_rom.mem);
        end
        wait_cycles(20);
        check("LEDs are off in reset", led === 6'b111111);
        check("UART idles high in reset", uart_tx === 1'b1);
        if ($test$plusargs("expect_trap")) run_trap_test;
        if ($test$plusargs("expect_rom_fault")) run_bus_fault_test("ROM");
        if ($test$plusargs("expect_unmapped_fault")) run_bus_fault_test("default slave");
        if ($test$plusargs("expect_apb_fault")) run_bus_fault_test("UART, through the bridge,", 1'b1);
        if (spi_demo_mode) run_spi_demo_test;
        @(negedge clk);
        rst_n = 1'b1;

        // ---- The firmware report ----
        guard = 0;
        while ((rx_count == 0 || rx_log[rx_count - 1] !== 8'h0A) && guard < 2000000) begin
            @(posedge clk);
            guard++;
        end
        check("Firmware finishes its report", guard < 2000000);
        if (!report_is_pass()) print_log;
        check("Firmware reports IBEX PASS", report_is_pass());
        check("UART stop bits are all high", bad_stop_bits == 0);
        check("No trap was taken", trap_chars == 0);
        check("First fetch is the reset vector", first_fetch === 32'h0000_0080);
        check("CPU is driving the bus", fetches > 500);
        check($sformatf("Self-test 10 fetched its code from SRAM, %0d fetches", sram_fetches),
              sram_fetches >= 3);
        check("No ERROR responses on the bus", error_responses == 0);

        // ---- SPI seen on the pins ----
        check("One SPI byte is sent", spi_edges == 8);
        check("SPI byte on MOSI is 0xA5", spi_byte === 8'hA5);
        check("CS0 is released", spi_cs_n[0] === 1'b1);

        // ---- LEDs ----
        wait_cycles(2000);
        check("PASS LED is on", led[1] === 1'b0);
        check("FAIL LED is off", led[2] === 1'b1);
        check("S2 LED is off", led[3] === 1'b1);
        check("Unused LEDs are off", led[5:4] === 2'b11);

        toggles = 0;
        previous_led = led[0];
        timer_vectors = vec_timer_fetches;
        repeat (30000) begin
            @(posedge clk);
            if (led[0] !== previous_led) toggles++;
            previous_led = led[0];
        end
        timer_vectors = vec_timer_fetches - timer_vectors;
        check("Heartbeat LED toggles", toggles >= 5 && toggles <= 9);
        check($sformatf("Each toggle comes from a timer interrupt: %0d toggles, %0d vector fetches",
                        toggles, timer_vectors),
              timer_vectors >= toggles && timer_vectors <= toggles + 1);

        // ---- S2 ----
        btn_s2 = 1'b1;
        wait_cycles(500);
        check("Pressing S2 turns its LED on", led[3] === 1'b0);
        btn_s2 = 1'b0;
        wait_cycles(500);
        check("Releasing S2 turns its LED off", led[3] === 1'b1);

        // ---- UART echo through the CPU, from the RX interrupt ----
        uart_vectors = vec_uart_fetches;
        test_echo(8'h5A);
        test_echo(8'h00);
        test_echo(8'hFF);
        test_echo(8'hA5);
        uart_vectors = vec_uart_fetches - uart_vectors;
        check($sformatf("Each echo goes through the UART interrupt vector, got %0d", uart_vectors),
              uart_vectors == 4);

        // ---- Reset restarts the firmware ----
        rx_count = 0;
        rst_n = 1'b0;
        wait_cycles(5);
        check("LEDs are off during a later reset", led === 6'b111111);
        @(negedge clk);
        rst_n = 1'b1;
        guard = 0;
        while ((rx_count == 0 || rx_log[rx_count - 1] !== 8'h0A) && guard < 2000000) begin
            @(posedge clk);
            guard++;
        end
        if (!report_is_pass()) print_log;
        check("Firmware passes again after reset", report_is_pass());
        check("Still no ERROR responses", error_responses == 0);

        $display("Bus transfers accepted: %0d", fetches);
        $display("RESULT: %0d checks, %0d failures", checks, failures);
        $finish;
    end

endmodule
