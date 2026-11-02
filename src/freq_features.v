// Frequency-domain features from the FFT magnitude stream:
//   total energy, band energy around 1x and 2x rotation bins, dominant bin.
// Stream is bins 0..N/2-1; latched when the last bin arrives.
`timescale 1ns/1ps
module freq_features #(
    parameter N = 1024,
    parameter BAND = 2          // half-width in bins
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,           // new frame
    input  wire [9:0]  bin1x,
    input  wire [9:0]  bin2x,
    input  wire        mag_valid,
    input  wire [9:0]  mag_bin,
    input  wire [31:0] mag_pow,
    output reg  [47:0] total_energy,
    output reg  [47:0] band1_energy,
    output reg  [47:0] band2_energy,
    output reg  [9:0]  dom_bin,
    output reg  [31:0] dom_pow,
    output reg         feat_valid
);
    wire in_b1 = (mag_bin >= (bin1x>BAND ? bin1x-BAND : 0)) &&
                 (mag_bin <= bin1x+BAND);
    wire in_b2 = (mag_bin >= (bin2x>BAND ? bin2x-BAND : 0)) &&
                 (mag_bin <= bin2x+BAND);

    // Synchronous local flush, matching the FFT pipeline.
    always @(posedge clk) begin
        if (!rst_n) begin
            total_energy<=0; band1_energy<=0; band2_energy<=0;
            dom_bin<=0; dom_pow<=0; feat_valid<=0;
        end else begin
            feat_valid<=0;
            if (clear) begin
                total_energy<=0; band1_energy<=0; band2_energy<=0;
                dom_bin<=0; dom_pow<=0;
            end else if (mag_valid) begin
                // Remove residual rounded DC from all vibration features.
                if (mag_bin != 0) begin
                total_energy <= total_energy + mag_pow;
                if (in_b1) band1_energy <= band1_energy + mag_pow;
                if (in_b2) band2_energy <= band2_energy + mag_pow;
                if (mag_pow > dom_pow) begin
                    dom_pow <= mag_pow;
                    dom_bin <= mag_bin;
                end
                end
                if (mag_bin == N/2-1) feat_valid <= 1;
            end
        end
    end
endmodule
