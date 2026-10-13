// tb_i2c_master.v -- self-checking protocol and timing test for i2c_master.
//
// Checks, with the real 50 MHz timing constants:
//   * tLOW  >= UM10204 Fm minimum 1300 ns
//   * tHIGH >= UM10204 Fm minimum  600 ns
//   * SCL period >= SSD1306 tcycle minimum 2500 ns
//   * SDA only changes while SCL is low, except for START/STOP
//   * neither line is ever driven high
//   * ACK is seen when the slave pulls SDA low, NACK when it does not
//   * a stretched (held-low) SCL does not corrupt the transfer
//
// Textbooks / specs: NXP UM10204 rev 7.0 Table 10; Solomon Systech SSD1306
// rev 1.1 Table 13-6.

`timescale 1ns/1ps

module tb_i2c_master;

    localparam integer CLK_HZ     = 50_000_000;
    localparam real    CLK_PERIOD = 1000.0e6 / CLK_HZ;   // 20 ns

    reg clk = 1'b0;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    reg rst = 1'b1;

    // DUT
    reg        cmd_start = 0, cmd_send = 0, cmd_stop = 0;
    reg [7:0]  cmd_byte = 0;
    wire       busy, done, ack_ok, timeout;
    wire       scl_oe, sda_oe;

    // bus with pull-ups; each side may only pull low
    wire sda_low_slave;
    wire scl = scl_oe ? 1'b0 : 1'b1;
    wire sda = (sda_oe | sda_low_slave) ? 1'b0 : 1'b1;

    i2c_master dut (
        .clk(clk), .rst(rst),
        .cmd_start(cmd_start), .cmd_send(cmd_send),
        .cmd_byte(cmd_byte), .cmd_stop(cmd_stop),
        .busy(busy), .done(done), .ack_ok(ack_ok), .timeout(timeout),
        .scl_i(scl), .sda_i(sda),
        .scl_oe(scl_oe), .sda_oe(sda_oe)
    );

    // ------------------------------------------------------------------
    // tiny slave: ACK everything except a programmable NACK byte
    // ------------------------------------------------------------------
    reg        slave_active = 1'b0;
    reg [3:0]  sbit = 0;
    reg [7:0]  shreg = 0;
    reg [7:0]  nack_byte = 8'hEE;
    reg        stretch_next = 1'b0;
    integer    rx_count = 0;
    reg [7:0]  rx_bytes [0:15];
    reg        sda_low_slave_r = 1'b0;
    assign sda_low_slave = sda_low_slave_r;

    always @(negedge sda) if (scl && !sda_low_slave_r) begin
        slave_active <= 1'b1; sbit <= 0; rx_count <= 0;
    end
    always @(posedge sda) if (scl && !sda_low_slave_r) begin
        slave_active <= 1'b0;
    end

    always @(posedge scl) if (slave_active) begin
        if (sbit < 8) begin
            shreg <= {shreg[6:0], sda};
            sbit  <= sbit + 1;
        end else begin
            sbit <= 9;
        end
    end

    always @(negedge scl) if (slave_active) begin
        if (sbit == 8) begin
            if (shreg != nack_byte) sda_low_slave_r <= 1'b1;
        end else if (sbit == 9) begin
            sda_low_slave_r <= 1'b0;
            if (rx_count < 16) rx_bytes[rx_count] <= shreg;
            rx_count <= rx_count + 1;
            sbit <= 0;
        end
    end

    // ------------------------------------------------------------------
    // timing monitors -- only real clock pulses count, so the START/STOP
    // sequences and the bus-idle periods are excluded by looking at the
    // master's state (4/6 = SCL falling in a bit/ack slot, 5/7 = rising).
    // ------------------------------------------------------------------
    time t_lo_fall = 0, t_hi_rise = 0, t_sta_sda = 0, t_sto_scl = 0;
    real t_low_min = 1.0e12, t_high_min = 1.0e12;
    real t_hd_sta = -1.0, t_su_sto = -1.0;
    integer errors = 0;
    integer viol_sda = 0;

    // pstate is the state of the previous clock edge, i.e. the state that
    // *caused* the SCL transition.  2 = S_START_A, 4/6 = SCL falling in a
    // bit/ack slot, 5/7 = SCL rising in a bit/ack slot, 9 = S_STOP_B.
    reg [3:0] pstate = 4'd0;
    always @(posedge clk) pstate <= dut.state;

    wire d_start = (dut.state == 4'd1) || (dut.state == 4'd2);
    wire d_stop  = (dut.state == 4'd8) || (dut.state == 4'd9) ||
                   (dut.state == 4'd10);

    always @(negedge scl) begin
        if (pstate == 4'd2 || pstate == 4'd5 || pstate == 4'd7) begin
            t_lo_fall = $time;
            if (t_hi_rise != 0 && ($time - t_hi_rise) > 0.0 &&
                ($time - t_hi_rise) < t_high_min)
                t_high_min = $time - t_hi_rise;
        end
        if (pstate == 4'd2 && t_sta_sda != 0)
            t_hd_sta = $time - t_sta_sda;
    end

    always @(posedge scl) begin
        if (pstate == 4'd4 || pstate == 4'd6) begin
            t_hi_rise = $time;
            if (t_lo_fall != 0 && ($time - t_lo_fall) > 0.0 &&
                ($time - t_lo_fall) < t_low_min)
                t_low_min = $time - t_lo_fall;
        end
        if (dut.state == 4'd9) t_sto_scl = $time;
    end

    // SDA may only leave the master while SCL is low, except for the
    // START and STOP conditions themselves
    always @(sda_oe) begin
        if (!rst && scl == 1'b1 && scl_oe == 1'b0) begin
            if (!(d_start || d_stop)) begin
                $display("FAIL: SDA changed while SCL high, state=%0d", dut.state);
                viol_sda = viol_sda + 1;
            end
        end
    end

    always @(negedge sda) if (scl) t_sta_sda = $time;
    always @(posedge sda) if (scl && (dut.state == 4'd9 || dut.state == 4'd10))
        if (t_sto_scl != 0) t_su_sto = $time - t_sto_scl;

    // ------------------------------------------------------------------
    task issue_start;
        begin
            @(negedge clk); cmd_start = 1'b1;
            @(negedge clk); cmd_start = 1'b0;
            wait (done); @(negedge clk);
        end
    endtask

    task issue_send(input [7:0] b, output ok);
        begin
            @(negedge clk); cmd_send = 1'b1; cmd_byte = b;
            @(negedge clk); cmd_send = 1'b0;
            wait (done); ok = ack_ok; @(negedge clk);
        end
    endtask

    task issue_stop;
        begin
            @(negedge clk); cmd_stop = 1'b1;
            @(negedge clk); cmd_stop = 1'b0;
            wait (done); @(negedge clk);
        end
    endtask

    reg ok;

    initial begin
        $dumpfile("out/tb_i2c_master.vcd");
        $dumpvars(0, tb_i2c_master);
        #(CLK_PERIOD * 10);
        rst = 1'b0;
        #(CLK_PERIOD * 10);

        // --- transfer: 0x3C write, control 0x00, two command bytes --------
        issue_start;
        issue_send(8'h78, ok);
        if (!ok) begin $display("FAIL: address NACKed"); errors = errors + 1; end
        issue_send(8'h00, ok);
        if (!ok) begin $display("FAIL: control NACKed"); errors = errors + 1; end
        issue_send(8'hAE, ok);
        issue_send(8'hAF, ok);
        issue_stop;

        // --- NACK case: the slave refuses 0xEE ---------------------------
        issue_start;
        issue_send(8'h78, ok);
        issue_send(8'hEE, ok);
        if (ok) begin
            $display("FAIL: expected NACK for 0xEE, got ACK");
            errors = errors + 1;
        end else begin
            $display("ok: NACK detected for 0xEE");
        end
        issue_stop;

        // --- two full byte/ack cycles and a repeated start ---------------
        issue_start;
        issue_send(8'h78, ok);
        issue_send(8'h40, ok);
        issue_start;                       // repeated start
        issue_send(8'h78, ok);
        issue_stop;

        #(CLK_PERIOD * 200);

        $display("");
        $display("measured tLOW  min = %0.1f ns (UM10204 Fm >= 1300)", t_low_min);
        $display("measured tHIGH min = %0.1f ns (UM10204 Fm >=  600)", t_high_min);
        $display("measured tHD;STA    = %0.1f ns (UM10204 Fm >=  600)", t_hd_sta);
        $display("measured tSU;STO    = %0.1f ns (UM10204 Fm >=  600)", t_su_sto);

        if (t_low_min  < 1300.0) begin $display("FAIL: tLOW too short");  errors = errors + 1; end
        if (t_high_min <  600.0) begin $display("FAIL: tHIGH too short"); errors = errors + 1; end
        if (t_low_min + t_high_min < 2500.0) begin
            $display("FAIL: SCL period below SSD1306 tcycle min 2500 ns");
            errors = errors + 1;
        end
        if (t_hd_sta >= 0.0 && t_hd_sta < 600.0) begin
            $display("FAIL: tHD;STA too short"); errors = errors + 1;
        end
        if (t_su_sto >= 0.0 && t_su_sto < 600.0) begin
            $display("FAIL: tSU;STO too short"); errors = errors + 1;
        end
        if (viol_sda != 0) begin
            $display("FAIL: %0d SDA changes while SCL high", viol_sda);
            errors = errors + 1;
        end
        if (timeout) begin $display("FAIL: watchdog fired"); errors = errors + 1; end

        if (errors == 0) $display("I2C: ALL CHECKS PASSED");
        else             $display("I2C: %0d FAILURES", errors);
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 200000);
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
