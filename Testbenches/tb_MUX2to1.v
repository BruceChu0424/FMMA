module tb_MUX2to1;

// Define data width
localparam DATA_WIDTH = 16;

// Inputs
reg [DATA_WIDTH-1:0] in0_data, in1_data;
reg control_in;

// Outputs
wire [DATA_WIDTH-1:0] out_data;

// Instantiate the Unit Under Test (UUT)
MUX2to1 uut (
    .in0(in0_data),
    .in1(in1_data),
    .control(control_in),
    .out(out_data)
);

initial begin
    $display("===== MUX2to1 Combinational Verification =====");
    
    $monitor("Time=%0t | Control=%b | in0=%h, in1=%h | Output=%h",
             $time, control_in, in0_data, in1_data, out_data);

    // Initial values
    in0_data = 16'hAAAA;
    in1_data = 16'h5555;
    
    // --- Test Case 1: Control = 0 (Select in0) ---
    control_in = 1'b0;
    #5;
    $display("--- Test 1: Control = 0. Output should be AAAA ---");
    
    // --- Test Case 2: Control = 1 (Select in1) ---
    control_in = 1'b1;
    #5;
    $display("--- Test 2: Control = 1. Output should be 5555 ---");
    
    // --- Test Case 3: Control = 1, but change inputs (Test Reactivity) ---
    in0_data = 16'hCAFE;
    in1_data = 16'hBEEF;
    #5;
    $display("--- Test 3: Control = 1. Output should be BEEF ---");

    // --- Test Case 4: Control = 0, keep new inputs ---
    control_in = 1'b0;
    #5;
    $display("--- Test 4: Control = 0. Output should be CAFE ---");

    $finish;
end
endmodule