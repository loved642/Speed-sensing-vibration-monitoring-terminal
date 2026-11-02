`timescale 1ns/1ps
module tb_fft;
 reg clk=0,rst_n=0,start=0;always #5 clk=~clk;
 wire busy,done,mv,overflow;wire[9:0] fa,mb;wire[31:0] mp;
 reg[15:0] fd;reg[15:0] frames[0:12287];
 reg signed[25:0] mean_q8;integer ci=0,f,i,ss,count,feature_count;
 wire[47:0] total,b1,b2;wire[9:0] dom;wire[31:0] dp;wire fv;
 always @(posedge clk)fd<=frames[ci*1024+fa];
 fft_engine dut(.clk(clk),.rst_n(rst_n),.start(start),.mean_q8(mean_q8),.busy(busy),.done(done),.frm_addr(fa),.frm_data(fd),.mag_valid(mv),.mag_bin(mb),.mag_pow(mp),.overflow(overflow));
 freq_features ff(.clk(clk),.rst_n(rst_n),.clear(start),.bin1x(10'd17),.bin2x(10'd34),.mag_valid(mv),.mag_bin(mb),.mag_pow(mp),.total_energy(total),.band1_energy(b1),.band2_energy(b2),.dom_bin(dom),.dom_pow(dp),.feat_valid(fv));
 always @(posedge clk)begin
  if(mv)begin
   if(mb!==count)$fatal(1,"TB_FFT: FAIL expected bin %0d got %0d",count,mb);
   $fwrite(f,"%0d,%0d,%0d\n",ci,mb,mp);count=count+1;
  end
  if(fv)feature_count=feature_count+1;
 end
 initial begin
  $readmemh("numeric_frames.mem",frames);f=$fopen("fft_actual.csv","w");
  repeat(20)@(negedge clk);rst_n=1;
  for(ci=0;ci<12;ci=ci+1)begin
   ss=0;for(i=0;i<1024;i=i+1)ss=ss+$signed(frames[ci*1024+i]);
   mean_q8=ss>>>2;count=0;feature_count=0;
   @(negedge clk);start=1;@(negedge clk);start=0;
   wait(done);repeat(5)@(negedge clk);
   if(count!=512 || feature_count!=1 || overflow)$fatal(1,"TB_FFT: FAIL count=%0d complete=%0d overflow=%0d",count,feature_count,overflow);
  end
  $fclose(f);$display("TB_FFT: PASS 12 frames, all bins, one completion per frame");$finish;
 end
 initial begin #15000000;$fatal(1,"TB_FFT: FAIL watchdog");end
endmodule
