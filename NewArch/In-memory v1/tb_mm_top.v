// AXI4-Lite testbench for mm_top. Run with:
//   iverilog -g2012 -o sim tb/tb_mm_top.v rtl/*.v && vvp sim
`timescale 1ns/1ps
module tb_mm_top;
    localparam N_SYM = 4, LEVELS = 1024, IDX_W = 10, POS_W = 32, QTY_W = 32, AW = 24;
    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    // Address map helpers (see axi_ctrl.v)
    function [AW-1:0] sym_base(input integer s); sym_base = 24'h800000 + s * 24'h4000; endfunction
    function [AW-1:0] bid_qty (input integer s, input integer i); bid_qty = sym_base(s) + 24'h2000 + i*4; endfunction
    function [AW-1:0] ask_qty (input integer s, input integer i); ask_qty = sym_base(s) + 24'h3000 + i*4; endfunction

    reg clk = 0;
    always #1.5 clk = ~clk;
    reg rst = 1;

    reg  [AW-1:0] awaddr = 0, araddr = 0;
    reg           awvalid = 0, wvalid = 0, arvalid = 0;
    reg  [31:0]   wdata = 0;
    wire          awready, wready, bvalid, arready, rvalid;
    wire [1:0]    bresp, rresp;
    wire [31:0]   rdata;

    reg                    upd_valid = 0, upd_side = 0;
    reg  [1:0]             upd_sym = 0;
    reg  [IDX_W-1:0]       upd_idx = 0;
    reg  [QTY_W-1:0]       upd_delta = 0;
    reg  [N_SYM*POS_W-1:0] position = 0;
    reg  [N_SYM-1:0]       pos_update = 0;
    wire [N_SYM-1:0]       q_valid, q_bid_en, q_ask_en;
    wire [N_SYM*IDX_W-1:0] q_bid, q_ask;

    mm_top #(.N_SYM(N_SYM), .LEVELS(LEVELS)) dut (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(1'b1),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(1'b1),
        .upd_valid(upd_valid), .upd_sym(upd_sym), .upd_side(upd_side),
        .upd_idx(upd_idx), .upd_delta(upd_delta),
        .position(position), .pos_update(pos_update),
        .q_valid(q_valid), .q_bid_en(q_bid_en), .q_ask_en(q_ask_en),
        .q_bid(q_bid), .q_ask(q_ask)
    );

    integer errors = 0, cyc = 0, i;
    always @(posedge clk) cyc <= cyc + 1;

    // ---------------- AXI4-Lite master ----------------
    task axi_write(input [AW-1:0] a, input [31:0] d, output [1:0] resp);
    begin
        awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
        do @(posedge clk); while (!awready);
        awvalid <= 0; wvalid <= 0;
        do @(posedge clk); while (!bvalid);
        resp = bresp;
    end endtask

    task axi_read(input [AW-1:0] a, output [31:0] d, output [1:0] resp);
    begin
        araddr <= a; arvalid <= 1;
        do @(posedge clk); while (!arready);
        arvalid <= 0;
        do @(posedge clk); while (!rvalid);
        d = rdata; resp = rresp;
    end endtask

    reg [31:0] d;
    reg [1:0]  r;

    task wr(input [AW-1:0] a, input [31:0] v);
    begin
        axi_write(a, v, r);
        if (r !== OKAY) begin $display("FAIL write %h: resp %b", a, r); errors = errors + 1; end
    end endtask

    task expect_rd(input [AW-1:0] a, input [31:0] v, input [255:0] name);
    begin
        axi_read(a, d, r);
        if (r !== OKAY || d !== v) begin
            $display("FAIL %0s: read %h = %h resp %b, expected %h", name, a, d, r, v);
            errors = errors + 1;
        end else
            $display("ok   %0s: [%h] = %h", name, a, d);
    end endtask

    task expect_err(input is_write, input [AW-1:0] a, input [255:0] name);
    begin
        if (is_write) axi_write(a, 32'hDEAD, r); else axi_read(a, d, r);
        if (r !== SLVERR) begin
            $display("FAIL %0s: [%h] resp %b, expected SLVERR", name, a, r);
            errors = errors + 1;
        end else
            $display("ok   %0s: [%h] -> SLVERR", name, a);
    end endtask

    // ---------------- Feed driver ----------------
    task drive(input [1:0] s, input side, input [IDX_W-1:0] idx, input integer qty);
    begin
        upd_valid <= 1; upd_sym <= s; upd_side <= side; upd_idx <= idx; upd_delta <= qty;
        @(posedge clk);
    end endtask

    task idle(input integer n);
    begin
        upd_valid <= 0;
        repeat (n) @(posedge clk);
    end endtask

    // Last quote seen on symbol 2
    reg       lq_be, lq_ae;
    reg [9:0] lq_b, lq_a;
    always @(posedge clk) if (q_valid[2]) begin
        lq_be <= q_bid_en[2]; lq_ae <= q_ask_en[2];
        lq_b  <= q_bid[2*IDX_W +: IDX_W]; lq_a <= q_ask[2*IDX_W +: IDX_W];
    end

    integer burst_end, read_done;

    initial begin
        repeat (4) @(posedge clk);
        rst <= 0;

        // 1. Wait for the books to clear, check global registers
        d = 0;
        while (!d[0]) axi_read(24'h000008, d, r);
        expect_rd(24'h000008, {8'd0, 8'd4, 15'd0, 1'b1}, "STATUS ready, N_SYM=4");
        expect_rd(24'h000000, 32'h4D4D0100, "ID");

        // 2. Configure symbol 2 over AXI
        wr(sym_base(2) + 24'h004, 2);          // half spread
        wr(sym_base(2) + 24'h008, 500);        // position limit
        expect_rd(sym_base(2) + 24'h004, 2,   "HALF_SPREAD readback");
        expect_rd(sym_base(2) + 24'h008, 500, "POS_LIMIT readback");
        for (i = 0; i < 64; i = i + 1)
            wr(sym_base(2) + 24'h100 + i*4, (i - 32) >>> 2);
        wr(sym_base(2) + 24'h00C, 1);          // swap skew buffers
        wr(24'h000004, 1);                     // quote_enable

        // 3. Build a book on symbol 2, read it back over AXI
        drive(2, 0, 500, 10);
        drive(2, 1, 510, 10);
        idle(10);
        expect_rd(sym_base(2), 32'hC1FE01F4,   "TOB bid 500 / ask 510");
        expect_rd(bid_qty(2, 500), 10,         "BID_QTY[500]");
        expect_rd(ask_qty(2, 510), 10,         "ASK_QTY[510]");
        expect_rd(bid_qty(1, 500), 0,          "other symbol untouched");
        if (lq_be && lq_ae && lq_b == 503 && lq_a == 507)
            $display("ok   quote from AXI-loaded config: 503 / 507");
        else begin
            $display("FAIL quote %0d(%0d) / %0d(%0d)", lq_b, lq_be, lq_a, lq_ae);
            errors = errors + 1;
        end

        // 4. Host read issued during a saturated burst on the same level.
        //    It must wait for the first idle cycle, then race the final write.
        fork
            begin
                for (i = 0; i < 20; i = i + 1) drive(2, 0, 500, 1);
                burst_end = cyc;
                idle(1);
            end
            begin
                repeat (5) @(posedge clk);
                axi_read(bid_qty(2, 500), d, r);
                read_done = cyc;
            end
        join
        if (d === 30 && r === OKAY && read_done > burst_end)
            $display("ok   read starved by feed, then returned %0d (fresh)", d);
        else begin
            $display("FAIL starved read: %0d resp %b (done %0d, burst end %0d)",
                     d, r, read_done, burst_end);
            errors = errors + 1;
        end

        // 5. Error responses
        expect_err(1, bid_qty(2, 500),       "write to book");
        expect_err(0, sym_base(5),           "symbol beyond N_SYM");
        expect_err(0, 24'h000100,            "unmapped global");
        expect_err(0, sym_base(0) + 24'h040, "unmapped symbol reg");

        // 6. Kill switch over AXI
        wr(24'h000004, 0);
        drive(2, 0, 501, 5);
        idle(10);
        if (!lq_be && !lq_ae) $display("ok   kill switch via CTRL");
        else begin $display("FAIL kill switch"); errors = errors + 1; end

        $display("%0s: %0d error(s)", errors ? "FAILED" : "PASSED", errors);
        $finish;
    end
endmodule
