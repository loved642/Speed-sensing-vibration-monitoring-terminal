// Independent pin-level ADXL345 model. No access to DUT state for responses.
`timescale 1ns/1ps
module tb_adxl345_i2c;
    reg clk=0, rst_n=0, en=0;
    always #5 clk=~clk;
    wire scl, sda, cs, sample_valid;
    wire signed [15:0] ax_x, ax_y, ax_z;
    wire [7:0] devid;
    wire [31:0] status, sample_count;
    // Ideal pull-ups; slave release delay below exercises nonzero input delay.
    reg slave_low=0, hold_sda=0, hold_scl=0;
    assign (strong0, highz1) #(20,20,120) sda = (slave_low || hold_sda) ? 1'b0 : 1'bz;
    assign (strong0, highz1) scl = hold_scl ? 1'b0 : 1'bz;
    pullup(sda); pullup(scl);
    adxl345_i2c #(.STARTUP_CYCLES(1000),.RETRY_CYCLES(2000),.TIMEOUT_CYCLES(10000)) dut(
        .clk(clk),.rst_n(rst_n),.en(en),.scl(scl),.sda(sda),.cs(cs),
        .ax_x(ax_x),.ax_y(ax_y),.ax_z(ax_z),.sample_valid(sample_valid),
        .devid(devid),.i2c_status(status),.sample_count(sample_count));

    localparam RX=0, ACK_SETUP=1, ACK_CLOCK=2, ACK_END=3,
               TX=4, TX_ACK_SETUP=5, TX_ACK_CLOCK=6, TX_ACK_END=7, IGNORE=8;
    reg [3:0] model_state=IGNORE;
    reg [1:0] address_phase=0;
    reg [3:0] bits=0;
    reg [7:0] input_byte=0, output_byte=0, pointer=0;
    reg selected=0, ack_this=0, send_after_ack=0, master_ack=0;
    reg present=1;
    reg [6:0] slave_address=7'h53;
    integer nack_kind=0;
    reg [7:0] memory [0:255];
    reg scl_d=1, sda_d=1;
    wire rise=scl && !scl_d;
    wire fall=!scl && scl_d;
    wire start=scl && scl_d && sda_d && !sda;
    wire stop=scl && scl_d && !sda_d && sda;
    wire [7:0] received={input_byte[6:0],sda};
    integer errors=0, checks=0, start_count=0, stop_count=0;
    integer rx_byte_count=0, final_nacks=0, read_acks=0;
    integer samples_seen=0;
    time previous_sample=0, previous_scl_fall=0, previous_scl_rise=0;
    reg check_period=0;

    task check;
        input condition;
        input [8*100-1:0] description;
        begin
            checks=checks+1;
            if (condition!==1'b1) begin errors=errors+1; $display("TB_I2C: FAIL %0s at %0t status=%08x",description,$time,status); end
        end
    endtask
    task restart;
        begin
            @(negedge clk); en=0; rst_n=0;
            repeat(10) @(negedge clk);
            rst_n=1; en=1; previous_sample=0;
        end
    endtask
    task await_sample;
        integer timeout;
        begin
            timeout=0;
            while (!sample_valid && timeout<250000) begin @(negedge clk); timeout=timeout+1; end
            check(sample_valid,"sample arrived before timeout");
            check(devid==8'hE5,"DEVID E5");
            check(ax_x==16'h1234 && ax_y==16'h5678 && ax_z==16'h9ABC,"all six bytes including first bit assembled correctly");
            @(negedge clk);
        end
    endtask
    task await_error;
        input [3:0] expected;
        integer timeout;
        begin
            timeout=0;
            while (status[7:4]!=expected && timeout<150000) begin @(negedge clk); timeout=timeout+1; end
            check(status[7:4]==expected,"expected fault diagnostic");
            check(!status[0] && sample_count==0,"fault cannot produce initialized flag or fabricated samples");
        end
    endtask

    // The model drives ACK and TX bits ONLY on falling SCL, and holds them
    // through rising SCL. This catches the old one-bit-shifted slave model.
    always @(posedge clk) begin
        scl_d<=scl; sda_d<=sda;
        if (!rst_n) begin
            model_state<=IGNORE; slave_low<=0; selected<=0; bits<=0; address_phase<=0;
        end else if (start) begin
            model_state<=RX; bits<=0; input_byte<=0; address_phase<=0;
            selected<=0; slave_low<=0; start_count=start_count+1;
        end else if (stop) begin
            model_state<=IGNORE; slave_low<=0; selected<=0; stop_count=stop_count+1;
        end else begin
            if (rise) case(model_state)
                RX: begin
                    input_byte<=received;
                    if (bits==7) begin
                        bits<=0; model_state<=ACK_SETUP; send_after_ack<=0;
                        if (address_phase==0) begin
                            selected<=present && received[7:1]==slave_address;
                            ack_this<=present && received[7:1]==slave_address &&
                                !((nack_kind==1 && !received[0]) || (nack_kind==4 && received[0]));
                            send_after_ack<=received[0]; address_phase<=1;
                        end else if (address_phase==1) begin
                            ack_this<=selected && nack_kind!=2;
                            if (nack_kind!=2) pointer<=received;
                            address_phase<=2;
                        end else begin
                            ack_this<=selected && nack_kind!=3;
                            if (selected && nack_kind!=3) begin memory[pointer]<=received; pointer<=pointer+1'b1; end
                        end
                    end else bits<=bits+1'b1;
                end
                ACK_CLOCK: model_state<=ACK_END;
                TX: begin
                    if (bits==7) begin bits<=0; model_state<=TX_ACK_SETUP; end
                    else bits<=bits+1'b1;
                end
                TX_ACK_CLOCK: begin
                    master_ack<=!sda; model_state<=TX_ACK_END;
                    if (sda) final_nacks=final_nacks+1;
                    else read_acks=read_acks+1;
                    // DEVID is one byte; axes burst must ACK first five bytes,
                    // then NACK the sixth. Never use model state from DUT.
                    if (pointer==0 || pointer==8'h37) check(sda==1,"master NACKs final read byte");
                    else if (pointer>=8'h32 && pointer<8'h37) check(sda==0,"master ACKs intermediate read byte");
                end
                default: ;
            endcase
            if (fall) case(model_state)
                ACK_SETUP: begin slave_low<=ack_this; model_state<=ACK_CLOCK; end
                ACK_END: begin
                    if (!ack_this) begin slave_low<=0; model_state<=IGNORE; end
                    else if (send_after_ack) begin
                        output_byte<=memory[pointer]; slave_low<=!memory[pointer][7];
                        bits<=0; model_state<=TX;
                    end else begin slave_low<=0; model_state<=RX; bits<=0; end
                end
                TX: slave_low<=!output_byte[7-bits];
                TX_ACK_SETUP: begin slave_low<=0; model_state<=TX_ACK_CLOCK; end
                TX_ACK_END: begin
                    if (master_ack) begin
                        pointer<=pointer+1'b1; output_byte<=memory[pointer+1'b1];
                        slave_low<=!memory[pointer+1'b1][7]; bits<=0; model_state<=TX;
                    end else begin slave_low<=0; model_state<=IGNORE; end
                end
                default: ;
            endcase
        end
        if (en && rst_n && cs!==1'b1) check(0,"CS held high for I2C mode");
        if (sample_valid) begin
            if (check_period && previous_sample!=0) check($time-previous_sample>=1250000 && $time-previous_sample<=1250100,"800 Hz sample cadence includes transaction time");
            previous_sample=$time; samples_seen=samples_seen+1;
        end
    end
    // Pin-level minimum high/low times, independent of the command phases.
    always @(posedge scl) if (en && rst_n) begin
        if (previous_scl_fall!=0) check($time-previous_scl_fall>=1300,"SCL low time meets fast-mode minimum");
        previous_scl_rise=$time;
    end
    always @(negedge scl) if (en && rst_n) begin
        if (previous_scl_rise!=0) check($time-previous_scl_rise>=600,"SCL high time meets fast-mode minimum");
        previous_scl_fall=$time;
    end

    integer k, before_count;
    initial begin
        for (k=0;k<256;k=k+1) memory[k]=0;
        memory[0]=8'hE5; memory[8'h32]=8'h34; memory[8'h33]=8'h12;
        memory[8'h34]=8'h78; memory[8'h35]=8'h56; memory[8'h36]=8'hBC; memory[8'h37]=8'h9A;
        restart; check_period=1;
        await_sample; await_sample; await_sample;
        check(memory[8'h2C]==8'h0D && memory[8'h31]==8'h0B && memory[8'h2D]==8'h08,"sensor configuration writes acknowledged");
        check(status[0] && status[7:4]==0 && status[31:16]==0,"normal initialization without errors");
        check(sample_count==3,"sample counter increments once per burst");
        check(final_nacks>=4 && read_acks>=15,"single-byte and multibyte reads observed");
        check_period=0;
        $display("TB_I2C: normal, repeated START, burst ACK/NACK and cadence checked");
        // NACK each phase independently; then reconnect without resetting DUT.
        for(k=1;k<=4;k=k+1) begin
            nack_kind=k; restart; await_error(1);
            repeat(2000) @(negedge clk);
            check(sample_count==0,"NACK retry does not publish samples");
            nack_kind=0; await_sample;
            check(status[31:16]!=0 && status[7:4]==0,"NACK recovery preserves fault count and clears current error");
        end
        present=0; restart; await_error(1); present=1; await_sample;
        slave_address=7'h1D; restart; await_error(1); slave_address=7'h53; await_sample;
        memory[0]=8'h00; restart; await_error(4); memory[0]=8'hE5; await_sample;
        $display("TB_I2C: NACK at every TX phase, absent/wrong-address sensor, invalid ID and automatic retry checked");
        hold_sda=1; restart; await_error(2); hold_sda=0; await_sample;
        // Stuck SDA released by an unfinished slave after nine recovery clocks.
        hold_sda=1; restart;
        repeat(9) @(posedge scl);
        @(negedge scl); hold_sda=0;
        await_sample;
        hold_scl=1; restart; await_error(3); hold_scl=0; await_sample;
        // Finite clock stretching midway through a transaction must not time out.
        restart; repeat(12) @(negedge scl); hold_scl=1;
        repeat(3000) @(negedge clk); hold_scl=0;
        await_sample; check(status[31:16]==0,"finite clock stretch supported");
        $display("TB_I2C: stuck SDA, nine-clock bus recovery, SCL timeout and clock stretching checked");
        restart; repeat(10) @(negedge scl);
        @(negedge clk); en=0;
        repeat(10) @(negedge clk);
        // A slave may still hold its ACK low after an asynchronous abort.
        // The master must release its outputs; the next enable clears that bus.
        repeat(30) @(negedge clk);
        check(scl===1 && (slave_low || sda===1) && !status[0],"disable mid-byte releases master outputs and clears ready");
        before_count=sample_count;
        repeat(1000) @(negedge clk);
        check(sample_count==before_count,"disabled acquisition produces no samples");
        en=1; await_sample;
        if(errors!=0) $fatal(1,"TB_I2C: FAIL errors=%0d checks=%0d",errors,checks);
        $display("TB_I2C: PASS checks=%0d samples=%0d starts=%0d stops=%0d",checks,samples_seen,start_count,stop_count);
        $finish;
    end
    initial begin #40000000; $fatal(1,"TB_I2C: FAIL global watchdog timeout status=%08x",status); end
endmodule
