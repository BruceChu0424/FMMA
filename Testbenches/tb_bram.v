module tb_bram;

localparam DATA_WIDTH = 16;
localparam ADDR_WIDTH = 10;
localparam ADDR_RANGE = 2**ADDR_WIDTH; // 1024

// Inputs
reg clk;
reg [DATA_WIDTH-1:0] data_a_in, data_b_in;
reg [ADDR_WIDTH-1:0] addr_a_in, addr_b_in;
reg we_a_in, we_b_in;

// Outputs
wire [DATA_WIDTH-1:0] q_a_out, q_b_out;


initial clk = 0;
always #10 clk = ~clk;

// Instantiate the Unit Under Test (UUT)
bram #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) uut (
    .clk(clk),
    .data_a(data_a_in),
    .data_b(data_b_in),
    .addr_a(addr_a_in),
    .addr_b(addr_b_in),
    .we_a(we_a_in),
    .we_b(we_b_in),
    .q_a(q_a_out),
    .q_b(q_b_out)
);

initial begin
    $display("===== True Dual Port BRAM Verification =====");
    $monitor("Time=%0t | W_A=%b, Addr_A=%h, Data_A=%h, Q_A=%h | W_B=%b, Addr_B=%h, Data_B=%h, Q_B=%h", 
             $time, we_a_in, addr_a_in, data_a_in, q_a_out, we_b_in, addr_b_in, data_b_in, q_b_out);

    // 1. Initial State (Read Cycle)
    we_a_in = 1'b0;
    we_b_in = 1'b0;
    data_a_in = 16'h0000;
    data_b_in = 16'h0000;


    addr_a_in = 10'h000;
    addr_b_in = 10'h001;

    #5; 
	 
    $display("\n--- Step 1: Initial Read Check (Verify Initialization) ---");
    @(posedge clk);
    $display("INFO: Reading Address 0 (Expected 0) on Port A and Address 1 (Expected 1) on Port B.");
    
    // 2. Dual Write Cycle
    $display("\n--- Step 2: Dual Write (Simultaneous Write) ---");

    we_a_in = 1'b1;
    we_b_in = 1'b1;
    
    addr_a_in = 10'h010;       
    data_a_in = 16'hDEAD;      
    
    addr_b_in = 10'h011;       
    data_b_in = 16'hBEEF; 

    @(posedge clk); 

    // 3. Dual Read Cycle (Verify Write)
    $display("\n--- Step 3: Dual Read (Verify simultaneous write) ---");
    
 
    we_a_in = 1'b0;
    we_b_in = 1'b0;
    
    @(posedge clk);

    // 4. Simultaneous write to the same address (should be bad)
    $display("\n--- Step 4: Contention Write (Write to Addr 0x010 on both ports) ---");
    
    we_a_in = 1'b1;
    we_b_in = 1'b1;
    

    addr_a_in = 10'h010;
    data_a_in = 16'hCAFE;
    
    addr_b_in = 10'h010; 
    data_b_in = 16'h5A5A;

    @(posedge clk); 

    $display("\n--- Step 5: Contention Read (Verify resulting value) ---");

    we_a_in = 1'b0;
    we_b_in = 1'b0;
    
    addr_a_in = 10'h010; 
    addr_b_in = 10'h010;

    @(posedge clk); 

    #100;
end
endmodule