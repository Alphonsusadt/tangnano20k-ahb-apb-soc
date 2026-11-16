// ==============================================================================
// Module: apb_timer
// Description: 64-bit machine timer on APB, in the style of the RISC-V mtime and
//              mtimecmp registers. mtime counts one tick per clock while EN is set.
//              The interrupt is a level: irq_timer = EN && (mtime >= mtimecmp). It
//              stays high until software raises mtimecmp or clears EN, so it can
//              never be lost, and needs no pending register to clear.
//
// Registers (see docs/memory_map.md, section 5):
//   0x00 MTIME_LO     0x04 MTIME_HI     0x08 MTIMECMP_LO     0x0C MTIMECMP_HI
//   0x10 TIMER_CTRL   [0] EN (R/W), [1] IRQ (RO, same as irq_timer)
// ==============================================================================

module apb_timer (
    input  wire         pclk,
    input  wire         preset_n,

    input  wire         psel,
    input  wire         penable,
    input  wire         pwrite,
    input  wire  [31:0] paddr,
    input  wire  [31:0] pwdata,
    input  wire  [3:0]  pstrb,
    output logic [31:0] prdata,
    output wire         pready,
    output wire         pslverr,

    output wire         irq_timer
);

    assign pready = 1'b1;
    // Offsets past TIMER_CTRL answer with an error instead of aliasing onto a register.
    wire reg_valid = (paddr[11:5] == 7'h00) && (paddr[4:2] <= 3'b100);
    assign pslverr = psel && penable && !reg_valid;

    logic [63:0] mtime;
    logic [63:0] mtimecmp;
    logic        en;

    assign irq_timer = en && (mtime >= mtimecmp);

    always_comb begin
        case (paddr[4:2])
            3'b000:  prdata = mtime[31:0];
            3'b001:  prdata = mtime[63:32];
            3'b010:  prdata = mtimecmp[31:0];
            3'b011:  prdata = mtimecmp[63:32];
            3'b100:  prdata = {30'h0, irq_timer, en};
            default: prdata = 32'h0;
        endcase
    end

    wire apb_write = psel && penable && pwrite && reg_valid;

    // Byte enables for the 32-bit word, widened to bits.
    wire [31:0] wmask = {{8{pstrb[3]}}, {8{pstrb[2]}}, {8{pstrb[1]}}, {8{pstrb[0]}}};

    // The counter keeps running in the cycle of a write; written bytes take the new
    // value and the other bytes keep the incremented one.
    wire [63:0] mtime_inc = en ? mtime + 64'd1 : mtime;

    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            mtime    <= 64'h0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF; // No interrupt until software sets it
            en       <= 1'b0;
        end else begin
            mtime <= mtime_inc;
            if (apb_write) begin
                case (paddr[4:2])
                    3'b000: mtime[31:0]     <= (mtime_inc[31:0]  & ~wmask) | (pwdata & wmask);
                    3'b001: mtime[63:32]    <= (mtime_inc[63:32] & ~wmask) | (pwdata & wmask);
                    3'b010: mtimecmp[31:0]  <= (mtimecmp[31:0]   & ~wmask) | (pwdata & wmask);
                    3'b011: mtimecmp[63:32] <= (mtimecmp[63:32]  & ~wmask) | (pwdata & wmask);
                    3'b100: if (pstrb[0]) en <= pwdata[0];
                    default: ;
                endcase
            end
        end
    end

endmodule
