// tb_font.v -- dumps all ten glyphs as text; scripts/font_gen.py --check
// compares the dump with the generator's own bitmap table.

`timescale 1ns/1ps

module tb_font;

    reg  [3:0] digit;
    reg  [2:0] col, row;
    wire       pix;

    pong_font dut (.digit(digit), .col(col), .row(row), .pix(pix));

    integer d, x, y;
    integer fd;

    initial begin
        fd = $fopen("out/font_dump.txt", "w");
        for (d = 0; d < 10; d = d + 1) begin
            $fwrite(fd, "digit %0d\n", d);
            for (y = 0; y < 8; y = y + 1) begin
                for (x = 0; x < 8; x = x + 1) begin
                    digit = d[3:0]; col = x[2:0]; row = y[2:0];
                    #1;
                    $fwrite(fd, "%s", pix ? "#" : ".");
                end
                $fwrite(fd, "\n");
            end
        end
        $fclose(fd);
        $display("font dump written: out/font_dump.txt");
        $finish;
    end

endmodule
