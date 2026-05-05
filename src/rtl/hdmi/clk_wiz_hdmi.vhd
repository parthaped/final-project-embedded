-- ============================================================================
-- clk_wiz_hdmi.vhd
--   Wraps an MMCME2_BASE primitive that takes the on-board 125 MHz sysclk
--   and produces:
--     clk_sys     - 125 MHz, BUFG'd, drives the rest of the design
--     clk_pixel   - 25  MHz, BUFG'd, drives the VGA timing / renderer
--     clk_serial  - 125 MHz, BUFG'd, drives the OSERDESE2 serializers
--                   (5x pixel; matches the system clock frequency)
--
--   VCO = 125 * 8 = 1000 MHz, well inside the MMCME2 -1 speed-grade range.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity clk_wiz_hdmi is
    port (
        clk_in     : in  std_logic;
        rst_in     : in  std_logic;
        clk_sys    : out std_logic;
        clk_pixel  : out std_logic;
        clk_serial : out std_logic;
        locked     : out std_logic
    );
end entity;

architecture rtl of clk_wiz_hdmi is
    signal clk_in_buf  : std_logic;
    signal clk_fb_unb  : std_logic;
    signal clk_fb      : std_logic;
    signal clk_pix_unb : std_logic;
    signal clk_ser_unb : std_logic;
    signal clk_sys_unb : std_logic;
begin

    ibuf_clk : IBUFG
        port map ( I => clk_in, O => clk_in_buf );

    mmcm_i : MMCME2_BASE
        generic map (
            BANDWIDTH          => "OPTIMIZED",
            CLKFBOUT_MULT_F    => 8.0,             -- VCO = 1000 MHz
            CLKFBOUT_PHASE     => 0.0,
            CLKIN1_PERIOD      => 8.0,             -- 125 MHz
            CLKOUT0_DIVIDE_F   => 40.0,            -- 25 MHz pixel
            CLKOUT0_PHASE      => 0.0,
            CLKOUT0_DUTY_CYCLE => 0.5,
            CLKOUT1_DIVIDE     => 8,               -- 125 MHz serial
            CLKOUT1_PHASE      => 0.0,
            CLKOUT1_DUTY_CYCLE => 0.5,
            CLKOUT2_DIVIDE     => 8,               -- 125 MHz sys
            CLKOUT2_PHASE      => 0.0,
            CLKOUT2_DUTY_CYCLE => 0.5,
            DIVCLK_DIVIDE      => 1,
            REF_JITTER1        => 0.010,
            STARTUP_WAIT       => FALSE )
        port map (
            CLKOUT0   => clk_pix_unb,
            CLKOUT0B  => open,
            CLKOUT1   => clk_ser_unb,
            CLKOUT1B  => open,
            CLKOUT2   => clk_sys_unb,
            CLKOUT2B  => open,
            CLKOUT3   => open,
            CLKOUT3B  => open,
            CLKOUT4   => open,
            CLKOUT5   => open,
            CLKOUT6   => open,
            CLKFBOUT  => clk_fb_unb,
            CLKFBOUTB => open,
            LOCKED    => locked,
            CLKIN1    => clk_in_buf,
            PWRDWN    => '0',
            RST       => rst_in,
            CLKFBIN   => clk_fb );

    bufg_fb  : BUFG port map ( I => clk_fb_unb,  O => clk_fb );
    bufg_pix : BUFG port map ( I => clk_pix_unb, O => clk_pixel );
    bufg_ser : BUFG port map ( I => clk_ser_unb, O => clk_serial );
    bufg_sys : BUFG port map ( I => clk_sys_unb, O => clk_sys );

end architecture;
