-- clock_div.vhd
--   Lab 1 style clock divider. A counter increments every clk and
--   clk_en pulses high for one cycle every DIV ticks. The pulse is used
--   as a clock-enable on downstream flops so we never make a new clock
--   for slow logic; we just gate things off the system clock.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity clock_div is
    generic (
        DIV : positive := 100_000
    );
    port (
        clk    : in  std_logic;
        rst    : in  std_logic;
        en     : in  std_logic := '1';
        clk_en : out std_logic
    );
end entity;

architecture rtl of clock_div is
    signal cnt : unsigned(31 downto 0) := (others => '0');
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cnt    <= (others => '0');
                clk_en <= '0';
            elsif en = '0' then
                cnt    <= (others => '0');
                clk_en <= '0';
            else
                if cnt = to_unsigned(DIV-1, cnt'length) then
                    cnt    <= (others => '0');
                    clk_en <= '1';
                else
                    cnt    <= cnt + 1;
                    clk_en <= '0';
                end if;
            end if;
        end if;
    end process;
end architecture;
