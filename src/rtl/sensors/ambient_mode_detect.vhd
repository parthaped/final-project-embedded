-- ============================================================================
-- ambient_mode_detect.vhd
--   Maps a filtered ALS reading (0..255 as exposed by pmod_als_spi) to one
--   of four ambient modes with hysteresis to prevent rapid bouncing across
--   threshold boundaries:
--
--       NIGHT  : als < 16
--       DIM    : 16 <= als < 96
--       DAY    : 96 <= als < 200
--       BRIGHT : als >= 200
--
--   Hysteresis: once we are in a given mode, the ALS must move past the
--   neighbouring threshold by HYST_DELTA before we transition.  This
--   keeps the risk-matrix cursor from twitching when the filtered ALS
--   value sits right on a boundary.
--
--   Outputs an unsigned(1 downto 0) mode code:
--       "00" NIGHT  "01" DIM  "10" DAY  "11" BRIGHT
--   plus a 1-cycle `mode_change` pulse whenever the mode transitions
--   (used by the OLED to know to re-render its mode line, and reserved
--   for any future audible-cue logic).
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ambient_mode_detect is
    generic (
        -- Boundaries on the 0..255 ALS scale.
        TH_DIM    : natural := 16;
        TH_DAY    : natural := 96;
        TH_BRIGHT : natural := 200;
        -- Symmetric hysteresis applied to all three boundaries.
        HYST_DELTA : natural := 8
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- Filtered ALS value.  We only care about the low 8 bits because
        -- the ALS is 8-bit; the upstream filter returns a 16-bit unsigned.
        als_value    : in  unsigned(15 downto 0);

        ambient_mode : out unsigned(1 downto 0);
        mode_change  : out std_logic
    );
end entity;

architecture rtl of ambient_mode_detect is
    constant M_NIGHT  : unsigned(1 downto 0) := "00";
    constant M_DIM    : unsigned(1 downto 0) := "01";
    constant M_DAY    : unsigned(1 downto 0) := "10";
    constant M_BRIGHT : unsigned(1 downto 0) := "11";

    -- Snapshot the low byte once per clock to break long paths from the
    -- moving average filter into the threshold comparators.
    signal als_lo    : unsigned(7 downto 0) := (others => '0');

    signal mode_r    : unsigned(1 downto 0) := M_DAY;
    signal mode_d1   : unsigned(1 downto 0) := M_DAY;

    -- Compute hysteresis-adjusted upper/lower bounds of the *current*
    -- mode.  Using natural here so we can subtract HYST_DELTA without
    -- worrying about underflow at the boundaries; if a threshold ends up
    -- negative we clamp at 0.  Same on the high end for 255.
    function clamp_lo (n : integer) return natural is
    begin
        if n < 0 then return 0; else return n; end if;
    end function;

    function clamp_hi (n : integer) return natural is
    begin
        if n > 255 then return 255; else return n; end if;
    end function;

    constant TH_DIM_HI    : natural := clamp_hi(TH_DIM    + HYST_DELTA);
    constant TH_DIM_LO    : natural := clamp_lo(TH_DIM    - HYST_DELTA);
    constant TH_DAY_HI    : natural := clamp_hi(TH_DAY    + HYST_DELTA);
    constant TH_DAY_LO    : natural := clamp_lo(TH_DAY    - HYST_DELTA);
    constant TH_BRIGHT_HI : natural := clamp_hi(TH_BRIGHT + HYST_DELTA);
    constant TH_BRIGHT_LO : natural := clamp_lo(TH_BRIGHT - HYST_DELTA);
begin

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                als_lo  <= (others => '0');
                mode_r  <= M_DAY;
                mode_d1 <= M_DAY;
            else
                -- Saturate-to-byte.  Anything over 255 stays at 255.
                if als_value > to_unsigned(255, als_value'length) then
                    als_lo <= to_unsigned(255, als_lo'length);
                else
                    als_lo <= als_value(7 downto 0);
                end if;

                mode_d1 <= mode_r;

                case mode_r is
                    when M_NIGHT =>
                        if als_lo >= to_unsigned(TH_DIM_HI, als_lo'length) then
                            mode_r <= M_DIM;
                        end if;

                    when M_DIM =>
                        if als_lo < to_unsigned(TH_DIM_LO, als_lo'length) then
                            mode_r <= M_NIGHT;
                        elsif als_lo >= to_unsigned(TH_DAY_HI, als_lo'length) then
                            mode_r <= M_DAY;
                        end if;

                    when M_DAY =>
                        if als_lo < to_unsigned(TH_DAY_LO, als_lo'length) then
                            mode_r <= M_DIM;
                        elsif als_lo >= to_unsigned(TH_BRIGHT_HI, als_lo'length) then
                            mode_r <= M_BRIGHT;
                        end if;

                    when M_BRIGHT =>
                        if als_lo < to_unsigned(TH_BRIGHT_LO, als_lo'length) then
                            mode_r <= M_DAY;
                        end if;

                    when others =>
                        mode_r <= M_DAY;
                end case;
            end if;
        end if;
    end process;

    ambient_mode <= mode_r;
    mode_change  <= '1' when mode_r /= mode_d1 else '0';

end architecture;
