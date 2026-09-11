////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
//
// tb_alu - equivalence test between Code/ALUFinal
// and the golden model in Software/fmma_sim.py.
//
// Reads alu_vectors.txt (produced by
// Software/gen_alu_vectors.py) and drives every
// case through the real ALU, checking both the
// result and all five flags.
//
//   cd Testbenches
//   iverilog -g2005 -o tb_alu.vvp ../Code/ALUFinal tb_alu.v
//   vvp tb_alu.vvp
//
// A failure here means the hardware and the
// simulator disagree, so every result the Python
// strategy tests produce is suspect. See
// docs/12-verification-plan.md.
////////////////////////////////////////////////

`timescale 1ns/1ps

module tb_alu;

    reg  [31:0] A, B;
    reg  [3:0]  Opcode;
    reg         Cin;
    wire [31:0] C;
    wire [4:0]  Flags;

    ALUFinal dut (
        .A(A), .B(B), .Opcode(Opcode), .Cin(Cin),
        .C(C), .Flags(Flags)
    );

    integer fd, code, checked, failures, line_no;
    reg [31:0] exp_c;
    reg [4:0]  exp_flags;
    reg [3:0]  op;
    reg [31:0] va, vb;
    reg [31:0] vcin;
    reg [1023:0] text;

    initial begin
        checked  = 0;
        failures = 0;
        line_no  = 0;

        fd = $fopen("alu_vectors.txt", "r");
        if (fd == 0) begin
            $display("FATAL: cannot open alu_vectors.txt - run");
            $display("       python ../Software/gen_alu_vectors.py");
            $finish;
        end

        while (!$feof(fd)) begin
            // Skip comment lines.
            code = $fscanf(fd, "%h %h %h %h %h %h\n",
                           op, va, vb, vcin, exp_c, exp_flags);
            line_no = line_no + 1;
            if (code != 6) begin
                // Not a vector line: consume the rest of it and move on.
                code = $fgets(text, fd);
            end
            else begin
                Opcode = op;
                A      = va;
                B      = vb;
                Cin    = vcin[0];
                #1;

                if (C !== exp_c || Flags !== exp_flags) begin
                    failures = failures + 1;
                    if (failures <= 25)
                        $display("FAIL op=%h A=%h B=%h Cin=%b : C=%h/%h flags=%b/%b (rtl/model)",
                                 op, va, vb, vcin[0], C, exp_c, Flags, exp_flags);
                end
                checked = checked + 1;
            end
        end
        $fclose(fd);

        $display("");
        $display("tb_alu: %0d vectors checked, %0d failures", checked, failures);
        if (checked == 0) begin
            $display("=== tb_alu FAILED (no vectors were read) ===");
            $fatal(1);
        end
        else if (failures == 0)
            $display("=== tb_alu PASSED ===");
        else begin
            $display("=== tb_alu FAILED ===");
            $fatal(1);
        end
        $finish;
    end

endmodule
