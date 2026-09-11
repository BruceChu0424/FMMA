////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
//
// tb_fmma - full-chain simulation of the real
// top level against a behavioural Qsys system.
//
// The testbench plays the HPS: it loads the
// program over the s1 bridge port, publishes
// quotes through the seqlock, edge-detects
// SIGNAL_SEQ and reports fills back - the same
// sequence MarketStream.c performs, so a protocol
// mistake shows up here rather than on the board.
//
//   cd Testbenches
//   iverilog -g2005 -o tb_fmma.vvp \
//     ../Software/HFTtop.v ../Code/PC.v ../Code/IR ../Code/FR \
//     ../Code/registerFinal ../Code/MUX16to1 ../Code/MUX2to1 \
//     ../Code/ALUFinal ../Code/FSMTrial ../Code/disp \
//     ../Code/Encoder4to16 ../Code/decoder.v \
//     HPSfgpa2_stub.v tb_fmma.v
//   vvp tb_fmma.vvp
//
// run_sim.sh runs this and the rest of the suite.
////////////////////////////////////////////////

`timescale 1ns/1ps

`include "fmma_protocol.vh"

module tb_fmma;

    // 50 MHz board clock
    reg CLOCK_50 = 1'b0;
    always #10 CLOCK_50 = ~CLOCK_50;

    reg  [0:0] KEY = 1'b1;          // active low reset button
    wire [6:0] HEX0;

    HFTTop dut (
        .CLOCK_50 (CLOCK_50),
        .KEY      (KEY),
        .HEX0     (HEX0)
    );

    // Program image produced by Assembler.py
    reg [31:0] prog [0:255];
    integer    prog_len;

    integer errors, checks;
    integer k;
    reg [31:0] v, seen_signal_seq, tick, fill_seq;
    reg [31:0] sig_side, sig_tick;

    localparam THRESH  = 1000;      // $10.00 in cents
    localparam MAX_POS = 3;

    // ---------------- helpers ----------------

    task check(input [31:0] got, input [31:0] exp, input [511:0] what);
    begin
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("  FAIL: %0s - got %0d (0x%08h), expected %0d",
                     what, got, got, exp);
        end else begin
            $display("  pass: %0s = %0d", what, got);
        end
    end
    endtask

    task check_true(input cond, input [511:0] what);
    begin
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            $display("  FAIL: %0s", what);
        end else begin
            $display("  pass: %0s", what);
        end
    end
    endtask

    task wr(input [9:0] a, input [31:0] d);
        begin dut.u0.hps_write(a, d); end
    endtask

    task rd(input [9:0] a, output [31:0] d);
        begin dut.u0.hps_read(a, d); end
    endtask

    // Load the program the way the loader does: every word except the
    // entry point first, then the entry point.  Until that last write
    // lands, the word the PC is sitting on is still zero (the halt
    // instruction), so the CPU cannot start on a partial image.
    task load_program;
    begin
        for (k = 1; k < prog_len; k = k + 1)
            wr(`FMMA_PROGRAM_BASE + k, prog[k]);
        wr(`FMMA_PROGRAM_BASE, prog[0]);
    end
    endtask

    // Publish one quote through the seqlock: odd sequence number while
    // the block is being written, even when it is consistent.
    task publish(input [31:0] bid, input [31:0] ask);
    begin
        tick = tick + 1;
        wr(`FMMA_TICK_SEQ, tick * 2 - 1);
        wr(`FMMA_BID, bid);
        wr(`FMMA_ASK, ask);
        wr(`FMMA_BID_SIZE, 10000);
        wr(`FMMA_ASK_SIZE, 10000);
        wr(`FMMA_TICK_SEQ, tick * 2);
        repeat (400) @(posedge CLOCK_50);     // let the CPU react
    end
    endtask

    task report_fill(input [31:0] side, input [31:0] qty);
    begin
        wr(`FMMA_FILL_SIDE, side);
        wr(`FMMA_FILL_QTY, qty);
        fill_seq = fill_seq + 1;
        wr(`FMMA_FILL_SEQ, fill_seq);
        repeat (400) @(posedge CLOCK_50);
    end
    endtask

    // Returns side = 0 when the CPU has not published anything new.
    task take_signal(output [31:0] side, output [31:0] from_tick);
        reg [31:0] seq;
    begin
        rd(`FMMA_SIGNAL_SEQ, seq);
        if (seq === seen_signal_seq) begin
            side = 0;
            from_tick = 0;
        end else begin
            seen_signal_seq = seq;
            rd(`FMMA_SIGNAL, side);
            rd(`FMMA_SIGNAL_TICK, from_tick);
        end
    end
    endtask

    // ---------------- test sequence ----------------

    initial begin
        errors = 0;
        checks = 0;
        tick = 0;
        fill_seq = 0;
        seen_signal_seq = 0;

        for (k = 0; k < 256; k = k + 1) prog[k] = 32'h0;
        $readmemh("../Software/fpga_program.hex", prog);
        prog_len = 0;
        for (k = 0; k < 256; k = k + 1)
            if (prog[k] !== 32'h0) prog_len = k + 1;

        $display("=== tb_fmma: full chain, protocol v%0d ===",
                 `FMMA_PROTOCOL_VERSION);
        $display("program: %0d words at word %0d", prog_len, `FMMA_PROGRAM_BASE);
        if (prog_len < 10) begin
            $display("FATAL: fpga_program.hex looks empty - run");
            $display("       python ../Software/Assembler.py trading.asm");
            $fatal(1);
        end

        // ---- 1: the CPU waits for a program ----
        $display("\n[1] CPU parks until a program appears");
        repeat (200) @(posedge CLOCK_50);
        check(dut.pc, `FMMA_PROGRAM_BASE, "PC parked at the entry point");
        rd(`FMMA_HEARTBEAT, v);
        check(v, 32'd0, "heartbeat still zero");

        // ---- 2: configure, load, start ----
        $display("\n[2] loader: config, image, restart");
        wr(`FMMA_CFG_ENABLE, 0);
        wr(`FMMA_CFG_THRESH, THRESH);
        wr(`FMMA_CFG_MAX_POS, MAX_POS);
        wr(`FMMA_CFG_POSITION, 0);
        wr(`FMMA_CFG_RESTART, 0);
        load_program;
        repeat (2000) @(posedge CLOCK_50);

        rd(`FMMA_FW_VERSION, v);
        check(v, `FMMA_PROTOCOL_VERSION,
              "CPU published its protocol version (datapath probe passed)");
        rd(`FMMA_STATUS, v);
        check(v, `FMMA_STATUS_RUNNING, "status = running");
        rd(`FMMA_HEARTBEAT, v);
        check_true(v != 0, "heartbeat is advancing");

        wr(`FMMA_CFG_ENABLE, 1);

        // ---- 3: first quote only anchors ----
        $display("\n[3] the first quote sets the anchor, no signal");
        publish(32'd1000000, 32'd1000100);        // $10000.00 / $10001.00
        take_signal(sig_side, sig_tick);
        check(sig_side, 32'd0, "no signal on the first quote");

        // ---- 4: a small move stays inside the band ----
        $display("\n[4] a $1 move stays inside the band");
        publish(32'd999900, 32'd1000000);
        take_signal(sig_side, sig_tick);
        check(sig_side, 32'd0, "no signal for a small move");

        // ---- 5: the market falls -> BUY ----
        $display("\n[5] the market falls $20 -> BUY");
        publish(32'd998000, 32'd998100);
        take_signal(sig_side, sig_tick);
        check(sig_side, `FMMA_SIGNAL_BUY, "signal = BUY");
        check(sig_tick, tick * 2, "the signal names the quote that caused it");

        // ---- 6: the market rises -> SELL ----
        $display("\n[6] the market rises $20 -> SELL");
        publish(32'd1000000, 32'd1000100);
        take_signal(sig_side, sig_tick);
        check(sig_side, `FMMA_SIGNAL_SELL, "signal = SELL");

        // ---- 7: no new quote, no new signal ----
        $display("\n[7] a quiet market produces nothing");
        repeat (4000) @(posedge CLOCK_50);
        take_signal(sig_side, sig_tick);
        check(sig_side, 32'd0, "no signal without a new quote");

        // ---- 8: fills move the inventory ----
        $display("\n[8] fills move the inventory");
        report_fill(`FMMA_FILL_BOUGHT, 2);
        rd(`FMMA_POSITION, v);
        check(v, 32'd2, "position after buying 2");
        report_fill(`FMMA_FILL_SOLD, 1);
        rd(`FMMA_POSITION, v);
        check(v, 32'd1, "position after selling 1");

        // ---- 9: the risk limit blocks a buy ----
        $display("\n[9] the position limit blocks a buy");
        report_fill(`FMMA_FILL_BOUGHT, 2);          // position = 3 = MAX_POS
        rd(`FMMA_POSITION, v);
        check(v, MAX_POS, "position at the limit");
        rd(`FMMA_REJECTS, v);
        k = v;
        publish(32'd1000000, 32'd1000100);          // re-anchor
        publish(32'd997000, 32'd997100);            // would be a BUY
        take_signal(sig_side, sig_tick);
        check(sig_side, 32'd0, "buy suppressed at the long limit");
        rd(`FMMA_REJECTS, v);
        check(v, k + 1, "the rejection was counted");
        rd(`FMMA_STATUS, v);
        check_true((v & `FMMA_STATUS_RISK_BLOCKED) != 0, "status shows risk-blocked");

        // ---- 10: selling is still allowed while long ----
        $display("\n[10] selling is still allowed while long");
        publish(32'd1000000, 32'd1000100);
        take_signal(sig_side, sig_tick);
        check(sig_side, `FMMA_SIGNAL_SELL, "sell allowed at the long limit");

        // ---- 10b: flatten the book before the next tests ----
        // Steps 9 and 10 left the inventory at the long limit, which
        // would make every later buy risk-blocked for the wrong reason.
        $display("\n[10b] flatten the inventory");
        report_fill(`FMMA_FILL_SOLD, MAX_POS);
        rd(`FMMA_POSITION, v);
        check(v, 32'd0, "inventory flat again");

        // ---- 11: the master switch ----
        $display("\n[11] CFG_ENABLE suppresses everything");
        wr(`FMMA_CFG_ENABLE, 0);
        publish(32'd1000000, 32'd1000100);
        publish(32'd997000, 32'd997100);
        take_signal(sig_side, sig_tick);
        check(sig_side, 32'd0, "no signal while disabled");
        rd(`FMMA_STATUS, v);
        check_true((v & `FMMA_STATUS_DISABLED) != 0, "status shows disabled");
        wr(`FMMA_CFG_ENABLE, 1);

        // ---- 12: an odd sequence number is not consumed ----
        $display("\n[12] a half-written quote is ignored");
        publish(32'd1000000, 32'd1000100);          // re-anchor
        take_signal(sig_side, sig_tick);
        wr(`FMMA_TICK_SEQ, tick * 2 + 1);           // writer in progress
        wr(`FMMA_BID, 32'd990000);                  // a huge move...
        wr(`FMMA_ASK, 32'd990100);
        repeat (2000) @(posedge CLOCK_50);
        take_signal(sig_side, sig_tick);
        check(sig_side, 32'd0, "nothing acted on a half-written quote");
        wr(`FMMA_TICK_SEQ, tick * 2 + 2);           // ...now publish it
        tick = tick + 1;
        repeat (2000) @(posedge CLOCK_50);
        take_signal(sig_side, sig_tick);
        check(sig_side, `FMMA_SIGNAL_BUY, "acted once the quote was complete");

        // ---- 13: software restart ----
        $display("\n[13] CFG_RESTART restarts the strategy");
        wr(`FMMA_CFG_POSITION, 0);
        wr(`FMMA_CFG_RESTART, 1);
        repeat (3000) @(posedge CLOCK_50);
        rd(`FMMA_CFG_RESTART, v);
        check(v, 32'd0, "the restart request was consumed");
        rd(`FMMA_POSITION, v);
        check(v, 32'd0, "inventory reset to the value the HPS supplied");
        rd(`FMMA_REJECTS, v);
        check(v, 32'd0, "counters cleared");
        rd(`FMMA_FW_VERSION, v);
        check(v, `FMMA_PROTOCOL_VERSION, "version republished after the restart");

        // ---- 14: the reset button ----
        $display("\n[14] KEY[0] resets the CPU");
        KEY = 1'b0;
        repeat (50) @(posedge CLOCK_50);
        check(dut.pc, `FMMA_PROGRAM_BASE, "PC held at the entry point");
        KEY = 1'b1;
        repeat (3000) @(posedge CLOCK_50);
        rd(`FMMA_FW_VERSION, v);
        check(v, `FMMA_PROTOCOL_VERSION, "CPU came back up after the reset");
        rd(`FMMA_HEARTBEAT, v);
        check_true(v != 0, "heartbeat running again");

        // ---- 15: the two ports never wrote the same word ----
        $display("\n[15] port discipline");
        check(dut.u0.write_collisions, 32'd0,
              "no word was written by both ports in the same cycle");

        // ---- verdict ----
        $display("\n=== tb_fmma: %0d checks, %0d failures ===", checks, errors);
        if (errors == 0) $display("=== tb_fmma PASSED ===");
        else begin
            $display("=== tb_fmma FAILED ===");
            $fatal(1);
        end
        $finish;
    end

    // Global watchdog: a hung CPU must fail the run, not hang the suite.
    initial begin
        #20_000_000;
        $display("=== tb_fmma FAILED (timeout) ===");
        $fatal(1);
    end

endmodule
