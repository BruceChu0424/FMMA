////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
// ECE 4900 senior project, built on the ECE 3710
// group 1011 custom 32-bit RISC CPU.
//
// Top level: custom CPU + shared on-chip RAM + HPS
//
// The Qsys system (HPSfgpa2) contains:
//   - Cyclone V HPS (ARM) with DDR3
//   - 4 KB dual-port on-chip RAM
//       port s1 <- HPS lightweight AXI master
//                  (Linux mmap base 0xFF200000)
//       port s2 <- this CPU (fetch / load / store)
//
// Boot behaviour: the RAM powers up zeroed and a
// 32'b0 instruction parks the CPU in a halt-poll
// state (see FSMTrial). The HPS Linux program
// writes the trading program into RAM first, then
// streams market data. As soon as the word at the
// PC becomes non-zero the CPU decodes it and runs,
// so no reset handshake between HPS and FPGA is
// required.
//
// Kept in sync with Code/HFTtop.v (this copy is
// the one referenced by HFTTop.qsf).
////////////////////////////////////////////////

module HFTTop(
    input                    CLOCK_50,

    //////////// KEY //////////
    // KEY[0] is the CPU reset button. The DE1-SoC push buttons are
    // active low (pressed = 0). Holding it restarts the CPU from the
    // top of its program without reconfiguring the FPGA, which is
    // what makes a demo repeatable; the HPS has its own software
    // path for the same thing (CFG_RESTART, see docs/07).
    input            [0:0]   KEY,

    //////////// SEG7 //////////
    output           [6:0]   HEX0,

    //////////// HPS //////////
    output           [12:0]  HPS_DDR3_ADDR,
    output            [2:0]  HPS_DDR3_BA,
    output                   HPS_DDR3_CAS_N,
    output                   HPS_DDR3_CKE,
    output                   HPS_DDR3_CK_N,
    output                   HPS_DDR3_CK_P,
    output                   HPS_DDR3_CS_N,
    output                   HPS_DDR3_DM,
    inout             [7:0]  HPS_DDR3_DQ,
    inout                   HPS_DDR3_DQS_N,
    inout                   HPS_DDR3_DQS_P,
    output                   HPS_DDR3_ODT,
    output                   HPS_DDR3_RAS_N,
    output                   HPS_DDR3_RESET_N,
    input                    HPS_DDR3_RZQ,
    output                   HPS_DDR3_WE_N
);

// --------------------------------------------
// Power-on reset for the CPU fabric.
// The CPU registers use an active-high reset,
// the FSM an active-low reset (legacy lab code);
// POR is asserted for ~16 cycles after
// configuration and then released forever.
// --------------------------------------------
reg [4:0] por_cnt = 5'd0;
always @(posedge CLOCK_50) begin
    if (!KEY[0])
        por_cnt <= 5'd0;             // button held: stay in reset
    else if (!por_cnt[4])
        por_cnt <= por_cnt + 5'd1;
end

// Two synchronising stages on the button so a press, which is
// asynchronous to CLOCK_50 and bounces, cannot put the reset
// distribution into a metastable state.
reg [1:0] key_sync = 2'b11;
always @(posedge CLOCK_50)
    key_sync <= {key_sync[0], KEY[0]};

wire reset_active = ~por_cnt[4] | ~key_sync[1];
wire cpu_rst = reset_active;         // active high
wire fsm_rst = ~reset_active;        // active low (release)

// --------------------------------------------
// CPU <-> shared RAM bus (Avalon MM slave that
// the Qsys system exports as fpga_bram_s2).
// The port is word addressed (1024 x 32 bit).
// --------------------------------------------
wire [9:0]  mem_addr;                // word address
wire [31:0] mem_rdata;
wire [31:0] mem_wdata;
wire        mem_write;

wire [31:0] r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15;
wire [31:0] instrR, instr, rAddr, Imm, ALUout, DestImm, rDest, rSrc2, ALUMUXout, addr, data;
wire [15:0] ren;
wire [9:0]  pc_out, PCchange;
wire [7:0]  disp;
wire [4:0]  flags, flagsR;
wire [3:0]  op, rSrc, outaddr, rDst;
wire [1:0]  dispcontrol;
wire        ImmSelect, RS, PCen, LS, we, Fen, IRen;

