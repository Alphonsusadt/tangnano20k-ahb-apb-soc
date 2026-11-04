// ==============================================================================
// Module: prim_clock_gating
// Description: Pass-through replacement for the Ibex clock gate on the FPGA.
//
// The generic version gates the clock with a latch and an AND gate, which adds skew
// on FPGA fabric. Ibex stays correct with a free-running clock: while it sleeps its
// controller waits in its sleep state, so only the power saving is lost.
// ==============================================================================

module prim_clock_gating #(
    parameter bit NoFpgaGate = 1'b0,
    parameter bit FpgaBufGlobal = 1'b1
)(
    input  logic clk_i,
    input  logic en_i,
    input  logic test_en_i,
    output logic clk_o
);

    assign clk_o = clk_i;

    logic unused_inputs;
    assign unused_inputs = en_i ^ test_en_i;

endmodule
