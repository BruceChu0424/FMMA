////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
// ECE 4900 senior project, built on the ECE 3710
// group 1011 custom 32-bit RISC CPU.
//
// Top level for the Terasic DE1-SoC. Its whole job is to say how four
// things are wired to the board:
//
//   HPSfgpa2    the Platform Designer system - the Cyclone V HPS plus
//               a 4 KB dual-port on-chip RAM. Port s1 of that RAM is
//               on the HPS lightweight AXI master (the host maps it at
//               0xFF200000); port s2 is exported as fpga_bram_s2 and
//               is what the CPU fetches, loads and stores through.
//   cpu_core    the CPU itself (Code/cpu_core.v)
//   reset_ctrl  power-on reset and the KEY[0] button (Code/reset_ctrl.v)
//   decoder     the seven-segment debug display
//
// Boot behaviour: the RAM powers up zeroed and a 32'b0 instruction
// parks the CPU in a halt-poll state, so after configuration it sits
// at the entry word showing a steady 8 on HEX0. The host writes the
// program with the entry word LAST, which makes it impossible for the
// CPU to start on a half-written image, so no reset handshake between
// the two sides is needed. docs/07 section 7.4.
//
// Kept byte-identical to Code/HFTtop.v; only this copy is in the QSF,
// because two definitions of the same module would collide.
////////////////////////////////////////////////

module HFTTop(
    input                    CLOCK_50,

    //////////// KEY //////////
    // KEY[0] resets the CPU. The DE1-SoC buttons are active low.
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
    inout                    HPS_DDR3_DQS_N,
    inout                    HPS_DDR3_DQS_P,
    output                   HPS_DDR3_ODT,
    output                   HPS_DDR3_RAS_N,
    output                   HPS_DDR3_RESET_N,
    input                    HPS_DDR3_RZQ,
    output                   HPS_DDR3_WE_N
);

// --------------------------------------------
// Reset
// --------------------------------------------
wire cpu_rst;      // active high, for the CPU's registers
wire cpu_rst_n;    // active low,  for the control FSM

reset_ctrl reset_ctrl_inst (
    .clk       (CLOCK_50),
    .key_n     (KEY[0]),
    .rst_high  (cpu_rst),
    .rst_low_n (cpu_rst_n)
);

// --------------------------------------------
// CPU <-> shared RAM
// --------------------------------------------
wire [9:0]  mem_addr;      // word address into the 1024-word RAM
wire [31:0] mem_rdata;
wire [31:0] mem_wdata;
wire        mem_write;
wire [9:0]  pc;

cpu_core cpu (
    .clk       (CLOCK_50),
    .rst       (cpu_rst),
    .rst_n     (cpu_rst_n),
    .mem_addr  (mem_addr),
    .mem_wdata (mem_wdata),
    .mem_write (mem_write),
    .mem_rdata (mem_rdata),
    .pc        (pc)
);

// --------------------------------------------
// Debug display: the low nibble of the program counter.
// A steady 8 means "parked at the entry word, waiting for a program",
// which is the normal state after configuration and the quickest
// confirmation that the fabric is alive. docs/05 section 5.5.
// --------------------------------------------
decoder PCDisplay (
    .in              (pc),
    .segment_display (HEX0)
);

// --------------------------------------------
// Platform Designer system
// --------------------------------------------
HPSfgpa2 u0 (
    .clk_clk                     (CLOCK_50),        //      clk.clk

    // Shared on-chip RAM, the CPU's port
    .fpga_bram_s2_address        (mem_addr),        // fpga_bram_s2.address
    .fpga_bram_s2_chipselect     (1'b1),            //             .chipselect
    .fpga_bram_s2_clken          (1'b1),            //             .clken
    .fpga_bram_s2_write          (mem_write),       //             .write
    .fpga_bram_s2_readdata       (mem_rdata),       //             .readdata
    .fpga_bram_s2_writedata      (mem_wdata),       //             .writedata
    .fpga_bram_s2_byteenable     (4'b1111),         //             .byteenable

    // MPU events are unused on this board
    .hps_0_h2f_mpu_events_eventi     (1'b0),
    .hps_0_h2f_mpu_events_evento     (),
    .hps_0_h2f_mpu_events_standbywfe (),
    .hps_0_h2f_mpu_events_standbywfi (),

    // HPS DDR3 conduit. These pins belong to the HPS hard IP; the
    // fabric only passes them through. Their parameterisation in the
    // Qsys system is a placeholder - see docs/05 section 5.7.
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

    // This system has no external reset port: the interconnect and the
    // RAM are reset from the HPS h2f_reset output.
);

endmodule
