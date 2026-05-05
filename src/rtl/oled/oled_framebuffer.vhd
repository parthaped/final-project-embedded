-- ============================================================================
-- oled_framebuffer.vhd
--   512-byte simple dual-port RAM (4 pages x 128 columns) for the SSD1306
--   128x32 panel.  Vivado will infer one BRAM18.
--
--   Layout matches the SSD1306 horizontal-addressing data stream:
--       byte index = page * 128 + column
--       inside the byte, bit 0 = top pixel of the page.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity oled_framebuffer is
    port (
        clk    : in  std_logic;

        -- Write port
        we     : in  std_logic;
        waddr  : in  unsigned(8 downto 0);            -- 0..511
        wdata  : in  std_logic_vector(7 downto 0);

        -- Read port
        raddr  : in  unsigned(8 downto 0);
        rdata  : out std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of oled_framebuffer is
    type ram_t is array (0 to 511) of std_logic_vector(7 downto 0);
    signal ram : ram_t := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                ram(to_integer(waddr)) <= wdata;
            end if;
            rdata <= ram(to_integer(raddr));
        end if;
    end process;
end architecture;
