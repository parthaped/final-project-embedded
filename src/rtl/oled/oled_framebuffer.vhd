-- oled_framebuffer.vhd
--   512-byte simple dual-port RAM for the SSD1306 (4 pages of 128
--   columns). The synthesizer infers one BRAM18 from the case-statement
--   read and the registered write. Layout matches the SSD1306
--   horizontal addressing data stream: byte index = page * 128 + col,
--   bit 0 of each byte is the top pixel.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity oled_framebuffer is
    port (
        clk    : in  std_logic;

        we     : in  std_logic;
        waddr  : in  unsigned(8 downto 0);
        wdata  : in  std_logic_vector(7 downto 0);

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
