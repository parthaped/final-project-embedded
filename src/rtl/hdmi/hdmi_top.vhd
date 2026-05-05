-- ============================================================================
-- hdmi_top.vhd
--   Wires together the VGA timing generator, the radar renderer, three
--   TMDS encoders and four TMDS serializers (R / G / B / clock) to drive
--   the on-board HDMI TX port in DVI mode.
--
--   Clock channel:  Sends the constant 10-bit pattern "1111100000" so the
--                   sink recovers a clock at f_pixel.
--
--   DVI channel mapping (DDC EDID is unused; we drive HPD high to convince
--   most monitors to lock without it):
--       Channel 0 = Blue   (carries c0=hsync, c1=vsync during blanking)
--       Channel 1 = Green  (c0=c1=0)
--       Channel 2 = Red    (c0=c1=0)
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity hdmi_top is
    port (
        clk_pixel    : in  std_logic;
        clk_serial   : in  std_logic;
        rst          : in  std_logic;

        distance_in  : in  unsigned(15 downto 0);
        als_value    : in  unsigned(15 downto 0);

        hdmi_tx_clk_p : out std_logic;
        hdmi_tx_clk_n : out std_logic;
        hdmi_tx_d_p   : out std_logic_vector(2 downto 0);
        hdmi_tx_d_n   : out std_logic_vector(2 downto 0);
        hdmi_tx_hpd   : out std_logic
    );
end entity;

architecture rtl of hdmi_top is
    -- VGA timing
    signal x_t, y_t       : unsigned(9 downto 0);
    signal de_t, hs_t, vs_t : std_logic;

    -- Renderer outputs
    signal red, green, blue : std_logic_vector(7 downto 0);
    signal de_r, hs_r, vs_r : std_logic;

    -- Encoder outputs
    signal q_b, q_g, q_r : std_logic_vector(9 downto 0);

    -- TMDS clock pattern
    constant CLK_PATTERN : std_logic_vector(9 downto 0) := "1111100000";
begin

    hdmi_tx_hpd <= '1';

    -- ---------------------------------------------------------------
    -- Pixel pipeline: timing -> renderer
    -- ---------------------------------------------------------------
    timing_i : entity work.vga_timing_640x480
        port map (
            clk_pixel => clk_pixel,
            rst       => rst,
            x         => x_t,
            y         => y_t,
            de        => de_t,
            hsync     => hs_t,
            vsync     => vs_t );

    radar_i : entity work.radar_renderer
        port map (
            clk_pixel   => clk_pixel,
            rst         => rst,
            x_in        => x_t,
            y_in        => y_t,
            de_in       => de_t,
            hsync_in    => hs_t,
            vsync_in    => vs_t,
            distance_in => distance_in,
            als_value   => als_value,
            red         => red,
            green       => green,
            blue        => blue,
            de_out      => de_r,
            hsync_out   => hs_r,
            vsync_out   => vs_r );

    -- ---------------------------------------------------------------
    -- TMDS encoders (per channel)
    -- ---------------------------------------------------------------
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

    -- ---------------------------------------------------------------
    -- Serializers + differential output buffers
    -- ---------------------------------------------------------------
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
