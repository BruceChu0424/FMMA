module tb_FibTop;

// Inputs
reg clk;
reg rst;
reg [3:0] select;
initial clk = 0;
always #10 clk = ~clk;

// Outputs
wire [15:0] out;
wire [4:0] Flags;
wire [6:0] sevSeg;

integer i;

// Instantiate the Unit Under Test (UUT)
FibTop uut(.displaySelect(select), .clk(clk), .rst(rst), .sevSeg(sevSeg), 
			  .aluFlagsOut(Flags), .displayVal(out));

initial begin
$display("===== Datapath Testing =====");
 $monitor("time=%0t, select=%b --> out=%h", $time, select, out);

  // Assert reset
  rst = 0;
  select = 4'b0000;
  @(negedge clk);  // hold reset through a clock edge

  // Release reset
  rst = 1;
  @(negedge clk);  // FSM will now move from RESET -> S1

  // Step through select values
  for (i = 1; i < 16; i = i + 1) begin
    @(negedge clk);
    select = i[3:0];
  end

  #100;
  $finish;
end

endmodule
