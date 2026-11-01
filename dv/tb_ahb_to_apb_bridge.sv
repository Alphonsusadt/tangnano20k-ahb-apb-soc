`timescale 1ns/1ps

// Directed, self-checking bridge regression with consecutive AHB requests.
// APB models assert PREADY only during ACCESS, to expose early completion.
module tb_ahb_to_apb_bridge;
    reg hclk = 0;
    always #5 hclk = ~hclk;
    reg hreset_n = 0;
    reg hsel = 0, hwrite = 0;
    reg [31:0] haddr = 0, hwdata = 0;
    reg [1:0] htrans = 0;
    reg [2:0] hsize = 2;
    wire [31:0] hrdata, paddr, pwdata;
    wire hready, hresp, pwrite, penable;
    wire [2:0] pprot;
    wire [3:0] pstrb;
    wire psel_uart, psel_spi, psel_gpio;
    wire [2:0] selects = {psel_gpio, psel_spi, psel_uart};
    integer errors = 0, checks = 0, completed = 0;
    integer access_cycles = 0, wait_cycles = 0;
    reg ready_in_setup = 0;
    reg [2:0] slave_errors = 0;
    wire ready = (penable && (access_cycles >= wait_cycles)) ||
                 (ready_in_setup && !penable);
    // Non-selected slaves are deliberately ready and may signal errors.
    wire uart_ready = psel_uart ? ready : 1'b1;
    wire spi_ready = psel_spi ? ready : 1'b1;
    wire gpio_ready = psel_gpio ? ready : 1'b1;
    // Data is meaningful only on the completion cycle.
    wire [31:0] uart_data = (psel_uart && penable && ready) ? 32'h11223344 : 32'hdead0000;
    wire [31:0] spi_data = (psel_spi && penable && ready) ? 32'h55667788 : 32'hdead1111;
    wire [31:0] gpio_data = (psel_gpio && penable && ready) ? 32'h99aabbcc : 32'hdead2222;
    ahb_to_apb_bridge dut (
        .hclk(hclk), .hreset_n(hreset_n), .hsel(hsel),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite),
        .hsize(hsize), .hwdata(hwdata), .hrdata(hrdata),
        .hready(hready), .hresp(hresp), .paddr(paddr),
        .pwdata(pwdata), .pwrite(pwrite), .pprot(pprot),
        .pstrb(pstrb), .penable(penable),
        .psel_uart(psel_uart), .psel_spi(psel_spi), .psel_gpio(psel_gpio),
        .prdata_uart(uart_data), .pready_uart(uart_ready), .pslverr_uart(slave_errors[0]),
        .prdata_spi(spi_data), .pready_spi(spi_ready), .pslverr_spi(slave_errors[1]),
        .prdata_gpio(gpio_data), .pready_gpio(gpio_ready), .pslverr_gpio(slave_errors[2])
    );

    // Count actual APB completions at the sampling edge, before NBA updates.
    always @(posedge hclk) begin
        if (!hreset_n) access_cycles <= 0;
        else if (|selects && penable) begin
            if (ready) begin
                completed = completed + 1;
                access_cycles <= 0;
            end else access_cycles <= access_cycles + 1;
        end else access_cycles <= 0;
    end

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL @ %0t: %s", $time, message);
            end
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge hclk);
            hreset_n = 0; hsel = 0; htrans = 0; hwdata = 0;
            repeat (3) @(negedge hclk);
            check(selects === 0 && penable === 0 && hready === 1,
                  "reset must leave buses idle and HREADY high");
            hreset_n = 1;
        end
    endtask

    // Monitor the bus at sampling edges, including SETUP -> ACCESS stability.
    reg previous_setup = 0, previous_wait = 0;
    reg [74:0] saved_controls;
    wire [74:0] controls = {selects, paddr, pwdata, pwrite, pstrb, pprot};
    always @(posedge hclk) begin
        if (!hreset_n) begin
            previous_setup = 0;
            previous_wait = 0;
        end else begin
            check((selects == 0) || (selects == 1) || (selects == 2) || (selects == 4),
                  "peripheral selection is one-hot");
            check(!penable || (|selects), "PENABLE requires a selected peripheral");
            if (previous_setup || previous_wait) begin
                check(penable && (|selects), "SETUP/wait must be followed by ACCESS");
                check(controls === saved_controls, "APB signals stable from SETUP through completion");
            end
            if ((|selects) && (!penable || !ready))
                check(!hready && !hresp, "no AHB completion/error before APB completion");
            previous_setup = (|selects) && !penable;
            previous_wait = (|selects) && penable && !ready;
            saved_controls = controls;
        end
    end

    task automatic transfer(
        input [31:0] address, input logic writing, input [31:0] data,
        input [2:0] size, input [1:0] trans, input integer waits,
        input logic slave_error, input logic local_error
    );
        integer cycles, before_count, error_cycles;
        reg [2:0] target;
        reg [3:0] strobes;
        reg [31:0] expected_read;
        reg saw_setup;
        begin
            case (address[31:12])
                20'h40000: begin target = 1; expected_read = 32'h11223344; end
                20'h40001: begin target = 2; expected_read = 32'h55667788; end
                20'h40002: begin target = 4; expected_read = 32'h99aabbcc; end
                default: begin target = 0; expected_read = 0; end
            endcase
            strobes = !writing ? 0 : size == 0 ? (4'b0001 << address[1:0]) :
                      size == 1 ? (4'b0011 << address[1:0]) : 4'b1111;
            @(negedge hclk);
            check(hready, "master starts only at an available response edge");
            before_count = completed;
            wait_cycles = waits;
            // Force errors on unselected slaves to check response isolation.
            slave_errors = slave_error ? 3'b111 : ~target;
            hsel = 1; htrans = trans; haddr = address; hwrite = writing;
            hsize = size; hwdata = 32'hdeadbeef;
            @(posedge hclk); #1;
            check(!hready && selects == 0, "address accepted before APB data capture");
            @(negedge hclk);
            hsel = 0; htrans = 0; hwdata = data;
            // Change the next address/control; accepted context must be retained.
            haddr = ~address; hwrite = !writing; hsize = 7;
            cycles = 0; error_cycles = 0; saw_setup = 0;
            begin : response_loop
                repeat (40) begin
                    @(posedge hclk); #1;
                    cycles = cycles + 1;
                    if ((|selects) && !penable) begin
                        saw_setup = 1;
                        check(!local_error && selects == target, "correct target in SETUP");
                        check(paddr == address && pwrite == writing && pprot == 0,
                              "latched APB address and control");
                        check(pstrb == strobes, "APB byte strobes match HSIZE and lane");
                        if (writing) check(pwdata == data, "write data valid already in SETUP");
                    end
                    if (hresp) begin
                        error_cycles = error_cycles + 1;
                        check(slave_error || local_error, "only expected transfers return ERROR");
                        check(hready == (error_cycles == 2), "AHB ERROR is low-ready then high-ready");
                    end
                    if (hready) disable response_loop;
                end
            end
            check(cycles < 40 && hready, "bounded AHB response");
            check(cycles == (local_error ? 2 : waits + 3 + slave_error),
                  "response latency matches APB wait count and error sequencing");
            check(error_cycles == ((slave_error || local_error) ? 2 : 0), "complete two-cycle ERROR or OKAY");
            check(saw_setup == !local_error, "invalid transfers do not reach APB");
            check(completed == before_count + (local_error ? 0 : 1), "exactly one APB completion for valid request");
            if (!writing && !local_error && !slave_error)
                check(hrdata == expected_read, "read captures completion-cycle PRDATA");
            check(selects == 0 && !penable, "APB idle during AHB response");
        end
    endtask

    task automatic abort_transfer(input integer phase_cycles);
        integer n, before_count;
        begin
            @(negedge hclk);
            hsel = 1; htrans = 2; haddr = 32'h40001008; hwrite = 1; hsize = 2;
            slave_errors = 0; wait_cycles = 10; hwdata = 32'hbad;
            @(posedge hclk); #1;
            @(negedge hclk); hsel = 0; htrans = 0; hwdata = 32'h1234;
            for (n = 0; n < phase_cycles; n = n + 1) begin
                @(posedge hclk); #1;
                @(negedge hclk);
            end
            before_count = completed;
            hreset_n = 0; #1;
            check(!penable && selects == 0 && hready && !hresp, "asynchronous reset aborts pending transfer");
            repeat (2) @(negedge hclk);
            hreset_n = 1;
            repeat (2) @(negedge hclk);
            check(completed == before_count && selects == 0, "reset causes no stale APB completion");
        end
    endtask

    integer i, port_index, lane;
    initial begin
        $dumpfile("tb_ahb_to_apb_bridge.vcd");
        $dumpvars(0, tb_ahb_to_apb_bridge);
        reset_dut;
        @(negedge hclk); hsel = 1; htrans = 0;
        repeat (3) @(negedge hclk);
        check(selects == 0 && hready, "HTRANS IDLE ignored");
        htrans = 1;
        repeat (3) @(negedge hclk);
        check(selects == 0 && hready, "HTRANS BUSY ignored");
        hsel = 0; htrans = 2;
        repeat (3) @(negedge hclk);
        check(selects == 0, "unselected NONSEQ ignored");

        // Consecutive requests without reset; next address is accepted at response edge.
        for (port_index = 0; port_index < 3; port_index = port_index + 1) begin
            for (i = 0; i < 2; i = i + 1) begin
                ready_in_setup = i;
                transfer(32'h40000004 + port_index * 4096, 1, 32'h12345678, 2, 2, i*3, 0, 0);
                transfer(32'h40000008 + port_index * 4096, 0, 0, 2, 3, i, 0, 0);
            end
            for (lane = 0; lane < 4; lane = lane + 1) begin
                transfer(32'h40000000 + port_index*4096 + lane, 1, 32'ha5a55a5a, 0, 2, lane, 0, 0);
                transfer(32'h40000000 + port_index*4096 + lane, 0, 0, 0, 2, 0, 0, 0);
            end
            for (lane = 0; lane < 4; lane = lane + 2) begin
                transfer(32'h40000000 + port_index*4096 + lane, 1, 32'hbeefcafe, 1, 2, 2, 0, 0);
                transfer(32'h40000000 + port_index*4096 + lane, 0, 0, 1, 2, 0, 0, 0);
            end
            transfer(32'h40000000 + port_index*4096, 1, 32'h55, 2, 2, 3, 1, 0);
            transfer(32'h40000000 + port_index*4096, 0, 0, 2, 2, 0, 1, 0);
            transfer(32'h40000fff + port_index*4096, 1, 32'hff000000, 0, 2, 0, 0, 0);
        end
        // Decode misses, unsupported size, and misalignment must not select APB.
        transfer(32'h40003000, 1, 0, 2, 2, 0, 0, 1);
        transfer(32'h50001000, 0, 0, 2, 2, 0, 0, 1);
        transfer(32'h40001001, 1, 0, 1, 2, 0, 0, 1);
        transfer(32'h40001002, 0, 0, 2, 2, 0, 0, 1);
        transfer(32'h40001000, 1, 0, 3, 2, 0, 0, 1);
        // DATA, SETUP, and stalled ACCESS aborts, each followed by recovery.
        for (i = 0; i < 3; i = i + 1) begin
            abort_transfer(i);
            transfer(32'h40001000, 0, 0, 2, 2, 0, 0, 0);
        end
        @(negedge hclk); slave_errors = 7; hsel = 0; htrans = 0;
        repeat (3) @(negedge hclk);
        check(!hresp && hready && selects == 0, "idle ignores stale peripheral errors");
        $display("RESULT: %0d checks, %0d failures", checks, errors);
        if (errors != 0) $fatal(1, "AHB bridge verification failed");
        $display("PASS: AHB bridge directed tests");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Global watchdog timeout");
    end
endmodule
