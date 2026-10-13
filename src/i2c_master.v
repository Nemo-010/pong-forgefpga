// i2c_master.v -- byte-granularity, open-drain I2C master.
//
// The master NEVER drives a line high. It either pulls a line low
// (oe = 1) or releases it (oe = 0) and lets the external pull-up do the
// rest. This matches SSD1306 datasheet rev 1.1 sec. 8.1.5.2 ("Both the
// data line (SDA) and the clock line (SCL) should be pulled up by
// external resistors").
//
// Timing (defaults, at a nominal 50 MHz OSC):
//   T_LOW_CYC  = 71  -> 1420 ns  (UM10204 Fm tLOW  min 1300 ns)
//   T_HIGH_CYC = 77  -> 1540 ns  (UM10204 Fm tHIGH min  600 ns)
//   => SCL period 2960 ns -> 337.8 kHz, cycle time 2.96 us
//      (SSD1306 Table 13-6 tcycle min 2500 ns)
// The values are chosen so that even at the SLG47910 OSC worst case
// (54.110 MHz over -40..+85 C, datasheet rev 1.05 sec. 3.3.4) the cycle
// time stays above 2.5 us and tLOW stays above 1.3 us.  See
// scripts/i2c_timing.py, which recomputes and asserts all of this.
//
// Command interface: issue one command, wait for `done` (one-cycle pulse).
//   START  -> cmd_start
//   byte   -> cmd_send + cmd_byte   (ack_ok valid with done)
//   STOP   -> cmd_stop
//
// Reading ACK requires sda_i to be the pin input while sda_oe = 0.
//
// AREA / DEPTH NOTE.  The bit period is one 7-bit counter with ONE shared
// limit, selected from the state, instead of a comparator per state: on
// this device a wide comparator is either a whole CLB's carry chain or a
// three-level LUT chain (see the CARRY note in fpga/Makefile), and eight
// of them was both area and depth.  The period test is registered, so the
// FSM's next-state cone starts from a flip-flop instead of from the
// comparator output.

