-- ============================================================================
-- tb_threshold_detect.vhd
--   Walks the reworked threshold comparator through every meaningful
--   (sonar_band, ambient_mode) cell in the severity table and asserts
--   the resulting severity_now / sonar_alert / sonar_warn / trig flags
--   after the 2-cycle output pipeline has settled.
--
--   Severity table (matches threshold_detect.vhd and the project plan):
--       alert + DAY     -> LOW    "00"
--       alert + DIM     -> MED    "01"
--       alert + NIGHT   -> HIGH   "10"
--       alert + BRIGHT  -> CRIT   "11"
--       warn  + DIM/NIGHT -> LOW  "00"   (and trig=1)
--       warn  + DAY/BRIGHT -> trig=0 (warn does not promote in good light)
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_threshold_detect is
end entity;

architecture sim of tb_threshold_detect is
    constant CLK_PERIOD : time := 10 ns;

    -- Ambient codes (must match ambient_mode_detect / threshold_detect).
    constant A_NIGHT  : unsigned(1 downto 0) := "00";
    constant A_DIM    : unsigned(1 downto 0) := "01";
    constant A_DAY    : unsigned(1 downto 0) := "10";
    constant A_BRIGHT : unsigned(1 downto 0) := "11";

    constant SEV_LOW  : unsigned(1 downto 0) := "00";
    constant SEV_MED  : unsigned(1 downto 0) := "01";
    constant SEV_HIGH : unsigned(1 downto 0) := "10";
    constant SEV_CRIT : unsigned(1 downto 0) := "11";

    signal clk           : std_logic := '0';
    signal rst           : std_logic := '1';
    signal sonar_in      : unsigned(15 downto 0) := (others => '0');
    signal ambient_mode  : unsigned(1 downto 0)  := A_DAY;
    signal sonar_near_th : unsigned(7 downto 0)  := to_unsigned(24, 8);
    signal sonar_warn_th : unsigned(7 downto 0)  := to_unsigned(48, 8);

    signal sonar_alert   : std_logic;
    signal sonar_warn    : std_logic;
    signal trig          : std_logic;
    signal severity_now  : unsigned(1 downto 0);
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.threshold_detect
        port map (
            clk           => clk,
            rst           => rst,
            sonar_in      => sonar_in,
            ambient_mode  => ambient_mode,
            sonar_near_th => sonar_near_th,
            sonar_warn_th => sonar_warn_th,
            sonar_alert   => sonar_alert,
            sonar_warn    => sonar_warn,
            trig          => trig,
            severity_now  => severity_now );

    main : process
        procedure tick(n : integer := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure check (
            sonar    : integer;
            amb      : unsigned(1 downto 0);
            e_alert  : std_logic;
            e_warn   : std_logic;
            e_trig   : std_logic;
            e_sev    : unsigned(1 downto 0);
            tag      : string )
        is
        begin
            sonar_in     <= to_unsigned(sonar, sonar_in'length);
            ambient_mode <= amb;
            tick(4);
            assert sonar_alert = e_alert
                report tag & ": sonar_alert expected " & to_string(e_alert) &
                       " got " & to_string(sonar_alert)
                severity failure;
            assert sonar_warn = e_warn
                report tag & ": sonar_warn expected " & to_string(e_warn) &
                       " got " & to_string(sonar_warn)
                severity failure;
            assert trig = e_trig
                report tag & ": trig expected " & to_string(e_trig) &
                       " got " & to_string(trig)
                severity failure;
            -- severity is don't-care when no band is asserted; only
            -- check it where the contact_log would actually sample it.
            if (e_alert = '1') or (e_warn = '1' and e_trig = '1') then
                assert severity_now = e_sev
                    report tag & ": severity_now expected " & to_string(e_sev) &
                           " got " & to_string(severity_now)
                    severity failure;
            end if;
        end procedure;
    begin
        tick(3);
        rst <= '0';
        tick(2);

        -- Far away in any ambient -> nothing fires.
        check(sonar => 100, amb => A_DAY,
              e_alert => '0', e_warn => '0',
              e_trig => '0', e_sev => SEV_LOW,
              tag => "safe-far DAY");

        -- alert + DAY    -> LOW
        check(sonar => 12, amb => A_DAY,
              e_alert => '1', e_warn => '0',
              e_trig => '1', e_sev => SEV_LOW,
              tag => "alert+DAY");

        -- alert + DIM    -> MED  (this is the path the original build
        -- could never reach; verifies the fix.)
        check(sonar => 12, amb => A_DIM,
              e_alert => '1', e_warn => '0',
              e_trig => '1', e_sev => SEV_MED,
              tag => "alert+DIM");

        -- alert + NIGHT  -> HIGH
        check(sonar => 8, amb => A_NIGHT,
              e_alert => '1', e_warn => '0',
              e_trig => '1', e_sev => SEV_HIGH,
              tag => "alert+NIGHT");

        -- alert + BRIGHT -> CRIT
        check(sonar => 8, amb => A_BRIGHT,
              e_alert => '1', e_warn => '0',
              e_trig => '1', e_sev => SEV_CRIT,
              tag => "alert+BRIGHT");

        -- warn + DIM     -> LOW (trig promoted because ambient is dark)
        check(sonar => 36, amb => A_DIM,
              e_alert => '0', e_warn => '1',
              e_trig => '1', e_sev => SEV_LOW,
              tag => "warn+DIM");

        -- warn + NIGHT   -> LOW (trig promoted)
        check(sonar => 36, amb => A_NIGHT,
              e_alert => '0', e_warn => '1',
              e_trig => '1', e_sev => SEV_LOW,
              tag => "warn+NIGHT");

        -- warn + DAY     -> trig=0 (warn does NOT promote in good light)
        check(sonar => 36, amb => A_DAY,
              e_alert => '0', e_warn => '1',
              e_trig => '0', e_sev => SEV_LOW,
              tag => "warn+DAY (no trig)");

        -- warn + BRIGHT  -> trig=0 likewise
        check(sonar => 36, amb => A_BRIGHT,
              e_alert => '0', e_warn => '1',
              e_trig => '0', e_sev => SEV_LOW,
              tag => "warn+BRIGHT (no trig)");

        -- Boundary: sonar exactly at near_th should NOT alert.
        check(sonar => 24, amb => A_DAY,
              e_alert => '0', e_warn => '1',
              e_trig => '0', e_sev => SEV_LOW,
              tag => "sonar=NEAR (warn band)");

        -- Boundary: sonar = near_th - 1 should alert.
        check(sonar => 23, amb => A_DAY,
              e_alert => '1', e_warn => '0',
              e_trig => '1', e_sev => SEV_LOW,
              tag => "sonar=NEAR-1 (alert)");

        -- sonar=0 is "no sample"; never trips.
        check(sonar => 0, amb => A_NIGHT,
              e_alert => '0', e_warn => '0',
              e_trig => '0', e_sev => SEV_LOW,
              tag => "sonar=0 (no sample)");

        -- Reset clears all outputs.
        sonar_in     <= to_unsigned(8, sonar_in'length);
        ambient_mode <= A_NIGHT;
        tick(4);
        rst <= '1';
        tick(3);
        assert (trig = '0') and (sonar_alert = '0') and (sonar_warn = '0')
            report "threshold_detect: outputs not cleared by reset"
            severity failure;

        report "tb_threshold_detect PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
