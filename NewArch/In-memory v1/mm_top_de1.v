// -----------------------------------------------------------------------------
// mm_top_de1.v
//
// Fixed-size wrapper around mm_top for the DE1-SoC, packaged as a Platform
// Designer component by mm_top_de1_hw.tcl.
//
//   4 symbols, 1024 levels per side, 18-bit AXI address (256 KB window)
//
// Address map inside the component's window (add the base you assign in
// Platform Designer, plus 0xFF200000 for the lightweight bridge):
//   0x00000  global regs (ID, CTRL, STATUS)
//   0x20000 + s * 0x4000  symbol s (see axi_ctrl.v for offsets)
//
// awprot/arprot are unused; older Platform Designer versions require them on
// an AXI4-Lite slave.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module mm_top_de1 (
    input  wire          clk,
    input  wire          rst,

    // AXI4-Lite slave (connect to hps_0.h2f_lw_axi_master)
    input  wire [17:0]   s_axi_awaddr,
    input  wire [2:0]    s_axi_awprot,
    input  wire          s_axi_awvalid,
    output wire          s_axi_awready,
    input  wire [31:0]   s_axi_wdata,
    input  wire [3:0]    s_axi_wstrb,
    input  wire          s_axi_wvalid,
    output wire          s_axi_wready,
    output wire [1:0]    s_axi_bresp,
    output wire          s_axi_bvalid,
    input  wire          s_axi_bready,
    input  wire [17:0]   s_axi_araddr,
    input  wire [2:0]    s_axi_arprot,
    input  wire          s_axi_arvalid,
    output wire          s_axi_arready,
    output wire [31:0]   s_axi_rdata,
    output wire [1:0]    s_axi_rresp,
    output wire          s_axi_rvalid,
    input  wire          s_axi_rready,

    // Feed (conduit)
    input  wire          upd_valid,
    input  wire [1:0]    upd_sym,
    input  wire          upd_side,
    input  wire [9:0]    upd_idx,
    input  wire [31:0]   upd_delta,

    // Inventory (conduit)
    input  wire [127:0]  position,      // 4 x 32-bit signed
    input  wire [3:0]    pos_update,

    // Quotes (conduit)
    output wire [3:0]    q_valid,
    output wire [3:0]    q_bid_en,
    output wire [3:0]    q_ask_en,
    output wire [39:0]   q_bid,         // 4 x 10-bit level index
    output wire [39:0]   q_ask
);
    mm_top #(
        .N_SYM  (4),
        .LEVELS (1024),
        .QTY_W  (32),
        .POS_W  (32),
        .AW     (18)
    ) u_mm (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .upd_valid(upd_valid), .upd_sym(upd_sym), .upd_side(upd_side),
        .upd_idx(upd_idx), .upd_delta(upd_delta),
        .position(position), .pos_update(pos_update),
        .q_valid(q_valid), .q_bid_en(q_bid_en), .q_ask_en(q_ask_en),
        .q_bid(q_bid), .q_ask(q_ask)
    );
endmodule
