-- hdmi_top.vhd
--   Wires the VGA timing generator, the console renderer, three TMDS
--   encoders, and four TMDS serializers (R/G/B + clock) into the
--   HDMI TX port in plain DVI mode (no audio, no DDC). HPD is held high
--   so the monitor latches.
--
--   DVI channel mapping:
--     Channel 0 = Blue   (carries c0=hsync, c1=vsync during blanking)
--     Channel 1 = Green  (c0=c1=0)
--     Channel 2 = Red    (c0=c1=0)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

use work.contact_pkg.all;

entity hdmi_top is
    port (
        clk_pixel    : in  std_logic;
        clk_serial   : in  std_logic;
        rst          : in  std_logic;

        range_in        : in  unsigned(7 downto 0);
        als_value       : in  unsigned(7 downto 0);
        ambient_mode    : in  unsigned(1 downto 0);
        severity_now    : in  unsigned(1 downto 0);
        presence        : in  std_logic;
        log_pulse_pixel : in  std_logic;
        sev_value       : in  unsigned(1 downto 0);
        contacts        : in  contact_array_t;
        count           : in  unsigned(3 downto 0);
        t_seconds       : in  unsigned(15 downto 0);
        arm             : in  std_logic;
        near_th         : in  unsigned(7 downto 0);
        warn_th         : in  unsigned(7 downto 0);

        hdmi_tx_clk_p : out std_logic;
        hdmi_tx_clk_n : out std_logic;
        hdmi_tx_d_p   : out std_logic_vector(2 downto 0);
        hdmi_tx_d_n   : out std_logic_vector(2 downto 0);
        hdmi_tx_hpd   : out std_logic
    );
end entity;

architecture rtl of hdmi_top is
    signal x_t, y_t       : unsigned(9 downto 0);
    signal de_t, hs_t, vs_t : std_logic;

    signal red, green, blue : std_logic_vector(7 downto 0);
    signal de_r, hs_r, vs_r : std_logic;

    signal q_b, q_g, q_r : std_logic_vector(9 downto 0);

    constant CLK_PATTERN : std_logic_vector(9 downto 0) := "1111100000";
begin

    hdmi_tx_hpd <= '1';

    timing_i : entity work.vga_timing_640x480
        port map (
            clk_pixel => clk_pixel,
            rst       => rst,
            x         => x_t,
            y         => y_t,
            de        => de_t,
            hsync     => hs_t,
            vsync     => vs_t );

    console_i : entity work.console_renderer
        port map (
            clk_pixel       => clk_pixel,
            rst             => rst,
            x_in            => x_t,
            y_in            => y_t,
            de_in           => de_t,
            hsync_in        => hs_t,
            vsync_in        => vs_t,
            range_in        => range_in,
            als_value       => als_value,
            ambient_mode    => ambient_mode,
            severity_now    => severity_now,
            presence        => presence,
            log_pulse_pixel => log_pulse_pixel,
            sev_value       => sev_value,
            contacts        => contacts,
            count           => count,
            t_seconds       => t_seconds,
            arm             => arm,
            near_th         => near_th,
            warn_th         => warn_th,
            red             => red,
            green           => green,
            blue            => blue,
            de_out          => de_r,
            hsync_out       => hs_r,
            vsync_out       => vs_r );

    enc_b : entity work.tmds_encoder
        port map ( clk_pixel => clk_pixel, rst => rst,
                   d => blue, c0 => hs_r, c1 => vs_r, de => de_r,
                   q_out => q_b );

    enc_g : entity work.tmds_encoder
        port map ( clk_pixel => clk_pixel, rst => rst,
                   d => green, c0 => '0', c1 => '0', de => de_r,
                   q_out => q_g );

    enc_r : entity work.tmds_encoder
        port map ( clk_pixel => clk_pixel, rst => rst,
                   d => red, c0 => '0', c1 => '0', de => de_r,
                   q_out => q_r );

    ser_b : entity work.tmds_serializer
        port map ( clk_pixel => clk_pixel, clk_serial => clk_serial, rst => rst,
                   data_in => q_b, d_p => hdmi_tx_d_p(0), d_n => hdmi_tx_d_n(0) );

    ser_g : entity work.tmds_serializer
        port map ( clk_pixel => clk_pixel, clk_serial => clk_serial, rst => rst,
                   data_in => q_g, d_p => hdmi_tx_d_p(1), d_n => hdmi_tx_d_n(1) );

    ser_r : entity work.tmds_serializer
        port map ( clk_pixel => clk_pixel, clk_serial => clk_serial, rst => rst,
                   data_in => q_r, d_p => hdmi_tx_d_p(2), d_n => hdmi_tx_d_n(2) );

    ser_c : entity work.tmds_serializer
        port map ( clk_pixel => clk_pixel, clk_serial => clk_serial, rst => rst,
                   data_in => CLK_PATTERN,
                   d_p => hdmi_tx_clk_p, d_n => hdmi_tx_clk_n );

end architecture;
