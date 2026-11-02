// Qualified pulse periods, one-revolution rolling average, bounded stop detection.
`timescale 1ns/1ps
module speed_capture #(
 parameter FCLK_HZ=100_000_000, FS_HZ=800, NFFT=1024, SLOTS=20,
 parameter FILTER_CYCLES=FCLK_HZ/1_000_000,
 parameter MIN_PERIOD=FCLK_HZ/20_000,
 parameter TIMEOUT_CYCLES=FCLK_HZ,
 // Average measured periods, not their reciprocals. With AVG_PERIODS=SLOTS,
 // the sum spans one complete revolution and cancels fixed slot-pitch error.
 parameter AVG_PERIODS=SLOTS
)(
 input wire clk,rst_n,pulse,
 output reg [31:0] rpm_x100,
 output reg [9:0] bin1x,bin2x,
 output reg [31:0] period_cyc,
 output reg speed_valid,
 output reg speed_ok,
 output wire [47:0] window_cycles,
 output wire [31:0] window_count
);
 localparam FILTER=FILTER_CYCLES<2?2:FILTER_CYCLES;
 localparam AVG=AVG_PERIODS<1?1:AVG_PERIODS;
 localparam PTR_W=AVG<2?1:$clog2(AVG);
 localparam CNT_W=$clog2(AVG+1);
 localparam [47:0] NUM=48'd6000*FCLK_HZ*AVG;
 localparam [63:0] K=(64'd16777216*NFFT+3000*FS_HZ)/(6000*FS_HZ);
 (* ASYNC_REG="TRUE" *) reg[2:0] sync;
 reg level,level_d,armed;reg[31:0] qual,count;
 reg pending,start_div;reg[47:0] per;
 reg[31:0] periods[0:AVG-1];
 reg[PTR_W-1:0] write_ptr;
 reg[CNT_W-1:0] filled;
 reg[47:0] period_sum;
 wire[31:0] next_period=count+1'b1;
 wire[47:0] next_sum=period_sum+{16'd0,next_period}-
                            (filled==AVG?{16'd0,periods[write_ptr]}:48'd0);
 assign window_cycles=period_sum;
 assign window_count=filled;
 wire[47:0] quotient;wire dv,dbusy;
 reg[47:0] denominator;
 wire[63:0] scaled=quotient[31:0]*K;
 wire[63:0] nearest1=(scaled+64'd8388608)>>24;
 wire[63:0] nearest2=((scaled<<1)+64'd8388608)>>24;
 divider48 div(.clk(clk),.rst_n(rst_n),.start(start_div),.a(NUM),.b(denominator),.q(quotient),.valid(dv),.busy(dbusy));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   sync<=0;level<=0;level_d<=0;qual<=0;count<=0;armed<=0;
   rpm_x100<=0;bin1x<=0;bin2x<=0;period_cyc<=0;speed_valid<=0;speed_ok<=0;
   pending<=0;start_div<=0;per<=0;denominator<=1;
   write_ptr<=0;filled<=0;period_sum<=0;
  end else begin
   sync<={sync[1:0],pulse};level_d<=level;
   if(sync[2]==level)qual<=0;
   else if(qual==FILTER-1)begin level<=sync[2];qual<=0;end
   else qual<=qual+1'b1;
   start_div<=0;speed_valid<=0;
   if(count<TIMEOUT_CYCLES)count<=count+1'b1;
   if(pending && !dbusy && !start_div)begin
    denominator<=per*SLOTS;start_div<=1;pending<=0;
   end
   if(dv && armed && filled==AVG && count<TIMEOUT_CYCLES)begin
    rpm_x100<=|quotient[47:32]?32'hFFFFFFFF:quotient[31:0];
    bin1x<=nearest1>511?511:nearest1[9:0];
    bin2x<=nearest2>511?511:nearest2[9:0];
    speed_valid<=1;speed_ok<=1;
   end
   if(count>=TIMEOUT_CYCLES)begin
    armed<=0;pending<=0;speed_ok<=0;rpm_x100<=0;period_cyc<=0;bin1x<=0;bin2x<=0;
    write_ptr<=0;filled<=0;period_sum<=0;
   end
   if(level && !level_d)begin
    if(!armed || count>=TIMEOUT_CYCLES)begin
     armed<=1;count<=0;pending<=0;speed_ok<=0;
     write_ptr<=0;filled<=0;period_sum<=0;
    end
    else if(count>=MIN_PERIOD-1)begin
     // PERIOD_CYC remains the most recent raw slot interval for diagnosis.
     period_cyc<=next_period;count<=0;
     periods[write_ptr]<=next_period;period_sum<=next_sum;
     write_ptr<=write_ptr==AVG-1?0:write_ptr+1'b1;
     if(filled<AVG)filled<=filled+1'b1;
     if(filled>=AVG-1)begin per<=next_sum;pending<=1;end
    end
   end
  end
 end
endmodule

// 48-bit unsigned restoring divider (48/48 -> 48), 48 cycles.
`timescale 1ns/1ps
module divider48(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [47:0] a,
    input  wire [47:0] b,
    output reg  [47:0] q,
    output reg         valid,
    output reg         busy
);
    reg [47:0] rem, dvd, div;
    reg [6:0]  i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q<=0; valid<=0; busy<=0; rem<=0; i<=0; dvd<=0; div<=1;
        end else begin
            valid<=0;
            if (!busy) begin
                if (start && b!=0) begin
                    busy<=1; dvd<=a; div<=b; rem<=0; q<=0; i<=48;
                end
            end else begin
                if (i==0) begin busy<=0; valid<=1; end
                else begin
                    rem = {rem[46:0], dvd[47]};
                    dvd = {dvd[46:0], 1'b0};
                    q   = {q[46:0], 1'b0};
                    if (rem >= div) begin rem = rem - div; q[0]=1'b1; end
                    i <= i-1;
                end
            end
        end
    end
endmodule