`default_nettype none

module i2c_master #(
    parameter integer T_LOW_CYC    = 71,
    parameter integer T_HIGH_CYC   = 77,
    parameter integer T_BUF_CYC    = 71,
    parameter integer T_STA_CYC    = 35,
    parameter integer T_STO_CYC    = 35,
    // The watchdog is the top bit of wd, so the timeout test costs one bit
    // instead of a 12-bit compare: wd counts up from 0 and wraps, which
    // takes 2**11 = 2048 clocks = 41 us at 50 MHz.  One byte needs about
    // 1332 clocks, so a stuck bus is always caught.
    parameter integer WATCHDOG_BIT  = 11
) (
    input  wire       clk,
    input  wire       rst,

    input  wire       cmd_start,
    input  wire       cmd_send,
    input  wire [7:0] cmd_byte,
    input  wire       cmd_stop,

    output reg        busy,
    output reg        done,
    output reg        ack_ok,
    output reg        timeout,

    input  wire       scl_i,
    input  wire       sda_i,
    output reg        scl_oe,   // 1 = pull SCL low
    output reg        sda_oe    // 1 = pull SDA low
);

    // period limits as 7-bit constants: written as expressions they would
    // be 32-bit, and the assignment to t_lim (7 bits) would truncate.
    localparam [6:0] T_BUF_LIM   = T_BUF_CYC  - 1,
                     T_STA_LIM   = T_STA_CYC  - 1,
                     T_LOW_LIM   = T_LOW_CYC  - 1,
                     T_HIGH_LIM  = T_HIGH_CYC - 1,
                     T_ACK_LIM   = (T_HIGH_CYC >> 1),
                     T_STO_LIM   = T_STO_CYC  - 1;

    localparam [3:0] S_IDLE    = 4'd0,
                     S_BUF     = 4'd1,
                     S_START_A = 4'd2,
                     S_START_B = 4'd3,
                     S_BIT_LO  = 4'd4,
                     S_BIT_HI  = 4'd5,
                     S_ACK_LO  = 4'd6,
                     S_ACK_HI  = 4'd7,
                     S_STOP_A  = 4'd8,
                     S_STOP_B  = 4'd9,
                     S_STOP_C  = 4'd10;

    reg [3:0]  state;
    // t only counts to max(T_LOW, T_HIGH, T_BUF)-1 (77 with the fast-mode
    // defaults), so 7 bits is enough; wd outlasts one byte (about 1300
    // clocks) and a stall, so 12 bits.
    reg [6:0]  t;
    reg [11:0] wd;
    reg [2:0]  bitc;
    reg [7:0]  shreg;
    reg        scl_seen_hi;
    reg        ack_sampled;

    // period limit for the current state; the test is a plain 7-bit
    // equality, one comparator for the whole design
    reg [6:0]  t_lim;
    wire       t_end = (t == t_lim);

    always @(*) begin
        case (state)
            S_BUF:     t_lim = T_BUF_LIM;
            S_START_A: t_lim = T_STA_LIM;
            S_START_B,
            S_BIT_LO,
            S_ACK_LO,
            S_STOP_A:  t_lim = T_LOW_LIM;
            S_BIT_HI:  t_lim = T_HIGH_LIM;
            S_ACK_HI:  t_lim = ack_sampled ? T_HIGH_LIM : T_ACK_LIM;
            S_STOP_B:  t_lim = T_STO_LIM;
            S_STOP_C:  t_lim = T_BUF_LIM;
            default:   t_lim = 7'h7f;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            t           <= 7'd0;
            wd          <= 12'd0;
            busy        <= 1'b0;
            done        <= 1'b0;
            ack_ok      <= 1'b0;
            timeout     <= 1'b0;
            scl_oe      <= 1'b0;
            sda_oe      <= 1'b0;
            bitc        <= 3'd0;
            shreg       <= 8'd0;
            scl_seen_hi <= 1'b0;
            ack_sampled <= 1'b0;
        end else begin
            done <= 1'b0;

            if (wd[WATCHDOG_BIT]) begin
                timeout <= 1'b1;
                state   <= S_IDLE;
                busy    <= 1'b0;
                scl_oe  <= 1'b0;
                sda_oe  <= 1'b0;
                t       <= 7'd0;
                wd      <= 12'd0;
            end else begin
                t  <= t + 7'd1;      // states override this with a reload
                wd <= wd + 12'd1;

                case (state)
                    // ------------------------------------------------------
                    S_IDLE: begin
                        busy <= 1'b0;
                        if (cmd_start) begin
                            state   <= S_BUF;
                            busy    <= 1'b1;
                            t       <= 7'd0;
                            wd      <= 12'd0;
                            scl_oe  <= 1'b0;
                            sda_oe  <= 1'b0;
                        end else if (cmd_send) begin
                            state   <= S_BIT_LO;
                            busy    <= 1'b1;
                            t       <= 7'd0;
                            wd      <= 12'd0;
                            shreg   <= cmd_byte;
                            bitc    <= 3'd0;
                            scl_oe  <= 1'b1;
                        end else if (cmd_stop) begin
                            state   <= S_STOP_A;
                            busy    <= 1'b1;
                            t       <= 7'd0;
                            wd      <= 12'd0;
                            scl_oe  <= 1'b1;
                            sda_oe  <= 1'b1;
                        end
                    end

                    // ---- START: SDA falls while SCL is high, then SCL falls
                    S_BUF: begin
                        scl_oe <= 1'b0;
                        sda_oe <= 1'b0;
                        if (t_end) begin
                            sda_oe <= 1'b1;      // SDA low, SCL still high
                            t      <= 7'd0;
                            state  <= S_START_A;
                        end
                    end

                    S_START_A: begin
                        sda_oe <= 1'b1;
                        scl_oe <= 1'b0;
                        if (t_end) begin
                            scl_oe <= 1'b1;      // SCL low
                            sda_oe <= 1'b0;      // release SDA (idle data = 1)
                            t      <= 7'd0;
                            state  <= S_START_B;
                        end
                    end

                    S_START_B: begin
                        scl_oe <= 1'b1;
                        sda_oe <= 1'b0;
                        if (t_end) begin
                            t      <= 7'd0;
                            wd     <= 12'd0;
                            done   <= 1'b1;
                            busy   <= 1'b0;
                            state  <= S_IDLE;
                        end
                    end

                    // ---- data bit: SDA while SCL low, then SCL high
                    S_BIT_LO: begin
                        scl_oe      <= 1'b1;
                        sda_oe      <= ~shreg[7];
                        scl_seen_hi <= 1'b0;
                        if (t_end) begin
                            scl_oe <= 1'b0;
                            t      <= 7'd0;
                            state  <= S_BIT_HI;
                        end
                    end

                    S_BIT_HI: begin
                        scl_oe <= 1'b0;
                        if (!scl_seen_hi) begin
                            if (scl_i) begin
                                scl_seen_hi <= 1'b1;
                                t           <= 7'd0;
                            end
                        end else if (t_end) begin
                            scl_oe      <= 1'b1;   // SCL low again
                            scl_seen_hi <= 1'b0;
                            t           <= 7'd0;
                            if (bitc == 3'd7) begin
                                state <= S_ACK_LO;
                            end else begin
                                bitc  <= bitc + 1'b1;
                                shreg <= {shreg[6:0], 1'b0};
                                state <= S_BIT_LO;
                            end
                        end
                    end

                    // ---- ACK slot: master releases SDA, samples it
                    S_ACK_LO: begin
                        scl_oe      <= 1'b1;
                        sda_oe      <= 1'b0;
                        scl_seen_hi <= 1'b0;
                        ack_sampled <= 1'b0;
                        if (t_end) begin
                            scl_oe <= 1'b0;
                            t      <= 7'd0;
                            state  <= S_ACK_HI;
                        end
                    end

                    S_ACK_HI: begin
                        scl_oe <= 1'b0;
                        if (!scl_seen_hi) begin
                            if (scl_i) begin
                                scl_seen_hi <= 1'b1;
                                t           <= 7'd0;
                            end
                        end else if (!ack_sampled && t_end) begin
                            ack_ok      <= ~sda_i;   // sample mid-high
                            ack_sampled <= 1'b1;
                        end else if (ack_sampled && t_end) begin
                            scl_oe      <= 1'b1;
                            scl_seen_hi <= 1'b0;
                            ack_sampled <= 1'b0;
                            t           <= 7'd0;
                            wd          <= 12'd0;
                            done        <= 1'b1;
                            busy        <= 1'b0;
                            state       <= S_IDLE;
                        end
                    end

                    // ---- STOP: SDA rises while SCL is high
                    S_STOP_A: begin
                        scl_oe <= 1'b1;
                        sda_oe <= 1'b1;
                        if (t_end) begin
                            scl_oe <= 1'b0;
                            t      <= 7'd0;
                            state  <= S_STOP_B;
                        end
                    end

                    S_STOP_B: begin
                        scl_oe <= 1'b0;
                        sda_oe <= 1'b1;
                        if (scl_i && t_end) begin
                            sda_oe <= 1'b0;        // SDA releases -> high
                            t      <= 7'd0;
                            state  <= S_STOP_C;
                        end
                    end

                    S_STOP_C: begin
                        scl_oe <= 1'b0;
                        sda_oe <= 1'b0;
                        if (t_end) begin
                            t      <= 7'd0;
                            wd     <= 12'd0;
                            done   <= 1'b1;
                            busy   <= 1'b0;
                            state  <= S_IDLE;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
