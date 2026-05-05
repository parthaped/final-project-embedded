-- ============================================================================
-- pmod_maxsonar_pw.vhd
--   Reads the PW output of a Pmod MAXSONAR (MaxBotix LV-MaxSonar-EZ1).
--
--   The sensor pulses PW high for 147 us per inch of measured range, in
--   free-running mode about every 50 ms.  At a 100 MHz system clock that
--   is 14_700 cycles per inch, so:
--       inches = pw_high_count / 14_700
--   Division is implemented as a multiply-by-reciprocal:
--       inches ~= (pw_high_count * 1141) >> 24
--   which is exact within +/- 0.1 inch over the full 6..254 inch range.
--
--   A 100 ms watchdog produces `data_valid = 1` with `distance_in = 0`
--   if no pulse arrives, so the rest of the system does not stall.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pmod_maxsonar_pw is
    generic (
        -- Multiply-by-reciprocal constants for `cycles_per_inch`.
        -- Defaults assume 100 MHz sys_clk and 147 us/inch:
        --    cycles_per_inch = 14700
        --    RECIP_MUL       = round(2^24 / 14700) = 1141
        --    RECIP_SHIFT     = 24
        RECIP_MUL        : positive := 1141;
        RECIP_SHIFT      : positive := 24;
        -- Watchdog: drop a zero reading if no pulse for this many cycles.
        -- Default 100 ms at 100 MHz.
        WATCHDOG_CYCLES  : positive := 10_000_000
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        pw_in       : in  std_logic;     -- raw async PW pin
        distance_in : out unsigned(15 downto 0);
        data_valid  : out std_logic
    );
end entity;

architecture rtl of pmod_maxsonar_pw is
    signal pw_sync   : std_logic;
    signal pw_d1     : std_logic := '0';
    signal pw_rise   : std_logic;
    signal pw_fall   : std_logic;

    signal counting  : std_logic := '0';
    signal high_cnt  : unsigned(31 downto 0) := (others => '0');
    signal wdt_cnt   : unsigned(31 downto 0) := (others => '0');

    -- Multiplication pipeline.
    signal mul_busy  : std_logic := '0';
    signal mul_in    : unsigned(31 downto 0) := (others => '0');
    signal mul_res   : unsigned(31 + 16 downto 0) := (others => '0');
begin
    -- Sync the PW input.
    sync_i : entity work.synchronizer
        generic map ( STAGES => 2, RST_VAL => '0' )
        port map    ( clk => clk, rst => rst, d_in => pw_in, d_out => pw_sync );

    pw_rise <= pw_sync and not pw_d1;
    pw_fall <= (not pw_sync) and pw_d1;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pw_d1       <= '0';
                counting    <= '0';
                high_cnt    <= (others => '0');
                wdt_cnt     <= (others => '0');
                mul_busy    <= '0';
                mul_in      <= (others => '0');
                mul_res     <= (others => '0');
                distance_in <= (others => '0');
                data_valid  <= '0';
            else
                pw_d1      <= pw_sync;
                data_valid <= '0';

                ---------------------------------------------------------------
                -- Pulse-width capture
                ---------------------------------------------------------------
                if pw_rise = '1' then
                    counting <= '1';
                    high_cnt <= (others => '0');
                    wdt_cnt  <= (others => '0');
                elsif pw_fall = '1' and counting = '1' then
                    counting <= '0';
                    -- Kick off the multiply.
                    mul_in   <= high_cnt;
                    mul_busy <= '1';
                elsif counting = '1' then
                    high_cnt <= high_cnt + 1;
                end if;

                ---------------------------------------------------------------
                -- Watchdog (only ticks while we are *not* counting)
                ---------------------------------------------------------------
                if counting = '0' then
                    if wdt_cnt = to_unsigned(WATCHDOG_CYCLES-1, wdt_cnt'length) then
                        wdt_cnt     <= (others => '0');
                        distance_in <= (others => '0');
                        data_valid  <= '1';
                    else
                        wdt_cnt <= wdt_cnt + 1;
                    end if;
                end if;

                ---------------------------------------------------------------
                -- Multiply-by-reciprocal.  One DSP multiplier; one cycle.
                ---------------------------------------------------------------
                if mul_busy = '1' then
                    mul_res  <= mul_in * to_unsigned(RECIP_MUL, 16);
                    mul_busy <= '0';
                    -- Reuse mul_busy as a 1-cycle delay flag: when it falls
                    -- to 0, mul_res is valid; latch the result on the next
                    -- iteration.
                end if;

                -- Detect "mul just finished": when mul_busy was '1' last
                -- cycle and is '0' now, mul_res holds the answer.  We
                -- collapse this into a registered output: emit the value
                -- one cycle after mul_busy goes low.
                if mul_busy = '0' and (mul_res /= 0) then
                    distance_in <= resize(
                        shift_right(mul_res, RECIP_SHIFT),
                        distance_in'length);
                    data_valid <= '1';
                    mul_res    <= (others => '0');
                end if;
            end if;
        end if;
    end process;

end architecture;
