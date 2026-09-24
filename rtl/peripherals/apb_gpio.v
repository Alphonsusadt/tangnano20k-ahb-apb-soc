// ==============================================================================
// Module: apb_gpio
// Description: Simple APB4 GPIO Controller for LEDs and Pushbuttons
// ==============================================================================

module apb_gpio (
    input  wire        pclk,
    input  wire        preset_n,

    // APB4 Slave Interface
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    input  wire [3:0]  pstrb,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // External GPIO Pins
    output reg  [5:0]  gpio_out, // Tang Nano 20K Onboard LEDs (active low)
    input  wire [1:0]  gpio_in   // Tang Nano 20K Pushbuttons S1 & S2
);

    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    reg [5:0] dir_reg;

    always @(*) begin
        case (paddr[3:2])
            2'b00: prdata = {26'h0, gpio_out};
            2'b01: prdata = {30'h0, gpio_in};
            2'b10: prdata = {26'h0, dir_reg};
            default: prdata = 32'h0;
        endcase
    end

    wire apb_write = psel && penable && pwrite;

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            gpio_out <= 6'b111111; // LEDs OFF (active-low)
            dir_reg  <= 6'b111111;
        end else if (apb_write) begin
            case (paddr[3:2])
                2'b00: gpio_out <= pwdata[5:0];
                2'b10: dir_reg  <= pwdata[5:0];
                default: ;
            endcase
        end
    end

endmodule
