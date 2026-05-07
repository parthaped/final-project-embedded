-- ============================================================================
-- event_log_renderer.vhd
--   Six-row timestamped event log panel using the 5x8 OLED font at
--   scale 2 (16 px tall glyphs).  Each row shows one entry from the
--   `contact_log`, formatted as a tightly-packed 27-character line:
--
--       T-MM:SS  XXX IN  AMBIENT  SEV
--
--   Each row's background is tinted by its severity colour so the
--   panel reads as a colour-coded list at a glance.
--
--   Implementation: each row is pre-formatted into a fixed-length
--   27-char array of ASCII bytes, registered once per clock from the
--   live contact array.  The per-pixel decision then performs a
--   single character-array lookup followed by one font_glyph_lit call,
--   which keeps the LUT/ROM cost manageable at synthesis time.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.contact_pkg.all;
use work.font_5x8_pkg.all;
use work.font_render_pkg.all;

entity event_log_renderer is
    generic (
        PANEL_W : positive := 640;
        N_ROWS  : positive := 6;
        ROW_H   : positive := 20;
        SCALE   : positive := 2
    );
    port (
        clk_pixel : in  std_logic;
        rst       : in  std_logic;

        x_in      : in  unsigned(9 downto 0);
        y_in      : in  unsigned(9 downto 0);

        contacts  : in  contact_array_t;
        t_seconds : in  unsigned(15 downto 0);

        red       : out std_logic_vector(7 downto 0);
        green     : out std_logic_vector(7 downto 0);
        blue      : out std_logic_vector(7 downto 0);
        active    : out std_logic
    );
end entity;

