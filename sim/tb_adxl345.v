// ADXL345 SPI slave model + checks for adxl345_spi (mode 3).
// Faithful model: the slave samples MOSI on the rising edge of SCLK and
// drives MISO on the falling edge (as the real ADXL345 does in SPI mode 3).
`timescale 1ns/1ps
module tb_adxl345;
    reg clk=0, rst_n=0, en=0;
    wire spi_sclk, spi_mosi, spi_cs_n;
    reg  spi_miso=0;
    wire signed [15:0] ax_x, ax_y, ax_z;
    wire [7:0] devid;
    wire sample_valid;

    adxl345_spi #(.FCLK_HZ(100_000_000), .FS_HZ(2000)) dut(
        .clk(clk), .rst_n(rst_n), .en(en),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n), .spi_miso(spi_miso),
        .ax_x(ax_x), .ax_y(ax_y), .ax_z(ax_z), .sample_valid(sample_valid), .devid(devid));

    always #5 clk = ~clk;

    // ---------------- ADXL345 SPI slave (mode 3) ----------------
    reg [7:0] tx_sr, rx_sr;
    reg [3:0] bitcnt;
    reg [2:0] bytecnt;
    reg [7:0] cmd;
    reg [2:0] didx;
    reg [7:0] dat [0:5];
    initial begin
        dat[0]=8'h34; dat[1]=8'h12;   // DATAX0, DATAX1  -> X = 0x1234
        dat[2]=8'h78; dat[3]=8'h56;   // DATAY0, DATAY1  -> Y = 0x5678
        dat[4]=8'hBC; dat[5]=8'h9A;   // DATAZ0, DATAZ1  -> Z = 0x9ABC
    end
    wire [7:0] rx_full = {rx_sr[6:0], spi_mosi};

    always @(spi_sclk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            bitcnt<=0; bytecnt<=0; rx_sr<=0; cmd<=0; didx<=0; tx_sr<=0; spi_miso<=0;
        end else if (spi_sclk) begin
            // rising edge: sample MOSI (MSB first)
            rx_sr <= rx_full;
            if (bitcnt == 4'd7) begin
                bitcnt <= 0;
                if (bytecnt == 3'd0) begin
                    cmd <= rx_full;
                    case (rx_full)
                        8'h80: begin tx_sr <= 8'hE5; didx <= 3'd0; end // DEVID -> 0xE5
                        8'hF2: begin tx_sr <= dat[0]; didx <= 3'd1; end // multi-byte data read
                        default: tx_sr <= 8'h00;
                    endcase
                end else begin
                    if (cmd == 8'hF2) begin
                        if (didx <= 3'd5) begin tx_sr <= dat[didx]; didx <= didx + 1'b1; end
                        else tx_sr <= 8'h00;
                    end else tx_sr <= 8'h00;
                end
                bytecnt <= bytecnt + 1'b1;
            end else begin
                bitcnt <= bitcnt + 1'b1;
            end
        end else begin
            // falling edge: drive MISO (MSB first)
            spi_miso <= tx_sr[7];
            tx_sr    <= {tx_sr[6:0], 1'b0};
        end
    end

    integer errors=0;
    initial begin
        rst_n=0; repeat(10) @(posedge clk); rst_n=1; en=1;
        wait (sample_valid==1'b1);
        repeat(2) @(posedge clk);
        $display("TB_ADXL: devid=%02x  X=%04x Y=%04x Z=%04x", devid, ax_x, ax_y, ax_z);
        if (devid!==8'hE5) begin errors=errors+1; $display("  FAIL devid expected E5"); end
        if (ax_x!==16'sh1234) begin errors=errors+1; $display("  FAIL X expected 1234"); end
        if (ax_y!==16'sh5678) begin errors=errors+1; $display("  FAIL Y expected 5678"); end
        if (ax_z!==16'sh9ABC) begin errors=errors+1; $display("  FAIL Z expected 9ABC"); end
        if (errors==0) $display("TB_ADXL: PASS"); else $display("TB_ADXL: FAIL");
        $finish;
    end
endmodule
