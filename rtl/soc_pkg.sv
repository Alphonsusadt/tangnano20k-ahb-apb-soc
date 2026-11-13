// ==============================================================================
// Package: soc_pkg
// Description: The SoC memory map in one place, matching docs/memory_map.md. The
//              interconnect, the bridge, and the bus assertions decode from these
//              constants, so a new block is added here first.
// ==============================================================================

package soc_pkg;

    // AHB slaves
    localparam logic [31:0] ROM_BASE   = 32'h0000_0000; // 32 KB, read-only, write answers ERROR
    localparam logic [31:0] ROM_SIZE   = 32'h0000_8000;
    localparam logic [31:0] SRAM_BASE  = 32'h2000_0000; // 32 KB
    localparam logic [31:0] SRAM_SIZE  = 32'h0000_8000;
    localparam logic [31:0] APB_BASE   = 32'h4000_0000; // 0x4xxx_xxxx goes to the bridge
    localparam logic [31:0] APB_SIZE   = 32'h1000_0000;

    // APB peripherals, one 4 KB block each
    localparam logic [31:0] APB_BLOCK_SIZE = 32'h0000_1000;
    localparam logic [31:0] UART_BASE      = 32'h4000_0000;
    localparam logic [31:0] SPI_BASE       = 32'h4000_1000;
    localparam logic [31:0] GPIO_BASE      = 32'h4000_2000;
    localparam logic [31:0] TIMER_BASE     = 32'h4000_3000; // Decoded once the timer exists (F4)
    localparam logic [31:0] SYSCTRL_BASE   = 32'h4000_4000; // Decoded once the loader exists (F6)

    // Decode helpers. ROM and SRAM are 32 KB, so bits [31:15] select the block.
    function automatic logic in_rom(input logic [31:0] addr);
        return addr[31:15] == ROM_BASE[31:15];
    endfunction

    function automatic logic in_sram(input logic [31:0] addr);
        return addr[31:15] == SRAM_BASE[31:15];
    endfunction

    function automatic logic in_apb(input logic [31:0] addr);
        return addr[31:28] == APB_BASE[31:28];
    endfunction

    // True when addr is inside the 4 KB block that starts at base.
    function automatic logic in_apb_block(input logic [31:0] addr, input logic [31:0] base);
        return addr[31:12] == base[31:12];
    endfunction

endpackage
