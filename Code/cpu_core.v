////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
//
// cpu_core - the 32-bit RISC CPU, assembled from the ECE 3710
// group 1011 modules.
//
// This is everything between the memory port and the debug display:
// datapath, control FSM, register bank and next-PC logic. Keeping it
// separate from the top level means the CPU can be instantiated
// against a plain memory in a testbench without dragging in the HPS,
// and the top level is left saying only how the pieces are wired to
// the board.
//
// Interface: one memory port, word addressed, with a one-cycle
// registered read. Fetch, load and store are time multiplexed onto
// it - the CPU never needs two accesses in the same cycle.
//
// Timing: the whole core changes state on the FALLING edge of clk,
// while the memory it talks to is clocked on the rising edge. That
// gives each direction half a period to settle and is why one clock
// serves both without a wait state. See docs/03.
////////////////////////////////////////////////

module cpu_core (
    input  wire        clk,
    input  wire        rst,          // active high: registers
    input  wire        rst_n,        // active low:  control FSM

    // Word-addressed memory port, one-cycle registered read
    output wire [9:0]  mem_addr,
    output wire [31:0] mem_wdata,
    output wire        mem_write,
    input  wire [31:0] mem_rdata,

    // Visibility for the board display and for testbenches
    output wire [9:0]  pc
);

    // ---- datapath nets ----
    wire [31:0] r0, r1, r2, r3, r4, r5, r6, r7;
    wire [31:0] r8, r9, r10, r11, r12, r13, r14, r15;
    wire [31:0] instrR, instr, rAddr, Imm;
    wire [31:0] ALUout, DestImm, rDest, rSrc2, ALUMUXout, data;
    wire [15:0] ren;
    wire [9:0]  pc_out, PCchange;
    wire [4:0]  flags, flagsR;
    wire [3:0]  op, rSrc, rDst;
    wire [1:0]  dispcontrol;
    wire        ImmSelect, RS, PCen, LS, we, Fen, IRen;

    assign pc = pc_out;

    // Fetch uses the PC; a load or a store borrows the port for one
    // cycle and addresses it from the address register instead.
    assign mem_addr  = (LS | we) ? rAddr[9:0] : pc_out;
    assign mem_wdata = rSrc2;
    assign mem_write = we;

    // The same read port feeds the instruction and the load data; which
    // one it is depends on where the FSM is in the cycle.
    assign instr = mem_rdata;
    assign data  = mem_rdata;

    // ---- register file read ports ----
    //
    // The source select comes from the FSM (which decodes the raw
    // memory word), the destination and address selects from the IR.
    // That distinction matters: by the time a load or store executes,
    // the memory port has been switched to the data address, so the
    // instruction is no longer on mem_rdata and only the IR still
    // holds it.
    MUX16to1 srcMUX (
        .in0(r0),  .in1(r1),  .in2(r2),  .in3(r3),
        .in4(r4),  .in5(r5),  .in6(r6),  .in7(r7),
        .in8(r8),  .in9(r9),  .in10(r10),.in11(r11),
        .in12(r12),.in13(r13),.in14(r14),.in15(r15),
        .control(rSrc),
        .out(rSrc2)
    );

    MUX16to1 destMUX (
        .in0(r0),  .in1(r1),  .in2(r2),  .in3(r3),
        .in4(r4),  .in5(r5),  .in6(r6),  .in7(r7),
        .in8(r8),  .in9(r9),  .in10(r10),.in11(r11),
        .in12(r12),.in13(r13),.in14(r14),.in15(r15),
        .control(instrR[11:8]),
        .out(rDest)
    );

    MUX16to1 addrMUX (
        .in0(r0),  .in1(r1),  .in2(r2),  .in3(r3),
        .in4(r4),  .in5(r5),  .in6(r6),  .in7(r7),
        .in8(r8),  .in9(r9),  .in10(r10),.in11(r11),
        .in12(r12),.in13(r13),.in14(r14),.in15(r15),
        .control(instrR[3:0]),
        .out(rAddr)
    );

    // ---- ALU operand selection ----
    //
    // The ALU computes A op B and the result goes back to Rd, so both
    // instruction forms put R[rd] on A and the second operand on B.
    // This mux used to sit on the A input, which made the immediate
    // form compute "imm op Rd": SUB Rd,#k was k-Rd and MOV Rd,#k did
    // nothing at all. Moving it to B fixes every immediate instruction
    // and leaves the register form bit-for-bit identical. trading.asm
    // probes for this at startup; see docs/04 section 4.8.
    MUX2to1 immMUX (
        .in0(rSrc2),
        .in1(Imm),
        .control(ImmSelect),
        .out(DestImm)
    );

    ALUFinal ALU (
        .A(rDest),          // always R[rd]
        .B(DestImm),        // R[rs] for R-type, the immediate for I-type
        .Opcode(op),
        .C(ALUout),
        .Flags(flags),
        .Cin(flagsR[3])     // carry in from the flag register, so
    );                      // ADDC and SUBC can chain

    // Write-back source: load data for a load, the ALU otherwise.
    MUX2to1 ALUMUX (
        .in0(ALUout),
        .in1(data),
        .control(LS),
        .out(ALUMUXout)
    );

    RegBank regBank (
        .ALUBus(ALUMUXout),
        .r0(r0),   .r1(r1),   .r2(r2),   .r3(r3),
        .r4(r4),   .r5(r5),   .r6(r6),   .r7(r7),
        .r8(r8),   .r9(r9),   .r10(r10), .r11(r11),
        .r12(r12), .r13(r13), .r14(r14), .r15(r15),
        .regEnable(ren),
        .clk(clk),
        .rst(rst)
    );

    // One-hot write enable for the destination register.
    Encoder4to16 Encoder (
        .Rdst(instrR[11:8]),
        .regbankEn(ren),
        .encoderEn(RS)
    );

    // ---- control ----
    FSMtrial FSM (
        .clk(clk),
        .rst(rst_n),               // active low, inherited convention
        .memin(instr),
        .Ren(RS),
        .displaceControl(dispcontrol),
        .RI(ImmSelect),
        .PCen(PCen),
        .opcode(op),
        .rSrc(rSrc),
        .rDst(rDst),
        .Imm(Imm),
        .Fen(Fen),
        .IRen(IRen),
        .instruction(instrR),
        .LS(LS),
        .we(we),
        .flags(flagsR)
    );

    // ---- sequencing registers ----
    PC PC (
        .in(PCchange),
        .out(pc_out),
        .clk(clk),
        .rst(rst),
        .enable(PCen)
    );

    Disp Disp (
        .PCnew(PCchange),
        .PCold(pc_out),
        .control(dispcontrol),
        .disp(instrR[7:0]),
        .addr(rAddr[9:0])
    );

    IR IR (
        .in(instr),
        .out(instrR),
        .clk(clk),
        .rst(rst),
        .enable(IRen)
    );

    FR FR (
        .in(flags),
        .out(flagsR),
        .clk(clk),
        .rst(rst),
        .enable(Fen)
    );

endmodule
