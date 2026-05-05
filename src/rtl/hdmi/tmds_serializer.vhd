-- ============================================================================
-- tmds_serializer.vhd
--   10:1 serializer for one TMDS lane on Zynq-7000 (xc7z010).  Uses two
--   cascaded OSERDESE2 primitives (master + slave) in DDR 10:1 mode, then
--   drives the result through OBUFDS.
--
--   The same module is reused for the clock channel by feeding the constant
--   pattern "1111100000" on `data_in`.
--
--   Reference: Xilinx XAPP1064 / UG471 7-Series SelectIO User Guide.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity tmds_serializer is
    port (
        clk_pixel  : in  std_logic;
        clk_serial : in  std_logic;
        rst        : in  std_logic;
        data_in    : in  std_logic_vector(9 downto 0);
        d_p        : out std_logic;
        d_n        : out std_logic
    );
end entity;

architecture rtl of tmds_serializer is
    signal shift1 : std_logic;
    signal shift2 : std_logic;
    signal oq     : std_logic;
begin

    -- Master serializer: emits bits 0..7.
    oserdes_m : OSERDESE2
        generic map (
            DATA_RATE_OQ   => "DDR",
            DATA_RATE_TQ   => "DDR",
            DATA_WIDTH     => 10,
            SERDES_MODE    => "MASTER",
            TRISTATE_WIDTH => 1 )
        port map (
            OFB       => open,
            OQ        => oq,
            SHIFTOUT1 => open,
            SHIFTOUT2 => open,
            TBYTEOUT  => open,
            TFB       => open,
            TQ        => open,
            CLK       => clk_serial,
            CLKDIV    => clk_pixel,
            D1        => data_in(0),
            D2        => data_in(1),
            D3        => data_in(2),
            D4        => data_in(3),
            D5        => data_in(4),
            D6        => data_in(5),
            D7        => data_in(6),
            D8        => data_in(7),
            OCE       => '1',
            RST       => rst,
            SHIFTIN1  => shift1,
            SHIFTIN2  => shift2,
            T1        => '0',
            T2        => '0',
            T3        => '0',
            T4        => '0',
            TBYTEIN   => '0',
            TCE       => '0' );

    -- Slave serializer: contributes bits 8 and 9 via SHIFTOUT.
    oserdes_s : OSERDESE2
        generic map (
            DATA_RATE_OQ   => "DDR",
            DATA_RATE_TQ   => "DDR",
            DATA_WIDTH     => 10,
            SERDES_MODE    => "SLAVE",
            TRISTATE_WIDTH => 1 )
        port map (
            OFB       => open,
            OQ        => open,
            SHIFTOUT1 => shift1,
            SHIFTOUT2 => shift2,
            TBYTEOUT  => open,
            TFB       => open,
            TQ        => open,
            CLK       => clk_serial,
            CLKDIV    => clk_pixel,
            D1        => '0',
            D2        => '0',
            D3        => data_in(8),
            D4        => data_in(9),
            D5        => '0',
            D6        => '0',
            D7        => '0',
            D8        => '0',
            OCE       => '1',
            RST       => rst,
            SHIFTIN1  => '0',
            SHIFTIN2  => '0',
            T1        => '0',
            T2        => '0',
            T3        => '0',
            T4        => '0',
            TBYTEIN   => '0',
            TCE       => '0' );

    diff_buf : OBUFDS
        port map ( I => oq, O => d_p, OB => d_n );

end architecture;
