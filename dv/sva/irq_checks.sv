// ==============================================================================
// Module: irq_checks
// Description: Assertions for the two interrupt lines into Ibex. Both are levels
//              that only software can clear, so a line may fall only right after
//              software accessed the peripheral that drives it. A line that falls on
//              its own was a pulse, and the CPU could miss it.
//              dv/sva/soc_top_checks_bind.sv attaches it to soc_top.
// ==============================================================================

module irq_checks (
    input wire hclk,
    input wire hreset_n,
    input wire irq_timer,
    input wire uart_irq,
    input wire penable,
    input wire pwrite,
    input wire psel_timer,
    input wire psel_uart
);

    // The access completes at the edge where PSEL and PENABLE are sampled high; the
    // register changes after that edge, and the line is seen low one edge later.
    wire timer_write = psel_timer && penable && pwrite;
    wire uart_access = psel_uart && penable;

    a_timer_irq_held: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        $fell(irq_timer) |-> $past(timer_write)
    ) else $error("Timer interrupt fell without a write to the timer");

    // TX_EMPTY falls two edges after the UART_DATA write (start request, then busy).
    a_uart_irq_held: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        $fell(uart_irq) |-> ($past(uart_access) || $past(uart_access, 2))
    ) else $error("UART interrupt fell without an access to the UART");

    integer n_timer_rise = 0, n_timer_fall = 0, n_uart_rise = 0, n_uart_fall = 0;
    always @(posedge hclk) begin
        if (hreset_n) begin
            if ($rose(irq_timer)) n_timer_rise <= n_timer_rise + 1;
            if ($fell(irq_timer)) n_timer_fall <= n_timer_fall + 1;
            if ($rose(uart_irq))  n_uart_rise  <= n_uart_rise + 1;
            if ($fell(uart_irq))  n_uart_fall  <= n_uart_fall + 1;
        end
    end

    // Same prefix as the bus checker, so the regression requires every counter to be
    // above zero across the Ibex runs.
    final begin
        $display("SVA: irq_timer_rise=%0d irq_timer_fall=%0d irq_uart_rise=%0d irq_uart_fall=%0d",
                 n_timer_rise, n_timer_fall, n_uart_rise, n_uart_fall);
    end

endmodule
