// Integer square root, sequential, 32-bit -> 16-bit (floor).
`timescale 1ns/1ps
module int_sqrt(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [31:0] x,
    output reg  [15:0] y,
    output reg         valid,
    output reg         busy
);
    reg [31:0] rem;
    reg [31:0] root;
    reg [31:0] bitpos;
    reg [5:0]  i;
    // Acquisition-local clear is sampled on clk, not routed as an async reset.
    always @(posedge clk) begin
        if (!rst_n) begin
            y<=0; valid<=0; busy<=0; rem<=0; root<=0; bitpos<=0; i<=0;
        end else begin
            valid<=0;
            if (!busy) begin
                if (start) begin
                    busy<=1; rem<=x; root<=0; bitpos<=32'h40000000; i<=16;
                end
            end else begin
                if (i==0) begin
                    busy<=0; valid<=1; y<=root[15:0];
                end else begin
                    if (rem >= (root + bitpos)) begin
                        rem  <= rem - (root + bitpos);
                        root <= (root >> 1) + bitpos;
                    end else begin
                        root <= root >> 1;
                    end
                    bitpos <= bitpos >> 2;
                    i <= i-1;
                end
            end
        end
    end
endmodule
