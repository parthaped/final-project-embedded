-- ============================================================================
-- system_clock.vhd
--   Free-running clock-of-the-system used by the perimeter monitor.
--
--   Generates a 60 Hz tick (one cycle pulse every 1/60 s) and a
--   16-bit "seconds since arm" counter.  Both are produced in the
--   sys clock domain (typ. 125 MHz on Zybo Rev B); CDC into the pixel
--   domain happens at the renderer boundary.
--
--   The seconds counter is reset on the rising edge of `arm` (so the
--   header can show "T+00:00:00" the moment the operator flips the ARM
--   switch on).  The 60 Hz tick is independent of arm so the rest of
--   the system (history buffer, contact aging) keeps ticking even when
--   the FSM is parked in IDLE.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity system_clock is
    generic (
        -- Default 125 MHz / 60 = 2_083_333 cycles per 60 Hz tick.
        TICK_PERIOD_CYCLES : positive := 2_083_333
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        arm        : in  std_logic;     -- level: '1' = system armed

        tick_60hz  : out std_logic;     -- 1-cycle pulse @ ~60 Hz
        t_seconds  : out unsigned(15 downto 0)
    );
end entity;

architecture rtl of system_clock is
    signal tick_cnt   : unsigned(31 downto 0) := (others => '0');
    signal tick_r     : std_logic := '0';

    signal frame_cnt  : unsigned(5 downto 0) := (others => '0');  -- 0..59
    signal sec_cnt    : unsigned(15 downto 0) := (others => '0');

    signal arm_d1     : std_logic := '0';
begin
    process(clk)
        variable arm_rise : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                tick_cnt   <= (others => '0');
                tick_r     <= '0';
                frame_cnt  <= (others => '0');
                sec_cnt    <= (others => '0');
                arm_d1     <= '0';
            else
                arm_rise := arm and not arm_d1;
                arm_d1   <= arm;

                -- 60 Hz tick generator.
                if tick_cnt = to_unsigned(TICK_PERIOD_CYCLES-1, tick_cnt'length) then
                    tick_cnt <= (others => '0');
                    tick_r   <= '1';
                else
                    tick_cnt <= tick_cnt + 1;
                    tick_r   <= '0';
                end if;

                -- Seconds counter advances every 60 ticks.  Reset on a
                -- fresh ARM rising edge so the header reads "T+00:00:00"
                -- the moment the operator arms the system.
                if arm_rise = '1' then
                    frame_cnt <= (others => '0');
                    sec_cnt   <= (others => '0');
                elsif tick_r = '1' then
                    if frame_cnt = to_unsigned(59, frame_cnt'length) then
                        frame_cnt <= (others => '0');
                        if sec_cnt /= x"FFFF" then
                            sec_cnt <= sec_cnt + 1;
                        end if;
                    else
                        frame_cnt <= frame_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    tick_60hz <= tick_r;
    t_seconds <= sec_cnt;

end architecture;
