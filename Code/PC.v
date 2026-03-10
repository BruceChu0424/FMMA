////////////////////////////////////////////////
// ECE 3710
// Group 1011
// October, 27 2025
// 
// Program Counter Design
//
////////////////////////////////////////////////

module PC(in, out, clk, rst, enable);

// Input for the in value of the PC
input [9:0] in;
// Inputs to enable and rst PC
input rst, clk, enable;

// An output for the out value
output reg [9:0] out;

// Always run of the negative edge of the clock
	always @(negedge clk)
    begin
        // If rst is set, rst the reg to 0

		// non blocking assignment for sequential 
        if(rst) out <= 10'b0000001000;

        else begin
            if(enable) out <= in;
        end
    end

endmodule
