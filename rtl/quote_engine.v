// -----------------------------------------------------------------------------
// quote_engine.v
//
// Sits beside a book_bank. On every top-of-book change or position change it
// produces a two-sided quote:
//
//   fair  = floor((best_bid + best_ask) / 2)
//   bid   = fair - half_spread - skew[position bucket]
//   ask   = fair + half_spread - skew[position bucket]
//
// The skew table lives in a small double-buffered RAM. The host writes the
// inactive half, then pulses cfg_lut_swap, so the pipeline never sees a
// half-written table. Risk checks run in parallel and only gate the enables.
//
// Latency: trigger in cycle 0 -> q_valid in cycle 2.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module quote_engine #(
    parameter IDX_W     = 10,
    parameter POS_W     = 32,
    parameter LUT_AW    = 6,     // 64 inventory buckets
    parameter BUCKET_SH = 4      // 2^BUCKET_SH position units per bucket
)(
    input  wire                     clk,
    input  wire                     rst,

    // From book_bank
    input  wire                     tob_valid,
    input  wire                     bid_present,
    input  wire                     ask_present,
    input  wire [IDX_W-1:0]         best_bid,
    input  wire [IDX_W-1:0]         best_ask,

    // Live inventory from fill processing
    input  wire signed [POS_W-1:0]  position,
    input  wire                     pos_update,     // pulse on fill

    // Control plane
    input  wire                     quote_enable,   // kill switch
    input  wire [7:0]               half_spread,    // ticks
    input  wire signed [POS_W-1:0]  pos_limit,      // absolute, > 0
    input  wire                     cfg_lut_we,
    input  wire [LUT_AW-1:0]        cfg_lut_addr,
    input  wire signed [7:0]        cfg_lut_data,   // skew in ticks
    input  wire                     cfg_lut_swap,

    // Quote out
    output reg                      q_valid,
    output reg                      q_bid_en,
    output reg                      q_ask_en,
    output reg  [IDX_W-1:0]         q_bid,
    output reg  [IDX_W-1:0]         q_ask
);
    localparam LUT_N   = 1 << LUT_AW;
    localparam MAX_IDX = (1 << IDX_W) - 1;
    localparam W       = IDX_W + 3;               // signed working width

    // ------------------------------------------------------------------
    // Double-buffered skew LUT (LUTRAM; switch to "block" for big tables)
    // ------------------------------------------------------------------
    (* ram_style = "distributed" *)
    reg signed [7:0] skew_lut [0:2*LUT_N-1];
    reg              live_buf;

    always @(posedge clk) begin
        if (rst)               live_buf <= 1'b0;
        else if (cfg_lut_swap) live_buf <= ~live_buf;
    end

    always @(posedge clk)
        if (cfg_lut_we) skew_lut[{~live_buf, cfg_lut_addr}] <= cfg_lut_data;

    // Position -> bucket, saturating. Offset binary: 0 = most short.
    wire signed [POS_W-1:0] pos_sh = position >>> BUCKET_SH;
    wire [LUT_AW-1:0] bucket =
        (pos_sh >  (LUT_N/2 - 1)) ? {LUT_AW{1'b1}} :
        (pos_sh < -(LUT_N/2))     ? {LUT_AW{1'b0}} :
        {~pos_sh[LUT_AW-1], pos_sh[LUT_AW-2:0]};

    // ------------------------------------------------------------------
    // Q0: LUT read and risk checks, in parallel
    // ------------------------------------------------------------------
    reg                 q0_valid, q0_book_ok, q0_long_lim, q0_short_lim;
    reg  [IDX_W-1:0]    q0_bid, q0_ask;
    reg  signed [7:0]   q0_skew;

    always @(posedge clk) begin
        if (rst) q0_valid <= 1'b0;
        else     q0_valid <= tob_valid || pos_update;

        q0_skew      <= skew_lut[{live_buf, bucket}];
        q0_bid       <= best_bid;
        q0_ask       <= best_ask;
        q0_book_ok   <= bid_present && ask_present && (best_bid < best_ask);
        q0_long_lim  <= (position >=  pos_limit);
        q0_short_lim <= (position <= -pos_limit);
    end

    // ------------------------------------------------------------------
    // Q1: price arithmetic, crossing clamp, enables
    // ------------------------------------------------------------------
    wire signed [W-1:0] bid_s = $signed({3'b000, q0_bid});
    wire signed [W-1:0] ask_s = $signed({3'b000, q0_ask});
    wire signed [W-1:0] hs    = $signed({{(W-8){1'b0}}, half_spread});
    wire signed [W-1:0] sk    = q0_skew;              // sign-extends
    wire signed [W-1:0] fair  = (bid_s + ask_s) >>> 1;

    wire signed [W-1:0] raw_bid = fair - hs - sk;
    wire signed [W-1:0] raw_ask = fair + hs - sk;

    // Never cross: our bid stays below best ask, our ask above best bid
    wire signed [W-1:0] c_bid = (raw_bid >= ask_s) ? ask_s - 1 : raw_bid;
    wire signed [W-1:0] c_ask = (raw_ask <= bid_s) ? bid_s + 1 : raw_ask;

    wire bid_on_grid = (c_bid >= 0);
    wire ask_on_grid = (c_ask <= MAX_IDX);

    always @(posedge clk) begin
        if (rst) q_valid <= 1'b0;
        else     q_valid <= q0_valid;

        q_bid    <= c_bid[IDX_W-1:0];
        q_ask    <= c_ask[IDX_W-1:0];
        q_bid_en <= quote_enable && q0_book_ok && !q0_long_lim  && bid_on_grid;
        q_ask_en <= quote_enable && q0_book_ok && !q0_short_lim && ask_on_grid;
    end

endmodule
