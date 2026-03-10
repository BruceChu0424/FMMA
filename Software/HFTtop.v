module HFTtop(

    input clk, input rst, output [6:0] dataseg,

    //////////// CLOCK //////////
    input                    CLOCK2_50,
    input                    CLOCK3_50,
    input                    CLOCK4_50,
    input                    CLOCK_50,

    //////////// SEG7 //////////
    //output           [6:0]  HEX0,
    //output           [6:0]  HEX1,
    //output           [6:0]  HEX2,
    //output           [6:0]  HEX3,
    //output           [6:0]  HEX4,
    //output           [6:0]  HEX5,
 
    //////////// KEY //////////
    //input            [3:0]  KEY,

    //////////// HPS //////////
    inout                     HPS_CONV_USB_N,
    output           [14:0]   HPS_DDR3_ADDR,
    output            [2:0]   HPS_DDR3_BA,
    output                    HPS_DDR3_CAS_N,
    output                    HPS_DDR3_CKE,
    output                    HPS_DDR3_CK_N,
    output                    HPS_DDR3_CK_P,
    output                    HPS_DDR3_CS_N,
    output            [3:0]   HPS_DDR3_DM,
    inout            [31:0]   HPS_DDR3_DQ,
    inout             [3:0]   HPS_DDR3_DQS_N,
    inout             [3:0]   HPS_DDR3_DQS_P,
    output                    HPS_DDR3_ODT,
    output                    HPS_DDR3_RAS_N,
    output                    HPS_DDR3_RESET_N,
    input                     HPS_DDR3_RZQ,
    output                    HPS_DDR3_WE_N,
    output                    HPS_ENET_GTX_CLOCK_50,
    inout                     HPS_ENET_INT_N,
    output                    HPS_ENET_MDC,
    inout                     HPS_ENET_MDIO,
    input                     HPS_ENET_RX_CLOCK_50,
    input             [3:0]   HPS_ENET_RX_DATA,
    input                     HPS_ENET_RX_DV,
    output            [3:0]   HPS_ENET_TX_DATA,
    output                    HPS_ENET_TX_EN,
    inout             [3:0]   HPS_FLASH_DATA,
    output                    HPS_FLASH_DCLOCK_50,
    output                    HPS_FLASH_NCSO,
    inout                     HPS_GSENSOR_INT,
    inout                     HPS_I2C1_SCLOCK_50,
    inout                     HPS_I2C1_SDAT,
    inout                     HPS_I2C2_SCLOCK_50,
    inout                     HPS_I2C2_SDAT,
    inout                     HPS_I2C_CONTROL,
    inout                     HPS_KEY,
    inout                     HPS_LED,
    inout                     HPS_LTC_GPIO,
    output                    HPS_SD_CLOCK_50,
    inout                     HPS_SD_CMD,
    inout             [3:0]   HPS_SD_DATA,
    output                    HPS_SPIM_CLOCK_50,
    input                     HPS_SPIM_MISO,
    output                    HPS_SPIM_MOSI,
    inout                     HPS_SPIM_SS,
    input                     HPS_UART_RX,
    output                    HPS_UART_TX,
    input                     HPS_USB_CLOCK_50OUT,
    inout             [7:0]   HPS_USB_DATA,
    input                     HPS_USB_DIR,
    input                     HPS_USB_NXT,
    output                    HPS_USB_STP
);

wire [31:0] r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15;
wire [31:0] instrR, instr, rAddr, Imm, ALUout, DestImm, rDest, rSrc2, ALUMUXout, addr, data;
wire [15:0] ren;
wire [9:0]  pc_out, PCchange;
wire [7:0]  disp;
wire [4:0]  flags, flagsR;
wire [3:0]  op, rSrc, outaddr, rDst;
wire [1:0]  dispcontrol;
wire        ImmSelect, RS, PCen, LS, we, Fen, IRen;

// *** NEW: memory bus helper signals for single-port on-chip RAM ***
wire [31:0] mem_addr;      // Avalon-style address (use low bits)
wire [31:0] mem_rdata;
wire [31:0] mem_wdata;
wire        mem_write;

// 7-seg display to test bram read (data load)
decoder DataDisplay(.in(mem_rdata[15:0]), .segment_display(dataseg));

// Old custom BRAM (dual-port) – now replaced by PD on-chip memory
//bram memory(.data_a(32'b00000000000000000000000000000000), .data_b(rSrc2), 
//.we_a(1'b0), .we_b(we), .addr_a(pc_out), .addr_b(rAddr[9:0]), .q_a(instr), .q_b(data), .clk(CLOCK_50));

///////////////////////////////////////////
// Single-port on-chip memory wiring
///////////////////////////////////////////

// Address mux:
//  - When LS = 0 → instruction fetch: use PC
//  - When LS = 1 → load/store: use rAddr
assign mem_addr  = LS ? {22'b0, rAddr[9:0]} : {22'b0, pc_out};

// Data to write on store comes from rSrc2 (source register)
assign mem_wdata = rSrc2;

