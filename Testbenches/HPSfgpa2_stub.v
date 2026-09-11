////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
//
// Behavioral replacement for the Platform
// Designer system "HPSfgpa2" (simulation only -
// the real generated module is used in Quartus).
//
// Models the parts the CPU sees:
//  - 4 KB dual-port on-chip RAM (1024 x 32 bit)
//  - the exported CPU slave port fpga_bram_s2
//    with a registered (pipelined) read, like
//    the real onchip_memory2 IP
//  - a short reset window after power-up where
//    readdata is zero (the HPS h2f_reset)
//
// The "HPS" side of the testbench pokes words
// directly into the ram array (that is what
// port s1 / the LW bridge would deliver).
////////////////////////////////////////////////

`timescale 1ns/1ps

module HPSfgpa2 (
    input  wire        clk_clk,
    input  wire [9:0]  fpga_bram_s2_address,
    input  wire        fpga_bram_s2_chipselect,
    input  wire        fpga_bram_s2_clken,
    input  wire        fpga_bram_s2_write,
    output wire [31:0] fpga_bram_s2_readdata,
    input  wire [31:0] fpga_bram_s2_writedata,
    input  wire [3:0]  fpga_bram_s2_byteenable,
    input  wire        hps_0_h2f_mpu_events_eventi,
    output wire        hps_0_h2f_mpu_events_evento,
    output wire [1:0]  hps_0_h2f_mpu_events_standbywfe,
    output wire [1:0]  hps_0_h2f_mpu_events_standbywfi,
    output wire [12:0] memory_mem_a,
    output wire [2:0]  memory_mem_ba,
    output wire        memory_mem_ck,
    output wire        memory_mem_ck_n,
    output wire        memory_mem_cke,
    output wire        memory_mem_cs_n,
    output wire        memory_mem_ras_n,
    output wire        memory_mem_cas_n,
    output wire        memory_mem_we_n,
    output wire        memory_mem_reset_n,
    inout  wire [7:0]  memory_mem_dq,
    inout  wire        memory_mem_dqs,
    inout  wire        memory_mem_dqs_n,
    output wire        memory_mem_odt,
    output wire        memory_mem_dm,
    input  wire        memory_oct_rzqin
);

    // ---- shared on-chip RAM, powers up zeroed ----
    reg [31:0] ram [0:1023];

    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1)
            ram[i] = 32'h00000000;
    end

    // ---- registered slave port behaviour ----
    integer  rst_cnt;
    reg [31:0] rdata_r;

    initial begin
        rst_cnt  = 0;
        rdata_r  = 32'h0;
    end

    always @(posedge clk_clk) begin
        if (rst_cnt < 8)
            rst_cnt <= rst_cnt + 1;

        if (rst_cnt >= 8 && fpga_bram_s2_write && fpga_bram_s2_chipselect)
            ram[fpga_bram_s2_address] <= fpga_bram_s2_writedata;

        rdata_r <= (rst_cnt >= 8) ? ram[fpga_bram_s2_address] : 32'h0;
    end

    assign fpga_bram_s2_readdata = rdata_r;

    // ---- unused HPS pins ----
    assign hps_0_h2f_mpu_events_evento     = 1'b0;
    assign hps_0_h2f_mpu_events_standbywfe = 2'b00;
    assign hps_0_h2f_mpu_events_standbywfi = 2'b00;
    assign memory_mem_a        = 13'd0;
    assign memory_mem_ba       = 3'd0;
    assign memory_mem_ck       = 1'b0;
    assign memory_mem_ck_n     = 1'b0;
    assign memory_mem_cke      = 1'b0;
    assign memory_mem_cs_n     = 1'b1;
    assign memory_mem_ras_n    = 1'b1;
    assign memory_mem_cas_n    = 1'b1;
    assign memory_mem_we_n     = 1'b1;
    assign memory_mem_reset_n  = 1'b1;
    assign memory_mem_odt      = 1'b0;
    assign memory_mem_dm       = 1'b0;
    // inouts stay undriven (high Z)

endmodule
