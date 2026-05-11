-- pmod_maxsonar_pw.vhd
--   Reads the PW pin of the Pmod MaxSonar.
--   ref: MaxBotix LV-MaxSonar-EZ1 datasheet; Digilent Pmod MAXSONAR
--        reference manual.
--
--   PW goes high for 147 us per inch of distance, repeating about
--   every 50 ms. At 100 MHz that's 14_700 cycles per inch, so we
--   could divide. Hardware divide is expensive though, so we do the
--   classic "multiply by reciprocal then shift" trick: the constants
--   default to RECIP_MUL = round(2^24 / 14700) = 1141 and RECIP_SHIFT
--   = 24, which gets us inches = (count * 1141) >> 24 to within about
--   +/-0.1 inch over the full range. If no pulse arrives for
--   WATCHDOG_CYCLES, we still emit data_valid='1' with distance=0 so
--   the rest of the pipeline doesn't stall.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pmod_maxsonar_pw is
    generic (
        RECIP_MUL        : positive := 1141;
        RECIP_SHIFT      : positive := 24;
        WATCHDOG_CYCLES  : positive := 10_000_000
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        pw_in       : in  std_logic;
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

    signal mul_busy  : std_logic := '0';
    signal mul_in    : unsigned(31 downto 0) := (others => '0');
    signal mul_res   : unsigned(31 + 16 downto 0) := (others => '0');
begin
    sync_i : entity work.synchronizer
        port map ( clk => clk, rst => rst, d_in => pw_in, d_out => pw_sync );

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

                if pw_rise = '1' then
                    counting <= '1';
                    high_cnt <= (others => '0');
                    wdt_cnt  <= (others => '0');
                elsif pw_fall = '1' and counting = '1' then
                    counting <= '0';
                    mul_in   <= high_cnt;
                    mul_busy <= '1';
                elsif counting = '1' then
                    high_cnt <= high_cnt + 1;
                end if;

                if counting = '0' then
                    if wdt_cnt = to_unsigned(WATCHDOG_CYCLES-1, wdt_cnt'length) then
                        wdt_cnt     <= (others => '0');
                        distance_in <= (others => '0');
                        data_valid  <= '1';
                    else
                        wdt_cnt <= wdt_cnt + 1;
                    end if;
                end if;

                if mul_busy = '1' then
                    mul_res  <= mul_in * to_unsigned(RECIP_MUL, 16);
                    mul_busy <= '0';
                end if;

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
