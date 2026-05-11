-- risk_banner_renderer.vhd
--   The big "RISK: <word>" headline panel plus two smaller status rows
--   (PRESENCE / LIGHT). 384x160 px panel; the composer drops it onto
--   the screen and gates the rest of the picture.
--
--   Inputs are registered once (decouple the composer's signals from
--   our combinational logic) and the per-pixel colour is also
--   registered, so the panel has 2 cycles of latency end-to-end. The
--   composer accounts for that when delaying sync.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.font_5x8_pkg.all;
use work.font_render_pkg.all;

entity risk_banner_renderer is
    generic (
        PANEL_W   : positive := 384;
        PANEL_H   : positive := 160;
        BIG_SCALE : positive := 5;
        SMALL_SCALE : positive := 2
    );
    port (
        clk_pixel    : in  std_logic;
        rst          : in  std_logic;

        x_in         : in  unsigned(9 downto 0);
        y_in         : in  unsigned(9 downto 0);

        severity_now : in  unsigned(1 downto 0);
        presence     : in  std_logic;
        range_in     : in  unsigned(7 downto 0);
        ambient_mode : in  unsigned(1 downto 0);
        als_value    : in  unsigned(7 downto 0);
        blink        : in  std_logic;
        arm          : in  std_logic;

        red          : out std_logic_vector(7 downto 0);
        green        : out std_logic_vector(7 downto 0);
        blue         : out std_logic_vector(7 downto 0);
        active       : out std_logic
    );
end entity;

architecture rtl of risk_banner_renderer is
    signal x_s1, y_s1     : integer range 0 to 1023 := 0;
    signal sev_s1         : unsigned(1 downto 0) := (others => '0');
    signal pres_s1        : std_logic := '0';
    signal range_s1       : unsigned(7 downto 0) := (others => '0');
    signal amb_s1         : unsigned(1 downto 0) := (others => '0');
    signal als_s1         : unsigned(7 downto 0) := (others => '0');
    signal blink_s1       : std_logic := '0';
    signal arm_s1         : std_logic := '1';

    signal red_r, green_r, blue_r : std_logic_vector(7 downto 0) :=
        (others => '0');
    signal active_r       : std_logic := '0';

    -- Severity words, padded with leading spaces so each occupies four
    -- glyph slots and the headline width never changes.
    constant W_SAFE : string(1 to 4) := "SAFE";
    constant W_LOW  : string(1 to 4) := " LOW";
    constant W_MED  : string(1 to 4) := " MED";
    constant W_HIGH : string(1 to 4) := "HIGH";
    constant W_CRIT : string(1 to 4) := "CRIT";

    constant W_NIGHT  : string(1 to 6) := "NIGHT ";
    constant W_DIM    : string(1 to 6) := "DIM   ";
    constant W_DAY    : string(1 to 6) := "DAY   ";
    constant W_BRIGHT : string(1 to 6) := "BRIGHT";

    -- BIG-text layout
    constant BIG_Y    : integer := 14;
    constant BIG_W    : integer := 6 * BIG_SCALE;
    constant BIG_X0   : integer := (PANEL_W - 10 * BIG_W) / 2;

    -- Small-text layout
    constant SML_W    : integer := 6 * SMALL_SCALE;
    constant ROW_PRES : integer := 84;
    constant ROW_LIGHT: integer := 110;
    constant SML_X0   : integer := 24;

    function sev_color_r (s : unsigned(1 downto 0); blnk : std_logic;
                          armed : std_logic; pres : std_logic)
        return std_logic_vector
    is
    begin
        if armed = '0' or pres = '0' then
            return x"30";
        else
            case s is
                when "00" => return x"FF";  -- LOW   yellow
                when "01" => return x"FF";  -- MED   orange
                when "10" => return x"FF";  -- HIGH  red
                when others =>              -- CRIT  red+blink
                    if blnk = '1' then return x"FF"; else return x"40"; end if;
            end case;
        end if;
    end function;

    function sev_color_g (s : unsigned(1 downto 0); blnk : std_logic;
                          armed : std_logic; pres : std_logic)
        return std_logic_vector
    is
    begin
        if armed = '0' or pres = '0' then
            return x"E0";
        else
            case s is
                when "00" => return x"E0";
                when "01" => return x"80";
                when "10" => return x"00";
                when others =>
                    if blnk = '1' then return x"00"; else return x"00"; end if;
            end case;
        end if;
    end function;

    function sev_color_b (s : unsigned(1 downto 0); blnk : std_logic;
                          armed : std_logic; pres : std_logic)
        return std_logic_vector
    is
    begin
        if armed = '0' or pres = '0' then
            return x"30";
        else
            case s is
                when "00" => return x"00";
                when "01" => return x"00";
                when "10" => return x"00";
                when others =>
                    if blnk = '1' then return x"00"; else return x"00"; end if;
            end case;
        end if;
    end function;

