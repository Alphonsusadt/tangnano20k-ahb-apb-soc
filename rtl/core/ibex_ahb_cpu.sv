// ==============================================================================
// Module: ibex_ahb_cpu
// Description: lowRISC Ibex (RV32IMC, no cache, PMP, or debug) with its instruction
//              and data ports joined onto one AHB-Lite master port.
//
// Ibex starts fetching at boot_addr_i + 0x80. Interrupts are tied off for now.
// ==============================================================================

module ibex_ahb_cpu (
    input  wire        clk_i,
    input  wire        rst_ni,

    output wire [31:0] haddr,
    output wire [1:0]  htrans,
    output wire        hwrite,
    output wire [2:0]  hsize,
    output wire [31:0] hwdata,
    input  wire [31:0] hrdata,
    input  wire        hready,
    input  wire        hresp
);

    wire        instr_req, instr_gnt, instr_rvalid, instr_err;
    wire [31:0] instr_addr, instr_rdata;

    wire        data_req, data_gnt, data_rvalid, data_we, data_err;
    wire [3:0]  data_be;
    wire [31:0] data_addr, data_wdata, data_rdata;

    ibex_top #(
        .BaseIsa (ibex_pkg::BaseIsaRV32I),
        .RV32E   (1'b0),
        .RV32M   (ibex_pkg::RV32MSlow),
        .RV32B   (ibex_pkg::RV32BNone),
        .RV32ZC  (ibex_pkg::RV32Zca),
        .RegFile (ibex_pkg::RegFileFF)
    ) u_ibex (
        .clk_i                   (clk_i),
        .rst_ni                  (rst_ni),
        .test_en_i               (1'b0),
        .scan_rst_ni             (1'b1),

        // The instruction cache is off, so its RAM configuration does nothing.
        .ram_cfg_icache_tag_i    ('0),
        .ram_cfg_icache_tag_o    (),
        .ram_cfg_icache_data_i   ('0),
        .ram_cfg_icache_data_o   (),

        .cheriot_enable_i        (ibex_pkg::IbexMuBiOff),
        .hart_id_i               (32'h0),
        .boot_addr_i             (32'h0),
        .trvk_heap_base_addr_i   (32'h0),

        .instr_req_o             (instr_req),
        .instr_gnt_i             (instr_gnt),
        .instr_rvalid_i          (instr_rvalid),
        .instr_addr_o            (instr_addr),
        .instr_rdata_i           (instr_rdata),
        .instr_rdata_intg_i      (7'h0),
        .instr_err_i             (instr_err),

        .data_req_o              (data_req),
        .data_gnt_i              (data_gnt),
        .data_rvalid_i           (data_rvalid),
        .data_we_o               (data_we),
        .data_be_o               (data_be),
        .data_addr_o             (data_addr),
        .data_wdata_o            (data_wdata),
        .data_wdata_intg_o       (),
        .data_tag_o              (),
        .data_rdata_i            (data_rdata),
        .data_rdata_intg_i       (7'h0),
        .data_tag_i              (1'b0),
        .data_err_i              (data_err),

        // CHERIoT revocation port, unused with the RV32I base ISA.
        .trvk_revbm_req_o        (),
        .trvk_revbm_gnt_i        (1'b0),
        .trvk_revbm_rvalid_i     (1'b0),
        .trvk_revbm_addr_o       (),
        .trvk_revbm_rdata_i      (32'h0),
        .trvk_revbm_rdata_intg_i (7'h0),
        .trvk_revbm_err_i        (1'b0),

        .irq_software_i          (1'b0),
        .irq_timer_i             (1'b0),
        .irq_external_i          (1'b0),
        .irq_fast_i              (15'h0),
        .irq_nm_i                (1'b0),

        .scramble_key_valid_i    (1'b0),
        .scramble_key_i          ('0),
        .scramble_nonce_i        ('0),
        .scramble_req_o          (),

        .debug_req_i             (1'b0),
        .crash_dump_o            (),
        .double_fault_seen_o     (),

        .fetch_enable_i          (ibex_pkg::IbexMuBiOn),
        .mcounteren_writable_i   (ibex_pkg::IbexMuBiOn),
        .alert_minor_o           (),
        .alert_major_internal_o  (),
        .alert_major_bus_o       (),
        .core_sleep_o            (),
        .lockstep_cmp_en_o       ()
    );

    obi_to_ahb_adapter u_adapter (
        .hclk           (clk_i),
        .hreset_n       (rst_ni),

        .instr_req_i    (instr_req),
        .instr_gnt_o    (instr_gnt),
        .instr_rvalid_o (instr_rvalid),
        .instr_addr_i   (instr_addr),
        .instr_rdata_o  (instr_rdata),
        .instr_err_o    (instr_err),

        .data_req_i     (data_req),
        .data_gnt_o     (data_gnt),
        .data_rvalid_o  (data_rvalid),
        .data_we_i      (data_we),
        .data_be_i      (data_be),
        .data_addr_i    (data_addr),
        .data_wdata_i   (data_wdata),
        .data_rdata_o   (data_rdata),
        .data_err_o     (data_err),

        .haddr          (haddr),
        .htrans         (htrans),
        .hwrite         (hwrite),
        .hsize          (hsize),
        .hwdata         (hwdata),
        .hrdata         (hrdata),
        .hready         (hready),
        .hresp          (hresp)
    );

endmodule
