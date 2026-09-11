////////////////////////////////////////////////
// FMMA - FPGA Market Maker Accelerator
//
// Hex digit to 7-segment decoder.
// The DE1-SoC HEX displays are common anode,
// so a segment lights when its output is 0.
// Bit order: {g, f, e, d, c, b, a}
////////////////////////////////////////////////

module decoder(in, segment_display);

// A 16-bit value is accepted for compatibility
// with the other top level files; only the
// lowest nibble is displayed.
input [15:0] in;
output reg [6:0] segment_display;

always @(*) begin
    case (in[3:0])
        4'h0: segment_display = 7'b1000000;
        4'h1: segment_display = 7'b1111001;
        4'h2: segment_display = 7'b0100100;
        4'h3: segment_display = 7'b0110000;
        4'h4: segment_display = 7'b0011001;
        4'h5: segment_display = 7'b0010010;
        4'h6: segment_display = 7'b0000010;
        4'h7: segment_display = 7'b1111000;
        4'h8: segment_display = 7'b0000000;
        4'h9: segment_display = 7'b0011000;
        4'hA: segment_display = 7'b0001000;
        4'hB: segment_display = 7'b0000011;
        4'hC: segment_display = 7'b1000110;
        4'hD: segment_display = 7'b0100001;
        4'hE: segment_display = 7'b0000110;
        4'hF: segment_display = 7'b0001110;
        default: segment_display = 7'b1111111;
    endcase
end

endmodule
