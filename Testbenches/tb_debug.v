////////////////////////////////////////////////
// tb_debug - cycle-by-cycle trace of the CPU
// (development tool, not part of the regression)
////////////////////////////////////////////////

`timescale 1ns/1ps

module tb_debug;

    reg CLOCK_50;
    initial CLOCK_50 = 1'b0;
    always #10 CLOCK_50 = ~CLOCK_50;

    wire [6:0] HEX0;

    HFTTop dut(
        .CLOCK_50 (CLOCK_50),
        .HEX0     (HEX0)
    );

    reg [31:0] prog [0:255];
    integer k;
    integer cyc;

    initial begin
        $readmemh("../Software/fpga_program.hex", prog);
        #400;                          // POR done, CPU parked in hlt

        // Load the whole program "instantly" (HPS would be slower)
        for (k = 0; k < 45; k = k + 1)
            tb_debug.dut.u0.ram[8 + k] = prog[k];

        cyc = 0;
        // Trace ~120 CPU cycles: log every negedge
        repeat (240) @(negedge CLOCK_50) begin
            cyc = cyc + 1;
            $display("cyc=%0d t=%0t state=%0d PC=%0d we=%b LS=%b Ren=%b IRen=%b PCen=%b addr=%0d wr=%b wdata=%0d rdata=%08h IR=%08h",
                     cyc, $time, tb_debug.dut.FSM.state, tb_debug.dut.pc_out,
                     tb_debug.dut.we, tb_debug.dut.LS, tb_debug.dut.RS, tb_debug.dut.IRen,
                     tb_debug.dut.PCen, tb_debug.dut.mem_addr, tb_debug.dut.mem_write,
                     tb_debug.dut.mem_wdata, tb_debug.dut.mem_rdata, tb_debug.dut.instrR);
        end

        $display("---- ram dump ----");
        for (k = 0; k < 70; k = k + 1)
            if (tb_debug.dut.u0.ram[k] !== 32'h0)
                $display("ram[%0d] = %0d (0x%08h)", k, tb_debug.dut.u0.ram[k], tb_debug.dut.u0.ram[k]);

        $finish;
    end

endmodule
