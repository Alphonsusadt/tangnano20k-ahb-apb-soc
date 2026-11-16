// ==============================================================================
// Testbench: tb_apb_wait
// Description: Verilator run of the AHB-to-APB bridge with a peripheral that stretches
//              every access with 0-3 PREADY wait cycles. It checks that each write
//              reaches the register and each read returns it, and it runs the APB
//              assertions in dv/sva/apb_checks.sv, which need Verilator --assert.
//              dv/run_apb_wait.sh runs this and a broken copy of the bridge.
// ==============================================================================

`timescale 1ns/1ps

module tb_apb_wait;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    // AHB side, driven by the testbench
    logic        hsel = 1'b0;
    logic [31:0] haddr = '0;
    logic [1:0]  htrans = 2'b00;
    logic        hwrite = 1'b0;
    logic [31:0] hwdata = '0;
    wire  [31:0] hrdata;
    wire         hready, hresp;

    // APB side
    wire [31:0] paddr, pwdata;
    wire        pwrite, penable;
    wire [2:0]  pprot;
    wire [3:0]  pstrb;
    wire        psel_uart, psel_spi, psel_gpio, psel_timer;
    wire [31:0] prdata_gpio;
    wire        pready_gpio, pslverr_gpio;

    ahb_to_apb_bridge u_bridge (
        .hclk         (clk),
        .hreset_n     (rst_n),
        .hsel         (hsel),
        .haddr        (haddr),
        .htrans       (htrans),
        .hwrite       (hwrite),
        .hsize        (3'b010),
        .hwdata       (hwdata),
        .hready_in    (1'b1),
        .hrdata       (hrdata),
        .hready       (hready),
        .hresp        (hresp),
        .paddr        (paddr),
        .pwdata       (pwdata),
        .pwrite       (pwrite),
        .pprot        (pprot),
        .pstrb        (pstrb),
        .penable      (penable),
        .psel_uart    (psel_uart),
        .psel_spi     (psel_spi),
        .psel_gpio    (psel_gpio),
        .prdata_uart  (32'h0),
        .pready_uart  (1'b1),
        .pslverr_uart (1'b0),
        .prdata_spi   (32'h0),
        .pready_spi   (1'b1),
        .pslverr_spi  (1'b0),
        .prdata_gpio  (prdata_gpio),
        .pready_gpio  (pready_gpio),
        .pslverr_gpio (pslverr_gpio),
        .psel_timer   (psel_timer),
        .prdata_timer (32'h0),
        .pready_timer (1'b1),
        .pslverr_timer(1'b0)
    );

    // A peripheral with one 32-bit register. Each access takes 0, 2, 1, or 3 extra
    // cycles, in that order, so PADDR and the other APB signals must hold during them.
    logic [31:0] reg_q = '0;
    logic [1:0]  stretch_q = 2'd0;
    logic [1:0]  wait_q = 2'd0;
    logic [1:0]  seq_q = 2'd0;
    wire         access = psel_gpio && penable;

    assign pready_gpio  = !access || (wait_q == 2'd0);
    assign pslverr_gpio = 1'b0;
    assign prdata_gpio  = reg_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            reg_q  <= '0;
            wait_q <= 2'd0;
            seq_q  <= 2'd0;
        end else if (psel_gpio && !penable) begin
            wait_q <= (seq_q == 2'd0) ? 2'd0 : (seq_q == 2'd1) ? 2'd2 : (seq_q == 2'd2) ? 2'd1 : 2'd3;
            seq_q  <= seq_q + 2'd1;
        end else if (access && wait_q != 2'd0) begin
            wait_q <= wait_q - 2'd1;
        end else if (access && pready_gpio && pwrite) begin
            reg_q <= pwdata;
        end
    end

    apb_checks u_apb_checks (
        .hclk        (clk),
        .hreset_n    (rst_n),
        .penable     (penable),
        .psel_uart   (psel_uart),
        .psel_spi    (psel_spi),
        .psel_gpio   (psel_gpio),
        .psel_timer  (psel_timer),
        .pready_uart (1'b1),
        .pready_spi  (1'b1),
        .pready_gpio (pready_gpio),
        .pready_timer(1'b1),
        .pwrite      (pwrite),
        .paddr       (paddr),
        .pwdata      (pwdata),
        .pstrb       (pstrb)
    );

    integer checks = 0, failures = 0;

    task automatic check(input string name, input bit ok);
        checks++;
        if (!ok) begin
            failures++;
            $display("FAIL [%0t] %s", $time, name);
        end
    endtask

    // One AHB transfer. Address goes on the bus at one edge, data follows one cycle
    // later, and the task returns when the bridge has finished the transfer.
    task automatic ahb_access(input logic write, input logic [31:0] addr, input logic [31:0] data,
                              output logic [31:0] rdata);
        @(negedge clk);
        hsel = 1'b1; htrans = 2'b10; haddr = addr; hwrite = write;
        @(negedge clk);
        htrans = 2'b00; hsel = 1'b0; hwdata = data;
        // The bridge has finished when it is back in RESPONSE or IDLE with HREADY high.
        // Each step waits one cycle, and a bound stops a stuck transfer.
        begin : wait_done
            integer guard;
            for (guard = 0; guard < 50 && !hready; guard++) @(negedge clk);
            if (guard == 50) $display("FAIL [%0t] bridge did not finish", $time);
        end
        rdata = hrdata;
        @(negedge clk);
    endtask

    logic [31:0] got;
    integer i;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // Eight writes, each followed by a read of the same register.
        for (i = 0; i < 8; i++) begin
            ahb_access(1'b1, 32'h4000_2000, 32'hA5A5_0000 + i, got);
            ahb_access(1'b0, 32'h4000_2000, 32'h0, got);
            check($sformatf("Read after write %0d returns the value", i), got == (32'hA5A5_0000 + i));
        end

        $display("RESULT: %0d checks, %0d failures", checks, failures);
        $finish;
    end

endmodule