// Fetch uses the PC; loads (LS) and stores (we)
// use the address register. Stores assert we for
// exactly one cycle (fixed: the old dual-port
// design gated the write with we alone).
assign mem_addr  = (LS | we) ? rAddr[9:0] : pc_out;
assign mem_wdata = rSrc2;
assign mem_write = we;

// Memory read data feeds both the instruction
// and the data path (single port, time muxed).
assign instr = mem_rdata;
assign data  = mem_rdata;

// Debug display: low nibble of the program
// counter (steady '8' while waiting for the
// program, flickering while the CPU runs).
decoder PCDisplay(.in(pc_out), .segment_display(HEX0));

// --------------------------------------------
// Platform Designer system
// --------------------------------------------
HPSfgpa2 u0 (
    .clk_clk                     (CLOCK_50),        //      clk.clk

    // Shared on-chip RAM, CPU port
    .fpga_bram_s2_address        (mem_addr),        // fpga_bram_s2.address
    .fpga_bram_s2_chipselect     (1'b1),            //               .chipselect
    .fpga_bram_s2_clken          (1'b1),            //               .clken
    .fpga_bram_s2_write          (mem_write),       //               .write
    .fpga_bram_s2_readdata       (mem_rdata),       //               .readdata
    .fpga_bram_s2_writedata      (mem_wdata),       //               .writedata
    .fpga_bram_s2_byteenable     (4'b1111),         //               .byteenable

    // MPU events are unused on this board
    .hps_0_h2f_mpu_events_eventi     (1'b0),
    .hps_0_h2f_mpu_events_evento     (),
    .hps_0_h2f_mpu_events_standbywfe (),
    .hps_0_h2f_mpu_events_standbywfi (),

    // HPS DDR3 (hard controller on dedicated pins)
    .memory_mem_a        (HPS_DDR3_ADDR),           //   memory.mem_a
    .memory_mem_ba       (HPS_DDR3_BA),             //         .mem_ba
    .memory_mem_ck       (HPS_DDR3_CK_P),           //         .mem_ck
    .memory_mem_ck_n     (HPS_DDR3_CK_N),           //         .mem_ck_n
    .memory_mem_cke      (HPS_DDR3_CKE),            //         .mem_cke
    .memory_mem_cs_n     (HPS_DDR3_CS_N),           //         .mem_cs_n
    .memory_mem_ras_n    (HPS_DDR3_RAS_N),          //         .mem_ras_n
    .memory_mem_cas_n    (HPS_DDR3_CAS_N),          //         .mem_cas_n
    .memory_mem_we_n     (HPS_DDR3_WE_N),           //         .mem_we_n
    .memory_mem_reset_n  (HPS_DDR3_RESET_N),        //         .mem_reset_n
    .memory_mem_dq       (HPS_DDR3_DQ),             //         .mem_dq
    .memory_mem_dqs      (HPS_DDR3_DQS_P),          //         .mem_dqs
    .memory_mem_dqs_n    (HPS_DDR3_DQS_N),          //         .mem_dqs_n
    .memory_mem_odt      (HPS_DDR3_ODT),            //         .mem_odt
    .memory_mem_dm       (HPS_DDR3_DM),             //         .mem_dm
    .memory_oct_rzqin    (HPS_DDR3_RZQ)             //         .oct_rzqin

    // Note: this system has no external reset port.
    // The interconnect and RAM are reset internally
    // from the HPS h2f_reset output.
);

// --------------------------------------------
// CPU datapath + control
// --------------------------------------------
MUX16to1 srcMUX(
    .in0(r0),  .in1(r1),  .in2(r2),  .in3(r3),
    .in4(r4),  .in5(r5),  .in6(r6),  .in7(r7),
    .in8(r8),  .in9(r9),  .in10(r10),.in11(r11),
    .in12(r12),.in13(r13),.in14(r14),.in15(r15),
    .control(rSrc),
    .out(rSrc2)
);

// Datapath note: register/memory selection comes from the IR
// output (instrR), not the raw RAM output. The IR latches the
// instruction at the end of fetch and holds it for the whole
// execute cycle. The original dual-port BRAM kept the
// instruction readable on port A forever, but this single-port
// RAM switches the address to rAddr during load/store, so
// mem_rdata (instr) no longer holds the instruction then.
MUX16to1 destMUX(
    .in0(r0),  .in1(r1),  .in2(r2),  .in3(r3),
    .in4(r4),  .in5(r5),  .in6(r6),  .in7(r7),
    .in8(r8),  .in9(r9),  .in10(r10),.in11(r11),
    .in12(r12),.in13(r13),.in14(r14),.in15(r15),
    .control(instrR[11:8]),
    .out(rDest)
);

MUX16to1 addrMUX(
    .in0(r0),  .in1(r1),  .in2(r2),  .in3(r3),
    .in4(r4),  .in5(r5),  .in6(r6),  .in7(r7),
    .in8(r8),  .in9(r9),  .in10(r10),.in11(r11),
    .in12(r12),.in13(r13),.in14(r14),.in15(r15),
    .control(instrR[3:0]),
    .out(rAddr)
);

// Operand routing for the ALU.
//
// The ALU computes "A op B" and the result is written back to Rd, so
// the ISA's "OP Rd, X" must put R[rd] on A and X on B.  This mux used
// to sit on the A input and select between R[rd] and the immediate,
// which made the R-type form A = R[rd], B = R[rs] (right) but the
// I-type form A = imm, B = R[rd] (backwards).  The consequence was
// that every non-commutative immediate instruction did the wrong
// thing without any diagnostic: SUB Rd,#k computed k - Rd, CMP Rd,#k
// compared k against Rd, and MOV Rd,#k was a no-op because MOV
// returns its B input.
//
// Moving the mux to the B input fixes all of them and leaves the
// R-type encoding bit-for-bit identical.  trading.asm's init block
// verifies the wiring at run time before it declares the protocol
// version, so an old bitstream paired with a new program fails
// loudly instead of trading on bad arithmetic.
MUX2to1 immMUX(
    .in0(rSrc2),
    .in1(Imm),
    .control(ImmSelect),
    .out(DestImm)
);

MUX2to1 ALUMUX(
    .in0(ALUout),
    .in1(data),
    .control(LS),
    .out(ALUMUXout)
);

RegBank regBank(
    .ALUBus(ALUMUXout),
    .r0(r0),   .r1(r1),   .r2(r2),   .r3(r3),
    .r4(r4),   .r5(r5),   .r6(r6),   .r7(r7),
    .r8(r8),   .r9(r9),   .r10(r10), .r11(r11),
    .r12(r12), .r13(r13), .r14(r14), .r15(r15),
    .regEnable(ren),
    .clk(CLOCK_50),
    .rst(cpu_rst)
);

// The carry input comes from the flag register, which is what makes
// ADDC/SUBC able to chain across instructions. It used to be tied to
// zero, which made ADDC identical to ADD and made SUBC subtract an
// extra one on every use.
ALUFinal ALU(
    .A(rDest),        // always R[rd]
    .B(DestImm),      // R[rs] for R-type, the immediate for I-type
    .Opcode(op),
    .C(ALUout),
    .Flags(flags),
    .Cin(flagsR[3])
);

// The FSM holds an active-low reset (legacy lab
// convention), every other CPU block is active high.
FSMtrial FSM(
    .clk(CLOCK_50),
    .rst(fsm_rst),
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

PC PC(
    .in(PCchange),
    .out(pc_out),
    .clk(CLOCK_50),
    .rst(cpu_rst),
    .enable(PCen)
);

Disp Disp(
    .PCnew(PCchange),
    .PCold(pc_out),
    .control(dispcontrol),
    .disp(instrR[7:0]),
    .addr(rAddr[9:0])
);

IR IR(
    .in(instr),
    .out(instrR),
    .clk(CLOCK_50),
    .rst(cpu_rst),
    .enable(IRen)
);

FR FR(
    .in(flags),
    .out(flagsR),
    .clk(CLOCK_50),
    .rst(cpu_rst),
    .enable(Fen)
);

Encoder4to16 Encoder(
    .Rdst(instrR[11:8]),
    .regbankEn(ren),
    .encoderEn(RS)
);

endmodule
