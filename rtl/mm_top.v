// -----------------------------------------------------------------------------
// mm_top.v
//
// mm_core plus its AXI4-Lite control plane. Connect s_axi_* to your bridge
// (e.g. the XDMA AXI-Lite master, via an AXI Clock Converter if the bridge
// clock differs from clk). See axi_ctrl.v for the address map.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module mm_top #(
    parameter N_SYM  = 8,
    parameter LEVELS = 1024,
    parameter QTY_W  = 32,
    parameter POS_W  = 32,
    parameter AW     = 24,
    parameter IDX_W  = $clog2(LEVELS),
    parameter SYM_W  = $clog2(N_SYM)
)(
    input  wire                     clk,
    input  wire                     rst,

    // AXI4-Lite control plane
    input  wire [AW-1:0]            s_axi_awaddr,
    input  wire                     s_axi_awvalid,
    output wire                     s_axi_awready,
    input  wire [31:0]              s_axi_wdata,
    input  wire [3:0]               s_axi_wstrb,
    input  wire                     s_axi_wvalid,
    output wire                     s_axi_wready,
    output wire [1:0]               s_axi_bresp,
    output wire                     s_axi_bvalid,
    input  wire                     s_axi_bready,
    input  wire [AW-1:0]            s_axi_araddr,
    input  wire                     s_axi_arvalid,
    output wire                     s_axi_arready,
    output wire [31:0]              s_axi_rdata,
    output wire [1:0]               s_axi_rresp,
    output wire                     s_axi_rvalid,
    input  wire                     s_axi_rready,

    // Normalised feed
    input  wire                     upd_valid,
    input  wire [SYM_W-1:0]         upd_sym,
    input  wire                     upd_side,
    input  wire [IDX_W-1:0]         upd_idx,
    input  wire [QTY_W-1:0]         upd_delta,

    // Inventory from fill processing
    input  wire [N_SYM*POS_W-1:0]   position,
    input  wire [N_SYM-1:0]         pos_update,

    // Quotes
    output wire [N_SYM-1:0]         q_valid,
    output wire [N_SYM-1:0]         q_bid_en,
    output wire [N_SYM-1:0]         q_ask_en,
    output wire [N_SYM*IDX_W-1:0]   q_bid,
    output wire [N_SYM*IDX_W-1:0]   q_ask
);
    wire                     ready, quote_enable;
    wire [N_SYM*8-1:0]       half_spread;
    wire [N_SYM*POS_W-1:0]   pos_limit;
    wire [SYM_W-1:0]         cfg_sym, host_rd_sym;
    wire                     cfg_lut_we, cfg_lut_swap;
    wire [5:0]               cfg_lut_addr;
    wire [7:0]               cfg_lut_data;
    wire                     host_rd_req, host_rd_ack;
    wire [IDX_W:0]           host_rd_addr;
    wire [QTY_W-1:0]         host_rd_data;
    wire [N_SYM-1:0]         tob_bid_present, tob_ask_present;
    wire [N_SYM*IDX_W-1:0]   tob_best_bid, tob_best_ask;

    axi_ctrl #(.N_SYM(N_SYM), .LEVELS(LEVELS), .QTY_W(QTY_W),
               .POS_W(POS_W), .AW(AW)) u_axi (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .core_ready(ready), .quote_enable(quote_enable),
        .half_spread(half_spread), .pos_limit(pos_limit),
        .cfg_sym(cfg_sym), .cfg_lut_we(cfg_lut_we), .cfg_lut_addr(cfg_lut_addr),
        .cfg_lut_data(cfg_lut_data), .cfg_lut_swap(cfg_lut_swap),
        .host_rd_req(host_rd_req), .host_rd_sym(host_rd_sym), .host_rd_addr(host_rd_addr),
        .host_rd_ack(host_rd_ack), .host_rd_data(host_rd_data),
        .tob_bid_present(tob_bid_present), .tob_ask_present(tob_ask_present),
        .tob_best_bid(tob_best_bid), .tob_best_ask(tob_best_ask)
    );

    mm_core #(.N_SYM(N_SYM), .LEVELS(LEVELS), .QTY_W(QTY_W), .POS_W(POS_W)) u_core (
        .clk(clk), .rst(rst), .ready(ready),
        .upd_valid(upd_valid), .upd_sym(upd_sym), .upd_side(upd_side),
        .upd_idx(upd_idx), .upd_delta(upd_delta),
        .position(position), .pos_update(pos_update),
        .quote_enable(quote_enable), .half_spread(half_spread), .pos_limit(pos_limit),
        .cfg_sym(cfg_sym), .cfg_lut_we(cfg_lut_we), .cfg_lut_addr(cfg_lut_addr),
        .cfg_lut_data(cfg_lut_data), .cfg_lut_swap(cfg_lut_swap),
        .q_valid(q_valid), .q_bid_en(q_bid_en), .q_ask_en(q_ask_en),
        .q_bid(q_bid), .q_ask(q_ask),
        .host_rd_req(host_rd_req), .host_rd_sym(host_rd_sym), .host_rd_addr(host_rd_addr),
        .host_rd_ack(host_rd_ack), .host_rd_data(host_rd_data),
        .tob_bid_present(tob_bid_present), .tob_ask_present(tob_ask_present),
        .tob_best_bid(tob_best_bid), .tob_best_ask(tob_best_ask)
    );

endmodule
