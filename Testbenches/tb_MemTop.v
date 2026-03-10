module tb_MemTop;

// Inputs to the system
reg clk;
reg rst;
initial clk = 0;
always #10 clk = ~clk;

// Wires connecting MemTop's exposed ports
wire we_a, we_b;
wire [9:0] addr_a, addr_b;
wire [15:0] data_a, data_b;
wire [15:0] q_a, q_b;

// Instantiate the Unit Under Test (UUT)
MemTop uut(
    .clk(clk), 
    .rst(rst),
    .we_a(we_a), 
    .we_b(we_b),
    .addr_a(addr_a), 
    .addr_b(addr_b),
    .data_a(data_a), 
    .data_b(data_b),
    .q_a(q_a), 
    .q_b(q_b)
);

initial begin
    $display("===== Memory FSM Testing =====");

    // Setup $monitor for memory traffic
    $monitor("time=%0t | we_a=%b, addr_a=%h, data_a=%h, q_a=%h | we_b=%b, addr_b=%h, data_b=%h, q_b=%h", 
            $time, we_a, addr_a, data_a, q_a, we_b, addr_b, data_b, q_b);

    // Initial stabilization delay
    #5; 

    // Assert reset
    rst = 0;
    @(negedge clk);
    
    // T=30. Hold reset through a clock edge
    @(negedge clk); 

    // T=50. Release reset. FSM moves to READ on the next posedge (T=60)
    rst = 1;
    @(negedge clk);  
    
    $display("--- State: READ (Outputs set for READ) ---"); // T=50. FSM is in RESET but outputs are already READ
    @(negedge clk); // T=70. PosEdge at T=60: State changes to MOD1, Q_A=0, Q_B=1 captured. FSM outputs address 0, 1.
    
    $display("--- State: MOD1 (readOut calculates 1 and 2) ---");
    @(negedge clk); // T=90. PosEdge at T=80: State changes to WR, readOut_a=1, readOut_b=2 calculated. FSM outputs address 0, 1.
    
    $display("--- State: WR (Writing 1 and 2 to 0 and 1) ---");
    @(negedge clk); // T=110. PosEdge at T=100: State changes to READ2, write 1 and 2 occurs. FSM outputs address 0, 1.
    
    $display("--- State: READ2 (Q_A=1, Q_B=2 captured on posedge) ---");
    @(negedge clk); // T=130. PosEdge at T=120: State changes to MOD2, Q_A=1, Q_B=2 captured. FSM outputs address 0, 1.
    
    $display("--- State: MOD2 (readOut calculates 2 and 3) ---");
    @(negedge clk); // T=150. PosEdge at T=140: State changes to WR2, readOut_a=2, readOut_b=3 calculated. FSM outputs address 0, 1.
    
    $display("--- State: WR2 (Writing 2 and 3 to 2 and 3) ---");
    @(negedge clk); // T=170. PosEdge at T=160: State remains WR2, write 2 and 3 occurs. FSM outputs address 2, 3.

    $display("--- State: WR2 (Final observation) ---");
    @(negedge clk); 
    
    #100;
    $finish;
end
endmodule
