-- ============================================================================
-- tb_threshold_detect.vhd
--   Walks the threshold comparator through every meaningful (sonar, als)
--   region and asserts the resulting trig / sonar_trig / als_trig / ok /
--   conf flags after the 2-cycle output pipeline has settled.
--
--   Recall:
--     son_t  := sonar_in > 0  AND  sonar_in < SONAR_NEAR_TH
--     als_t  := als_value < ALS_DARK_TH  OR  als_value > ALS_BRIGHT_TH
--     trig   := son_t or als_t
--     ok     := son_t and als_t          (multi-sensor agreement)
--     conf   := son_t and not als_t      (single-sensor confirm)
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_threshold_detect is
end entity;

architecture sim of tb_threshold_detect is
    constant CLK_PERIOD : time := 10 ns;

    constant SONAR_NEAR : positive := 24;
    constant ALS_DARK   : natural  := 32;
    constant ALS_BRIGHT : natural  := 220;

    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal als_value  : unsigned(15 downto 0) := (others => '0');
    signal sonar_in   : unsigned(15 downto 0) := (others => '0');

    signal trig       : std_logic;
    signal sonar_trig : std_logic;
    signal als_trig   : std_logic;
    signal ok         : std_logic;
    signal conf       : std_logic;
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.threshold_detect
        generic map (
            SONAR_NEAR_TH => SONAR_NEAR,
            ALS_DARK_TH   => ALS_DARK,
            ALS_BRIGHT_TH => ALS_BRIGHT )
        port map (
            clk        => clk,
            rst        => rst,
            als_value  => als_value,
            sonar_in   => sonar_in,
            trig       => trig,
            sonar_trig => sonar_trig,
            als_trig   => als_trig,
            ok         => ok,
            conf       => conf );

    main : process
        procedure tick(n : integer := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- Apply (sonar, als), let the 2-cycle output pipeline settle, then
        -- check every flag.
        procedure check (
            sonar    : integer;
            als      : integer;
            e_son    : std_logic;
            e_als    : std_logic;
            e_trig   : std_logic;
            e_ok     : std_logic;
            e_conf   : std_logic;
            tag      : string )
        is
        begin
            sonar_in  <= to_unsigned(sonar, sonar_in'length);
            als_value <= to_unsigned(als,   als_value'length);
            tick(3);   -- 2 register stages + 1 cycle of slack
            assert sonar_trig = e_son
                report tag & ": sonar_trig expected " & to_string(e_son) &
                       " got " & to_string(sonar_trig)
                severity failure;
            assert als_trig = e_als
                report tag & ": als_trig expected " & to_string(e_als) &
                       " got " & to_string(als_trig)
                severity failure;
            assert trig = e_trig
                report tag & ": trig expected " & to_string(e_trig) &
                       " got " & to_string(trig)
                severity failure;
            assert ok = e_ok
                report tag & ": ok expected " & to_string(e_ok) &
                       " got " & to_string(ok)
                severity failure;
            assert conf = e_conf
                report tag & ": conf expected " & to_string(e_conf) &
                       " got " & to_string(conf)
                severity failure;
        end procedure;
    begin
        tick(3);
        rst <= '0';
        tick(2);

        -- All-zero inputs -> nothing should trigger (sonar=0 is treated as
        -- "no valid sample" and ignored; als=0 is < dark_th, so als_trig=1).
        check(sonar => 0, als => 0,
              e_son => '0', e_als => '1',
              e_trig => '1', e_ok => '0', e_conf => '0',
              tag => "all-zero");

        -- Mid-band, far away: nothing should trigger.
        check(sonar => 100, als => 128,
              e_son => '0', e_als => '0',
              e_trig => '0', e_ok => '0', e_conf => '0',
              tag => "safe-band");

        -- Single-sensor confirm: object close, ambient mid-range.
        -- sonar=10 < 24, als=128 (32..220). conf must assert, ok must not.
        check(sonar => 10, als => 128,
              e_son => '1', e_als => '0',
              e_trig => '1', e_ok => '0', e_conf => '1',
              tag => "near+midALS");

        -- Multi-sensor agreement: close object AND dark room.
        check(sonar => 5, als => 5,
              e_son => '1', e_als => '1',
              e_trig => '1', e_ok => '1', e_conf => '0',
              tag => "near+dark");

        -- Multi-sensor agreement: close object AND very bright.
        check(sonar => 12, als => 250,
              e_son => '1', e_als => '1',
              e_trig => '1', e_ok => '1', e_conf => '0',
              tag => "near+bright");

        -- ALS-only trigger (dark): no close object.
        check(sonar => 200, als => 10,
              e_son => '0', e_als => '1',
              e_trig => '1', e_ok => '0', e_conf => '0',
              tag => "far+dark");

        -- ALS-only trigger (bright): no close object.
        check(sonar => 200, als => 240,
              e_son => '0', e_als => '1',
              e_trig => '1', e_ok => '0', e_conf => '0',
              tag => "far+bright");

        -- Boundary: sonar exactly equal to threshold should NOT trigger
        -- (strict less-than).
        check(sonar => SONAR_NEAR, als => 128,
              e_son => '0', e_als => '0',
              e_trig => '0', e_ok => '0', e_conf => '0',
              tag => "sonar=NEAR_TH (boundary)");

        -- Boundary: sonar = NEAR_TH - 1 should trigger.
        check(sonar => SONAR_NEAR - 1, als => 128,
              e_son => '1', e_als => '0',
              e_trig => '1', e_ok => '0', e_conf => '1',
              tag => "sonar=NEAR_TH-1 (boundary)");

        -- Boundary: als exactly at DARK_TH should NOT trigger
        -- (strict less-than for dark; strict greater-than for bright).
        check(sonar => 100, als => ALS_DARK,
              e_son => '0', e_als => '0',
              e_trig => '0', e_ok => '0', e_conf => '0',
              tag => "als=DARK_TH (boundary)");

        check(sonar => 100, als => ALS_BRIGHT,
              e_son => '0', e_als => '0',
              e_trig => '0', e_ok => '0', e_conf => '0',
              tag => "als=BRIGHT_TH (boundary)");

        -- Reset clears all outputs.
        sonar_in  <= to_unsigned(5, sonar_in'length);
        als_value <= to_unsigned(5, als_value'length);
        tick(3);
        rst <= '1';
        tick(2);
        assert (trig = '0') and (sonar_trig = '0') and (als_trig = '0') and
               (ok = '0') and (conf = '0')
            report "threshold_detect: outputs not cleared by reset"
            severity failure;

        report "tb_threshold_detect PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
