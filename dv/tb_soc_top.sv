// ==============================================================================
// Testbench: tb_soc_top
// Description: SystemVerilog Top-Level SoC Testbench with UART Monitor & SPI loopback
// ==============================================================================

`timescale 1ns / 1ps

module tb_soc_top;

    // Clock and Reset
    logic clk_27m;
    logic rst_n;
    logic btn_s2;

    // Peripherals
    wire       uart_tx;
    logic      uart_rx;
    wire       spi_sck;
    wire       spi_mosi;
    logic      spi_miso;
    wire [7:0] spi_cs_n;
    wire [5:0] led;

    // Clock Generator (27 MHz ~ 37.037 ns period)
    initial clk_27m = 0;
    always #18.518 clk_27m = ~clk_27m;

    // DUT Instantiation
    soc_top #(
        .BOOT_HEX_FILE("sw/firmware.hex")
    ) u_dut (
        .clk_27m  (clk_27m),
        .rst_n    (rst_n),
        .btn_s2   (btn_s2),
        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (spi_miso),
        .spi_cs_n (spi_cs_n),
        .led      (led)
    );

    // SPI Loopback Slave Model (loops inverted MOSI data back to MISO)
    always_comb begin
        spi_miso = ~spi_mosi;
    end

    // --------------------------------------------------------------------------
    // UART Console Monitor (Decodes 115200 baud 8-N-1 serial TX output)
    // --------------------------------------------------------------------------
    localparam BIT_PERIOD = 8680; // ns for 115200 baud (~8.68 us)
    logic [7:0] rx_byte;

    always begin
        // Wait for start bit (falling edge on idle HIGH line)
        @(negedge uart_tx);
        #(BIT_PERIOD / 2); // align to center of start bit

        if (uart_tx == 1'b0) begin
            #(BIT_PERIOD);
            for (int i = 0; i < 8; i++) begin
                rx_byte[i] = uart_tx;
                #(BIT_PERIOD);
            end
            // Stop bit check
            if (uart_tx == 1'b1) begin
                $write("%c", rx_byte);
                $fflush();
            end
        end
    end

    // --------------------------------------------------------------------------
    // Main Test Stimulus
    // --------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_soc_top.vcd");
        $dumpvars(0, tb_soc_top);

        $display("==================================================");
        $display("[TB_SOC_TOP] Starting Tang Nano 20K SoC Simulation");
        $display("==================================================");

        // Initial inputs
        rst_n   = 1'b0;
        btn_s2  = 1'b1;
        uart_rx = 1'b1; // UART Idle is HIGH

        // Hold reset for 200 ns
        #200;
        @(posedge clk_27m);
        rst_n = 1'b1;
        $display("[TB_SOC_TOP] System Reset Deasserted at time %0t ns", $time);

        // Run simulation for enough cycles
        #200000;

        $display("\n==================================================");
        $display("[TB_SOC_TOP] Simulation Completed Successfully.");
        $display("==================================================");
        $finish;
    end

    // Watchdog Timer
    initial begin
        #5000000;
        $display("\n[TB_SOC_TOP] ERROR: Simulation Watchdog Timeout reached!");
        $finish;
    end

endmodule
