-- ============================================================================
-- threshold_detect.vhd
--   Pure-combinational threshold comparators for the filtered ALS and sonar
--   readings, with one-cycle registers on the outputs so the FSM can sample
--   them with no glitches.
--
--   Outputs:
--     trig         - any sensor outside its safe band (used by FSM Monitor).
--     sonar_trig   - sonar object closer than SONAR_NEAR_TH inches.
--     als_trig     - ALS reading either too dark or too bright.
--     ok           - BOTH sonar and ALS triggered (multi-sensor agreement).
--     conf         - ONLY sonar triggered (single-sensor confirm).
--
--   Threshold values are exposed as generics so the top level (or a
--   simulation harness) can re-tune them without touching this file.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity threshold_detect is
    generic (
        SONAR_NEAR_TH  : positive := 24;     -- inches
        ALS_DARK_TH    : natural  := 32;     -- 0..255 raw
        ALS_BRIGHT_TH  : natural  := 220     -- 0..255 raw
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        als_value  : in  unsigned(15 downto 0);
        sonar_in   : in  unsigned(15 downto 0);

        trig       : out std_logic;
        sonar_trig : out std_logic;
        als_trig   : out std_logic;
        ok         : out std_logic;
        conf       : out std_logic
    );
end entity;

architecture rtl of threshold_detect is
    signal son_t, als_t : std_logic;
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                son_t      <= '0';
                als_t      <= '0';
                trig       <= '0';
                sonar_trig <= '0';
                als_trig   <= '0';
                ok         <= '0';
                conf       <= '0';
            else
                son_t <= '0';
                if (sonar_in > 0) and
                   (sonar_in < to_unsigned(SONAR_NEAR_TH, sonar_in'length)) then
                    son_t <= '1';
                end if;

                als_t <= '0';
                if als_value < to_unsigned(ALS_DARK_TH, als_value'length) or
                   als_value > to_unsigned(ALS_BRIGHT_TH, als_value'length) then
                    als_t <= '1';
                end if;

                sonar_trig <= son_t;
                als_trig   <= als_t;
                trig       <= son_t or als_t;
                ok         <= son_t and als_t;
                conf       <= son_t and not als_t;
            end if;
        end if;
    end process;
end architecture;
