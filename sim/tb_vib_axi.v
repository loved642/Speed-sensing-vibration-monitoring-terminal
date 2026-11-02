`timescale 1ns/1ps
module tb_vib_axi;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0;
 tri1 scl,sda;
 reg pulse=0;
 reg[31:0] awaddr=0,wdata=0,araddr=0;
 reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
 reg[3:0] wstrb=4'hF;
 wire awready,wready,bvalid,arready,rvalid;
 wire[1:0] bresp,rresp;
 wire[31:0] rdata;
 wire pwm,in1,in2,stby,cs;
 wire miso=0;
 vib_top #(.FCLK_HZ(5_000_000),.FS_HZ(100)) dut(
  .clk(clk),.rst_n(rst_n),.spi_sclk(scl),.spi_mosi(sda),.spi_cs_n(cs),.spi_miso(miso),.pulse(pulse),
  .motor_pwm(pwm),.motor_in1(in1),.motor_in2(in2),.motor_stby(stby),
  .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
  .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
  .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
  .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
  .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
 task automatic tick; begin @(posedge clk); #1; end endtask
 task automatic read_reg(input[31:0] a,output[31:0] d);
  begin
   @(negedge clk); araddr=a;arvalid=1;
   @(posedge clk); while(!arready) @(posedge clk);
   @(negedge clk);arvalid=0;rready=0;
   while(!rvalid)tick(); repeat(4)begin tick(); if(!rvalid)$fatal(1,"missing RVALID at %h",a); end
   d=rdata;
   @(negedge clk);rready=1;tick();
   @(negedge clk);rready=0;
  end
 endtask
 reg[31:0] d;
 task automatic write_reg(input[31:0] a,input[31:0] v,input[3:0] strobes);
 begin
  @(negedge clk);awaddr=a;awvalid=1;wdata=v;wstrb=strobes;wvalid=1;
  @(posedge clk);while(!(awready && wready))@(posedge clk);
  @(negedge clk);awvalid=0;wvalid=0;
  while(!bvalid)tick();if(bresp!=0)$fatal(1,"write failed");
  @(negedge clk);bready=1;tick();@(negedge clk);bready=0;
 end endtask
 reg inject_valid=0;
 reg signed[15:0] inject_sample=0;
 task automatic samples(input integer n,input integer tone);
 integer j;
 begin
  for(j=0;j<n;j=j+1)begin
   @(negedge clk);
   if(tone==1)inject_sample=256+$rtoi(100.0*$sin(6.283185307179586*13*j/1024));
   else inject_sample=tone;
   inject_valid=1;
   @(negedge clk);inject_valid=0;repeat(127)@(negedge clk);
  end
 end endtask
 task automatic await_id(input[31:0] expected);
 integer timeout;
 begin
  timeout=0;
  while(dut.frame_id!=expected && timeout<100000)begin tick();timeout=timeout+1;end
  if(dut.frame_id!=expected)$fatal(1,"snapshot ID expected %d got %d state=%d",expected,dut.frame_id,dut.proc_state);
 end endtask
 reg[63:0] energy;
 integer hi_count;
 integer i;
 initial begin
  repeat(4)tick();rst_n=1;repeat(4)tick();
  // AW alone must not complete; then W arrives and response must hold under backpressure.
  @(negedge clk);awaddr=0;awvalid=1;
  @(posedge clk); while(!awready) @(posedge clk);
  @(negedge clk);awvalid=0;
  repeat(3)begin tick();if(bvalid)$fatal(1,"write responded without W");end
  @(negedge clk);wdata=32'h00000101;wvalid=1;
  @(posedge clk); while(!wready) @(posedge clk);
  @(negedge clk);wvalid=0;
  while(!bvalid)tick(); repeat(4)begin tick();if(!bvalid)$fatal(1,"missing held BVALID");if(bresp!=0)$fatal(1,"bad BRESP");end
  @(negedge clk);bready=1;tick();
  @(negedge clk);bready=0;
  read_reg(32'h88,d);if(d!=32'h00020002)$fatal(1,"version=%h",d);
  read_reg(32'hA8,d);if(d!=20)$fatal(1,"speed averaging depth=%d",d);
  read_reg(32'hAC,d);if(d!=0)$fatal(1,"speed window was not reset");
  read_reg(32'h00,d);if(d!=32'h00000101)$fatal(1,"CTRL=%h",d);
  // W before AW is also legal and must be buffered independently.
  @(negedge clk);wdata=32'h00000201;wvalid=1;
  @(posedge clk); while(!wready) @(posedge clk);
  @(negedge clk);wvalid=0;
  repeat(2)tick();if(bvalid)$fatal(1,"write responded without AW");
  @(negedge clk);awaddr=0;awvalid=1;
  @(posedge clk); while(!awready) @(posedge clk);
  @(negedge clk);awvalid=0;
  while(!bvalid) tick();
  @(negedge clk);bready=1;tick();
  @(negedge clk);bready=0;
  read_reg(32'h00,d);if(d!=32'h00000201)$fatal(1,"CTRL2=%h",d);
  // ARVALID held until READY, and RDATA/VALID held until RREADY.
  @(negedge clk);araddr=32'h04;arvalid=1;
  @(posedge clk); while(!arready) @(posedge clk);
  @(negedge clk);arvalid=0;
  while(!rvalid)tick(); for(i=0;i<5;i=i+1)begin tick();if(!rvalid)$fatal(1,"RVALID missing");if(rdata!=100)$fatal(1,"FS_HZ=%d",rdata);end
  @(negedge clk);rready=1;tick();
  @(negedge clk);rready=0;
  write_reg(0,0,1); // byte write must preserve selected Z axis
  read_reg(0,d);if(d!=32'h200)$fatal(1,"WSTRB did not preserve axis");
  // Sensor output injection isolates the complete digital frame/FFT/snapshot
  // path. Pin-level I2C and real pulse qualification have separate tests.
  force dut.i2c_status=32'hD;
  force dut.sample_valid=inject_valid;
  force dut.ax_z=inject_sample;
  force dut.rpm_x100=30000;
  force dut.speed_ok=1;
  write_reg(0,32'h201,15);
  samples(1024,1);await_id(1);
  read_reg(32'h20,d);if(d!=70)$fatal(1,"AC RMS=%d expected70",d);
  read_reg(32'h1C,d);if(d!=100)$fatal(1,"AC peak=%d",d);
  read_reg(32'h80,d);if(d!=256*256)$fatal(1,"mean=%d",d);
  read_reg(32'h44,d);if(d!=13)$fatal(1,"dominant bin=%d",d);
  read_reg(32'h70,d);if(d!=15)$fatal(1,"quality flags=%h",d);
  read_reg(32'h14,d);if(d!=51)$fatal(1,"frame bin1=%d",d);
  read_reg(32'h18,d);if(d!=102)$fatal(1,"frame bin2=%d",d);
  read_reg(32'h74,d);if(d!=30000)$fatal(1,"frame RPM=%d",d);
  energy=0;
  for(i=1;i<512;i=i+1)begin read_reg(32'h1000+4*i,d);energy=energy+d;end
  read_reg(32'h2C,d);if(d!=energy)$fatal(1,"spectrum/snapshot energy mismatch");
  samples(1024,-100);await_id(2);
  read_reg(32'h20,d);if(d!=0)$fatal(1,"DC affected RMS");
  read_reg(32'h1C,d);if(d!=0)$fatal(1,"DC affected peak");
  read_reg(32'h2C,d);if(d!=0)$fatal(1,"DC affected spectrum");
  read_reg(32'h80,d);if($signed(d)!=-100*256)$fatal(1,"negative mean");
  samples(512,777);write_reg(0,32'h200,15);write_reg(0,32'h201,15);
  samples(512,200);repeat(100)tick();
  if(dut.frame_id!=2 || dut.snapshot_valid)$fatal(1,"old partial frame survived restart");
  samples(512,200);await_id(3);
  read_reg(32'h80,d);if(d!=200*256)$fatal(1,"restart mixed frames");
  read_reg(32'h20,d);if(d!=0)$fatal(1,"restart DC RMS");
  if(dut.drop_count!=0)$fatal(1,"unexpected processing overrun");
  samples(512,300);force dut.i2c_status=0;repeat(5)tick();
  if(dut.snapshot_valid)$fatal(1,"sensor fault did not invalidate snapshot");
  force dut.i2c_status=13;
  samples(512,-200);repeat(100)tick();
  if(dut.frame_id!=3)$fatal(1,"sensor fault retained partial frame");
  samples(512,-200);await_id(4);
  read_reg(32'h80,d);if($signed(d)!=-200*256)$fatal(1,"sensor recovery mixed frames");
  // Half-duty, blanking, direction, watchdog and explicit rearm.
  write_reg(32'h94,500,15);
  write_reg(32'h94,32'h2C,1);read_reg(32'h94,d);if(d!=300)$fatal(1,"duty low byte merge");
  write_reg(32'h94,32'h200,2);read_reg(32'h94,d);if(d!=556)$fatal(1,"duty high byte merge");
  write_reg(32'h94,32'hFFFF0000,12);read_reg(32'h94,d);if(d!=1000)$fatal(1,"duty saturation");
  write_reg(32'h94,500,15);write_reg(32'h90,1,15);
  if(stby)$fatal(1,"missing direction blanking");
  repeat(5100)tick();if(!stby || !in1 || in2)$fatal(1,"forward motor not armed");
  hi_count=0;repeat(500)begin tick();if(pwm)hi_count=hi_count+1;end
  if(hi_count!=250)$fatal(1,"PWM duty=%d/500",hi_count);
  write_reg(32'h90,3,15);if(stby || pwm)$fatal(1,"direction change not blanked");
  repeat(5100)tick();if(!stby || in1 || !in2)$fatal(1,"reverse failed");
  repeat(5_000_010)tick();if(stby || pwm || in1 || in2)$fatal(1,"watchdog failed");
  write_reg(32'h98,1,15);repeat(20)tick();if(stby)$fatal(1,"heartbeat rearmed timed-out motor");
  write_reg(32'h90,1,15);repeat(5100)tick();if(!stby)$fatal(1,"explicit rearm failed");
  write_reg(32'h90,0,15);if(stby || pwm)$fatal(1,"stop failed");
  $display("TB_AXI: PASS AW/W, AR, backpressure, WSTRB, 4 snapshots, AC/DC, full spectrum, restart, sensor recovery, PWM and watchdog");
  $finish;
 end
 initial begin #100_000_000;$fatal(1,"TB_AXI timeout");end
endmodule
