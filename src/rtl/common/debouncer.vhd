-- debouncer.vhd
--   Active-high button debouncer. We sync the raw button into our clock
--   first, then only propagate a level change once it has held steady
--   for STABLE_CYCLES cycles. Also makes a 1-cycle pulse on the rising
--   edge of the debounced level so the FSM can use it as a "press"
--   event without re-detecting edges itself.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity debouncer is
    generic (
        STABLE_CYCLES : positive := 2_000_000   -- 20 ms at 100 MHz
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        btn_in     : in  std_logic;
        btn_level  : out std_logic;
        btn_pulse  : out std_logic
    );
end entity;

architecture rtl of debouncer is
    signal btn_sync   : std_logic;
    signal cnt        : unsigned(31 downto 0) := (others => '0');
    signal level_r    : std_logic := '0';
    signal level_d1   : std_logic := '0';
begin
    sync_inst : entity work.synchronizer
        port map ( clk => clk, rst => rst, d_in => btn_in, d_out => btn_sync );

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cnt      <= (others => '0');
                level_r  <= '0';
                level_d1 <= '0';
            else
                if btn_sync = level_r then
                    cnt <= (others => '0');
                else
                    if cnt = to_unsigned(STABLE_CYCLES-1, cnt'length) then
                        level_r <= btn_sync;
                        cnt     <= (others => '0');
                    else
                        cnt <= cnt + 1;
                    end if;
                end if;
                level_d1 <= level_r;
            end if;
        end if;
    end process;

    btn_level <= level_r;
    btn_pulse <= level_r and not level_d1;
end architecture;
