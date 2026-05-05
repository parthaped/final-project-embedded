-- ============================================================================
-- debouncer.vhd
--   Generic active-high button debouncer.  Synchronizes the input, then
--   requires it to remain stable for STABLE_CYCLES before propagating to
--   the output.  Also generates a one-cycle rising-edge pulse.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity debouncer is
    generic (
        -- Default: 20 ms at 100 MHz = 2_000_000 cycles.
        STABLE_CYCLES : positive := 2_000_000
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        btn_in     : in  std_logic;     -- raw async button input
        btn_level  : out std_logic;     -- debounced level
        btn_pulse  : out std_logic      -- 1-cycle pulse on rising edge of level
    );
end entity;

architecture rtl of debouncer is
    signal btn_sync   : std_logic;
    signal cnt        : unsigned(31 downto 0) := (others => '0');
    signal level_r    : std_logic := '0';
    signal level_d1   : std_logic := '0';
begin
    sync_inst : entity work.synchronizer
        generic map ( STAGES => 2, RST_VAL => '0' )
        port map    ( clk => clk, rst => rst, d_in => btn_in, d_out => btn_sync );

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
