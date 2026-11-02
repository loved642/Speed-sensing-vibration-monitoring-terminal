`timescale 1ns/1ps
module tb_speed;
 reg clk=0,rst_n=0,pulse=0;always #5 clk=~clk;
 wire[31:0] rpm,period;wire[9:0] b1,b2;wire valid,ok;
 speed_capture #(.FCLK_HZ(1000000),.FS_HZ(800),.AVG_PERIODS(1),.FILTER_CYCLES(4),.MIN_PERIOD(50),.TIMEOUT_CYCLES(20000)) dut(
 .clk(clk),.rst_n(rst_n),.pulse(pulse),.rpm_x100(rpm),.period_cyc(period),.bin1x(b1),.bin2x(b2),.speed_valid(valid),.speed_ok(ok));
 task edgepulse;begin pulse=1;repeat(100)@(negedge clk);pulse=0;repeat(9900)@(negedge clk);end endtask
 reg legacy_done=0,average_done=0;
 initial begin
 repeat(20)@(negedge clk);rst_n=1;
 pulse=1;@(negedge clk);pulse=0;repeat(100)@(negedge clk);
 if(ok || period!=0)$fatal(1,"TB_SPEED: FAIL glitch");
 edgepulse;
 if(ok)$fatal(1,"TB_SPEED: FAIL first edge produced speed");
 edgepulse;
 if(!ok || rpm!=30000 || period!=10000 || b1!=6 || b2!=13)$fatal(1,"TB_SPEED: FAIL running rpm=%0d period=%0d bins=%0d,%0d",rpm,period,b1,b2);
 repeat(21000)@(negedge clk);
 if(ok || rpm!=0 || period!=0)$fatal(1,"TB_SPEED: FAIL stale stop");
 edgepulse;if(ok)$fatal(1,"TB_SPEED: FAIL first edge after stop");
 edgepulse;if(!ok || rpm!=30000)$fatal(1,"TB_SPEED: FAIL restart");
 legacy_done=1;
 end

 // A full mechanical revolution contains fixed slot-pitch variation. Verify
 // time-domain averaging, warm-up, sliding updates and a real speed change.
 reg avg_reset=0,avg_pulse=0;
 wire[31:0] avg_rpm,raw_period,filled;
 wire[47:0] window_cycles;
 wire avg_valid,avg_ok;
 speed_capture #(.FCLK_HZ(1000000),.FS_HZ(800),.FILTER_CYCLES(4),
                 .MIN_PERIOD(50),.TIMEOUT_CYCLES(20000)) avg_dut(
 .clk(clk),.rst_n(avg_reset),.pulse(avg_pulse),.rpm_x100(avg_rpm),
 .period_cyc(raw_period),.bin1x(),.bin2x(),.speed_valid(avg_valid),.speed_ok(avg_ok),
 .window_cycles(window_cycles),.window_count(filled));
 task avg_edge_after(input integer interval);
 begin
  repeat(interval-100)@(negedge clk);
  avg_pulse=1;repeat(100)@(negedge clk);avg_pulse=0;
 end endtask
 integer n;
 initial begin
  repeat(20)@(negedge clk);avg_reset=1;
  // Sub-filter glitch must not arm the period measurement.
  avg_pulse=1;@(negedge clk);avg_pulse=0;repeat(100)@(negedge clk);
  if(avg_dut.armed || avg_ok || filled!=0)$fatal(1,"TB_SPEED: FAIL averaged glitch");
  avg_pulse=1;repeat(100)@(negedge clk);avg_pulse=0;
  if(avg_ok || filled!=0)$fatal(1,"TB_SPEED: FAIL average first edge");
  for(n=1;n<=40;n=n+1)begin
   avg_edge_after(n%2?9000:11000);
   if(raw_period!=(n%2?9000:11000))$fatal(1,"TB_SPEED: FAIL raw diagnostic period");
   if(n<20)begin
    if(avg_ok || avg_rpm!=0 || filled!=n)$fatal(1,"TB_SPEED: FAIL incomplete averaging window n=%d",n);
   end else begin
    if(!avg_ok || avg_rpm!=30000 || filled!=20 || window_cycles!=200000)
     $fatal(1,"TB_SPEED: FAIL slot pitch cancellation n=%d rpm=%d sum=%d",n,avg_rpm,window_cycles);
   end
  end
  // Full step response must converge after exactly twenty new intervals.
  for(n=1;n<=20;n=n+1)begin
   avg_edge_after(8000);
   if(!avg_ok || avg_rpm<30000 || avg_rpm>37500)$fatal(1,"TB_SPEED: FAIL step bounds");
  end
  if(avg_rpm!=37500 || window_cycles!=160000)$fatal(1,"TB_SPEED: FAIL real speed change");
  repeat(21000)@(negedge clk);
  if(avg_ok || avg_rpm!=0 || raw_period!=0 || filled!=0 || window_cycles!=0)
   $fatal(1,"TB_SPEED: FAIL average timeout retained history");
  avg_pulse=1;repeat(100)@(negedge clk);avg_pulse=0;
  for(n=1;n<=20;n=n+1)begin
   avg_edge_after(5000);
   if(n<20 && (avg_ok || avg_rpm!=0))$fatal(1,"TB_SPEED: FAIL restart published before fresh full window");
  end
  if(!avg_ok || avg_rpm!=60000 || window_cycles!=100000)
   $fatal(1,"TB_SPEED: FAIL average restart");
  average_done=1;
 end
 initial begin
  wait(legacy_done && average_done);
  $display("TB_SPEED: PASS raw mode, first edge, glitch, bins, full-turn warm-up, slot pitch cancellation, true speed step, stop and fresh restart");
  $finish;
 end
 initial begin #12000000;$fatal(1,"TB_SPEED: FAIL watchdog");end
endmodule