architecture rtl of event_log_renderer is
    constant CHAR_W   : integer := 6 * SCALE;        -- 12 px
    constant ROW_X0   : integer := 8;
    constant N_CHARS  : positive := 27;

    type row_chars_t is array (0 to N_CHARS-1) of std_logic_vector(7 downto 0);
    type rows_t is array (0 to N_ROWS-1) of row_chars_t;

    constant ROW_BLANK : row_chars_t := (others => (x"20"));

    constant W_NIGHT  : string(1 to 6) := "NIGHT ";
    constant W_DIM    : string(1 to 6) := " DIM  ";
    constant W_DAY    : string(1 to 6) := " DAY  ";
    constant W_BRIGHT : string(1 to 6) := "BRIGHT";

    constant W_LOW  : string(1 to 4) := " LOW";
    constant W_MED  : string(1 to 4) := " MED";
    constant W_HIGH : string(1 to 4) := "HIGH";
    constant W_CRIT : string(1 to 4) := "CRIT";

    -- Registered per-row data.
    signal rows_q  : rows_t := (others => ROW_BLANK);
    signal valid_q : std_logic_vector(N_ROWS-1 downto 0) := (others => '0');
    signal sev_q   : unsigned(2*N_ROWS-1 downto 0) := (others => '0');

    -- Registered pixel coords.
    signal x_s1, y_s1 : integer range 0 to 1023 := 0;

    -- Output pipeline.
    signal red_r, green_r, blue_r : std_logic_vector(7 downto 0) :=
        (others => '0');
    signal active_r : std_logic := '0';

    function sev_bg_r (s : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case s is
            when "00"   => return x"30";
            when "01"   => return x"40";
            when "10"   => return x"50";
            when others => return x"40";
        end case;
    end function;

    function sev_bg_g (s : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case s is
            when "00"   => return x"30";
            when "01"   => return x"20";
            when "10"   => return x"00";
            when others => return x"00";
        end case;
    end function;

    function sev_bg_b (s : unsigned(1 downto 0)) return std_logic_vector is
    begin
        return x"00";
    end function;

begin

    -- =========================================================================
    -- Build each row's character array from the contact_log entry.
    -- Recomputed every clock cycle, but the inputs are slow-changing
    -- (contacts updates only on a log_pulse, t_seconds increments only
    -- once per second) so this is just register-stable logic.
    -- =========================================================================
    process(clk_pixel)
        variable age_v : unsigned(15 downto 0);
        variable mm    : integer range 0 to 99;
        variable ss    : integer range 0 to 59;
        variable rng   : bcd3_t;
        variable amb_w : string(1 to 6);
        variable sev_w : string(1 to 4);
        variable r     : row_chars_t;
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                rows_q  <= (others => ROW_BLANK);
                valid_q <= (others => '0');
                sev_q   <= (others => '0');
                x_s1 <= 0; y_s1 <= 0;
            else
                x_s1 <= to_integer(x_in);
                y_s1 <= to_integer(y_in);

                for i in 0 to N_ROWS-1 loop
                    valid_q(i) <= contacts(i).valid;
                    sev_q(2*i+1 downto 2*i) <= contacts(i).severity_score;

                    if t_seconds >= contacts(i).t_log then
                        age_v := t_seconds - contacts(i).t_log;
                    else
                        age_v := (others => '0');
                    end if;
                    if age_v > to_unsigned(5999, 16) then
                        age_v := to_unsigned(5999, 16);
                    end if;

                    mm := to_integer(age_v) / 60;
                    ss := to_integer(age_v) mod 60;
                    rng := to_bcd3(contacts(i).range_in);

                    case contacts(i).ambient is
                        when "00"   => amb_w := W_NIGHT;
                        when "01"   => amb_w := W_DIM;
                        when "10"   => amb_w := W_DAY;
                        when others => amb_w := W_BRIGHT;
                    end case;
                    case contacts(i).severity_score is
                        when "00"   => sev_w := W_LOW;
                        when "01"   => sev_w := W_MED;
                        when "10"   => sev_w := W_HIGH;
                        when others => sev_w := W_CRIT;
                    end case;

                    r := ROW_BLANK;
                    -- "T-MM:SS"
                    r(0)  := asc_of('T');
                    r(1)  := asc_of('-');
                    r(2)  := digit_asc(mm / 10);
                    r(3)  := digit_asc(mm mod 10);
                    r(4)  := asc_of(':');
                    r(5)  := digit_asc(ss / 10);
                    r(6)  := digit_asc(ss mod 10);
                    -- "  XXX"
                    r(9)  := digit_asc(to_integer(rng.h));
                    r(10) := digit_asc(to_integer(rng.t));
                    r(11) := digit_asc(to_integer(rng.o));
                    -- " IN  "
                    r(13) := asc_of('I');
                    r(14) := asc_of('N');
                    -- 6-char ambient
                    r(17) := char_at(amb_w, 1);
                    r(18) := char_at(amb_w, 2);
                    r(19) := char_at(amb_w, 3);
                    r(20) := char_at(amb_w, 4);
                    r(21) := char_at(amb_w, 5);
                    r(22) := char_at(amb_w, 6);
                    -- 4-char severity
                    r(23) := char_at(sev_w, 1);
                    r(24) := char_at(sev_w, 2);
                    r(25) := char_at(sev_w, 3);
                    r(26) := char_at(sev_w, 4);

                    rows_q(i) <= r;
                end loop;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Per-pixel decision.  One mux into the per-row char array, one
    -- glyph_lit call.
    -- =========================================================================
    process(clk_pixel)
        variable px, py     : integer;
        variable row        : integer;
        variable row_y0     : integer;
        variable col_in_row : integer;
        variable c_origin_x : integer;
        variable asc        : std_logic_vector(7 downto 0);
        variable lit        : std_logic;
        variable bg_r, bg_g, bg_b : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                red_r   <= (others => '0');
                green_r <= (others => '0');
                blue_r  <= (others => '0');
                active_r <= '0';
            else
                px  := x_s1;
                py  := y_s1;
                row := py / ROW_H;

                if row >= 0 and row < N_ROWS then
                    row_y0     := row * ROW_H + (ROW_H - 8*SCALE)/2;
                    col_in_row := (px - ROW_X0) / CHAR_W;

                    if col_in_row < 0 or col_in_row >= N_CHARS then
                        asc := asc_of(' ');
                    else
                        asc := rows_q(row)(col_in_row);
                    end if;

                    if col_in_row < 0 or col_in_row >= N_CHARS then
                        c_origin_x := 0;
                    else
                        c_origin_x := ROW_X0 + col_in_row * CHAR_W;
                    end if;

                    if valid_q(row) = '1' then
                        lit := glyph_lit(px, py, c_origin_x, row_y0,
                                         SCALE, asc);
                        bg_r := sev_bg_r(sev_q(2*row+1 downto 2*row));
                        bg_g := sev_bg_g(sev_q(2*row+1 downto 2*row));
                        bg_b := sev_bg_b(sev_q(2*row+1 downto 2*row));

                        if lit = '1' then
                            red_r   <= x"FF";
                            green_r <= x"FF";
                            blue_r  <= x"FF";
                        else
                            red_r   <= bg_r;
                            green_r <= bg_g;
                            blue_r  <= bg_b;
                        end if;
                        active_r <= '1';
                    else
                        red_r   <= x"08";
                        green_r <= x"10";
                        blue_r  <= x"08";
                        active_r <= '1';
                    end if;
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
