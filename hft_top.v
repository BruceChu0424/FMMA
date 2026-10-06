// -----------------------------------------------------------------------------
// hft_top.v
//
// DE1-SoC top level: board pins in, HPSfgpa2 (HPS + market maker core) inside.
//
//   CLOCK_50   50 MHz board clock, drives the whole Platform Designer system
//   KEY[0]     press to reset the system (active low)
//   LEDR[9]    heartbeat: blinks once the FPGA image is loaded and clocked
//   LEDR[3:0]  toggles each time symbol 0..3 produces a quote
//
// The HPS DDR3 pins are dedicated HPS pins: Quartus places them itself, and
// hps_sdram_p0_pin_assignments.tcl sets their I/O standards.
// -----------------------------------------------------------------------------
module hft_top (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    output wire [9:0]  LEDR,

    // HPS DDR3 (1 GB, 32-bit)
    output wire [14:0] HPS_DDR3_ADDR,
    output wire [2:0]  HPS_DDR3_BA,
    output wire        HPS_DDR3_CK_P,
    output wire        HPS_DDR3_CK_N,
    output wire        HPS_DDR3_CKE,
    output wire        HPS_DDR3_CS_N,
    output wire        HPS_DDR3_RAS_N,
    output wire        HPS_DDR3_CAS_N,
    output wire        HPS_DDR3_WE_N,
    output wire        HPS_DDR3_RESET_N,
    inout  wire [31:0] HPS_DDR3_DQ,
    inout  wire [3:0]  HPS_DDR3_DQS_P,
    inout  wire [3:0]  HPS_DDR3_DQS_N,
    output wire        HPS_DDR3_ODT,
    output wire [3:0]  HPS_DDR3_DM,
    input  wire        HPS_DDR3_RZQ
);

    wire [3:0]  q_valid, q_bid_en, q_ask_en;
    wire [39:0] q_bid, q_ask;

    HPSfgpa2 u0 (
        .clk_clk                           (CLOCK_50),
        .reset_reset_n                     (KEY[0]),

        .memory_mem_a                      (HPS_DDR3_ADDR),
        .memory_mem_ba                     (HPS_DDR3_BA),
        .memory_mem_ck                     (HPS_DDR3_CK_P),
        .memory_mem_ck_n                   (HPS_DDR3_CK_N),
        .memory_mem_cke                    (HPS_DDR3_CKE),
        .memory_mem_cs_n                   (HPS_DDR3_CS_N),
        .memory_mem_ras_n                  (HPS_DDR3_RAS_N),
        .memory_mem_cas_n                  (HPS_DDR3_CAS_N),
        .memory_mem_we_n                   (HPS_DDR3_WE_N),
        .memory_mem_reset_n                (HPS_DDR3_RESET_N),
        .memory_mem_dq                     (HPS_DDR3_DQ),
        .memory_mem_dqs                    (HPS_DDR3_DQS_P),
        .memory_mem_dqs_n                  (HPS_DDR3_DQS_N),
        .memory_mem_odt                    (HPS_DDR3_ODT),
        .memory_mem_dm                     (HPS_DDR3_DM),
        .memory_oct_rzqin                  (HPS_DDR3_RZQ),

        // Feed and inventory: tied off until the HPS feed path is added
        .mm_top_de1_0_feed_upd_valid       (1'b0),
        .mm_top_de1_0_feed_upd_sym         (2'd0),
        .mm_top_de1_0_feed_upd_side        (1'b0),
        .mm_top_de1_0_feed_upd_idx         (10'd0),
        .mm_top_de1_0_feed_upd_delta       (32'd0),
        .mm_top_de1_0_inventory_position   (128'd0),
        .mm_top_de1_0_inventory_pos_update (4'd0),

        .mm_top_de1_0_quotes_q_valid       (q_valid),
        .mm_top_de1_0_quotes_q_bid_en      (q_bid_en),
        .mm_top_de1_0_quotes_q_ask_en      (q_ask_en),
        .mm_top_de1_0_quotes_q_bid         (q_bid),
        .mm_top_de1_0_quotes_q_ask         (q_ask)
    );

    // Heartbeat: ~0.75 Hz blink
    reg [25:0] hb = 26'd0;
    always @(posedge CLOCK_50) hb <= hb + 1'b1;

    // One toggle per quote, per symbol
    reg [3:0] q_toggle = 4'd0;
    always @(posedge CLOCK_50) q_toggle <= q_toggle ^ q_valid;

    assign LEDR[9]   = hb[25];
    assign LEDR[8:4] = 5'd0;
    assign LEDR[3:0] = q_toggle;

endmodule
