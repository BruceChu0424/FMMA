// Quartus Prime Verilog Template
// True Dual Port RAM with single clock

module bram
#(parameter DATA_WIDTH=32, parameter ADDR_WIDTH=10)
(
	input [(DATA_WIDTH-1):0] data_a, data_b,
	input [(ADDR_WIDTH-1):0] addr_a, addr_b,
	input we_a, we_b, clk,
	output reg [(DATA_WIDTH-1):0] q_a, q_b
);

	// Declare the RAM variable
	reg [DATA_WIDTH-1:0] ram[2**ADDR_WIDTH-1:0];
	integer i;
	initial
	begin
		for(i=0;i<1024;i=i+1) begin
			ram[i] = i[31:0]; 
        end
		  
		  // Move 1 to r13
		  ram[8] = 32'b00000000000000001111110100000001;		  
		  // Move 4 to r12
		  ram[9] = 32'b00000000000000001111110000000100;
		  	// Move 12 to r11
		  ram[10] = 32'b00000000000000001111101100001011;
		  // Move 0 to r15
		  ram[11] = 32'b00000000000000001111111000000000;
		  // Load bram[1] (ask price) to r1
		  ram[12] = 32'b00000000000000000100000100001101;
		  // Load bram[4] (bid price) to r2
		  ram[13] = 32'b00000000000000000100001000001100;
		  // Check if bid price is higher than ask price
		  ram[14] = 32'b00000000000000000000001010110001;
		  // Jump if less than to end (bis is higher than ask)
		  ram[15] = 32'b00000000000000001100011100000010;
		  // Set r15 to 1
		  ram[16] = 32'b00000000000000001111111100000001;
		  // Jump back to start
		  ram[17] = 32'b00000000000000000100111011001011;
	end






	// Port A 
	always @ (negedge clk)
	begin
		if (we_a) 
		begin
			ram[addr_a] <= data_a;
			q_a <= data_a;
		end
		else 
		begin
			q_a <= ram[addr_a];
		end 
	end 

	// Port B 
	always @ (negedge clk)
	begin
		if (we_b) 
		begin
			ram[addr_b] <= data_b;
			q_b <= data_b;
		end
		else 
		begin
			q_b <= ram[addr_b];
		end 
	end

endmodule
