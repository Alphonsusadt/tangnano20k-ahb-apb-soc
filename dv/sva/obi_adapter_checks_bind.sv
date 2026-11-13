// Attaches the AHB-Lite protocol assertions to the adapter's AHB port in the random
// adapter test. The memory map rules stay off, because that test has its own address
// space. Used only by dv/run_obi_sva.sh.
bind obi_to_ahb_adapter ahb_lite_checks #(
    .MAP_RULES (0)
) u_ahb_lite_checks (
    .hclk     (hclk),
    .hreset_n (hreset_n),
    .haddr    (haddr),
    .htrans   (htrans),
    .hwrite   (hwrite),
    .hsize    (hsize),
    .hwdata   (hwdata),
    .hready   (hready),
    .hresp    (hresp)
);
