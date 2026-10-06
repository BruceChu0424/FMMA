// -----------------------------------------------------------------------------
// mm_core.v
//
// One book_bank + quote_engine pair per symbol. Each symbol has its own RAM
// and its own logic, so all symbols compute concurrently and there is no
// shared memory to contend for. The CPU only touches the cfg_* ports.
//
// Quotes leave per symbol; an arbiter and order encoder go downstream.
// The cfg_*, host_rd_* and tob_* ports connect to axi_ctrl.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module mm_core #(
    parameter N_SYM  = 8,                  // >= 2
    parameter LEVELS = 1024,
    parameter QTY_W  = 32,
    parameter POS_W  = 32,
    parameter IDX_W  = $clog2(LEVELS),
    parameter SYM_W  = $clog2(N_SYM)
)(
    input  wire                     clk,
    input  wire                     rst,
    output wire                     ready,

    // Normalised feed: one message per clock
    input  wire                     upd_valid,
    input  wire [SYM_W-1:0]         upd_sym,
    input  wire                     upd_side,
    input  wire [IDX_W-1:0]         upd_idx,
    input  wire [QTY_W-1:0]         upd_delta,     // signed

    // Inventory per symbol (flattened)
    input  wire [N_SYM*POS_W-1:0]   position,
    input  wire [N_SYM-1:0]         pos_update,

    // Control plane
    input  wire                     quote_enable,
    input  wire [N_SYM*8-1:0]       half_spread,
    input  wire [N_SYM*POS_W-1:0]   pos_limit,
    input  wire [SYM_W-1:0]         cfg_sym,
    input  wire                     cfg_lut_we,
    input  wire [5:0]               cfg_lut_addr,
    input  wire [7:0]               cfg_lut_data,
    input  wire                     cfg_lut_swap,

    // Quotes per symbol (flattened)
    output wire [N_SYM-1:0]         q_valid,
    output wire [N_SYM-1:0]         q_bid_en,
    output wire [N_SYM-1:0]         q_ask_en,
    output wire [N_SYM*IDX_W-1:0]   q_bid,
    output wire [N_SYM*IDX_W-1:0]   q_ask,

    // Host read of book RAM (one request outstanding)
    input  wire                     host_rd_req,
    input  wire [SYM_W-1:0]         host_rd_sym,
    input  wire [IDX_W:0]           host_rd_addr,
    output wire                     host_rd_ack,
    output wire [QTY_W-1:0]         host_rd_data,

    // Top-of-book status per symbol
    output wire [N_SYM-1:0]         tob_bid_present,
    output wire [N_SYM-1:0]         tob_ask_present,
    output wire [N_SYM*IDX_W-1:0]   tob_best_bid,
    output wire [N_SYM*IDX_W-1:0]   tob_best_ask
);
    wire [N_SYM-1:0]       bank_ready, bank_ack;
    wire [N_SYM*QTY_W-1:0] bank_data;
    assign ready        = &bank_ready;
    assign host_rd_ack  = |bank_ack;
    assign host_rd_data = bank_data[host_rd_sym*QTY_W +: QTY_W];

    genvar s;
    generate for (s = 0; s < N_SYM; s = s + 1) begin : g_sym
        wire             tob_valid, bid_present, ask_present;
        wire [IDX_W-1:0] best_bid, best_ask;

        book_bank #(.LEVELS(LEVELS), .QTY_W(QTY_W)) u_book (
            .clk         (clk),
            .rst         (rst),
            .ready       (bank_ready[s]),
            .upd_valid   (upd_valid && (upd_sym == s)),
            .upd_side    (upd_side),
            .upd_idx     (upd_idx),
            .upd_delta   (upd_delta),
            .tob_valid   (tob_valid),
            .bid_present (bid_present),
            .ask_present (ask_present),
            .best_bid    (best_bid),
            .best_ask    (best_ask),
            .host_rd_req (host_rd_req && (host_rd_sym == s)),
            .host_rd_addr(host_rd_addr),
            .host_rd_ack (bank_ack[s]),
            .host_rd_data(bank_data[s*QTY_W +: QTY_W])
        );

        assign tob_bid_present[s]            = bid_present;
        assign tob_ask_present[s]            = ask_present;
        assign tob_best_bid[s*IDX_W +: IDX_W] = best_bid;
        assign tob_best_ask[s*IDX_W +: IDX_W] = best_ask;

        quote_engine #(.IDX_W(IDX_W), .POS_W(POS_W)) u_quote (
            .clk          (clk),
            .rst          (rst),
            .tob_valid    (tob_valid),
            .bid_present  (bid_present),
            .ask_present  (ask_present),
            .best_bid     (best_bid),
            .best_ask     (best_ask),
            .position     (position[s*POS_W +: POS_W]),
            .pos_update   (pos_update[s]),
            .quote_enable (quote_enable),
            .half_spread  (half_spread[s*8 +: 8]),
            .pos_limit    (pos_limit[s*POS_W +: POS_W]),
            .cfg_lut_we   (cfg_lut_we   && (cfg_sym == s)),
            .cfg_lut_addr (cfg_lut_addr),
            .cfg_lut_data (cfg_lut_data),
            .cfg_lut_swap (cfg_lut_swap && (cfg_sym == s)),
            .q_valid      (q_valid[s]),
            .q_bid_en     (q_bid_en[s]),
            .q_ask_en     (q_ask_en[s]),
            .q_bid        (q_bid[s*IDX_W +: IDX_W]),
            .q_ask        (q_ask[s*IDX_W +: IDX_W])
        );
    end endgenerate

endmodule
