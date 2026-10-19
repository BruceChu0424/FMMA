// Self-checking testbench for mm_core. Run with:
//   iverilog -g2012 -o sim tb/tb_mm_core.v rtl/*.v && vvp sim
`timescale 1ns/1ps
module tb_mm_core;
    localparam N_SYM = 2, LEVELS = 1024, IDX_W = 10, POS_W = 32, QTY_W = 32;

    reg clk = 0;
    always #1.5 clk = ~clk;                       // 333 MHz

    reg                       rst = 1;
    wire                      ready;
    reg                       upd_valid = 0, upd_side = 0;
    reg  [0:0]                upd_sym = 0;
    reg  [IDX_W-1:0]          upd_idx = 0;
    reg  [QTY_W-1:0]          upd_delta = 0;
    reg  [N_SYM*POS_W-1:0]    position = 0;
    reg  [N_SYM-1:0]          pos_update = 0;
    reg                       quote_enable = 0;
    reg  [N_SYM*8-1:0]        half_spread = {8'd2, 8'd2};
    reg  [N_SYM*POS_W-1:0]    pos_limit   = {32'd500, 32'd500};
    reg  [0:0]                cfg_sym = 0;
    reg                       cfg_lut_we = 0, cfg_lut_swap = 0;
    reg  [5:0]                cfg_lut_addr = 0;
    reg  [7:0]                cfg_lut_data = 0;
    wire [N_SYM-1:0]          q_valid, q_bid_en, q_ask_en;
    wire [N_SYM*IDX_W-1:0]    q_bid, q_ask;

    mm_core #(.N_SYM(N_SYM), .LEVELS(LEVELS)) dut (
        .clk(clk), .rst(rst), .ready(ready),
        .upd_valid(upd_valid), .upd_sym(upd_sym), .upd_side(upd_side),
        .upd_idx(upd_idx), .upd_delta(upd_delta),
        .position(position), .pos_update(pos_update),
        .quote_enable(quote_enable), .half_spread(half_spread), .pos_limit(pos_limit),
        .cfg_sym(cfg_sym), .cfg_lut_we(cfg_lut_we), .cfg_lut_addr(cfg_lut_addr),
        .cfg_lut_data(cfg_lut_data), .cfg_lut_swap(cfg_lut_swap),
        .q_valid(q_valid), .q_bid_en(q_bid_en), .q_ask_en(q_ask_en),
        .q_bid(q_bid), .q_ask(q_ask),
        .host_rd_req(1'b0), .host_rd_sym(1'b0), .host_rd_addr(11'd0),
        .host_rd_ack(), .host_rd_data(),
        .tob_bid_present(), .tob_ask_present(), .tob_best_bid(), .tob_best_ask()
    );

    integer cyc = 0, errors = 0, b;
    always @(posedge clk) cyc <= cyc + 1;

    // Last quote seen on symbol 0
    reg        lq_bid_en, lq_ask_en;
    reg [9:0]  lq_bid, lq_ask;
    integer    last_q_cyc, last_ask_cyc;
    always @(posedge clk) if (upd_valid && upd_side) last_ask_cyc <= cyc;
    always @(posedge clk) if (q_valid[0]) begin
        lq_bid_en <= q_bid_en[0]; lq_ask_en <= q_ask_en[0];
        lq_bid    <= q_bid[9:0];  lq_ask    <= q_ask[9:0];
        last_q_cyc <= cyc;
    end

    task drive(input side, input [IDX_W-1:0] idx, input integer qty);
    begin
        upd_valid <= 1; upd_sym <= 0; upd_side <= side;
        upd_idx <= idx; upd_delta <= qty;
        @(posedge clk);
    end endtask

    task idle(input integer n);
    begin
        upd_valid <= 0; pos_update <= 0;
        repeat (n) @(posedge clk);
    end endtask

    task set_pos(input integer p);
    begin
        position[31:0] <= p; pos_update <= 1;
        @(posedge clk);
        pos_update <= 0;
        repeat (6) @(posedge clk);
    end endtask

    task check_tob(input [9:0] eb, input [9:0] ea, input [255:0] name);
    begin
        if (dut.g_sym[0].best_bid !== eb || dut.g_sym[0].best_ask !== ea) begin
            $display("FAIL %0s: tob %0d/%0d, expected %0d/%0d", name,
                     dut.g_sym[0].best_bid, dut.g_sym[0].best_ask, eb, ea);
            errors = errors + 1;
        end else
            $display("ok   %0s: tob %0d/%0d", name, eb, ea);
    end endtask

    task check_q(input be, input [9:0] eb, input ae, input [9:0] ea, input [255:0] name);
    begin
        if (lq_bid_en !== be || lq_ask_en !== ae ||
            (be && lq_bid !== eb) || (ae && lq_ask !== ea)) begin
            $display("FAIL %0s: quote %0d(%0d) / %0d(%0d), expected %0d(%0d) / %0d(%0d)",
                     name, lq_bid, lq_bid_en, lq_ask, lq_ask_en, eb, be, ea, ae);
            errors = errors + 1;
        end else
            $display("ok   %0s: quote %0s%0d / %0s%0d", name,
                     be ? "" : "off ", eb, ae ? "" : "off ", ea);
    end endtask

    task check_qty(input [9:0] idx, input integer eq, input [255:0] name);
    begin
        if (dut.g_sym[0].u_book.level_qty[idx] !== eq) begin
            $display("FAIL %0s: qty %0d, expected %0d", name,
                     dut.g_sym[0].u_book.level_qty[idx], eq);
            errors = errors + 1;
        end else
            $display("ok   %0s: level %0d qty %0d", name, idx, eq);
    end endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 0;
        wait (ready); @(posedge clk);

        // Host loads skew = (bucket - 32) / 4 into the inactive buffer, then swaps
        for (b = 0; b < 64; b = b + 1) begin
            cfg_lut_we <= 1; cfg_lut_addr <= b; cfg_lut_data <= (b - 32) >>> 2;
            @(posedge clk);
        end
        cfg_lut_we <= 0; cfg_lut_swap <= 1; @(posedge clk); cfg_lut_swap <= 0;
        quote_enable <= 1;

        // 1. Basic book, and latency measurement
        drive(0, 500, 10);
        drive(1, 510, 10);
        idle(10);
        check_tob(500, 510, "basic book");
        $display("     feed-to-quote latency: %0d cycles", last_q_cyc - last_ask_cyc);
        check_q(1, 503, 1, 507, "flat position");

        // 2. Back-to-back updates on one level (forwarding path)
        drive(0, 505, 5);
        drive(0, 505, 7);
        idle(8);
        check_qty(505, 12, "b2b add fwd");
        check_tob(505, 510, "improved bid");

        drive(0, 505, -12);
        idle(8);
        check_tob(500, 510, "level emptied");

        drive(0, 505, 3);
        drive(0, 505, 4);
        drive(0, 505, -7);
        idle(8);
        check_qty(505, 0, "3x b2b fwd chain");
        check_tob(500, 510, "chain leaves bid at 500");

        // 3. Cancel more than resting: clamps at zero
        drive(1, 520, 5);
        drive(1, 520, -9);
        idle(8);
        check_qty(1024 + 520, 0, "over-cancel clamp");

        // 4. Inventory skew: pos 160 -> bucket 42 -> skew +2
        set_pos(160);
        check_q(1, 501, 1, 505, "long skew");

        // 5. Long limit pulls the bid
        set_pos(600);
        check_q(0, 0, 1, 501, "long limit");

        // 6. Short skew pushes bid into the ask: must clamp, not cross
        drive(0, 509, 10);
        idle(8);
        set_pos(-200);                    // bucket 19 -> skew -4
        check_q(1, 509, 1, 515, "crossing clamp");

        // 7. Kill switch
        quote_enable <= 0;
        set_pos(0);
        check_q(0, 0, 0, 0, "kill switch");

        $display("%0s: %0d error(s)", errors ? "FAILED" : "PASSED", errors);
        $finish;
    end
endmodule
