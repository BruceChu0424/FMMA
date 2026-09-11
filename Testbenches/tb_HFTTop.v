////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
//
// tb_HFTTop - full-chain simulation
//
// Instantiates the real FPGA top level (HFTTop)
// against a behavioral HPSfgpa2 stub and plays
// the role of the HPS Linux program:
//   1. waits for the CPU to park in its
//      halt/wait state (RAM still zero)
//   2. writes the trading program produced by
//      Assembler.py (fpga_program.hex)
//   3. streams synthetic market prices
//   4. checks the SIGNAL / HEARTBEAT words the
//      CPU writes back
//
// Self-checking: prints TEST PASS / FAIL lines
// and a final verdict. Run with Questa:
//   cd Testbenches
//   vlib work
//   vlog ..\Software\HFTtop.v ..\Code\PC.v ..\Code\IR ..\Code\FR ^
//         ..\Code\registerFinal ..\Code\MUX16to1 ..\Code\MUX2to1 ^
//         ..\Code\ALUFinal ..\Code\FSMTrial ..\Code\disp ^
//         ..\Code\Encoder4to16 ..\Code\decoder.v ^
//         HPSfgpa2_stub.v tb_HFTTop.v
//   vsim -c tb_HFTTop -do "run -all; quit -f"
////////////////////////////////////////////////

`timescale 1ns/1ps

module tb_HFTTop;

    // 50 MHz system clock
    reg CLOCK_50;
    initial CLOCK_50 = 1'b0;
    always #10 CLOCK_50 = ~CLOCK_50;

    wire [6:0] HEX0;

    // Device under test - the real top level
    HFTTop dut(
        .CLOCK_50 (CLOCK_50),
        .HEX0     (HEX0)
    );

    // Program image produced by Assembler.py
    reg [31:0] prog [0:255];

    // Shared memory word indices (must match Documents/PROTOCOL.md)
    localparam WORD_BUY_PRICE  = 64;
    localparam WORD_SELL_PRICE = 65;
    localparam WORD_SIGNAL     = 66;
    localparam WORD_HEARTBEAT  = 67;
    localparam PROG_BASE       = 8;
    localparam PROG_LEN        = 45;

    integer errors;
    integer k;
    reg [31:0] hb, sig;

    // ---------------- HPS emulation tasks ----------------

    // A word write as the LW bridge would deliver it
    task hps_write(input [9:0] wa, input [31:0] wd);
    begin
        tb_HFTTop.dut.u0.ram[wa] = wd;
        repeat (6) @(posedge CLOCK_50);   // bridge latency, in spirit
    end
    endtask

    task hps_read(input [9:0] wa, output [31:0] rd);
    begin
        rd = tb_HFTTop.dut.u0.ram[wa];
    end
    endtask

    task check(input [31:0] got, input [31:0] exp, input [127:0] what);
    begin
        if (got !== exp) begin
            errors = errors + 1;
            $display("FAIL: %0s - got %0d (0x%08h), expected %0d", what, got, got, exp);
        end
        else begin
            $display("PASS: %0s = %0d", what, got);
        end
    end
    endtask

    // ---------------- test sequence ----------------

    initial begin
        errors = 0;

        $readmemh("../Software/fpga_program.hex", prog);
        $display("=== FMMA full-chain testbench ===");

        // ---- Phase 0: RAM empty -> CPU must wait (halt state) ----
        $display("--- Phase 0: CPU waits for a program ---");
        #2000;   // 100 us: POR done long ago, CPU parked in hlt
        check(tb_HFTTop.dut.pc_out, 10'd8, "PC parked at 8  ");
        hps_read(WORD_HEARTBEAT, hb);
        check(hb, 32'd0, "heartbeat idle  ");

        // ---- Phase 1: HPS loads the trading program ----
        $display("--- Phase 1: HPS loads the program ---");
        for (k = 0; k < PROG_LEN; k = k + 1)
            hps_write(PROG_BASE + k, prog[k]);
        hps_write(WORD_SIGNAL,     32'd0);
        hps_write(WORD_HEARTBEAT,  32'd0);

        // CPU should wake up and start counting heartbeats
        #100000;  // 100 us: many loop iterations
        hps_read(WORD_HEARTBEAT, hb);
        if (hb == 0) begin
            errors = errors + 1;
            $display("FAIL: CPU did not start (heartbeat stuck at 0)");
        end
        else
            $display("PASS: CPU running, heartbeat = %0d", hb);

        // ---- Phase 2: crossed market, buy < sell -> SIGNAL 1 ----
        $display("--- Phase 2: crossed market (buy < sell) ---");
        hps_write(WORD_BUY_PRICE,  32'd1000000000);   // $100000.0000
        hps_write(WORD_SELL_PRICE, 32'd1000000500);   // $100000.0500
        #100000;
        hps_read(WORD_SIGNAL, sig);
        check(sig, 32'd1, "signal = BUY    ");

        // Normalise prices first, then clear the signal (the CPU
        // re-raises it while the triggering condition still holds,
        // exactly like the C program would see)
        hps_write(WORD_SELL_PRICE, 32'd1000000000);
        #10000;
        hps_write(WORD_SIGNAL, 32'd0);

        // ---- Phase 3: normal market, no signal ----
        $display("--- Phase 3: balanced market ---");
        #100000;
        hps_read(WORD_SIGNAL, sig);
        check(sig, 32'd0, "signal = none   ");

        // ---- Phase 4: price dips -> SIGNAL 1 (mean reversion) ----
        // Step 1: lower the sell side only; buy > sell so no cross.
        // Anchors become (1e9, 998.9e6).
        $display("--- Phase 4: price dip ($105 below anchor) ---");
        hps_write(WORD_SELL_PRICE, 32'd998900000);
        #10000;
        // Step 2: buy drops to 998.95e6 - $105 below the last_buy
        // anchor (threshold $10), still above sell so the crossed
        // branch does not fire first.
        hps_write(WORD_BUY_PRICE,  32'd998950000);
        #100000;
        hps_read(WORD_SIGNAL, sig);
        check(sig, 32'd1, "signal = BUY    ");

        // Normalise: raise the sell side (no spike vs its anchor yet),
        // wait, clear
        hps_write(WORD_SELL_PRICE, 32'd998900000);  // already there
        #10000;
        hps_write(WORD_SIGNAL, 32'd0);

        // ---- Phase 5: sell spikes -> SIGNAL 2 ----
        // anchors are now (998.95e6, 998.9e6). Step 1: raise buy
        // first (no cross, no dip vs its anchor). Step 2: raise
        // sell $155 above its anchor -> SELL.
        $display("--- Phase 5: price spike ($155 above anchor) ---");
        hps_write(WORD_BUY_PRICE,  32'd1000500000);
        #10000;
        hps_write(WORD_SELL_PRICE, 32'd1000450000);
        #100000;
        hps_read(WORD_SIGNAL, sig);
        check(sig, 32'd2, "signal = SELL   ");

        // ---- Verdict ----
        if (errors == 0)
            $display("=== ALL TESTS PASSED ===");
        else
            $display("=== %0d TEST(S) FAILED ===", errors);
        $finish;
    end

endmodule
