module tb_FSMMem;

// Define Parameters for FSMMem instantiation
localparam DATA_WIDTH = 16;
localparam ADDR_WIDTH = 10;

// Inputs to the FSM (Test Bench Regs)
reg clk;
reg rst;
// Input data from the simulated memory (q_a, q_b)
reg [DATA_WIDTH-1:0] q_a_in; 
reg [DATA_WIDTH-1:0] q_b_in;

// Outputs from the FSM (Test Bench Wires)
wire [DATA_WIDTH-1:0] data_a_out, data_b_out;
wire [ADDR_WIDTH-1:0] addr_a_out, addr_b_out;
wire we_a_out, we_b_out;

// Clock Generation
initial clk = 0;
always #10 clk = ~clk; // Clock period is 20 ns

// Instantiate the Unit Under Test (UUT)
FSMMem #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) uut (
    .clk(clk), 
    .rst(rst),
    
    // FSM Outputs (Memory Inputs)
    .we_a(we_a_out), 
    .we_b(we_b_out),
    .addr_a(addr_a_out), 
    .addr_b(addr_b_out),
    .data_a(data_a_out), 
    .data_b(data_b_out),
    
    // FSM Inputs (Memory Outputs)
    .q_a(q_a_in), 
    .q_b(q_b_in)
);

initial begin
    $display("===== FSMMem FSM Verification =====");

    // Setup $monitor for FSM outputs and memory inputs
    $monitor("time=%0t | State/Action: | we_a=%b, addr_a=%h, data_a=%h, q_a_in=%h | we_b=%b, addr_b=%h, data_b=%h, q_b_in=%h", 
            $time, we_a_out, addr_a_out, data_a_out, q_a_in, we_b_out, addr_b_out, data_b_out, q_b_in);

    // 1. Initial conditions
    rst = 0;
    q_a_in = 16'hFFFF; // Dummy data from memory before reset (initial read)
    q_b_in = 16'hEEEE;
    
    #5; // Wait for combinational logic to settle

    // 2. Assert and hold reset (RESET state active)
    @(negedge clk);
    $display("Current State: RESET");
    @(negedge clk); 

    // 3. Release reset. FSM moves RESET -> READ on next posedge (T=40)
    rst = 1;
    @(negedge clk);  
    
    // --- Clock Cycle 1 (State: READ) ---
    $display("--- State: READ ---");
    // FSM outputs address 0 and 1. We must supply the data to be captured on the next posedge.
    q_a_in = 16'h0000; // Assume BRAM content at address 0 is 0
    q_b_in = 16'h0001; // Assume BRAM content at address 1 is 1
    @(negedge clk); 
    
    // --- Clock Cycle 2 (State: MOD1) ---
    $display("--- State: MOD1 ---");
    // FSM is calculating readOut = readOut + 1 synchronously at posedge T=60 (0->1, 1->2)
    // q_a/q_b inputs don't matter in this state
    @(negedge clk); 
    
    // --- Clock Cycle 3 (State: WR) ---
    $display("--- State: WR (Outputs data_a=1, data_b=2) ---");
    // FSM is driving we=1 and data_a=1, data_b=2. Memory would write this.
    // The memory would return the old value until the posedge completes the write.
    q_a_in = 16'h0000; 
    q_b_in = 16'h0001;
    @(negedge clk); 
    
    // --- Clock Cycle 4 (State: READ2) ---
    $display("--- State: READ2 ---");
    // FSM is reading address 0 and 1 again. We simulate the *new* memory content.
    q_a_in = 16'h0001; // Data read back after the write
    q_b_in = 16'h0002;
    @(negedge clk); 
    
    // --- Clock Cycle 5 (State: MOD2) ---
    $display("--- State: MOD2 ---");
    // FSM is calculating readOut = readOut + 1 synchronously at posedge T=120 (1->2, 2->3)
    // q_a/q_b inputs don't matter in this state
    @(negedge clk); 
    
    // --- Clock Cycle 6 (State: WR2) ---
    $display("--- State: WR2 (Outputs data_a=2, data_b=3 to addr 2, 3) ---");
    // FSM is driving we=1, data_a=2, data_b=3, and addr=2, 3.
    // Memory would return the value at addr 0, 1 (which is 1, 2)
    q_a_in = 16'h0001; 
    q_b_in = 16'h0002;
    @(negedge clk); 

    // --- Clock Cycle 7 (State: WR2 - Final) ---
    $display("--- State: WR2 (Hold) ---");
    @(negedge clk); 

    #100;
    $finish;
end
endmodule