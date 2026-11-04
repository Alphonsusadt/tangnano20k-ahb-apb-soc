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
