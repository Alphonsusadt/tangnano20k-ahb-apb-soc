// ==============================================================================
// Module: soc_top
// Description: Tang Nano 20K RISC-V SoC Top-Level
// ==============================================================================

module soc_top #(
    parameter BOOT_HEX_FILE = ""
)(
    input  wire        clk_27m,
    input  wire        rst_n,

    // Pushbutton input
    input  wire        btn_s2,

    // UART Serial
    output wire        uart_tx,
    input  wire        uart_rx,

    // SPI Master
    output wire        spi_sck,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire [7:0]  spi_cs_n,

    // On-board LEDs
    output wire [5:0]  led
);

    wire clk = clk_27m;
    wire rst_sys_n = rst_n;

    // --------------------------------------------------------------------------
    // AHB Master Interface (From CPU)
    // --------------------------------------------------------------------------
    wire [31:0] cpu_haddr;
    wire [1:0]  cpu_htrans;
    wire        cpu_hwrite;
    wire [2:0]  cpu_hsize;
    wire [2:0]  cpu_hburst;
    wire [3:0]  cpu_hprot;
    wire [31:0] cpu_hwdata;
    wire [31:0] cpu_hrdata;
    wire        cpu_hready;
    wire        cpu_hresp;

    // --------------------------------------------------------------------------
    // AHB Slaves
    // --------------------------------------------------------------------------
    // Slave 0: Instruction ROM
    wire        imem_hsel;
    wire [31:0] imem_haddr;
    wire [1:0]  imem_htrans;
    wire        imem_hwrite;
    wire [2:0]  imem_hsize;
    wire [31:0] imem_hwdata;
    reg  [31:0] imem_hrdata;
    wire        imem_hready = 1'b1;
    wire        imem_hresp  = 1'b0;

    // Slave 1: Data SRAM
    wire        dmem_hsel;
    wire [31:0] dmem_haddr;
    wire [1:0]  dmem_htrans;
    wire        dmem_hwrite;
    wire [2:0]  dmem_hsize;
    wire [31:0] dmem_hwdata;
    reg  [31:0] dmem_hrdata;
    wire        dmem_hready = 1'b1;
    wire        dmem_hresp  = 1'b0;

    // Slave 2: AHB-to-APB Bridge
    wire        bridge_hsel;
    wire [31:0] bridge_haddr;
    wire [1:0]  bridge_htrans;
    wire        bridge_hwrite;
    wire [2:0]  bridge_hsize;
    wire [31:0] bridge_hwdata;
    wire [31:0] bridge_hrdata;
    wire        bridge_hready;
    wire        bridge_hresp;

    // --------------------------------------------------------------------------
    // AHB Interconnect Decoder
    // --------------------------------------------------------------------------
    ahb_interconnect u_ahb_interconnect (
        .hclk       (clk),
        .hreset_n   (rst_sys_n),

        // CPU Master
        .s_haddr    (cpu_haddr),
        .s_htrans   (cpu_htrans),
        .s_hwrite   (cpu_hwrite),
        .s_hsize    (cpu_hsize),
        .s_hburst   (cpu_hburst),
        .s_hprot    (cpu_hprot),
        .s_hwdata   (cpu_hwdata),
        .s_hrdata   (cpu_hrdata),
        .s_hready   (cpu_hready),
        .s_hresp    (cpu_hresp),

        // Slave 0: IMEM
        .m0_hsel    (imem_hsel),
        .m0_haddr   (imem_haddr),
        .m0_htrans  (imem_htrans),
        .m0_hwrite  (imem_hwrite),
        .m0_hsize   (imem_hsize),
        .m0_hwdata  (imem_hwdata),
        .m0_hrdata  (imem_hrdata),
        .m0_hready  (imem_hready),
        .m0_hresp   (imem_hresp),

        // Slave 1: DMEM
        .m1_hsel    (dmem_hsel),
        .m1_haddr   (dmem_haddr),
        .m1_htrans  (dmem_htrans),
        .m1_hwrite  (dmem_hwrite),
        .m1_hsize   (dmem_hsize),
        .m1_hwdata  (dmem_hwdata),
        .m1_hrdata  (dmem_hrdata),
        .m1_hready  (dmem_hready),
        .m1_hresp   (dmem_hresp),

        // Slave 2: Bridge
        .m2_hsel    (bridge_hsel),
        .m2_haddr   (bridge_haddr),
        .m2_htrans  (bridge_htrans),
        .m2_hwrite  (bridge_hwrite),
        .m2_hsize   (bridge_hsize),
        .m2_hwdata  (bridge_hwdata),
        .m2_hrdata  (bridge_hrdata),
        .m2_hready  (bridge_hready),
        .m2_hresp   (bridge_hresp)
    );

    // --------------------------------------------------------------------------
    // Instruction ROM (32 KB = 8192 words x 32-bit)
    // --------------------------------------------------------------------------
    reg [31:0] rom_mem [0:8191];
    initial begin
        if (BOOT_HEX_FILE != "") begin
            $readmemh(BOOT_HEX_FILE, rom_mem);
        end
    end

    always @(posedge clk) begin
        if (imem_hsel && (imem_htrans[1])) begin
            imem_hrdata <= rom_mem[imem_haddr[14:2]];
        end
    end

    // --------------------------------------------------------------------------
    // Data SRAM (32 KB = 8192 words x 32-bit)
    // --------------------------------------------------------------------------
    reg [31:0] sram_mem [0:8191];
    always @(posedge clk) begin
        if (dmem_hsel && dmem_htrans[1]) begin
            if (dmem_hwrite) begin
                sram_mem[dmem_haddr[14:2]] <= dmem_hwdata;
            end
            dmem_hrdata <= sram_mem[dmem_haddr[14:2]];
        end
    end

    // --------------------------------------------------------------------------
    // APB Interconnect & Peripherals
    // --------------------------------------------------------------------------
    wire [31:0] apb_paddr;
    wire [31:0] apb_pwdata;
    wire        apb_pwrite;
    wire [2:0]  apb_pprot;
    wire [3:0]  apb_pstrb;
    wire        apb_penable;

    wire        psel_uart, pready_uart, pslverr_uart;
    wire [31:0] prdata_uart;

    wire        psel_spi, pready_spi, pslverr_spi;
    wire [31:0] prdata_spi;

    wire        psel_gpio, pready_gpio, pslverr_gpio;
    wire [31:0] prdata_gpio;

    ahb_to_apb_bridge u_bridge (
        .hclk         (clk),
        .hreset_n     (rst_sys_n),

        .hsel         (bridge_hsel),
        .haddr        (bridge_haddr),
        .htrans       (bridge_htrans),
        .hwrite       (bridge_hwrite),
        .hsize        (bridge_hsize),
        .hwdata       (bridge_hwdata),
        .hrdata       (bridge_hrdata),
        .hready       (bridge_hready),
        .hresp        (bridge_hresp),

        .paddr        (apb_paddr),
        .pwdata       (apb_pwdata),
        .pwrite       (apb_pwrite),
        .pprot        (apb_pprot),
        .pstrb        (apb_pstrb),
        .penable      (apb_penable),

        .psel_uart    (psel_uart),
        .prdata_uart  (prdata_uart),
        .pready_uart  (pready_uart),
        .pslverr_uart (pslverr_uart),

        .psel_spi     (psel_spi),
        .prdata_spi   (prdata_spi),
        .pready_spi   (pready_spi),
        .pslverr_spi  (pslverr_spi),

        .psel_gpio    (psel_gpio),
        .prdata_gpio  (prdata_gpio),
        .pready_gpio  (pready_gpio),
        .pslverr_gpio (pslverr_gpio)
    );

    // Peripherals
    wire uart_irq;
    apb_uart #(
        .DEFAULT_BAUD_DIV(16'd234) // 27 MHz / 115200
    ) u_uart (
        .pclk         (clk),
        .preset_n     (rst_sys_n),
        .psel         (psel_uart),
        .penable      (apb_penable),
        .pwrite       (apb_pwrite),
        .paddr        (apb_paddr),
        .pwdata       (apb_pwdata),
        .pstrb        (apb_pstrb),
        .prdata       (prdata_uart),
        .pready       (pready_uart),
        .pslverr      (pslverr_uart),
        .uart_tx      (uart_tx),
        .uart_rx      (uart_rx),
        .uart_irq     (uart_irq)
    );

    apb_spi u_spi (
        .pclk         (clk),
        .preset_n     (rst_sys_n),
        .psel         (psel_spi),
        .penable      (apb_penable),
        .pwrite       (apb_pwrite),
        .paddr        (apb_paddr),
        .pwdata       (apb_pwdata),
        .pstrb        (apb_pstrb),
        .prdata       (prdata_spi),
        .pready       (pready_spi),
        .pslverr      (pslverr_spi),
        .spi_sck      (spi_sck),
        .spi_mosi     (spi_mosi),
        .spi_miso     (spi_miso),
        .spi_cs_n     (spi_cs_n)
    );

    apb_gpio u_gpio (
        .pclk         (clk),
        .preset_n     (rst_sys_n),
        .psel         (psel_gpio),
        .penable      (apb_penable),
        .pwrite       (apb_pwrite),
        .paddr        (apb_paddr),
        .pwdata       (apb_pwdata),
        .pstrb        (apb_pstrb),
        .prdata       (prdata_gpio),
        .pready       (pready_gpio),
        .pslverr      (pslverr_gpio),
        .gpio_out     (led),
        .gpio_in      ({btn_s2, rst_n})
    );

    assign cpu_hburst = 3'b000;
    assign cpu_hprot  = 4'b0011;

endmodule
