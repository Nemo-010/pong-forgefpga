// ssd1306_ctrl.v -- SSD1306 initialisation and frame streaming.
//
// Init sequence follows Solomon Systech SSD1306 rev 1.1 sec. 8.9 (power ON:
// RES# low then high, then commands, 0xAF last) and the fundamental/charge
// pump command tables in sec. 10.  After 0xAF the datasheet allows 100 ms
// before SEG/COM are on, which is the AF_WAIT below.
//
// Memory addressing is left in horizontal mode and the column/page window is
// set once to the full 128x64 panel, so a frame is a single I2C transfer:
//
//   START  <0x3C,0>  0x40  byte0 .. byte1023  STOP
//
// The 0x40 control byte (Co=0, D/C#=1) means "everything after this is
// GDDRAM data", and the SSD1306 increments the column pointer after every
// byte and wraps to the next page at the end of a page, so the whole panel
// is refreshed with one start/stop pair.  1024 data bytes at the byte
// timing in i2c_master.v is a 3.03 ms transfer, ~330 frames/s of wire
// budget; the renderer cannot be the bottleneck.

`default_nettype none

module ssd1306_ctrl #(
    // The three waiting times are counted in tick_gen ticks (1.31072 ms at
    // 50 MHz), not in clocks: a 23-bit down counter with a 23-bit comparator
    // costs several CLBs, a tick counter costs one.
    parameter integer POR_TICKS    = 76,          // ~100 ms before init
    parameter integer AF_TICKS     = 76,          // ~100 ms after 0xAF
    parameter integer ERR_TICKS    = 8,           // ~10 ms before a retry
    parameter integer FRAME_BYTES  = 1024,
    parameter [6:0]   SLAVE_ADDR   = 7'h3C
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       tick,       // time-base tick from tick_gen

    output reg        m_start,
    output reg        m_send,
    output reg [7:0]  m_byte,
    output reg        m_stop,
    input  wire       m_done,
    input  wire       m_ack_ok,
    input  wire       m_timeout,

    output reg        f_req,
    output reg [9:0]  f_index,
    input  wire [7:0] f_byte,
    input  wire       f_valid,

    output reg        o_frame_active,
    output reg        o_init_done,
    output reg        o_bus_error
);

    // ------------------------------------------------------------------
    // command table: 0x00 control byte then these bytes, one transfer
    // ------------------------------------------------------------------
    function [7:0] init_cmd;
        input [5:0] i;
        case (i)
            6'd0:  init_cmd = 8'hAE;  // display off
            6'd1:  init_cmd = 8'hD5;  // clk divide / osc freq
            6'd2:  init_cmd = 8'h80;
            6'd3:  init_cmd = 8'hA8;  // multiplex ratio
            6'd4:  init_cmd = 8'h3F;  // 64 rows
            6'd5:  init_cmd = 8'hD3;  // display offset
            6'd6:  init_cmd = 8'h00;
            6'd7:  init_cmd = 8'h40;  // start line 0
            6'd8:  init_cmd = 8'h8D;  // charge pump
            6'd9:  init_cmd = 8'h14;  //   enable
            6'd10: init_cmd = 8'h20;  // memory addressing mode
            6'd11: init_cmd = 8'h00;  //   horizontal
            6'd12: init_cmd = 8'hA1;  // segment remap
            6'd13: init_cmd = 8'hC8;  // COM scan direction
            6'd14: init_cmd = 8'hDA;  // COM pins hardware config
            6'd15: init_cmd = 8'h12;
            6'd16: init_cmd = 8'h81;  // contrast
            6'd17: init_cmd = 8'hCF;
            6'd18: init_cmd = 8'hD9;  // pre-charge period
            6'd19: init_cmd = 8'hF1;
            6'd20: init_cmd = 8'hDB;  // VCOMH deselect level
            6'd21: init_cmd = 8'h40;
            6'd22: init_cmd = 8'hA4;  // entire display: follow RAM
            6'd23: init_cmd = 8'hA6;  // normal (non-inverted)
            6'd24: init_cmd = 8'h2E;  // deactivate scroll
            6'd25: init_cmd = 8'h21;  // column address range
            6'd26: init_cmd = 8'h00;
            6'd27: init_cmd = 8'h7F;
            6'd28: init_cmd = 8'h22;  // page address range
            6'd29: init_cmd = 8'h00;
            6'd30: init_cmd = 8'h07;
            6'd31: init_cmd = 8'hAF;  // display on (last)
            default: init_cmd = 8'h00;
        endcase
    endfunction

    localparam integer INIT_LEN = 32;

    localparam [2:0] PH_POR   = 3'd0,
                     PH_INIT  = 3'd1,
                     PH_AF    = 3'd2,
                     PH_FRAME = 3'd3,
                     PH_ERR   = 3'd4;

    reg [2:0]  ph;
    reg [2:0]  sub;
    reg        wait_done;
    reg [5:0]  icnt;
    reg [10:0] fcnt;   // 11 bits: the counter has to reach FRAME_BYTES
    reg [7:0]  dly;    // in time-base ticks

    wire [7:0] init_b = init_cmd(icnt);

    always @(posedge clk) begin
        if (rst) begin
            ph             <= PH_POR;
            sub            <= 3'd0;
            wait_done      <= 1'b0;
            icnt           <= 6'd0;
            fcnt           <= 11'd0;
            dly            <= POR_TICKS[7:0];
            m_start        <= 1'b0;
            m_send         <= 1'b0;
            m_byte         <= 8'h00;
            m_stop         <= 1'b0;
            f_req          <= 1'b0;
            f_index        <= 10'd0;
            o_frame_active <= 1'b0;
            o_init_done    <= 1'b0;
            o_bus_error    <= 1'b0;
        end else begin
            m_start <= 1'b0;
            m_send  <= 1'b0;
            m_stop  <= 1'b0;
            f_req   <= 1'b0;

            o_frame_active <= (ph == PH_FRAME);

            if (m_timeout) begin
                o_bus_error <= 1'b1;
                ph          <= PH_ERR;
                wait_done   <= 1'b0;
                dly         <= ERR_TICKS[7:0];
            end else begin

                case (ph)

                    // ------------------------------------------------
                    PH_POR: begin
                        if (dly == 8'd0) begin
                            ph   <= PH_INIT;
                            sub  <= 3'd0;
                            icnt <= 6'd0;
                        end else if (tick) begin
                            dly <= dly - 1'b1;
                        end
                    end

                    // ------------------------------------------------
                    PH_INIT: begin
                        if (wait_done) begin
                            if (m_done) begin
                                wait_done <= 1'b0;
                                if (sub == 3'd1 && !m_ack_ok) begin
                                    o_bus_error <= 1'b1;
                                    ph          <= PH_ERR;
                                    dly         <= ERR_TICKS[7:0];
                                end else if (sub == 3'd3) begin
                                    sub  <= 3'd3;
                                    icnt <= icnt + 1'b1;
                                end else begin
                                    sub <= sub + 1'b1;
                                end
                            end
                        end else begin
                            case (sub)
                                3'd0: begin m_start <= 1'b1; wait_done <= 1'b1; end
                                3'd1: begin
                                    m_send   <= 1'b1;
                                    m_byte   <= {SLAVE_ADDR, 1'b0};
                                    wait_done <= 1'b1;
                                end
                                3'd2: begin
                                    m_send   <= 1'b1;
                                    m_byte   <= 8'h00;   // Co=0, D/C#=0
                                    wait_done <= 1'b1;
                                end
                                3'd3: begin
                                    if (icnt >= INIT_LEN[5:0]) begin
                                        sub <= 3'd4;
                                    end else begin
                                        m_send   <= 1'b1;
                                        m_byte   <= init_b;
                                        wait_done <= 1'b1;
                                    end
                                end
                                3'd4: begin m_stop <= 1'b1; wait_done <= 1'b1; end
                                3'd5: begin
                                    o_init_done <= 1'b1;
                                    ph          <= PH_AF;
                                    dly         <= AF_TICKS[7:0];
                                    sub         <= 3'd0;
                                end
                                default: sub <= 3'd0;
                            endcase
                        end
                    end

                    // ------------------------------------------------
                    PH_AF: begin
                        if (dly == 8'd0) begin
                            ph  <= PH_FRAME;
                            sub <= 3'd0;
                            fcnt <= 11'd0;
                        end else if (tick) begin
                            dly <= dly - 1'b1;
                        end
                    end

                    // ------------------------------------------------
                    PH_FRAME: begin
                        if (wait_done) begin
                            if (m_done) begin
                                wait_done <= 1'b0;
                                if (!m_ack_ok) begin
                                    o_bus_error <= 1'b1;
                                    ph          <= PH_ERR;
                                    dly         <= ERR_TICKS[7:0];
                                end else begin
                                    case (sub)
                                        3'd1: sub <= 3'd2;
                                        3'd2: begin sub <= 3'd3; fcnt <= 11'd0; end
                                        3'd5: begin
                                            if (fcnt >= FRAME_BYTES[10:0])
                                                 sub <= 3'd6;
                                            else sub <= 3'd3;
                                        end
                                        3'd6: sub <= 3'd0;
                                        default: sub <= sub + 1'b1;
                                    endcase
                                end
                            end
                        end else begin
                            case (sub)
                                3'd0: begin m_start <= 1'b1; wait_done <= 1'b1; end
                                3'd1: begin
                                    m_send   <= 1'b1;
                                    m_byte   <= {SLAVE_ADDR, 1'b0};
                                    wait_done <= 1'b1;
                                end
                                3'd2: begin
                                    m_send   <= 1'b1;
                                    m_byte   <= 8'h40;   // Co=0, D/C#=1
                                    wait_done <= 1'b1;
                                end
                                3'd3: begin
                                    f_req   <= 1'b1;
                                    f_index <= fcnt;
                                    sub     <= 3'd4;
                                end
                                3'd4: begin
                                    if (f_valid) begin
                                        m_send   <= 1'b1;
                                        m_byte   <= f_byte;
                                        wait_done <= 1'b1;
                                        fcnt     <= fcnt + 1'b1;
                                        sub      <= 3'd5;
                                    end
                                end
                                3'd5: ;   // waiting for the master (handled above)
                                3'd6: begin m_stop <= 1'b1; wait_done <= 1'b1; end
                                default: sub <= 3'd0;
                            endcase
                        end
                    end

                    // ------------------------------------------------
                    PH_ERR: begin
                        if (dly == 8'd0) begin
                            ph   <= PH_INIT;
                            sub  <= 3'd0;
                            icnt <= 6'd0;
                        end else if (tick) begin
                            dly <= dly - 1'b1;
                        end
                    end

                    default: ph <= PH_POR;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
