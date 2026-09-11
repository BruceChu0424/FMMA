////////////////////////////////////////////////
// FMMA - tb_isa_probe
//
// Runs Software/isa_probe.asm against the real RTL and reports the
// same bit mask the hardware probe publishes.
//
// This exists because of a specific failure.  market_maker.asm was
// refused by the loader on real hardware - "the CPU is alive but will
// not declare a version" - while trading.asm ran perfectly on the same
// bitstream, and the golden instruction-set simulator passed both.
// The strategies' built-in datapath probe reports one bit and then
// spins, which is right for production and useless for diagnosis.
//
// isa_probe.asm checks each instruction independently and publishes a
// mask.  Running the same image here gives the answer simulation is
// good at and hardware is not: which instruction, and why.
//
// The two must agree.  When they do not, this testbench is the place
// to find out what the silicon does that the model does not.
//
// It is assembled under its own prefix, so running this never changes
// which image the board would be given:
//
//   cd Software && python Assembler.py isa_probe.asm --prefix isa_probe
//   cd Testbenches && ./run_sim.sh
////////////////////////////////////////////////

`timescale 1ns/1ps

`include "fmma_protocol.vh"

module tb_isa_probe;

    reg CLOCK_50 = 1'b0;
    always #10 CLOCK_50 = ~CLOCK_50;

    reg  [0:0] KEY = 1'b1;
    wire [6:0] HEX0;

    HFTTop dut (
        .CLOCK_50 (CLOCK_50),
        .KEY      (KEY),
        .HEX0     (HEX0)
    );

    // isa_probe publishes its results into the CPU's output block.
    localparam MASK_WORD   = `FMMA_QUOTE_BID;       // 328
    localparam COUNT_WORD  = `FMMA_QUOTE_ASK;       // 329
    localparam BITREG_WORD = `FMMA_QUOTE_ASK + 1;   // 330

    localparam CHECKS = 10;

    reg [31:0] prog [0:255];
    integer    prog_len, k, errors;
    reg [31:0] mask, count, bitreg, beat0, beat1;

    task wr(input [9:0] a, input [31:0] d);
        begin dut.u0.hps_write(a, d); end
    endtask

    task rd(input [9:0] a, output [31:0] d);
        begin dut.u0.hps_read(a, d); end
    endtask

    // Names must match the comment block at the top of isa_probe.asm.
    function [255:0] bit_name(input integer i);
        case (i)
            0: bit_name = "MOV immediate";
            1: bit_name = "SUB immediate operand order";
            2: bit_name = "ADD immediate";
            3: bit_name = "LSH immediate, left";
            4: bit_name = "LSH immediate, right";
            5: bit_name = "ASH immediate, right, signed";
            6: bit_name = "CMP/BEQ taken";
            7: bit_name = "CMP/BNE taken";
            8: bit_name = "jump through a register";
            9: bit_name = "LOAD/STOR round trip";
            default: bit_name = "?";
        endcase
    endfunction

    initial begin
        errors = 0;

        for (k = 0; k < 256; k = k + 1) prog[k] = 32'h0;
        $readmemh("../Software/isa_probe.hex", prog);

        prog_len = 0;
        for (k = 0; k < 256; k = k + 1)
            if (prog[k] !== 32'h0 && prog[k] !== 32'hx) prog_len = k + 1;

        if (prog_len == 0) begin
            $display("FATAL: isa_probe.hex is empty - run");
            $display("       cd Software && python Assembler.py isa_probe.asm --prefix isa_probe");
            $finish;
        end

        $display("");
        $display("tb_isa_probe: %0d program words", prog_len);
        $display("");

        // Reset, exactly as the board does at power-on.
        KEY = 1'b0;
        repeat (8) @(posedge CLOCK_50);
        KEY = 1'b1;
        repeat (8) @(posedge CLOCK_50);

        // Load the way the loader does: entry word last.
        for (k = 1; k < prog_len; k = k + 1)
            wr(`FMMA_PROGRAM_BASE + k, prog[k]);
        wr(`FMMA_PROGRAM_BASE, prog[0]);

        // The probe is a few hundred instructions at three cycles each.
        repeat (4000) @(posedge CLOCK_50);

        rd(MASK_WORD,   mask);
        rd(COUNT_WORD,  count);
        rd(BITREG_WORD, bitreg);

        $display("  mask   0x%08h", mask);
        $display("  checks %0d", count);
        $display("  bit register ends at %0d (expected %0d)",
                 bitreg, 1 << CHECKS);
        $display("");

        if (count !== CHECKS) begin
            errors = errors + 1;
            $display("  FAIL: the probe did not run to completion");
            $display("        it published %0d of %0d checks", count, CHECKS);
        end

        // A bit register that did not end at 2**CHECKS means the mask
        // cannot be read bit by bit - report that rather than printing
        // a table of nonsense.
        if (bitreg !== (1 << CHECKS)) begin
            errors = errors + 1;
            $display("  FAIL: the bit register ended at %0d, not %0d.",
                     bitreg, 1 << CHECKS);
            $display("        The mask is not trustworthy: either the");
            $display("        accumulator or ADD itself is wrong.");
        end else begin
            for (k = 0; k < CHECKS; k = k + 1) begin
                if (mask[k]) begin
                    $display("  pass: %0s", bit_name(k));
                end else begin
                    errors = errors + 1;
                    $display("  FAIL: %0s", bit_name(k));
                end
            end
        end

        // The probe must keep running afterwards, not wedge.
        rd(`FMMA_HEARTBEAT, beat0);
        repeat (2000) @(posedge CLOCK_50);
        rd(`FMMA_HEARTBEAT, beat1);
        if (beat1 === beat0) begin
            errors = errors + 1;
            $display("  FAIL: the heartbeat stopped - the probe wedged");
        end else begin
            $display("  pass: still running (heartbeat %0d -> %0d)",
                     beat0, beat1);
        end

        $display("");
        if (errors == 0)
            $display("tb_isa_probe: all %0d checks pass in simulation", CHECKS);
        else
            $display("tb_isa_probe: %0d FAILURES", errors);
        $display("");
        $finish;
    end

    // A wedged CPU must not hang the simulation.
    initial begin
        #2000000;
        $display("tb_isa_probe: TIMEOUT");
        $finish;
    end

endmodule
