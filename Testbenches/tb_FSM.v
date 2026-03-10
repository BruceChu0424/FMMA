module tb_FSM;

// Inputs
reg clk;
reg rst;
reg [3:0] opcodeSelect_in;

// Outputs
wire [15:0] regBankEnable_out;
wire [3:0] src0_out, src1_out;
wire [3:0] Opcode_out;
wire flagEnable_out;
wire immediate_out;

integer i;

initial clk = 0;
always #10 clk = ~clk;

// --- Instantiate the Unit Under Test (UUT) ---
FSM uut (
    .clk(clk), 
    .rst(rst), 
    .opcodeSelect(opcodeSelect_in), 
    .regBankEnable(regBankEnable_out), 
    .src0(src0_out), 
    .src1(src1_out), 
    .Opcode(Opcode_out), 
    .flagEnable(flagEnable_out), 
    .immediate(immediate_out)
);

initial begin
    $display("===== FSM Control Signal Verification (ALU Test Sequence) =====");
    
    opcodeSelect_in = 4'b0000; 

    $monitor("time=%0t | Opcode_in=%b, R_EN=%h, src0=%b, src1=%b, Opcode_out=%b, Imm=%b", 
             $time, opcodeSelect_in, regBankEnable_out, src0_out, src1_out, Opcode_out, immediate_out);

    // 1. Assert Reset
    rst = 0;
    @(negedge clk);
    $display("INFO: Asserting RESET");
    
    // 2. Release Reset
    rst = 1;
    @(negedge clk); 
    $display("INFO: FSM now in RESET (T=%0t). Next state S1.", $time);

    // State S1: r2 = r0 + r1
    @(negedge clk);
    $display("--- State S1: Read R0, R1 -> Write R2 ---");
    
    // State S2: r3 = r1 + r2 
    @(negedge clk);
    $display("--- State S2: Read R1, R2 -> Write R3 ---");
    
    // State S3: r4 = r2 + r3
    @(negedge clk);
    $display("--- State S3: Read R2, R3 -> Write R4 ---");
    
    // State S4: r5 = r3 + r4
    @(negedge clk);
    $display("--- State S4: Read R3, R4 -> Write R5 ---");

    // State S5: r6 = r4 + r5
    @(negedge clk);
    $display("--- State S5: Read R4, R5 -> Write R6 ---");

    // State S6: r7 = r5 + r6 
    @(negedge clk);
    $display("--- State S6: Read R5, R6 -> Write R7 ---");

    // State S7: r8 = r6 + r7
    @(negedge clk);
    $display("--- State S7: Read R6, R7 -> Write R8 ---");

    // State S8: r9 = r7 + r8
    @(negedge clk);
    $display("--- State S8: Read R7, R8 -> Write R9 ---");

    // State S9: r10 = r8 + r9 
    @(negedge clk);
    $display("--- State S9: Read R8, R9 -> Write R10 ---");

    // State S10: r11 = r9 + r10
    @(negedge clk);
    $display("--- State S10: Read R9, R10 -> Write R11 ---");

    // State S11: r12 = r10 + r11 
    @(negedge clk);
    $display("--- State S11: Read R10, R11 -> Write R12 ---");

    // State S12: r13 = r11 + r12 
    @(negedge clk);
    $display("--- State S12: Read R11, R12 -> Write R13 ---");

    // State S13: r14 = r12 + r13 
    @(negedge clk);
    $display("--- State S13: Read R12, R13 -> Write R14 ---");

    // State S14: r15 = r13 + r14 (Looping state) 
    @(negedge clk);
    $display("--- State S14: Read R13, R14 -> Write R15 (Looping) ---");
    
    @(negedge clk);
    $display("--- State S14: (Second Loop) ---");
    
    #100;
    $finish;
end
endmodule