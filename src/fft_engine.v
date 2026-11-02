// 1024-point radix-2 DIT: bit-reversed input, natural-order positive spectrum.
// Internal complex values are signed 26-bit Q8; each butterfly scales by 1/2.
// Output power is counts^2 * 256, rounded and saturated (overflow is reported).
`timescale 1ns/1ps
module fft_engine #(parameter N=1024, LOGN=10)(
 input wire clk, rst_n, start,
 input wire signed [25:0] mean_q8,
 output reg busy, done,
 output reg [9:0] frm_addr,
 input wire [15:0] frm_data,
 output reg mag_valid,
 output reg [9:0] mag_bin,
 output reg [31:0] mag_pow,
 output reg overflow
);
 localparam IDLE=0, LD0=1, LD1=2, LD2=3, LD3=4,
 A0=5,A1=6,A2=7,B1=8,B2=9,MUL=10,ROT=11,WA=12,WB=13,NEXT=14,
 O0=15,O1=16,O2=17,O3=18,O4=19,FIN=20,LD_MUL=21,LD_ROUND=22;
 (* rom_style="block" *) reg [31:0] twrom[0:511];
 (* rom_style="block" *) reg [15:0] wrom[0:1023];
 initial $readmemh("twiddle.mem",twrom);
 initial $readmemh("hann.mem",wrom);
 (* ram_style="block" *) reg [51:0] mem[0:1023];
 reg [9:0] ra,wa,ta,wn,ld,grp,jj,half,k;
 reg [51:0] wd;
 (* keep="true" *) reg [51:0] rd;
 reg we;
 reg [31:0] tw;
 reg [15:0] win;
 reg [4:0] st;
 reg [3:0] stage;
 reg signed [25:0] ar,ai,br,bi;
 reg signed [15:0] tr,ti;
 reg signed [41:0] p0,p1,p2,p3;
 reg signed [26:0] rr,ri;
 reg [51:0] mr,mi;
 reg signed [25:0] centered_r;
 reg signed [42:0] window_product;
 wire signed [25:0] fr=$signed(frm_data);
 wire signed [25:0] centered=(fr <<< 8)-mean_q8;
 wire signed [16:0] win_signed=$signed({1'b0,win});
 wire signed [42:0] wp=centered_r*win_signed;
 wire signed [25:0] wv=(window_product+43'sd16384) >>> 15;
 wire signed [42:0] rot_r=$signed(p0)-$signed(p1);
 wire signed [42:0] rot_i=$signed(p2)+$signed(p3);
 wire signed [26:0] sumr=$signed(ar)+rr, sumi=$signed(ai)+ri;
 wire signed [26:0] difr=$signed(ar)-rr, difi=$signed(ai)-ri;
 wire signed [25:0] outr=(sumr+27'sd1) >>> 1, outi=(sumi+27'sd1) >>> 1;
 wire signed [25:0] downr=(difr+27'sd1) >>> 1, downi=(difi+27'sd1) >>> 1;
 wire signed [25:0] rd_re=rd[25:0], rd_im=rd[51:26];
 wire [52:0] power_sum={1'b0,mr}+{1'b0,mi}+53'd128;
 function [9:0] reverse;
 input [9:0] x; integer i;
 begin for(i=0;i<10;i=i+1) reverse[i]=x[9-i]; end
 endfunction
 always @(posedge clk) begin
  if(we) mem[wa]<=wd;
  rd<=mem[ra];tw<=twrom[ta];win<=wrom[wn];
 end
 // Local acquisition flush is synchronous; never drive arithmetic state async
 // reset pins from a LUT combining enable, sensor readiness and axis changes.
 always @(posedge clk) begin
  if(!rst_n) begin
   st<=IDLE;busy<=0;done<=0;mag_valid<=0;mag_bin<=0;mag_pow<=0;overflow<=0;
   ra<=0;wa<=0;ta<=0;wn<=0;ld<=0;grp<=0;jj<=0;half<=1;k<=0;stage<=0;
   frm_addr<=0;we<=0;wd<=0;ar<=0;ai<=0;br<=0;bi<=0;tr<=0;ti<=0;
   p0<=0;p1<=0;p2<=0;p3<=0;rr<=0;ri<=0;mr<=0;mi<=0;
   centered_r<=0;window_product<=0;
  end else begin
   done<=0;mag_valid<=0;we<=0;
   case(st)
   IDLE:if(start) begin busy<=1;overflow<=0;ld<=0;st<=LD0;end
   LD0:begin frm_addr<=ld;wn<=ld;st<=LD1;end
   LD1:st<=LD2;
   LD2:begin centered_r<=centered;st<=LD_MUL;end
   LD_MUL:begin window_product<=wp;st<=LD_ROUND;end
   LD_ROUND:begin we<=1;wa<=reverse(ld);wd<={26'd0,wv};st<=LD3;end
   LD3:if(ld==1023)begin stage<=0;half<=1;grp<=0;jj<=0;st<=A0;end
       else begin ld<=ld+1'b1;st<=LD0;end
   A0:begin ra<=grp+jj;ta<=jj<<(9-stage);st<=A1;end
   A1:st<=A2;
   A2:begin ar<=rd_re;ai<=rd_im;tr<=tw[15:0];ti<=tw[31:16];ra<=grp+jj+half;st<=B1;end
   B1:st<=B2;
   B2:begin br<=rd_re;bi<=rd_im;st<=MUL;end
   MUL:begin p0<=br*tr;p1<=bi*ti;p2<=br*ti;p3<=bi*tr;st<=ROT;end
   ROT:begin rr<=(rot_r+43'sd16384)>>>15;ri<=(rot_i+43'sd16384)>>>15;st<=WA;end
   WA:begin we<=1;wa<=grp+jj;wd<={outi,outr};st<=WB;end
   WB:begin we<=1;wa<=grp+jj+half;wd<={downi,downr};st<=NEXT;end
   NEXT:if(jj==half-1)begin
     jj<=0;
     if(({1'b0,grp}+({1'b0,half}<<1))>=1024)begin
      if(stage==9)begin k<=0;st<=O0;end
      else begin stage<=stage+1'b1;half<=half<<1;grp<=0;st<=A0;end
     end else begin grp<=grp+(half<<1);st<=A0;end
    end else begin jj<=jj+1'b1;st<=A0;end
   O0:begin ra<=k;st<=O1;end
   O1:st<=O2;
   O2:begin mr<=rd_re*rd_re;mi<=rd_im*rd_im;st<=O3;end
   O3:begin
     mag_bin<=k;mag_pow<=|power_sum[52:40]?32'hFFFFFFFF:power_sum[39:8];
     if(|power_sum[52:40])overflow<=1;
     mag_valid<=1;st<=O4;
    end
   O4:if(k==511)st<=FIN;else begin k<=k+1'b1;st<=O0;end
   FIN:begin busy<=0;done<=1;st<=IDLE;end
   default:st<=IDLE;
   endcase
  end
 end
 // synthesis translate_off
 initial if(N!=1024 || LOGN!=10)$fatal(1,"FFT supports N=1024 LOGN=10 only");
 // synthesis translate_on
endmodule
