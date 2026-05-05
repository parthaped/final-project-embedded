-- ============================================================================
-- pulse_gen.vhd
--   Generic strobe generator.  Emits a 1-cycle pulse every PERIOD_CYCLES
--   clocks.  Used to throttle ALS sampling, generate the OLED refresh tick,
--   and drive the alert blink in the top level.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pulse_gen is
    generic (
        PERIOD_CYCLES : positive := 100_000   -- default 1 ms at 100 MHz
    );
    port (
        clk    : in  std_logic;
        rst    : in  std_logic;
        en     : in  std_logic := '1';
        pulse  : out std_logic
    );
end entity;

architecture rtl of pulse_gen is
    signal cnt : unsigned(31 downto 0) := (others => '0');
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cnt   <= (others => '0');
                pulse <= '0';
            elsif en = '0' then
                cnt   <= (others => '0');
                pulse <= '0';
            else
                if cnt = to_unsigned(PERIOD_CYCLES-1, cnt'length) then
                    cnt   <= (others => '0');
                    pulse <= '1';
                else
                    cnt   <= cnt + 1;
                    pulse <= '0';
                end if;
            end if;
        end if;
    end process;
end architecture;
