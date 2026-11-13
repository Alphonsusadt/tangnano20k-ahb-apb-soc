// ==============================================================================
// Module: apb_checks
// Description: Assertions for the APB bus between the AHB-to-APB bridge and the
//              peripherals. dv/sva/soc_top_checks_bind.sv attaches it to soc_top,
//              so the RTL does not change. Simulation-only.
//
// APB transfer: SETUP (PSEL high, PENABLE low) lasts exactly one cycle, then ACCESS
// (PENABLE high too) repeats until PREADY is high. The transfer ends in the cycle
// where PREADY is high during ACCESS, and PENABLE falls in the cycle after.
// ==============================================================================

module apb_checks (
    input wire        hclk,
    input wire        hreset_n,
    input wire        penable,
    input wire        psel_uart,
    input wire        psel_spi,
    input wire        psel_gpio,
    input wire        pready_uart,
    input wire        pready_spi,
    input wire        pready_gpio,
    input wire        pwrite,
    input wire [31:0] paddr,
    input wire [31:0] pwdata,
    input wire [3:0]  pstrb
);

    wire psel_any  = psel_uart || psel_spi || psel_gpio;
    wire pready_sel = psel_uart ? pready_uart : psel_spi ? pready_spi : pready_gpio;

    wire setup    = psel_any && !penable;
    wire access   = psel_any && penable;
    wire wait_st  = access && !pready_sel;
    wire complete = access && pready_sel;

    // One peripheral is selected at a time, because the bridge decodes one address.
    a_apb_one_select: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        $onehot0({psel_uart, psel_spi, psel_gpio})
    ) else $error("More than one APB peripheral selected at the same time");

    // PENABLE only exists during a selected transfer.
    a_apb_enable_needs_select: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        penable |-> psel_any
    ) else $error("PENABLE high without PSEL");

    // ACCESS starts only from SETUP, so the first PENABLE cycle is preceded by SETUP.
    a_apb_access_follows_setup: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        $rose(penable) |-> $past(setup)
    ) else $error("PENABLE rose without a SETUP cycle before it");

    // SETUP is always followed by ACCESS, with no extra wait in between.
    a_apb_setup_then_access: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        setup |=> penable
    ) else $error("SETUP cycle was not followed by ACCESS");

    // Address, direction, data, and strobes must not change until the transfer is done.
    // The check runs from SETUP through every wait cycle, so it covers PREADY stalls too.
    a_apb_stable_until_done: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        (setup || wait_st) |=> ($stable(paddr) && $stable(pwrite) && $stable(pwdata) &&
                                $stable(pstrb) && $stable({psel_uart, psel_spi, psel_gpio}))
    ) else $error("APB address, control, or data changed before the transfer completed");

    // The transfer ends when PREADY is high in ACCESS. PENABLE must fall in the next
    // cycle, because the bridge never goes from ACCESS back to ACCESS.
    a_apb_enable_drops_after_complete: assert property (
        @(posedge hclk) disable iff (!hreset_n)
        complete |=> !penable
    ) else $error("PENABLE stayed high after the transfer completed");

    // Exercise counters for the final report. wait_cycles is zero while every
    // peripheral answers PREADY=1, so it shows which rules have not been stressed yet.
    integer n_setup = 0, n_complete = 0, n_wait = 0;
    always @(posedge hclk) begin
        if (hreset_n) begin
            if (setup)    n_setup    <= n_setup + 1;
            if (complete) n_complete <= n_complete + 1;
            if (wait_st)  n_wait     <= n_wait + 1;
        end
    end

    final begin
        $display("APB: setup=%0d complete=%0d wait_cycles=%0d", n_setup, n_complete, n_wait);
    end

endmodule
