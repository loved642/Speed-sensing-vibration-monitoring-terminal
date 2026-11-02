// Top: speed-aware vibration monitor PL core (no PS inside).
// ADXL345 I2C -> frame buffer -> windowed FFT -> time/freq features; AXI4-Lite exposes regs + spectrum.
`timescale 1ns/1ps
module vib_top #(
    parameter FCLK_HZ = 100_000_000,
    parameter FS_HZ   = 800,
    parameter [6:0] I2C_ADDR = 7'h53,
    parameter N       = 1024,
    parameter LOGN    = 10,
    parameter SLOTS   = 20,
    parameter BAND    = 2
)(
    input  wire        clk,
    input  wire        rst_n,
    // ADXL345 I2C  (SCL->Y18, SDA->Y19, CS->Y16 held high; Y17 unused)
    inout  wire        spi_sclk,   // I2C SCL (open-drain, supports clock stretching)
    inout  wire        spi_mosi,   // I2C SDA (open-drain)
    output wire        spi_cs_n,   // held high -> I2C mode
    input  wire        spi_miso,   // unused (kept for pin compatibility)
    // photoelectric speed pulse
    input  wire        pulse,
    output wire motor_pwm, motor_in1, motor_in2, motor_stby,
    // AXI4-Lite slave
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready
);

    reg en;reg[1:0] axis_sel;reg flush;
    wire signed[15:0] ax_x,ax_y,ax_z;
    wire sample_valid;wire[7:0] devid;wire[31:0] i2c_status,sample_count;
    wire signed[15:0] sample=axis_sel==0?ax_x:axis_sel==1?ax_y:ax_z;
    wire active=en && i2c_status[0] && !flush;
    wire data_reset_n=rst_n && active;
    adxl345_i2c #(.FCLK_HZ(FCLK_HZ),.FS_HZ(FS_HZ),.ADDR7(I2C_ADDR)) u_acc(
     .clk(clk),.rst_n(rst_n),.en(en),.scl(spi_sclk),.sda(spi_mosi),.cs(spi_cs_n),
     .ax_x(ax_x),.ax_y(ax_y),.ax_z(ax_z),.sample_valid(sample_valid),.devid(devid),
     .i2c_status(i2c_status),.sample_count(sample_count));
    wire frame_ready,ft_valid;wire[47:0] raw_sumsq;wire[15:0] raw_peak;
    wire signed[31:0] frame_sum;wire signed[15:0] frame_lo,frame_hi;
    wire[9:0] rd_addr;wire[15:0] rd_data;
    frame_ctrl #(.N(N),.LOGN(LOGN)) u_frm(.clk(clk),.rst_n(rst_n),.en(active),
     .sample_valid(sample_valid),.sample(sample),.rd_addr(rd_addr),.rd_data(rd_data),
     .frame_ready(frame_ready),.ft_valid(ft_valid),.sumsq(raw_sumsq),.peak(raw_peak),
     .sample_sum(frame_sum),.minimum(frame_lo),.maximum(frame_hi));
    wire[31:0] rpm_x100,period_cyc;wire[9:0] bin1x,bin2x;wire speed_valid,speed_ok;
    wire[47:0] speed_window_cycles;wire[31:0] speed_window_count;
    speed_capture #(.FCLK_HZ(FCLK_HZ),.FS_HZ(FS_HZ),.NFFT(N),.SLOTS(SLOTS)) u_spd(
     .clk(clk),.rst_n(rst_n),.pulse(pulse),.rpm_x100(rpm_x100),.period_cyc(period_cyc),
     .bin1x(bin1x),.bin2x(bin2x),.speed_valid(speed_valid),.speed_ok(speed_ok),
     .window_cycles(speed_window_cycles),.window_count(speed_window_count));
    reg fft_start;wire fft_busy,fft_done,mag_valid,fft_overflow;
    wire[9:0] mag_bin;wire[31:0] mag_pow;
    reg signed[25:0] mean_q8;
    fft_engine #(.N(N),.LOGN(LOGN)) u_fft(.clk(clk),.rst_n(data_reset_n),.start(fft_start),
     .mean_q8(mean_q8),.busy(fft_busy),.done(fft_done),.frm_addr(rd_addr),.frm_data(rd_data),
     .mag_valid(mag_valid),.mag_bin(mag_bin),.mag_pow(mag_pow),.overflow(fft_overflow));
    reg[9:0] work_b1,work_b2;
    wire[47:0] total_e,band1_e,band2_e;wire[9:0] dom_bin;wire[31:0] dom_pow;wire feat_valid;
    freq_features #(.N(N),.BAND(BAND)) u_ff(.clk(clk),.rst_n(data_reset_n),.clear(fft_start),
     .bin1x(work_b1),.bin2x(work_b2),.mag_valid(mag_valid),.mag_bin(mag_bin),.mag_pow(mag_pow),
     .total_energy(total_e),.band1_energy(band1_e),.band2_energy(band2_e),
     .dom_bin(dom_bin),.dom_pow(dom_pow),.feat_valid(feat_valid));
    reg sqrt_start;reg[31:0] ac_mean;wire[15:0] sqrt_rms;wire sqrt_valid,sqrt_busy;
    int_sqrt u_sqrt(.clk(clk),.rst_n(data_reset_n),.start(sqrt_start),.x(ac_mean),
     .y(sqrt_rms),.valid(sqrt_valid),.busy(sqrt_busy));

    // Working data never modifies the published snapshot. Two spectrum banks.
    (* ram_style="block" *)reg[31:0] spec_mem[0:1023];
    reg published_bank;reg[31:0] spec_rd;
    always @(posedge clk)if(active && mag_valid)spec_mem[{!published_bank,mag_bin[8:0]}]<=mag_pow;
    reg[31:0] frame_id,frame_flags,drop_count;
    reg snapshot_valid;
    reg[31:0] snap_rpm,snap_period,snap_rpm_min,snap_rpm_max;
    reg[9:0] snap_b1,snap_b2,snap_dom;
    reg[15:0] snap_peak,snap_rms;
    reg[47:0] snap_sq,snap_total,snap_e1,snap_e2;
    reg[31:0] snap_pow;reg signed[25:0] snap_mean;
    reg[2:0] proc_state;
    reg[47:0] work_raw_sq,work_ac_sq;
    reg signed[31:0] work_sum;
    reg signed[15:0] work_lo,work_hi;
    reg[63:0] sum_square;
    reg[31:0] work_rpm,work_period,work_min,work_max;
    reg work_speed_ok,work_clip,work_corrupt;
    reg[31:0] work_span;
    reg[36:0] work_span20;
    reg work_steady;
    reg[15:0] work_peak,work_rms;
    reg got_rms,got_features;
    reg[63:0] rpm_acc;
    reg[31:0] rpm_min,rpm_max;
    reg all_speed_ok,clip_seen;
    localparam[63:0] BIN_K=(64'd16777216*N+3000*FS_HZ)/(6000*FS_HZ);
    reg[63:0] bin_product;
    wire[63:0] rounded_b1=(bin_product+64'd8388608)>>24;
    wire[63:0] rounded_b2=((bin_product<<1)+64'd8388608)>>24;
    wire signed[25:0] low_q8=$signed(work_lo) <<< 8,high_q8=$signed(work_hi) <<< 8;
    wire signed[26:0] low_delta=$signed(mean_q8)-$signed(low_q8);
    wire signed[26:0] high_delta=$signed(high_q8)-$signed(mean_q8);
    wire[26:0] ac_peak_q8=low_delta>high_delta?low_delta:high_delta;
    always @(posedge clk or negedge rst_n)begin
     if(!rst_n)begin
      frame_id<=0;frame_flags<=0;drop_count<=0;snapshot_valid<=0;published_bank<=0;
      proc_state<=0;fft_start<=0;sqrt_start<=0;mean_q8<=0;ac_mean<=0;
      rpm_acc<=0;rpm_min<=32'hFFFFFFFF;rpm_max<=0;all_speed_ok<=1;clip_seen<=0;
      work_raw_sq<=0;work_ac_sq<=0;work_sum<=0;work_lo<=0;work_hi<=0;sum_square<=0;
      work_rpm<=0;work_period<=0;work_min<=0;work_max<=0;work_speed_ok<=0;work_clip<=0;
      work_b1<=0;work_b2<=0;work_peak<=0;work_rms<=0;got_rms<=0;got_features<=0;work_corrupt<=0;
      work_span<=0;work_span20<=0;work_steady<=0;
      bin_product<=0;
      snap_rpm<=0;snap_period<=0;snap_rpm_min<=0;snap_rpm_max<=0;snap_b1<=0;snap_b2<=0;
      snap_dom<=0;snap_peak<=0;snap_rms<=0;snap_sq<=0;snap_total<=0;snap_e1<=0;snap_e2<=0;snap_pow<=0;snap_mean<=0;
     end else begin
      fft_start<=0;sqrt_start<=0;
      if(!active)begin
       proc_state<=0;snapshot_valid<=0;frame_flags<=0;
       rpm_acc<=0;rpm_min<=32'hFFFFFFFF;rpm_max<=0;all_speed_ok<=1;clip_seen<=0;
       got_rms<=0;got_features<=0;work_corrupt<=0;
      end else begin
       if(sample_valid)begin
        rpm_acc<=rpm_acc+rpm_x100;
        if(rpm_x100<rpm_min)rpm_min<=rpm_x100;
        if(rpm_x100>rpm_max)rpm_max<=rpm_x100;
        if(!speed_ok)all_speed_ok<=0;
        if(sample>=4090 || sample<=-4090)clip_seen<=1;
       end
       if(frame_ready)begin
        rpm_acc<=0;rpm_min<=32'hFFFFFFFF;rpm_max<=0;all_speed_ok<=1;clip_seen<=0;
        if(proc_state!=0)begin work_corrupt<=1;drop_count<=drop_count+1'b1;end
       end
       if(sqrt_valid)begin work_rms<=sqrt_rms;got_rms<=1;end
       if(feat_valid)got_features<=1;
       case(proc_state)
       0:if(frame_ready)begin
        work_raw_sq<=raw_sumsq;work_sum<=frame_sum;work_lo<=frame_lo;work_hi<=frame_hi;
        mean_q8<=frame_sum >>> (LOGN-8);
        work_rpm<=rpm_acc>>LOGN;work_period<=period_cyc;work_min<=rpm_min;work_max<=rpm_max;
        work_speed_ok<=all_speed_ok;work_clip<=clip_seen;work_corrupt<=0;
        got_rms<=0;got_features<=0;proc_state<=1;
       end
       1:begin
        sum_square<=$signed(work_sum)*$signed(work_sum);
        bin_product<=work_rpm*BIN_K;
        work_span<=work_max-work_min;proc_state<=2;
       end
       2:begin
        work_ac_sq<=work_raw_sq-(sum_square>>LOGN);
        work_peak<=(ac_peak_q8+27'd255)>>8;
        work_b1<=rounded_b1>511?511:rounded_b1[9:0];
        work_b2<=rounded_b2>511?511:rounded_b2[9:0];proc_state<=3;
        work_span20<={5'd0,work_span}*5'd20;
       end
       3:begin
        ac_mean<=work_ac_sq>>LOGN;sqrt_start<=1;fft_start<=1;proc_state<=4;
        work_steady<=work_speed_ok && work_span20<={5'd0,work_rpm};
       end
       4:if(fft_done && got_rms && got_features)begin
        if(!work_corrupt && !frame_ready)begin
         snap_rpm<=work_rpm;snap_period<=work_period;snap_rpm_min<=work_min;snap_rpm_max<=work_max;
         snap_b1<=work_b1;snap_b2<=work_b2;snap_peak<=work_peak;snap_rms<=work_rms;snap_sq<=work_ac_sq;
         snap_total<=total_e;snap_e1<=band1_e;snap_e2<=band2_e;snap_dom<=dom_bin;snap_pow<=dom_pow;snap_mean<=mean_q8;
         frame_flags<={26'd0,work_clip,fft_overflow,
          (work_b1>BAND && work_b2>work_b1+2*BAND && work_b2<512-BAND),
          work_steady,work_speed_ok,1'b1};
         frame_id<=frame_id+1'b1;snapshot_valid<=1;published_bank<=!published_bank;
        end
        proc_state<=0;
       end
       default:proc_state<=0;
       endcase
      end
     end
    end

    // Motor defaults off. Explicit arm + heartbeat, 20 kHz PWM, 1 ms direction blanking.
    localparam PWM_PERIOD=FCLK_HZ/20000;
    reg[1:0] motor_ctrl;reg[9:0] motor_duty;
    reg[31:0] motor_watch,motor_blank,pwm_count;
    wire motor_live=motor_ctrl[0] && motor_watch<FCLK_HZ && motor_blank==0;
    // Split the constant before multiplication: at 100 MHz this is just duty*5,
    // avoiding a long multiply/divide chain on the output path.
    wire[31:0] pwm_limit=(PWM_PERIOD/1000)*motor_duty +
                        ((PWM_PERIOD%1000)*motor_duty)/1000;
    assign motor_stby=motor_live;
    assign motor_in1=motor_live && !motor_ctrl[1];
    assign motor_in2=motor_live && motor_ctrl[1];
    assign motor_pwm=motor_live && pwm_count<pwm_limit;

    // One outstanding AXI write; AW/W accepted independently, byte enables respected.
    reg aw_got,w_got;reg[31:0] awaddr_r,wdata_r;reg[3:0] wstrb_r;
    reg[31:0] merged;
    reg[31:0] duty_merged;
    always @(*)begin
     s_axi_awready=rst_n && !aw_got && !s_axi_bvalid;
     s_axi_wready=rst_n && !w_got && !s_axi_bvalid;
     merged={22'd0,axis_sel,7'd0,en};
     if(wstrb_r[0])merged[7:0]=wdata_r[7:0];
     if(wstrb_r[1])merged[15:8]=wdata_r[15:8];
     duty_merged={22'd0,motor_duty};
     if(wstrb_r[0])duty_merged[7:0]=wdata_r[7:0];
     if(wstrb_r[1])duty_merged[15:8]=wdata_r[15:8];
     if(wstrb_r[2])duty_merged[23:16]=wdata_r[23:16];
     if(wstrb_r[3])duty_merged[31:24]=wdata_r[31:24];
    end
    always @(posedge clk or negedge rst_n)begin
     if(!rst_n)begin
      en<=0;axis_sel<=2;flush<=0;aw_got<=0;w_got<=0;awaddr_r<=0;wdata_r<=0;wstrb_r<=0;
      s_axi_bvalid<=0;s_axi_bresp<=0;motor_ctrl<=0;motor_duty<=0;motor_watch<=FCLK_HZ;motor_blank<=0;pwm_count<=0;
     end else begin
      flush<=0;
      if(pwm_count==PWM_PERIOD-1)pwm_count<=0;else pwm_count<=pwm_count+1'b1;
      if(motor_blank!=0)motor_blank<=motor_blank-1'b1;
      if(motor_watch<FCLK_HZ)motor_watch<=motor_watch+1'b1;else motor_ctrl[0]<=0;
      if(s_axi_awready && s_axi_awvalid)begin awaddr_r<=s_axi_awaddr;aw_got<=1;end
      if(s_axi_wready && s_axi_wvalid)begin wdata_r<=s_axi_wdata;wstrb_r<=s_axi_wstrb;w_got<=1;end
      if(s_axi_bvalid && s_axi_bready)s_axi_bvalid<=0;
      if(aw_got && w_got && !s_axi_bvalid)begin
       aw_got<=0;w_got<=0;s_axi_bvalid<=1;s_axi_bresp<=0;
       case(awaddr_r[15:0])
       16'h0000:begin
        en<=merged[0];axis_sel<=merged[9:8];
        if(merged[0]!=en || merged[9:8]!=axis_sel)flush<=1;
       end
       16'h0090:if(wstrb_r[0])begin motor_ctrl<=wdata_r[1:0];motor_watch<=0;motor_blank<=FCLK_HZ/1000;end
       16'h0094:if(|wstrb_r)motor_duty<=duty_merged>1000?1000:duty_merged[9:0];
       16'h0098:if(|wstrb_r)motor_watch<=0;
       default:s_axi_bresp<=2'b10;
       endcase
      end
     end
    end

    // Registered BRAM read; acceptance is strictly ARVALID && ARREADY.
    reg[1:0] rstate;reg[31:0] araddr_r;reg read_bank;
    reg[31:0] rdata_mux;
    always @(*)begin
     s_axi_arready=rst_n && rstate==0;
     rdata_mux=32'hDEADBEEF;
     if(araddr_r[15:0]>=16'h1000 && araddr_r[15:0]<16'h1800)rdata_mux=spec_rd;
     else case(araddr_r[15:0])
     16'h00:rdata_mux={22'd0,axis_sel,7'd0,en};
     16'h04:rdata_mux=FS_HZ;
     16'h08:rdata_mux=SLOTS;
     16'h0C:rdata_mux={27'd0,snapshot_valid,snapshot_valid,speed_ok,snapshot_valid,fft_busy};
     16'h10:rdata_mux=rpm_x100;
     16'h14:rdata_mux=snap_b1;16'h18:rdata_mux=snap_b2;
     16'h1C:rdata_mux=snap_peak;16'h20:rdata_mux=snap_rms;
     16'h24:rdata_mux=snap_sq[31:0];16'h28:rdata_mux={16'd0,snap_sq[47:32]};
     16'h2C:rdata_mux=snap_total[31:0];16'h30:rdata_mux={16'd0,snap_total[47:32]};
     16'h34:rdata_mux=snap_e1[31:0];16'h38:rdata_mux={16'd0,snap_e1[47:32]};
     16'h3C:rdata_mux=snap_e2[31:0];16'h40:rdata_mux={16'd0,snap_e2[47:32]};
     16'h44:rdata_mux=snap_dom;16'h48:rdata_mux=snap_pow;
     16'h4C:rdata_mux=period_cyc;16'h50:rdata_mux=devid;16'h54:rdata_mux=spi_miso;
     16'h58:rdata_mux=i2c_status;16'h5C:rdata_mux=sample_count;
     16'h60:rdata_mux={{16{ax_x[15]}},ax_x};16'h64:rdata_mux={{16{ax_y[15]}},ax_y};
     16'h68:rdata_mux={{16{ax_z[15]}},ax_z};16'h6C:rdata_mux=frame_id;
     16'h70:rdata_mux=frame_flags;16'h74:rdata_mux=snap_rpm;
     16'h78:rdata_mux=snap_rpm_min;16'h7C:rdata_mux=snap_rpm_max;
     16'h80:rdata_mux={{6{snap_mean[25]}},snap_mean};16'h84:rdata_mux=drop_count;
     16'h88:rdata_mux=32'h00020002;16'h8C:rdata_mux=N;
     16'h90:rdata_mux=motor_ctrl;16'h94:rdata_mux=motor_duty;
     16'h98:rdata_mux=motor_watch;16'h9C:rdata_mux={30'd0,(motor_watch>=FCLK_HZ),motor_live};
     16'hA0:rdata_mux=speed_window_cycles[31:0];
     16'hA4:rdata_mux={16'd0,speed_window_cycles[47:32]};
     16'hA8:rdata_mux=SLOTS;16'hAC:rdata_mux=speed_window_count;
     default:;
     endcase
    end
    always @(posedge clk or negedge rst_n)begin
     if(!rst_n)begin rstate<=0;araddr_r<=0;read_bank<=0;spec_rd<=0;s_axi_rdata<=0;s_axi_rvalid<=0;s_axi_rresp<=0;end
     else case(rstate)
     0:if(s_axi_arvalid && s_axi_arready)begin araddr_r<=s_axi_araddr;read_bank<=published_bank;rstate<=1;end
     1:begin spec_rd<=spec_mem[{read_bank,araddr_r[10:2]}];rstate<=2;end
     2:begin s_axi_rdata<=rdata_mux;s_axi_rresp<=0;s_axi_rvalid<=1;rstate<=3;end
     3:if(s_axi_rvalid && s_axi_rready)begin s_axi_rvalid<=0;rstate<=0;end
     endcase
    end
endmodule
