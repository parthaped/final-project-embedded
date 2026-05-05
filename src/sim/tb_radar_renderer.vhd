-- ============================================================================
-- tb_radar_renderer.vhd
--   Drives the radar_renderer through one full 640x480 frame and writes
--   the rendered RGB pixels into a Netpbm PPM file (build/sim/radar.ppm)
--   so the result can be inspected visually offline.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_radar_renderer is
end entity;

architecture sim of tb_radar_renderer is
    constant CLK_PERIOD : time := 40 ns;     -- 25 MHz

    signal clk         : std_logic := '0';
    signal rst         : std_logic := '1';

    signal x_in, y_in  : unsigned(9 downto 0);
    signal de_in, hs_in, vs_in : std_logic;

    signal distance_in : unsigned(15 downto 0) := to_unsigned(36, 16);  -- 36 in
    signal als_value   : unsigned(15 downto 0) := to_unsigned(128, 16);

    signal red, green, blue : std_logic_vector(7 downto 0);
    signal de_o, hs_o, vs_o : std_logic;

begin
    clk <= not clk after CLK_PERIOD/2;

    timing : entity work.vga_timing_640x480
        port map (
            clk_pixel => clk,
            rst       => rst,
            x         => x_in,
            y         => y_in,
            de        => de_in,
            hsync     => hs_in,
            vsync     => vs_in );

    dut : entity work.radar_renderer
        port map (
            clk_pixel   => clk,
            rst         => rst,
            x_in        => x_in,
            y_in        => y_in,
            de_in       => de_in,
            hsync_in    => hs_in,
            vsync_in    => vs_in,
            distance_in => distance_in,
            als_value   => als_value,
            red         => red,
            green       => green,
            blue        => blue,
            de_out      => de_o,
            hsync_out   => hs_o,
            vsync_out   => vs_o );

    -- Capture one frame to a PPM file.  We wait for two vsync events to
    -- skip any partial first frame, then sample 480 lines x 640 pixels.
    capture : process
        file     fh    : text;
        variable line  : line;
        variable px    : integer := 0;
        variable lines_written : integer := 0;
    begin
        wait for CLK_PERIOD * 50;
        rst <= '0';

        -- Skip the first ~3 frames so the sweep settles.
        for f in 1 to 3 loop
            wait until vs_o = '0';
            wait until vs_o = '1';
        end loop;

        file_open(fh, "radar.ppm", write_mode);
        write(line, string'("P3"));     writeline(fh, line);
        write(line, string'("640 480")); writeline(fh, line);
        write(line, string'("255"));    writeline(fh, line);

        while lines_written < 480 loop
            wait until rising_edge(clk);
            if de_o = '1' then
                write(line, integer'(to_integer(unsigned(red))));
                write(line, string'(" "));
                write(line, integer'(to_integer(unsigned(green))));
                write(line, string'(" "));
                write(line, integer'(to_integer(unsigned(blue))));
                write(line, string'("  "));
                px := px + 1;
                if px = 640 then
                    writeline(fh, line);
                    px := 0;
                    lines_written := lines_written + 1;
                end if;
            end if;
        end loop;

        file_close(fh);
        report "tb_radar_renderer wrote 640x480 PPM frame" severity note;
        std.env.finish;
    end process;
end architecture;
