////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
//
// Behavioural replacement for the Platform
// Designer system "HPSfgpa2" (simulation only;
// Quartus compiles the real generated module).
//
// What it models, and why each part matters:
//
//  * The 4 KB dual-port on-chip RAM, 1024 x 32.
//
//  * BOTH ports.  s2 is the CPU port the top
//    level drives; s1 is the HPS port, which the
//    real system reaches through the lightweight
//    AXI bridge.  The testbench drives s1 through
//    the hps_* tasks below instead of poking the
//    ram array, so HPS and CPU accesses actually
//    contend for the same memory on the same
//    clock edges - which is the whole point of
//    testing the seqlock.
//
//  * One cycle of read latency.  The real
//    altsyncram registers the address and leaves
//    the output unregistered, so read data is
//    valid from the clock edge after the address
//    is presented.
//
//  * OLD_DATA mixed-port read-during-write: a
//    read of a word another port is writing in
//    the same cycle returns the previous
//    contents.  The generated RAM is configured
//    that way (read_during_write_mode_mixed_ports
//    = "OLD_DATA"); it used to be DONT_CARE,
//    which returns indeterminate data and makes
//    the seqlock unimplementable.
//
//  * A same-address write collision counter.  The
//    protocol says the HPS only writes the input
//    block and the CPU only writes the output
//    block, so the two ports must never write the
//    same word.  If they ever do, the hardware
//    result is undefined, so the testbench fails
//    rather than silently picking a winner.
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

    // ---- the shared RAM, zeroed at power-up ----
    // The real block is configured with no initialisation file, which
    // Quartus turns into an all-zero M10K image. Zero matters: a zero
    // word is the CPU's halt instruction, and that is what parks it
    // until the loader writes a program.
    reg [31:0] ram [0:1023];

    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1)
            ram[i] = 32'h00000000;
    end

    // ---- HPS side (port s1), driven by the testbench ----
    reg [9:0]  s1_address    = 10'd0;
    reg [31:0] s1_writedata  = 32'd0;
    reg        s1_write      = 1'b0;
    reg        s1_chipselect = 1'b0;
    reg [31:0] s1_readdata   = 32'd0;

    // ---- CPU side (port s2) ----
    reg [31:0] s2_readdata = 32'd0;

    integer rst_cnt;
    integer write_collisions;
    initial begin
        rst_cnt = 0;
        write_collisions = 0;
    end

    wire s1_wr = s1_write & s1_chipselect;
    wire s2_wr = fpga_bram_s2_write & fpga_bram_s2_chipselect
                                    & fpga_bram_s2_clken & (rst_cnt >= 8);

    always @(posedge clk_clk) begin
        if (rst_cnt < 8) rst_cnt <= rst_cnt + 1;

        // Reads are evaluated before the writes below because these are
        // non-blocking assignments: the right-hand sides all use the
        // memory contents as they were at this edge. That is exactly
        // OLD_DATA read-during-write.
        s1_readdata <= ram[s1_address];
        s2_readdata <= (rst_cnt >= 8) ? ram[fpga_bram_s2_address] : 32'h0;

        if (s1_wr) ram[s1_address] <= s1_writedata;
        if (s2_wr) ram[fpga_bram_s2_address] <= fpga_bram_s2_writedata;

        if (s1_wr && s2_wr && s1_address == fpga_bram_s2_address) begin
            write_collisions = write_collisions + 1;
            $display("ERROR (%0t): both ports wrote word %0d in the same cycle - undefined on hardware", $time, s1_address);
        end
    end

    assign fpga_bram_s2_readdata = s2_readdata;

    // ------------------------------------------------------------------
    // Tasks the testbench uses to act as the HPS.  These drive the real
    // s1 port over real clock edges rather than assigning into ram[],
    // so HPS traffic contends with the CPU exactly as it does on the
    // board.
    // ------------------------------------------------------------------

    task hps_write(input [9:0] addr, input [31:0] data);
    begin
        @(negedge clk_clk);
        s1_address    = addr;
        s1_writedata  = data;
        s1_write      = 1'b1;
        s1_chipselect = 1'b1;
        @(posedge clk_clk);
        @(negedge clk_clk);
        s1_write      = 1'b0;
        s1_chipselect = 1'b0;
    end
    endtask

    task hps_read(input [9:0] addr, output [31:0] data);
    begin
        @(negedge clk_clk);
        s1_address    = addr;
        s1_write      = 1'b0;
        s1_chipselect = 1'b1;
        @(posedge clk_clk);       // address is captured here
        @(negedge clk_clk);       // data is valid now
        data          = s1_readdata;
        s1_chipselect = 1'b0;
    end
    endtask

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
    // the inouts stay undriven

endmodule
