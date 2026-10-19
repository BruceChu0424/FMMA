// -----------------------------------------------------------------------------
// book_bank.v
//
// One symbol's order book held in on-chip RAM, with the update logic, an
// occupancy bitmap and the best-price search sitting directly beside it.
//
//   - One book update per clock (add / cancel / exec as a signed qty delta)
//   - Price levels indexed by tick offset from a reference price
//   - Read-modify-write hazard on the RAM covered by a one-deep forward path
//   - Best bid/ask found by a two-stage hierarchical priority encoder
//   - Clears its own RAM after reset (ready goes high when done)
//   - Host (AXI) reads use the RAM read port only in feed-idle cycles
//
// Latency: upd_valid in cycle 0 -> tob_valid in cycle 4.
// LEVELS must be a power of two, >= 64.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module book_bank #(
    parameter LEVELS = 1024,                 // price levels per side
    parameter QTY_W  = 32,
    parameter IDX_W  = $clog2(LEVELS)
)(
    input  wire                     clk,
    input  wire                     rst,
    output wire                     ready,       // low while RAM is being cleared

    // Book update stream from the feed handler
    input  wire                     upd_valid,
    input  wire                     upd_side,    // 0 = bid, 1 = ask
    input  wire [IDX_W-1:0]         upd_idx,     // tick offset from reference
    input  wire signed [QTY_W-1:0]  upd_delta,   // +add, -cancel/exec

    // Top of book
    output reg                      tob_valid,   // one pulse per update, fully applied
    output reg                      bid_present,
    output reg                      ask_present,
    output reg  [IDX_W-1:0]         best_bid,
    output reg  [IDX_W-1:0]         best_ask,

    // Host read port (from axi_ctrl). Hold req until ack.
    input  wire                     host_rd_req,
    input  wire [IDX_W:0]           host_rd_addr,  // {side, idx}
    output wire                     host_rd_ack,
    output wire [QTY_W-1:0]         host_rd_data
);
    localparam WORDS  = LEVELS / 32;
    localparam WSEL_W = $clog2(WORDS);

    // ------------------------------------------------------------------
    // Priority encoders
    // ------------------------------------------------------------------
    function [4:0] msb32;                         // highest set bit
        input [31:0] v;
        integer k;
        begin
            msb32 = 0;
            for (k = 0; k < 32; k = k + 1) if (v[k]) msb32 = k;
        end
    endfunction

    function [4:0] lsb32;                         // lowest set bit
        input [31:0] v;
        integer k;
        begin
            lsb32 = 0;
            for (k = 31; k >= 0; k = k - 1) if (v[k]) lsb32 = k;
        end
    endfunction

    function [WSEL_W-1:0] msbW;
        input [WORDS-1:0] v;
        integer k;
        begin
            msbW = 0;
            for (k = 0; k < WORDS; k = k + 1) if (v[k]) msbW = k;
        end
    endfunction

    function [WSEL_W-1:0] lsbW;
        input [WORDS-1:0] v;
        integer k;
        begin
            lsbW = 0;
            for (k = WORDS-1; k >= 0; k = k - 1) if (v[k]) lsbW = k;
        end
    endfunction

    // ------------------------------------------------------------------
    // Post-reset RAM clear
    // ------------------------------------------------------------------
    reg             clr_busy;
    reg [IDX_W:0]   clr_addr;

    always @(posedge clk) begin
        if (rst) begin
            clr_busy <= 1'b1;
            clr_addr <= 0;
        end else if (clr_busy) begin
            clr_addr <= clr_addr + 1'b1;
            if (&clr_addr) clr_busy <= 1'b0;
        end
    end
    assign ready = ~clr_busy;

    // ------------------------------------------------------------------
    // Level-quantity RAM: address = {side, idx}
    // Simple dual port, read-first. 2048 x 32 = two BRAM36 (or one URAM).
    // ------------------------------------------------------------------
    (* ram_style = "block" *)
    reg [QTY_W-1:0] level_qty [0:2*LEVELS-1];

    // The feed always wins the read port. A host read only goes out in a
    // cycle with no update, so it never adds latency to the trading path.
    reg              h1_valid;
    wire             upd_go  = upd_valid && ready;
    wire             host_go = host_rd_req && !upd_go && !h1_valid;
    wire [IDX_W:0]   rd_addr = upd_go ? {upd_side, upd_idx} : host_rd_addr;
    reg  [QTY_W-1:0] rd_qty;

    // Stage S1 (data back from RAM)
    reg                     s1_valid;
    reg  [IDX_W:0]          s1_addr;
    reg  signed [QTY_W-1:0] s1_delta;

    // Record of the write issued on the previous edge
    reg                     wb_valid;
    reg  [IDX_W:0]          wb_addr;
    reg  [QTY_W-1:0]        wb_qty;

    // Forwarding. The read for this update happened on the same edge that
    // the previous update wrote, and the RAM is read-first, so if they hit
    // the same level rd_qty is stale. Use the value that was written.
    wire             fwd     = wb_valid && (wb_addr == s1_addr);
    wire [QTY_W-1:0] cur_qty = fwd ? wb_qty : rd_qty;

    wire signed [QTY_W+1:0] sum = $signed({2'b00, cur_qty}) + s1_delta;
    wire [QTY_W-1:0] new_qty =
        sum[QTY_W+1] ? {QTY_W{1'b0}} :           // went negative: clamp to 0
        sum[QTY_W]   ? {QTY_W{1'b1}} :           // overflow: saturate
                       sum[QTY_W-1:0];

    always @(posedge clk) begin
        if (clr_busy)      level_qty[clr_addr] <= {QTY_W{1'b0}};
        else if (s1_valid) level_qty[s1_addr]  <= new_qty;
        rd_qty <= level_qty[rd_addr];
    end

    always @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            wb_valid <= 1'b0;
        end else begin
            s1_valid <= upd_go;
            wb_valid <= s1_valid;
        end
        s1_addr  <= rd_addr;
        s1_delta <= upd_delta;
        wb_addr  <= s1_addr;
        wb_qty   <= new_qty;
    end

    // Host read returns one cycle after issue. It can race the write from the
    // update just before it, so it uses the same forward path.
    reg [IDX_W:0] h1_addr;
    always @(posedge clk) begin
        if (rst) h1_valid <= 1'b0;
        else     h1_valid <= host_go;
        h1_addr <= host_rd_addr;
    end
    assign host_rd_ack  = h1_valid;
    assign host_rd_data = (wb_valid && (wb_addr == h1_addr)) ? wb_qty : rd_qty;

    // ------------------------------------------------------------------
    // Occupancy bitmaps (flops), updated alongside the RAM write
    // ------------------------------------------------------------------
    reg [LEVELS-1:0] bid_map, ask_map;
    wire             s1_side = s1_addr[IDX_W];
    wire [IDX_W-1:0] s1_idx  = s1_addr[IDX_W-1:0];

    always @(posedge clk) begin
        if (rst) begin
            bid_map <= {LEVELS{1'b0}};
            ask_map <= {LEVELS{1'b0}};
        end else if (s1_valid) begin
            if (s1_side) ask_map[s1_idx] <= (new_qty != 0);
            else         bid_map[s1_idx] <= (new_qty != 0);
        end
    end

    // ------------------------------------------------------------------
    // Best-price search, stage B1: every 32-bit word of both bitmaps is
    // encoded in parallel from the same snapshot.
    // ------------------------------------------------------------------
    reg [WORDS-1:0] bid_any, ask_any;
    reg [4:0]       bid_loc [0:WORDS-1];
    reg [4:0]       ask_loc [0:WORDS-1];
    integer w;

    always @(posedge clk) begin
        for (w = 0; w < WORDS; w = w + 1) begin
            bid_any[w] <= |bid_map[w*32 +: 32];
            ask_any[w] <= |ask_map[w*32 +: 32];
            bid_loc[w] <= msb32(bid_map[w*32 +: 32]);
            ask_loc[w] <= lsb32(ask_map[w*32 +: 32]);
        end
    end

    // Stage B2: pick the winning word, append its local bit position
    wire [WSEL_W-1:0] bid_w = msbW(bid_any);
    wire [WSEL_W-1:0] ask_w = lsbW(ask_any);

    always @(posedge clk) begin
        bid_present <= |bid_any;
        ask_present <= |ask_any;
        best_bid    <= {bid_w, bid_loc[bid_w]};
        best_ask    <= {ask_w, ask_loc[ask_w]};
    end

    // Valid pulse aligned with the result of each update
    reg v_map, v_b1;
    always @(posedge clk) begin
        if (rst) begin
            v_map     <= 1'b0;
            v_b1      <= 1'b0;
            tob_valid <= 1'b0;
        end else begin
            v_map     <= s1_valid;
            v_b1      <= v_map;
            tob_valid <= v_b1;
        end
    end

endmodule
