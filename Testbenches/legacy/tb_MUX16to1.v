module tb_MUX16to1;

// Define data width
localparam DATA_WIDTH = 16;
localparam CONTROL_WIDTH = 4;

// Inputs
reg [DATA_WIDTH-1:0] input_data [15:0];
reg [CONTROL_WIDTH-1:0] control_in;

// Outputs
wire [DATA_WIDTH-1:0] out_data;

integer i;
integer j;

// Instantiate the Unit Under Test (UUT)
MUX16to1 uut (
    .in0(input_data[0]), .in1(input_data[1]), .in2(input_data[2]), .in3(input_data[3]),
    .in4(input_data[4]), .in5(input_data[5]), .in6(input_data[6]), .in7(input_data[7]),
    .in8(input_data[8]), .in9(input_data[9]), .in10(input_data[10]), .in11(input_data[11]),
    .in12(input_data[12]), .in13(input_data[13]), .in14(input_data[14]), .in15(input_data[15]),
    .control(control_in),
    .out(out_data)
);

initial begin
    $display("===== MUX16to1 Combinational Verification =====");
    
    // 1. Initialize all inputs with unique, predictable data
    for (i = 0; i < 16; i = i + 1) begin
        // Assign data where the lower 8 bits match the input index (i)
        // e.g., in0 = 0x0000, in1 = 0x0001, ..., in15 = 0x000F
        input_data[i] = {8'h00, i[7:0]};
    end
    
    $monitor("Time=%0t | Control=%b (Selects in%0d) | Input_Selected=%h | Output=%h",
             $time, control_in, control_in, input_data[control_in], out_data);

    // 2. Iterate through all 16 control states (0 to 15)
    for (j = 0; j < 16; j = j + 1) begin
        control_in = j[CONTROL_WIDTH-1:0];
        
        #5; 
        
        if (out_data !== input_data[j]) begin
            $display("ERROR: Time=%0t, Control=%d, Expected %h, Got %h", $time, j, input_data[j], out_data);
        end
    end
    
    // 3. Test a random input to ensure reactivity
    $display("\n--- Testing final reactivity ---");
    control_in = 4'b1010; // Selects in10
    
    // Change input data without changing control
    input_data[10] = 16'hFEED;
    #5; // Output should immediately change to 0xFEED
    
    $finish;
end
endmodule