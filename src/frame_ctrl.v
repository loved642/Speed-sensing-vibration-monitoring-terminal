// Ping-pong raw frame capture. Disable discards a partial frame.
`timescale 1ns/1ps
module frame_ctrl #(parameter N=1024, LOGN=10)(
 input wire clk,rst_n,en,sample_valid,
 input wire signed [15:0] sample,
 input wire [9:0] rd_addr,
 output reg [15:0] rd_data,
 output reg frame_ready,
 output reg [47:0] sumsq,
 output reg [15:0] peak,
 output reg ft_valid,
 output reg signed [31:0] sample_sum,
 output reg signed [15:0] minimum,maximum
);
 (* ram_style="block" *) reg [15:0] mem[0:2047];
 reg ws,rs;reg[9:0] ptr;
 reg[47:0] acc;reg signed[31:0] sum;
 reg signed[15:0] lo,hi,s;
 reg[31:0] sq;reg[1:0] st;
 wire signed[31:0] wide=sample;
 wire[63:0] square=wide*wide;
 wire signed[15:0] next_lo=s<lo?s:lo,next_hi=s>hi?s:hi;
 wire[15:0] abslo=next_lo[15]?-next_lo:next_lo;
 wire[15:0] abshi=next_hi[15]?-next_hi:next_hi;
 always @(posedge clk)begin
  if(en && st==1)mem[{ws,ptr}]<=s;
  rd_data<=mem[{rs,rd_addr}];
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   ws<=0;rs<=0;ptr<=0;acc<=0;sum<=0;lo<=32767;hi<=-32768;s<=0;sq<=0;st<=0;
   frame_ready<=0;ft_valid<=0;sumsq<=0;peak<=0;sample_sum<=0;minimum<=0;maximum<=0;
  end else begin
   frame_ready<=0;ft_valid<=0;
   if(!en)begin ptr<=0;acc<=0;sum<=0;lo<=32767;hi<=-32768;st<=0;end
   else case(st)
   0:if(sample_valid)begin s<=sample;sq<=square[31:0];st<=1;end
   1:st<=2;
   2:begin
    if(ptr==1023)begin
     ptr<=0;rs<=ws;ws<=~ws;sumsq<=acc+sq;sample_sum<=sum+s;
     minimum<=next_lo;maximum<=next_hi;peak<=abslo>abshi?abslo:abshi;
     frame_ready<=1;ft_valid<=1;acc<=0;sum<=0;lo<=32767;hi<=-32768;
    end else begin ptr<=ptr+1'b1;acc<=acc+sq;sum<=sum+s;lo<=next_lo;hi<=next_hi;end
    st<=0;
   end
   default:st<=0;
   endcase
  end
 end
 // synthesis translate_off
 initial if(N!=1024 || LOGN!=10)$fatal(1,"Frame supports N=1024 only");
 // synthesis translate_on
endmodule
