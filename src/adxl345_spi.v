// ADXL345 I2C front-end. Historical filename retained for existing projects.
// SDO=0 selects 7'h53; CS must be HIGH. Both bus wires need external pull-ups.
`timescale 1ns/1ps
module adxl345_i2c #(
    parameter integer FCLK_HZ = 100_000_000,
    parameter integer FS_HZ = 800,
    parameter integer SCL_HZ = 400_000,
    parameter [6:0] ADDR7 = 7'h53,
    parameter integer STARTUP_CYCLES = FCLK_HZ / 100,
    parameter integer RETRY_CYCLES = FCLK_HZ / 100,
    parameter integer TIMEOUT_CYCLES = FCLK_HZ / 1000
)(
    input wire clk, rst_n, en,
    inout wire scl, sda,
    output wire cs,
    output reg signed [15:0] ax_x, ax_y, ax_z,
    output reg sample_valid,
    output reg [7:0] devid,
    // [0] ready, [1] busy, [2] SCL, [3] SDA, [7:4] last error,
    // [15:8] failed transaction/step, [31:16] saturating error count.
    output wire [31:0] i2c_status,
    output reg [31:0] sample_count
);
    localparam integer PERIOD = FCLK_HZ / FS_HZ;
    localparam integer RATE_Q = (FCLK_HZ + 4*SCL_HZ - 1) / (4*SCL_HZ);
    // Meet tLOW >= 1.3 us in fast mode, 4.7 us in standard mode.
    localparam integer LOW_Q = (SCL_HZ > 100_000) ?
        ((FCLK_HZ / 1000 * 13 + 19999) / 20000) :
        ((FCLK_HZ / 1000 * 47 + 19999) / 20000);
    localparam integer Q = (RATE_Q > LOW_Q) ? RATE_Q : LOW_Q;
    localparam [7:0] RATE_CODE = (FS_HZ == 800) ? 8'h0D :
        (FS_HZ == 400) ? 8'h0C : (FS_HZ == 200) ? 8'h0B : 8'h0A;
    localparam [2:0] OP_START=0, OP_STOP=1, OP_TX=2, OP_RX=3, OP_CLEAR=4;
    localparam [2:0] T_ID=0, T_CFG=1, T_DATA=2, T_CLEAR=3, T_ABORT=4;
    localparam [2:0] S_WAIT=0, S_BUS=1, S_IDLE=2, S_OP=3, S_DONE=4, S_GAP=5;
    localparam [3:0] ERR_NONE=0, ERR_NACK=1, ERR_SDA=2, ERR_SCL=3, ERR_ID=4;
    reg scl_low, sda_low;
    wire scl_in, sda_in;
    // Explicit pad primitives are essential for BD module-reference OOC
    // synthesis. Inferred internal tristates can otherwise become LUTs driving
    // constant zero (Synth 8-5799), permanently holding the physical bus low.
    // I is always zero: T=1 releases the wire; T=0 only ever sinks it.
    IOBUF scl_pad (.I(1'b0), .T(!scl_low), .O(scl_in), .IO(scl));
    IOBUF sda_pad (.I(1'b0), .T(!sda_low), .O(sda_in), .IO(sda));
    assign cs = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg [1:0] scl_sync, sda_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scl_sync<=2'b11; sda_sync<=2'b11; end
        else begin scl_sync<={scl_sync[0],scl_in}; sda_sync<={sda_sync[0],sda_in}; end
    end
    wire scl_i = scl_sync[1];
    wire sda_i = sda_sync[1];
    reg initialized, id_ok;
    reg [3:0] last_error;
    reg [7:0] failed_step;
    reg [15:0] error_count;
    reg be_go, be_busy, be_done;
    reg [3:0] be_error;
    reg [2:0] op;
    reg [7:0] txb, sh;
    reg [2:0] rxlen, byte_index;
    reg [7:0] rbuf [0:5];
    reg [3:0] bit_index;
    reg [1:0] phase;
    reg [31:0] quarter_count, stretch_count;
    wire tick = (quarter_count == Q-1);
    wire stretch = be_busy && phase==2 && !scl_i;
    assign i2c_status = {error_count,failed_step,last_error,sda_i,scl_i,be_busy,initialized};
    // Commands finish with SCL low except STOP; disable releases both bus wires.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_low<=0; sda_low<=0; be_busy<=0; be_done<=0; be_error<=0;
            phase<=0; bit_index<=0; byte_index<=0; sh<=0;
            quarter_count<=0; stretch_count<=0;
        end else if (!en) begin
            scl_low<=0; sda_low<=0; be_busy<=0; be_done<=0; be_error<=0;
            phase<=0; quarter_count<=0; stretch_count<=0;
        end else begin
            be_done<=0;
            if (!be_busy) begin
                quarter_count<=0; stretch_count<=0;
                if (be_go) begin
                    be_busy<=1; be_error<=0; phase<=0; bit_index<=0; byte_index<=0;
                    if (op==OP_TX) sh<=txb;
                    // Start the first low period immediately so CLEAR/STOP
                    // also get two complete low quarters when the bus was idle.
                    if (op==OP_CLEAR || op==OP_STOP) scl_low<=1;
                    if (op==OP_CLEAR) sda_low<=0;
                end
            end else if (stretch && stretch_count >= TIMEOUT_CYCLES-1) begin
                scl_low<=0; sda_low<=0; be_error<=ERR_SCL; be_done<=1; be_busy<=0;
                quarter_count<=0; stretch_count<=0;
            end else begin
                if (stretch) begin stretch_count<=stretch_count+1; quarter_count<=0; end
                else begin stretch_count<=0; quarter_count<=tick ? 0 : quarter_count+1; end
                if (tick && !stretch) begin
                    phase<=phase+1'b1;
                    case (op)
                        OP_START: case (phase)
                            0: sda_low<=0; // SDA settles before releasing SCL for repeated START.
                            1: scl_low<=0;
                            2: if (!sda_i) begin
                                be_error<=ERR_SDA; be_done<=1; be_busy<=0;
                                scl_low<=0; sda_low<=0;
                            end else sda_low<=1;
                            3: begin scl_low<=1; be_busy<=0; be_done<=1; end
                        endcase
                        OP_STOP: case (phase)
                            0: begin scl_low<=1; sda_low<=1; end
                            1: scl_low<=0;
                            2: sda_low<=0;
                            3: begin be_busy<=0; be_done<=1; end
                        endcase
                        OP_CLEAR: case (phase)
                            0: begin scl_low<=1; sda_low<=0; end
                            1: scl_low<=0;
                            2: ;
                            3: begin
                                scl_low<=1;
                                if (bit_index==8) begin be_busy<=0; be_done<=1; end
                                else bit_index<=bit_index+1'b1;
                            end
                        endcase
                        OP_TX: if (bit_index<8) begin
                            case (phase)
                                0: begin scl_low<=1; sda_low<=!sh[7]; end
                                1: scl_low<=0;
                                2: ;
                                3: begin scl_low<=1; sh<={sh[6:0],1'b0}; bit_index<=bit_index+1'b1; end
                            endcase
                        end else case (phase)
                            0: begin scl_low<=1; sda_low<=0; end
                            1: scl_low<=0;
                            2: if (sda_i) be_error<=ERR_NACK;
                            3: begin scl_low<=1; be_busy<=0; be_done<=1; end
                        endcase
                        OP_RX: if (bit_index<8) begin
                            case (phase)
                                0: begin scl_low<=1; sda_low<=0; end
                                1: scl_low<=0;
                                2: sh<={sh[6:0],sda_i};
                                3: begin scl_low<=1; bit_index<=bit_index+1'b1; end
                            endcase
                        end else case (phase)
                            0: begin scl_low<=1; sda_low<=(byte_index!=rxlen-1); end
                            1: scl_low<=0;
                            2: ;
                            3: begin
                                scl_low<=1; rbuf[byte_index]<=sh;
                                if (byte_index==rxlen-1) begin be_busy<=0; be_done<=1; end
                                else begin byte_index<=byte_index+1'b1; bit_index<=0; end
                            end
                        endcase
                        default: begin be_busy<=0; be_done<=1; end
                    endcase
                end
            end
        end
    end
    reg [2:0] state, txn;
    reg [3:0] step;
    reg dispatched;
    reg [1:0] cfg_index;
    reg [31:0] wait_count, sample_timer;
    wire [3:0] last_step = (txn==T_CFG) ? 4 : (txn==T_CLEAR) ? 1 : (txn==T_ABORT) ? 0 : 6;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_WAIT; txn<=T_ID; step<=0; dispatched<=0; cfg_index<=0;
            initialized<=0; id_ok<=0; wait_count<=STARTUP_CYCLES; sample_timer<=0;
            be_go<=0; op<=OP_START; txb<=0; rxlen<=0;
            ax_x<=0; ax_y<=0; ax_z<=0; sample_valid<=0; sample_count<=0; devid<=0;
            last_error<=0; failed_step<=0; error_count<=0;
        end else begin
            be_go<=0; sample_valid<=0;
            if (!en) begin
                state<=S_WAIT; wait_count<=STARTUP_CYCLES; dispatched<=0;
                initialized<=0; id_ok<=0; cfg_index<=0; sample_timer<=0;
                devid<=0; last_error<=0; failed_step<=0;
            end else begin
                if (sample_timer!=0) sample_timer<=sample_timer-1'b1;
                case (state)
                    S_WAIT: if (wait_count!=0) wait_count<=wait_count-1'b1; else state<=S_BUS;
                    S_BUS: begin
                        step<=0; dispatched<=0;
                        if (!scl_i || !sda_i) begin txn<=T_CLEAR; state<=S_OP; end
                        else state<=S_IDLE;
                    end
                    S_IDLE: begin
                        step<=0; dispatched<=0;
                        if (!id_ok) txn<=T_ID;
                        else if (!initialized) txn<=T_CFG;
                        else begin txn<=T_DATA; sample_timer<=PERIOD-1; end
                        state<=S_OP;
                    end
                    S_OP: if (!dispatched) begin
                        be_go<=1; dispatched<=1;
                        if (txn==T_CLEAR) op<=(step==0) ? OP_CLEAR : OP_STOP;
                        else if (txn==T_ABORT) op<=OP_STOP;
                        else if (txn==T_CFG) case (step)
                            0: op<=OP_START;
                            1: begin op<=OP_TX; txb<={ADDR7,1'b0}; end
                            2: begin op<=OP_TX; txb<=(cfg_index==0)?8'h2C:(cfg_index==1)?8'h31:8'h2D; end
                            3: begin op<=OP_TX; txb<=(cfg_index==0)?RATE_CODE:(cfg_index==1)?8'h0B:8'h08; end
                            default: op<=OP_STOP;
                        endcase else case (step)
                            0: op<=OP_START;
                            1: begin op<=OP_TX; txb<={ADDR7,1'b0}; end
                            2: begin op<=OP_TX; txb<=(txn==T_ID)?8'h00:8'h32; end
                            3: op<=OP_START;
                            4: begin op<=OP_TX; txb<={ADDR7,1'b1}; end
                            5: begin op<=OP_RX; rxlen<=(txn==T_ID)?1:6; end
                            default: op<=OP_STOP;
                        endcase
                    end else if (be_done) begin
                        dispatched<=0;
                        if (be_error!=ERR_NONE) begin
                            last_error<=be_error; failed_step<={1'b0,txn,step};
                            if (error_count!=16'hFFFF) error_count<=error_count+1'b1;
                            initialized<=0; id_ok<=0; cfg_index<=0; devid<=0;
                            if (be_error==ERR_NACK) begin txn<=T_ABORT; step<=0; end
                            else begin state<=S_WAIT; wait_count<=RETRY_CYCLES; end
                        end else if (step==last_step) state<=S_DONE;
                        else step<=step+1'b1;
                    end
                    S_DONE: case (txn)
                        T_ABORT: begin state<=S_WAIT; wait_count<=RETRY_CYCLES; end
                        T_CLEAR: if (!sda_i) begin
                            last_error<=ERR_SDA; failed_step<=8'h31;
                            if (error_count!=16'hFFFF) error_count<=error_count+1'b1;
                            state<=S_WAIT; wait_count<=RETRY_CYCLES;
                        end else state<=S_IDLE;
                        T_ID: begin
                            devid<=rbuf[0];
                            if (rbuf[0]==8'hE5) begin id_ok<=1; state<=S_IDLE; end
                            else begin
                                last_error<=ERR_ID; failed_step<=8'h06;
                                if (error_count!=16'hFFFF) error_count<=error_count+1'b1;
                                state<=S_WAIT; wait_count<=RETRY_CYCLES;
                            end
                        end
                        T_CFG: begin
                            if (cfg_index==2) begin initialized<=1; last_error<=0; failed_step<=0; end
                            else cfg_index<=cfg_index+1'b1;
                            state<=S_IDLE;
                        end
                        default: begin
                            ax_x<={rbuf[1],rbuf[0]}; ax_y<={rbuf[3],rbuf[2]}; ax_z<={rbuf[5],rbuf[4]};
                            sample_valid<=1; sample_count<=sample_count+1'b1; state<=S_GAP;
                        end
                    endcase
                    S_GAP: if (sample_timer==0) state<=S_IDLE;
                    default: state<=S_WAIT;
                endcase
            end
        end
    end
    // synthesis translate_off
    initial begin
        if (FS_HZ!=100 && FS_HZ!=200 && FS_HZ!=400 && FS_HZ!=800)
            $fatal(1,"I2C acquisition supports 100, 200, 400 or 800 Hz.");
        if (Q<4 || SCL_HZ>400_000 || PERIOD<400*Q || TIMEOUT_CYCLES<1)
            $fatal(1,"Unsupported I2C clock/sample timing parameters.");
    end
    // synthesis translate_on
endmodule