// Write only during store cycles (FSM asserts we when LS indicates memory op)
assign mem_write = we & LS;


// Feed memory read data into both instruction and data paths
assign instr = mem_rdata;
assign data  = mem_rdata;

///////////////////////////////////////////
// Platform Designer system
///////////////////////////////////////////

HPSfgpa2 u0 (
    .clk_clk             (CLOCK_50),             //      clk.clk

    // HPS DDR3 (unchanged)
    .memory_mem_a        (HPS_DDR3_ADDR),        //   memory.mem_a
    .memory_mem_ba       (HPS_DDR3_BA),         //         .mem_ba
    .memory_mem_ck       (HPS_DDR3_CK_P),       //         .mem_ck
    .memory_mem_ck_n     (HPS_DDR3_CK_N),       //         .mem_ck_n
    .memory_mem_cke      (HPS_DDR3_CKE),        //         .mem_cke
    .memory_mem_cs_n     (HPS_DDR3_CS_N),       //         .mem_cs_n
    .memory_mem_ras_n    (HPS_DDR3_RAS_N),      //         .mem_ras_n
    .memory_mem_cas_n    (HPS_DDR3_CAS_N),      //         .mem_cas_n
    .memory_mem_we_n     (HPS_DDR3_WE_N),       //         .mem_we_n
    .memory_mem_reset_n  (HPS_DDR3_RESET_N),    //         .mem_reset_n
    .memory_mem_dq       (HPS_DDR3_DQ),         //         .mem_dq
    .memory_mem_dqs      (HPS_DDR3_DQS_P),      //         .mem_dqs
    .memory_mem_dqs_n    (HPS_DDR3_DQS_N),      //         .mem_dqs_n
    .memory_mem_odt      (HPS_DDR3_ODT),        //         .mem_odt
    .memory_mem_dm       (HPS_DDR3_DM),         //         .mem_dm
    .memory_oct_rzqin    (HPS_DDR3_RZQ),        //         .oct_rzqin

    // On-chip BRAM interface exported as "bram_out"
    .bram_out_address    (mem_addr),        // bram_out.address (32-bit, low bits used)
    .bram_out_chipselect (1'b1),  //          .chipselect
    .bram_out_clken      (1'b1),            //          .clken
    .bram_out_write      (mem_write),       //          .write
    .bram_out_readdata   (mem_rdata),       //          .readdata
    .bram_out_writedata  (mem_wdata),       //          .writedata
    .bram_out_byteenable (4'b1111),         //          .byteenable

    .reset_reset_n       (rst)              //    reset.reset_n
);

///////////////////////////////////////////
// CPU datapath + control
///////////////////////////////////////////

MUX16to1 srcMUX(
    .in0(r0),  .in1(r1),  .in2(r2),  .in3(r3),
    .in4(r4),  .in5(r5),  .in6(r6),  .in7(r7),
    .in8(r8),  .in9(r9),  .in10(r10),.in11(r11),
    .in12(r12),.in13(r13),.in14(r14),.in15(r15),
    .control(rSrc),
    .out(rSrc2)
);

MUX16to1 destMUX(
    .in0(r0),  .in1(r1),  .in2(r2),  .in3(r3),
    .in4(r4),  .in5(r5),  .in6(r6),  .in7(r7),
    .in8(r8),  .in9(r9),  .in10(r10),.in11(r11),
    .in12(r12),.in13(r13),.in14(r14),.in15(r15),
    .control(instr[11:8]),
    .out(rDest)
);

MUX16to1 addrMUX(
    .in0(r0),  .in1(r1),  .in2(r2),  .in3(r3),
    .in4(r4),  .in5(r5),  .in6(r6),  .in7(r7),
    .in8(r8),  .in9(r9),  .in10(r10),.in11(r11),
    .in12(r12),.in13(r13),.in14(r14),.in15(r15),
    .control(instr[3:0]),
    .out(rAddr)
);

MUX2to1 immMUX(
    .in0(rDest),
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
    .rst(rst)
);

ALUFinal ALU(
    .A(DestImm),
    .B(rSrc2),
    .Opcode(op),
    .C(ALUout),
    .Flags(flags),
    .Cin(1'b0)
);

FSMtrial FSM(
    .clk(CLOCK_50),
    .rst(rst),
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
    .rst(rst),
    .enable(PCen)
);

Disp Disp(
    .PCnew(PCchange),
    .PCold(pc_out),
    .control(dispcontrol),
    .disp(instr[7:0]),
    .addr(rAddr[9:0])
);

IR IR(
    .in(instr),
    .out(instrR),
    .clk(CLOCK_50),
    .rst(rst),
    .enable(IRen)
);

FR FR(
    .in(flags),
    .out(flagsR),
    .clk(CLOCK_50),
    .rst(rst),
    .enable(Fen)
);

Encoder4to16 Encoder(
    .Rdst(instr[11:8]),
    .regbankEn(ren),
    .encoderEn(RS)
);

endmodule
