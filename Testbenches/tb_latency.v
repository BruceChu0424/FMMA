////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
//
// tb_latency - measures the numbers quoted in
// docs/14-latency-and-performance.md on the real
// RTL, and fails if any of them regress past the
// budget.
//
// Measuring rather than asserting a single value
// keeps the document honest: change the strategy
// and this prints the new figures, so the table
// can be updated from tool output instead of from
// memory.
////////////////////////////////////////////////

`timescale 1ns/1ps

`include "fmma_protocol.vh"

module tb_latency;

    reg CLOCK_50 = 1'b0;
    always #10 CLOCK_50 = ~CLOCK_50;

    reg  [0:0] KEY = 1'b1;
    wire [6:0] HEX0;

    HFTTop dut (.CLOCK_50(CLOCK_50), .KEY(KEY), .HEX0(HEX0));

    // Free-running cycle counter, ticking on the edge the CPU uses.
    integer cyc = 0;
    always @(negedge CLOCK_50) cyc = cyc + 1;

    reg [31:0] prog [0:255];
    integer prog_len, k, t0, t1, n, errors;
    reg [31:0] v, beat, seq;

    // Budgets, in 50 MHz clock cycles.  These are the numbers
    // docs/14 promises; exceeding one is a regression.
    localparam BUDGET_IDLE     = 60;     // one poll of the main loop
    localparam BUDGET_DECISION = 280;    // quote published -> signal published

    task wr(input [9:0] a, input [31:0] d);
        begin dut.u0.hps_write(a, d); end
    endtask
    task rd(input [9:0] a, output [31:0] d);
        begin dut.u0.hps_read(a, d); end
    endtask

    integer tick;
    task publish(input [31:0] bid, input [31:0] ask);
    begin
        tick = tick + 1;
        wr(`FMMA_TICK_SEQ, tick * 2 - 1);
        wr(`FMMA_BID, bid);
        wr(`FMMA_ASK, ask);
        wr(`FMMA_TICK_SEQ, tick * 2);
    end
    endtask

    task report(input [255:0] name, input integer cycles, input integer budget);
    begin
        $display("  %0s: %0d cycles = %0d ns", name, cycles, cycles * 20);
        if (cycles > budget) begin
            errors = errors + 1;
            $display("    FAIL: over the %0d cycle budget", budget);
        end
    end
    endtask

    initial begin
        errors = 0;
        tick = 0;
        for (k = 0; k < 256; k = k + 1) prog[k] = 32'h0;
        $readmemh("../Software/fpga_program.hex", prog);
        prog_len = 0;
        for (k = 0; k < 256; k = k + 1)
            if (prog[k] !== 32'h0) prog_len = k + 1;

        $display("=== tb_latency (50 MHz, 20 ns per cycle) ===");

        // Bring the CPU up.
        wr(`FMMA_CFG_ENABLE, 0);
        wr(`FMMA_CFG_THRESH, 1000);
        wr(`FMMA_CFG_MAX_POS, 100);
        wr(`FMMA_CFG_POSITION, 0);
        wr(`FMMA_CFG_RESTART, 0);
        for (k = 1; k < prog_len; k = k + 1)
            wr(`FMMA_PROGRAM_BASE + k, prog[k]);
        wr(`FMMA_PROGRAM_BASE, prog[0]);
        repeat (3000) @(posedge CLOCK_50);
        wr(`FMMA_CFG_ENABLE, 1);

        rd(`FMMA_FW_VERSION, v);
        if (v !== `FMMA_PROTOCOL_VERSION) begin
            $display("FATAL: the CPU did not come up (FW_VERSION = %0d)", v);
            $fatal(1);
        end

        // ---- idle loop period ----
        // Timed over 100 iterations so the measurement is not sensitive
        // to where in the loop it starts.
        rd(`FMMA_HEARTBEAT, beat);
        @(negedge CLOCK_50);
        while (dut.u0.ram[`FMMA_HEARTBEAT] === beat) @(negedge CLOCK_50);
        t0 = cyc;
        beat = dut.u0.ram[`FMMA_HEARTBEAT];
        n = 0;
        while (n < 100) begin
            @(negedge CLOCK_50);
            if (dut.u0.ram[`FMMA_HEARTBEAT] !== beat) begin
                beat = dut.u0.ram[`FMMA_HEARTBEAT];
                n = n + 1;
            end
        end
        t1 = cyc;
        report("idle loop period            ", (t1 - t0) / 100, BUDGET_IDLE);

        // ---- quote published -> signal published ----
        publish(32'd1000000, 32'd1000100);       // anchor
        repeat (2000) @(posedge CLOCK_50);
        seq = dut.u0.ram[`FMMA_SIGNAL_SEQ];

        @(negedge CLOCK_50);
        t0 = cyc;
        publish(32'd998000, 32'd998100);         // a $20 fall -> BUY
        while (dut.u0.ram[`FMMA_SIGNAL_SEQ] === seq) @(negedge CLOCK_50);
        t1 = cyc;
        report("quote -> signal (decision)  ", t1 - t0, BUDGET_DECISION);

        // ---- quote -> suppressed decision ----
        // The risk path is the other end of the decision: same work up
        // to the limit check, then a counter instead of a signal.
        wr(`FMMA_CFG_MAX_POS, 0);                // every buy is now blocked
        publish(32'd1000000, 32'd1000100);       // re-anchor
        repeat (2000) @(posedge CLOCK_50);
        seq = dut.u0.ram[`FMMA_REJECTS];

        @(negedge CLOCK_50);
        t0 = cyc;
        publish(32'd998000, 32'd998100);
        while (dut.u0.ram[`FMMA_REJECTS] === seq) @(negedge CLOCK_50);
        t1 = cyc;
        report("quote -> suppressed (risk)  ", t1 - t0, BUDGET_DECISION);

        $display("");
        if (errors == 0) $display("=== tb_latency PASSED ===");
        else begin
            $display("=== tb_latency FAILED (%0d over budget) ===", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #20_000_000;
        $display("=== tb_latency FAILED (timeout) ===");
        $fatal(1);
    end

endmodule
