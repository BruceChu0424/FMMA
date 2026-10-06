// -----------------------------------------------------------------------------
// axi_ctrl.v
//
// AXI4-Lite slave that maps every symbol's config, skew table and book RAM
// into one address space. Runs on the trading clock: if the bridge (XDMA,
// Zynq PS, etc.) is on another clock, put an AXI Clock Converter in front.
//
// Address map (byte addresses, 32-bit words, shown for LEVELS = 1024)
//
//   Global                0x000000
//     +0x000  ID            RO  0x4D4D0100
//     +0x004  CTRL          RW  [0] quote_enable (global kill switch)
//     +0x008  STATUS        RO  [0] core ready, [23:16] N_SYM
//
//   Symbol s              0x800000 + s * 0x4000
//     +0x0000 TOB           RO  [31] bid present, [30] ask present,
//                               [16 +: IDX_W] best ask, [0 +: IDX_W] best bid
//     +0x0004 HALF_SPREAD   RW  [7:0] ticks
//     +0x0008 POS_LIMIT     RW  [31:0]
//     +0x000C LUT_SWAP      WO  any write makes the written skew buffer live
//     +0x0100 SKEW_LUT[i]   WO  [7:0] signed ticks, i = 0..63, inactive buffer
//     +0x2000 BID_QTY[i]    RO  quantity at bid level i, i = 0..LEVELS-1
//     +0x3000 ASK_QTY[i]    RO  quantity at ask level i
//
//   In general the per-symbol stride is 2^(IDX_W+4) bytes and the book
//   starts at the half-way point of the window.
//
// Unmapped addresses, and writes to the book, return SLVERR.
// Accesses are full 32-bit words; WSTRB is ignored.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module axi_ctrl #(
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

    // AXI4-Lite slave
    input  wire [AW-1:0]            s_axi_awaddr,
    input  wire                     s_axi_awvalid,
    output wire                     s_axi_awready,
    input  wire [31:0]              s_axi_wdata,
    input  wire [3:0]               s_axi_wstrb,
    input  wire                     s_axi_wvalid,
    output wire                     s_axi_wready,
    output reg  [1:0]               s_axi_bresp,
    output reg                      s_axi_bvalid,
    input  wire                     s_axi_bready,
    input  wire [AW-1:0]            s_axi_araddr,
    input  wire                     s_axi_arvalid,
    output wire                     s_axi_arready,
    output reg  [31:0]              s_axi_rdata,
    output reg  [1:0]               s_axi_rresp,
    output reg                      s_axi_rvalid,
    input  wire                     s_axi_rready,

    // To / from mm_core
    input  wire                     core_ready,
    output reg                      quote_enable,
    output wire [N_SYM*8-1:0]       half_spread,
    output wire [N_SYM*POS_W-1:0]   pos_limit,
    output reg  [SYM_W-1:0]         cfg_sym,
    output reg                      cfg_lut_we,
    output reg  [5:0]               cfg_lut_addr,
    output reg  [7:0]               cfg_lut_data,
    output reg                      cfg_lut_swap,
    output reg                      host_rd_req,
    output reg  [SYM_W-1:0]         host_rd_sym,
    output reg  [IDX_W:0]           host_rd_addr,
    input  wire                     host_rd_ack,
    input  wire [QTY_W-1:0]         host_rd_data,
    input  wire [N_SYM-1:0]         tob_bid_present,
    input  wire [N_SYM-1:0]         tob_ask_present,
    input  wire [N_SYM*IDX_W-1:0]   tob_best_bid,
    input  wire [N_SYM*IDX_W-1:0]   tob_best_ask
);
    localparam WIN_W = IDX_W + 4;                 // log2(per-symbol stride)
    localparam [7:0] NSYM8 = N_SYM;
    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    localparam [2:0] K_NONE = 3'd0,   // unmapped
                     K_GREG = 3'd1,   // global register
                     K_SREG = 3'd2,   // per-symbol register
                     K_LUT  = 3'd3,   // skew table entry
                     K_BOOK = 3'd4;   // book RAM word

    // ------------------------------------------------------------------
    // Address decode: {kind, symbol, index}
    //   index = register number, LUT entry, or {side, level} for the book
    // ------------------------------------------------------------------
    localparam DEC_W = 3 + SYM_W + IDX_W + 1;

    function [DEC_W-1:0] decode;
        input [AW-1:0] a;
        reg   [2:0]       k;
        reg   [SYM_W-1:0] s;
        reg   [IDX_W:0]   i;
        reg   [WIN_W-1:0] off;
        begin
            k   = K_NONE;
            s   = a[WIN_W +: SYM_W];
            i   = 0;
            off = a[WIN_W-1:0];
            if (!a[AW-1]) begin                         // global space
                if (a[AW-2:8] == 0) begin
                    k = K_GREG;
                    i = a[7:2];
                end
            end else if (a[AW-2:WIN_W] < N_SYM) begin   // symbol space
                if (off[WIN_W-1]) begin
                    k = K_BOOK;
                    i = off[WIN_W-2:2];                 // {side, level}
                end else if (off[WIN_W-2:9] == 0) begin
                    k = off[8] ? K_LUT : K_SREG;
                    i = off[7:2];
                end
            end
            decode = {k, s, i};
        end
    endfunction

    // ------------------------------------------------------------------
    // Per-symbol config registers
    // ------------------------------------------------------------------
    reg [7:0]       hs_r  [0:N_SYM-1];
    reg [POS_W-1:0] lim_r [0:N_SYM-1];

    genvar g;
    generate for (g = 0; g < N_SYM; g = g + 1) begin : g_flat
        assign half_spread[g*8 +: 8]       = hs_r[g];
        assign pos_limit[g*POS_W +: POS_W] = lim_r[g];
    end endgenerate

    // ------------------------------------------------------------------
    // Write channel: accept AW and W together, one write per response
    // ------------------------------------------------------------------
    wire wr_fire = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_awready = wr_fire;
    assign s_axi_wready  = wr_fire;

    wire [DEC_W-1:0] wd    = decode(s_axi_awaddr);
    wire [2:0]       w_k   = wd[DEC_W-1 -: 3];
    wire [SYM_W-1:0] w_sym = wd[IDX_W+1 +: SYM_W];
    wire [IDX_W:0]   w_i   = wd[IDX_W:0];

    integer n;
    always @(posedge clk) begin
        cfg_lut_we   <= 1'b0;
        cfg_lut_swap <= 1'b0;
        if (rst) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= OKAY;
            quote_enable <= 1'b0;
            for (n = 0; n < N_SYM; n = n + 1) begin
                hs_r[n]  <= 8'd0;
                lim_r[n] <= {POS_W{1'b0}};    // limit 0 = both sides disabled
            end
        end else begin
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

            if (wr_fire) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= OKAY;
                case (w_k)
                    K_GREG: case (w_i)
                        1:       quote_enable <= s_axi_wdata[0];
                        0, 2:    ;                               // read-only
                        default: s_axi_bresp <= SLVERR;
                    endcase
                    K_SREG: case (w_i)
                        0:       ;                               // read-only
                        1:       hs_r[w_sym]  <= s_axi_wdata[7:0];
                        2:       lim_r[w_sym] <= s_axi_wdata[POS_W-1:0];
                        3:       begin cfg_sym <= w_sym; cfg_lut_swap <= 1'b1; end
                        default: s_axi_bresp <= SLVERR;
                    endcase
                    K_LUT: begin
                        cfg_sym      <= w_sym;
                        cfg_lut_addr <= w_i[5:0];
                        cfg_lut_data <= s_axi_wdata[7:0];
                        cfg_lut_we   <= 1'b1;
                    end
                    default: s_axi_bresp <= SLVERR;             // book, unmapped
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // Read channel: one read outstanding. Register reads return next
    // cycle; book reads wait for a feed-idle slot in the target bank.
    // ------------------------------------------------------------------
    reg              rd_busy;
    reg [2:0]        r_k;
    reg [SYM_W-1:0]  r_sym;
    reg [IDX_W:0]    r_i;

    assign s_axi_arready = !rd_busy && !s_axi_rvalid;
    wire ar_fire = s_axi_arvalid && s_axi_arready;

    wire [DEC_W-1:0] rd_dec = decode(s_axi_araddr);

    // Pack all top-of-book fields in one word so a single read is atomic
    wire [31:0] tob_word =
        ({31'd0, tob_bid_present[r_sym]} << 31) |
        ({31'd0, tob_ask_present[r_sym]} << 30) |
        ({{(32-IDX_W){1'b0}}, tob_best_ask[r_sym*IDX_W +: IDX_W]} << 16) |
         {{(32-IDX_W){1'b0}}, tob_best_bid[r_sym*IDX_W +: IDX_W]};

    always @(posedge clk) begin
        if (rst) begin
            rd_busy      <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= OKAY;
            host_rd_req  <= 1'b0;
        end else begin
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;

            if (ar_fire) begin
                rd_busy <= 1'b1;
                r_k     <= rd_dec[DEC_W-1 -: 3];
                r_sym   <= rd_dec[IDX_W+1 +: SYM_W];
                r_i     <= rd_dec[IDX_W:0];
                if (rd_dec[DEC_W-1 -: 3] == K_BOOK) begin
                    host_rd_req  <= 1'b1;
                    host_rd_sym  <= rd_dec[IDX_W+1 +: SYM_W];
                    host_rd_addr <= rd_dec[IDX_W:0];
                end
            end else if (rd_busy) begin
                if (r_k == K_BOOK) begin
                    if (host_rd_ack) begin
                        host_rd_req  <= 1'b0;
                        rd_busy      <= 1'b0;
                        s_axi_rvalid <= 1'b1;
                        s_axi_rresp  <= OKAY;
                        s_axi_rdata  <= host_rd_data;
                    end
                end else begin
                    rd_busy      <= 1'b0;
                    s_axi_rvalid <= 1'b1;
                    s_axi_rresp  <= OKAY;
                    s_axi_rdata  <= 32'd0;
                    case (r_k)
                        K_GREG: case (r_i)
                            0:       s_axi_rdata <= 32'h4D4D_0100;
                            1:       s_axi_rdata <= {31'd0, quote_enable};
                            2:       s_axi_rdata <= {8'd0, NSYM8, 15'd0, core_ready};
                            default: s_axi_rresp <= SLVERR;
                        endcase
                        K_SREG: case (r_i)
                            0:       s_axi_rdata <= tob_word;
                            1:       s_axi_rdata <= {24'd0, hs_r[r_sym]};
                            2:       s_axi_rdata <= lim_r[r_sym];
                            3:       ;                            // write-only
                            default: s_axi_rresp <= SLVERR;
                        endcase
                        K_LUT:   ;                                // write-only
                        default: s_axi_rresp <= SLVERR;
                    endcase
                end
            end
        end
    end

endmodule
