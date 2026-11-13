// Attaches the AHB-Lite assertions to the CPU bus in every soc_top instance.
bind soc_top ahb_lite_checks u_ahb_lite_checks (
    .hclk     (clk),
    .hreset_n (rst_sys_n),
    .haddr    (cpu_haddr),
    .htrans   (cpu_htrans),
    .hwrite   (cpu_hwrite),
    .hsize    (cpu_hsize),
    .hwdata   (cpu_hwdata),
    .hready   (cpu_hready),
    .hresp    (cpu_hresp)
);

// Attaches the APB assertions to the bridge-to-peripheral bus in every soc_top instance.
bind soc_top apb_checks u_apb_checks (
    .hclk        (clk),
    .hreset_n    (rst_sys_n),
    .penable     (apb_penable),
    .psel_uart   (psel_uart),
    .psel_spi    (psel_spi),
    .psel_gpio   (psel_gpio),
    .pready_uart (pready_uart),
    .pready_spi  (pready_spi),
    .pready_gpio (pready_gpio),
    .pwrite      (apb_pwrite),
    .paddr       (apb_paddr),
    .pwdata      (apb_pwdata),
    .pstrb       (apb_pstrb)
);
