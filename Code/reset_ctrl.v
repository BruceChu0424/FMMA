////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
//
// reset_ctrl - the CPU's reset source.
//
// Two things can reset the CPU:
//
//   power-on   a counter holds reset for 16 clocks after the FPGA is
//              configured, then releases it for good
//   KEY[0]     the DE1-SoC push buttons are active low; holding one
//              keeps the CPU in reset, which is what makes a demo
//              repeatable without reconfiguring the device
//
// The original design had no external reset at all, so the only way to
// restart the CPU was to reprogram the FPGA. That also made per-test
// reset impossible in simulation.
//
// The button is asynchronous to CLOCK_50 and it bounces, so it goes
// through two synchroniser flops before it reaches anything. Bounce
// itself needs no filtering here: every bounce edge just extends the
// reset, and the counter re-arms on release.
//
// Two polarities come out because the CPU is inherited lab code: the
// register bank, PC, IR and flag register take an active-high reset
// and the control FSM takes an active-low one.
////////////////////////////////////////////////

module reset_ctrl (
    input  wire clk,
    input  wire key_n,        // active-low button, asynchronous
    output wire rst_high,     // for the registers
    output wire rst_low_n     // for the control FSM
);

    // Two-stage synchroniser. Powers up at 1 (not pressed) so a
    // metastable first sample cannot look like a press.
    reg [1:0] key_sync = 2'b11;
    always @(posedge clk)
        key_sync <= {key_sync[0], key_n};

    // Power-on counter. Held at zero while the button is down, so the
    // full 16-clock release delay applies again after every press.
    reg [4:0] por_cnt = 5'd0;
    always @(posedge clk) begin
        if (!key_sync[1])
            por_cnt <= 5'd0;
        else if (!por_cnt[4])
            por_cnt <= por_cnt + 5'd1;
    end

    wire active = ~por_cnt[4] | ~key_sync[1];

    assign rst_high  =  active;
    assign rst_low_n = ~active;

endmodule
