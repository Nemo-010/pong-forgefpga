// ssd1306_model.v -- behavioural SSD1306 slave for simulation.
//
// Decodes the I2C stream, tracks the addressing mode and the column/page
// window, and writes received data bytes into a 1024-byte GDDRAM image
// (8 pages x 128 columns).  Whenever a transaction ends with at least one
// whole frame's worth of data it appends the GDDRAM to DUMP_FILE as 1024
// hex bytes, one frame per line, so the rendered picture can be inspected
// or turned into an image by scripts/frame_dump.py.
//
// Only the subset of commands the controller issues is interpreted; the
// parameter counts match the SSD1306 rev 1.1 command table so the byte
// stream stays in sync.

module ssd1306_model #(
    parameter [6:0]   ADDR        = 7'h3C,
    parameter integer DUMP_FRAMES = 64,
    parameter         DUMP_FILE   = "out/frames.hex"
) (
    input  wire scl,       // bus value, already pulled up
    input  wire sda,       // bus value, already pulled up
    output reg  sda_low,   // model pulls SDA low when 1
    output reg  [15:0] frame_count,
    output reg  display_on
);

    reg       active;
    reg [3:0] bitc;      // data bits received in the current byte
    reg [7:0] shreg;
    reg [7:0] rx;
    reg [11:0] byte_n;   // byte index within the current transfer
    reg       mode;      // 0 = command, 1 = data
    reg [2:0] pcount;    // remaining parameter bytes of the current command
    reg [7:0] cmd;

    reg [6:0] col, col_s, col_e;
    reg [2:0] page, page_s, page_e;
    reg       horiz;

    reg [7:0] gddram [0:1023];
    integer   i, fd, wr_cnt;

    initial begin
        active      = 1'b0;
        bitc        = 4'd0;
        shreg       = 8'h00;
        rx          = 8'h00;
        byte_n      = 12'd0;
        mode        = 1'b0;
        pcount      = 3'd0;
        col         = 7'd0;  col_s  = 7'd0;  col_e  = 7'd127;
        page        = 3'd0;  page_s = 3'd0;  page_e = 3'd7;
        horiz       = 1'b0;
        sda_low     = 1'b0;
        frame_count = 16'd0;
        display_on  = 1'b0;
        wr_cnt      = 0;
        for (i = 0; i < 1024; i = i + 1) gddram[i] = 8'h00;
        fd = $fopen(DUMP_FILE, "w");
    end

    // ---- bus event detection ------------------------------------------
    always @(negedge sda) begin
        if (scl && !sda_low) begin
            active  <= 1'b1;
            bitc    <= 4'd0;
            byte_n  <= 12'd0;
            pcount  <= 3'd0;
        end
    end

    always @(posedge sda) begin
        if (scl && !sda_low) begin
            active <= 1'b0;
            if (wr_cnt >= 1024) begin
                frame_count <= frame_count + 1'b1;
                if (frame_count < DUMP_FRAMES) begin
                    for (i = 0; i < 1024; i = i + 1)
                        $fwrite(fd, "%02x", gddram[i]);
                    $fwrite(fd, "\n");
                    $fflush(fd);
                end
                wr_cnt <= 0;
            end
        end
    end

    // ---- bit shift / ACK ----------------------------------------------
    always @(posedge scl) begin
        if (active) begin
            if (bitc < 4'd8) begin
                shreg <= {shreg[6:0], sda};
                bitc  <= bitc + 1'b1;
            end else begin
                bitc <= 4'd9;      // ACK clock (SDA is held low by us)
            end
        end
    end

    always @(negedge scl) begin
        if (active) begin
            if (bitc == 4'd8) begin
                sda_low <= 1'b1;             // pull ACK during the 9th clock
            end else if (bitc == 4'd9) begin
                sda_low <= 1'b0;
                rx      <= shreg;
                bitc    <= 4'd0;

                // ---- byte processing ----
                if (byte_n == 12'd0) begin
                    // address byte, always acknowledged by this model
                    if (shreg[7:1] !== ADDR || shreg[0] !== 1'b0)
                        $display("ssd1306_model: unexpected address byte %02x",
                                 shreg);
                end else if (byte_n == 12'd1) begin
                    mode   <= shreg[6];      // D/C#
                    pcount <= 3'd0;
                end else if (mode == 1'b0) begin
                    if (pcount == 3'd0) begin
                        case (shreg)
                            8'h20: begin cmd <= shreg; pcount <= 3'd1; end
                            8'h21: begin cmd <= shreg; pcount <= 3'd2; end
                            8'h22: begin cmd <= shreg; pcount <= 3'd2; end
                            8'h81, 8'hD5, 8'hA8, 8'hD3,
                            8'h8D, 8'hD9, 8'hDB, 8'hDA:
                                   begin cmd <= shreg; pcount <= 3'd1; end
                            8'hAF: display_on <= 1'b1;
                            8'hAE: display_on <= 1'b0;
                            default: ;
                        endcase
                    end else begin
                        case (cmd)
                            8'h20: horiz  <= (shreg == 8'h00);
                            8'h21: begin
                                // rev 1.1 ss 10.1.14: the column pointer is
                                // loaded with the start address
                                if (pcount == 3'd2) col_s <= shreg[6:0];
                                else begin
                                    col_e <= shreg[6:0];
                                    col   <= col_s;
                                end
                            end
                            8'h22: begin
                                // rev 1.1 ss 10.1.15: same for the page
                                if (pcount == 3'd2) page_s <= shreg[2:0];
                                else begin
                                    page_e <= shreg[2:0];
                                    page   <= page_s;
                                end
                            end
                            default: ;
                        endcase
                        pcount <= pcount - 1'b1;
                    end
                end else begin
                    // data byte -> GDDRAM
                    gddram[{page, col}] <= shreg;
                    wr_cnt <= wr_cnt + 1;
                    if (horiz) begin
                        if (col >= col_e) begin
                            col <= col_s;
                            if (page >= page_e) page <= page_s;
                            else                page <= page + 1'b1;
                        end else begin
                            col <= col + 1'b1;
                        end
                    end else begin
                        if (page >= page_e) page <= page_s;
                        else                page <= page + 1'b1;
                    end
                end
                byte_n <= byte_n + 1'b1;
            end
        end
    end

endmodule
