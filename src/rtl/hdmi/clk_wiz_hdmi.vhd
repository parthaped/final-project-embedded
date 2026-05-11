-- clk_wiz_hdmi.vhd
--   Wrapper around the Vivado Clocking Wizard IP (an MMCM under the
--   hood). Takes the on-board 125 MHz sysclk and produces three
--   synchronous outputs:
--     clk_pixel   25  MHz (VGA timing + console renderer + TMDS encode)
--     clk_serial  125 MHz (TMDS serializer high-speed input; matches
--                          the system clock so OSERDESE2 sees a
--                          synchronous CLK / CLKDIV pair)
--     clk_sys     125 MHz (the rest of the design)
--   ref: Vivado Clocking Wizard PG065; UG472 7-Series Clocking
--        Resources.
--
--   The IP itself is generated on the fly from scripts/build.tcl
--   (create_ip / set_property / generate_target) so there's no .xci
--   committed -- only this wrapper.

library ieee;
use ieee.std_logic_1164.all;

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

    -- IP-generated component. Vivado writes the matching declaration
    -- in <module_name>.vhd; we just need to match its port list.
    component clk_wiz_hdmi_ip
        port (
            clk_in1  : in  std_logic;
            reset    : in  std_logic;
            clk_out1 : out std_logic;     -- 25 MHz pixel
            clk_out2 : out std_logic;     -- 125 MHz serial
            clk_out3 : out std_logic;     -- 125 MHz sys
            locked   : out std_logic
        );
    end component;

begin

    u_clk_wiz : clk_wiz_hdmi_ip
        port map (
            clk_in1  => clk_in,
            reset    => rst_in,
            clk_out1 => clk_pixel,
            clk_out2 => clk_serial,
            clk_out3 => clk_sys,
            locked   => locked );

end architecture;