begin

    -- Register inputs.
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                x_s1     <= 0;
                y_s1     <= 0;
                sev_s1   <= (others => '0');
                pres_s1  <= '0';
                range_s1 <= (others => '0');
                amb_s1   <= (others => '0');
                als_s1   <= (others => '0');
                blink_s1 <= '0';
                arm_s1   <= '1';
            else
                x_s1     <= to_integer(x_in);
                y_s1     <= to_integer(y_in);
                sev_s1   <= severity_now;
                pres_s1  <= presence;
                range_s1 <= range_in;
                amb_s1   <= ambient_mode;
                als_s1   <= als_value;
                blink_s1 <= blink;
                arm_s1   <= arm;
            end if;
        end if;
    end process;

    -- Per-pixel decision. The big word is 10 chars wide ("RISK: " plus
    -- the 4-char severity word). The two small rows are <= 22 chars
    -- each at SMALL_SCALE.
    process(clk_pixel)
        variable big_lit  : std_logic;
        variable sml_lit  : std_logic;
        variable px, py   : integer;

        variable sev_word : string(1 to 4);

        variable rng_bcd : bcd3_t;
        variable als_bcd : bcd3_t;

        variable amb_word : string(1 to 6);

        -- When there is no live presence we always show SAFE so the
        -- headline never reads stale "HIGH" text just because there
        -- was a contact a minute ago. Disarmed also forces SAFE in
        -- dim colours.
        variable eff_sev : unsigned(1 downto 0);
        variable show_sev : boolean;

        constant LBL_PRES : string(1 to 10) := "PRESENCE: ";
        constant LBL_NO   : string(1 to 3)  := "NO ";
        constant LBL_YES  : string(1 to 3)  := "YES";
        constant LBL_LITE : string(1 to 7)  := "LIGHT: ";
        constant LBL_LUX  : string(1 to 4)  := "LUX ";
        constant LBL_RISK : string(1 to 6)  := "RISK: ";
        constant LBL_IN   : string(1 to 2)  := "IN";
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                red_r    <= (others => '0');
                green_r  <= (others => '0');
                blue_r   <= (others => '0');
                active_r <= '0';
            else
                px := x_s1;
                py := y_s1;

                show_sev := (arm_s1 = '1') and (pres_s1 = '1');
                if not show_sev then
                    sev_word := W_SAFE;
                    eff_sev  := "00";
                else
                    case sev_s1 is
                        when "00"   => sev_word := W_LOW;  eff_sev := sev_s1;
                        when "01"   => sev_word := W_MED;  eff_sev := sev_s1;
                        when "10"   => sev_word := W_HIGH; eff_sev := sev_s1;
                        when others => sev_word := W_CRIT; eff_sev := sev_s1;
                    end case;
                end if;

                case amb_s1 is
                    when "00"   => amb_word := W_NIGHT;
                    when "01"   => amb_word := W_DIM;
                    when "10"   => amb_word := W_DAY;
                    when others => amb_word := W_BRIGHT;
                end case;

                rng_bcd := to_bcd3(range_s1);
                als_bcd := to_bcd3(als_s1);

                -- Big word: "RISK: " + sev_word at BIG_SCALE.
                big_lit := '0';
                for i in 0 to 5 loop
                    big_lit := big_lit or
                        glyph_lit(px, py,
                                  BIG_X0 + i * BIG_W, BIG_Y,
                                  BIG_SCALE,
                                  char_at(LBL_RISK, i+1));
                end loop;
                for i in 0 to 3 loop
                    big_lit := big_lit or
                        glyph_lit(px, py,
                                  BIG_X0 + (6+i) * BIG_W, BIG_Y,
                                  BIG_SCALE,
                                  char_at(sev_word, i+1));
                end loop;

                -- Presence row: "PRESENCE: YES/NO  XXX IN"
                sml_lit := '0';
                for i in 0 to 9 loop
                    sml_lit := sml_lit or
                        glyph_lit(px, py,
                                  SML_X0 + i * SML_W, ROW_PRES,
                                  SMALL_SCALE,
                                  char_at(LBL_PRES, i+1));
                end loop;
                for i in 0 to 2 loop
                    if pres_s1 = '1' and arm_s1 = '1' then
                        sml_lit := sml_lit or
                            glyph_lit(px, py,
                                      SML_X0 + (10+i) * SML_W, ROW_PRES,
                                      SMALL_SCALE,
                                      char_at(LBL_YES, i+1));
                    else
                        sml_lit := sml_lit or
                            glyph_lit(px, py,
                                      SML_X0 + (10+i) * SML_W, ROW_PRES,
                                      SMALL_SCALE,
                                      char_at(LBL_NO, i+1));
                    end if;
                end loop;
                if pres_s1 = '1' and arm_s1 = '1' then
                    sml_lit := sml_lit or
                        glyph_lit(px, py,
                                  SML_X0 + 14 * SML_W, ROW_PRES,
                                  SMALL_SCALE,
                                  digit_asc(to_integer(rng_bcd.h)));
                    sml_lit := sml_lit or
                        glyph_lit(px, py,
                                  SML_X0 + 15 * SML_W, ROW_PRES,
                                  SMALL_SCALE,
                                  digit_asc(to_integer(rng_bcd.t)));
                    sml_lit := sml_lit or
                        glyph_lit(px, py,
                                  SML_X0 + 16 * SML_W, ROW_PRES,
                                  SMALL_SCALE,
                                  digit_asc(to_integer(rng_bcd.o)));
                    sml_lit := sml_lit or
                        glyph_lit(px, py,
                                  SML_X0 + 18 * SML_W, ROW_PRES,
                                  SMALL_SCALE,
                                  char_at(LBL_IN, 1));
                    sml_lit := sml_lit or
                        glyph_lit(px, py,
                                  SML_X0 + 19 * SML_W, ROW_PRES,
                                  SMALL_SCALE,
                                  char_at(LBL_IN, 2));
                end if;

                -- Light row: "LIGHT: <ambient> LUX XXX"
                for i in 0 to 6 loop
                    sml_lit := sml_lit or
                        glyph_lit(px, py,
                                  SML_X0 + i * SML_W, ROW_LIGHT,
                                  SMALL_SCALE,
                                  char_at(LBL_LITE, i+1));
                end loop;
                for i in 0 to 5 loop
                    sml_lit := sml_lit or
                        glyph_lit(px, py,
                                  SML_X0 + (7+i) * SML_W, ROW_LIGHT,
                                  SMALL_SCALE,
                                  char_at(amb_word, i+1));
                end loop;
                for i in 0 to 3 loop
                    sml_lit := sml_lit or
                        glyph_lit(px, py,
                                  SML_X0 + (14+i) * SML_W, ROW_LIGHT,
                                  SMALL_SCALE,
                                  char_at(LBL_LUX, i+1));
                end loop;
                sml_lit := sml_lit or
                    glyph_lit(px, py,
                              SML_X0 + 18 * SML_W, ROW_LIGHT,
                              SMALL_SCALE,
                              digit_asc(to_integer(als_bcd.h)));
                sml_lit := sml_lit or
                    glyph_lit(px, py,
                              SML_X0 + 19 * SML_W, ROW_LIGHT,
                              SMALL_SCALE,
                              digit_asc(to_integer(als_bcd.t)));
                sml_lit := sml_lit or
                    glyph_lit(px, py,
                              SML_X0 + 20 * SML_W, ROW_LIGHT,
                              SMALL_SCALE,
                              digit_asc(to_integer(als_bcd.o)));

                -- Big word picks up severity colour; small rows are a
                -- constant cyan-green so they read as supporting info.
                if big_lit = '1' then
                    red_r   <= sev_color_r(eff_sev, blink_s1, arm_s1, pres_s1);
                    green_r <= sev_color_g(eff_sev, blink_s1, arm_s1, pres_s1);
                    blue_r  <= sev_color_b(eff_sev, blink_s1, arm_s1, pres_s1);
                    active_r <= '1';
                elsif sml_lit = '1' then
                    red_r   <= x"50";
                    green_r <= x"FF";
                    blue_r  <= x"80";
                    active_r <= '1';
                else
                    red_r   <= (others => '0');
                    green_r <= (others => '0');
                    blue_r  <= (others => '0');
                    active_r <= '0';
                end if;
            end if;
        end if;
    end process;

    red    <= red_r;
    green  <= green_r;
    blue   <= blue_r;
    active <= active_r;

end architecture;
