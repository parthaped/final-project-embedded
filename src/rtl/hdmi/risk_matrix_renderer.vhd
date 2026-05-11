-- risk_matrix_renderer.vhd
--   4x2 risk matrix panel. Rows are ambient modes (BRIGHT / DAY / DIM
--   / NIGHT, top to bottom) and columns are presence (NO / YES). The
--   live cell, picked from the current ambient mode and presence,
--   gets a thick white highlight ring so the "cursor" visibly tracks
--   what the rest of the system is doing.
--
--   Panel size 256x160 px. y=2..18 title, y=22..40 column header row,
--   y=44..170 the four data rows of 30 px each.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.font_5x8_pkg.all;
use work.font_render_pkg.all;

entity risk_matrix_renderer is
    generic (
        PANEL_W : positive := 256;
        PANEL_H : positive := 160
    );
    port (
        clk_pixel    : in  std_logic;
        rst          : in  std_logic;

        x_in         : in  unsigned(9 downto 0);
        y_in         : in  unsigned(9 downto 0);

        ambient_mode : in  unsigned(1 downto 0);
        presence     : in  std_logic;
        blink        : in  std_logic;

        red          : out std_logic_vector(7 downto 0);
        green        : out std_logic_vector(7 downto 0);
        blue         : out std_logic_vector(7 downto 0);
        active       : out std_logic
    );
end entity;

architecture rtl of risk_matrix_renderer is
    constant TITLE_Y : integer := 2;
    constant HDR_Y   : integer := 22;
    constant ROWS_Y  : integer := 44;
    constant ROW_H   : integer := 30;
    constant COL_LBL_X : integer := 6;
    constant COL_LBL_W : integer := 6 * 2 * 6;
    constant DATA_X0 : integer := 78;
    constant CELL_W  : integer := 86;
    constant CELL_H  : integer := 30;
    constant SCALE   : integer := 2;
    constant CHAR_W  : integer := 6 * SCALE;

    signal x_s1, y_s1 : integer range 0 to 1023 := 0;
    signal amb_s1     : unsigned(1 downto 0) := (others => '0');
    signal pres_s1    : std_logic := '0';
    signal blink_s1   : std_logic := '0';

    signal red_r, green_r, blue_r : std_logic_vector(7 downto 0) :=
        (others => '0');
    signal active_r   : std_logic := '0';

    -- Top-to-bottom: BRIGHT / DAY / DIM / NIGHT. Putting the extreme
    -- ambient cases (NIGHT, BRIGHT) on the outside and the common
    -- ones in the middle reads better visually.
    constant ROW_BRIGHT : string(1 to 6) := "BRIGHT";
    constant ROW_DAY    : string(1 to 6) := " DAY  ";
    constant ROW_DIM    : string(1 to 6) := " DIM  ";
    constant ROW_NIGHT  : string(1 to 6) := "NIGHT ";

    constant LBL_TITLE  : string(1 to 11) := "RISK MATRIX";
    constant LBL_NO     : string(1 to 2)  := "NO";
    constant LBL_YES    : string(1 to 3)  := "YES";

    constant CELL_SAFE  : string(1 to 4) := "SAFE";
    constant CELL_LOW   : string(1 to 4) := " LOW";
    constant CELL_MED   : string(1 to 4) := " MED";
    constant CELL_HIGH  : string(1 to 4) := "HIGH";
    constant CELL_CRIT  : string(1 to 4) := "CRIT";

    -- Severity word per (row, col). row: 0=BRIGHT 1=DAY 2=DIM 3=NIGHT,
    -- col: 0=NO presence (always SAFE), 1=YES presence.
    function cell_word (row : integer; col : integer) return string is
    begin
        if col = 0 then
            return CELL_SAFE;
        else
            case row is
                when 0 => return CELL_CRIT;
                when 1 => return CELL_LOW;
                when 2 => return CELL_MED;
                when 3 => return CELL_HIGH;
                when others => return CELL_SAFE;
            end case;
        end if;
    end function;

    -- Background colour functions. CRIT cell flashes; the others are
    -- constant tints. Three separate functions because VHDL has no
    -- tuple return.
    function cell_bg_r (row, col : integer; blnk : std_logic)
        return std_logic_vector
    is
    begin
        if col = 0 then return x"08";
        else
            case row is
                when 0 =>
                    if blnk = '1' then return x"E0"; else return x"40"; end if;
                when 1 => return x"50";
                when 2 => return x"80";
                when 3 => return x"A0";
                when others => return x"08";
            end case;
        end if;
    end function;

    function cell_bg_g (row, col : integer; blnk : std_logic)
        return std_logic_vector
    is
    begin
        if col = 0 then return x"30";
        else
            case row is
                when 0 =>
                    if blnk = '1' then return x"00"; else return x"00"; end if;
                when 1 => return x"50";
                when 2 => return x"30";
                when 3 => return x"00";
                when others => return x"30";
            end case;
        end if;
    end function;

    function cell_bg_b (row, col : integer; blnk : std_logic)
        return std_logic_vector
    is
    begin
        if col = 0 then return x"08"; end if;
        return x"00";
    end function;

begin

    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                x_s1     <= 0;
                y_s1     <= 0;
                amb_s1   <= (others => '0');
                pres_s1  <= '0';
                blink_s1 <= '0';
            else
                x_s1     <= to_integer(x_in);
                y_s1     <= to_integer(y_in);
                amb_s1   <= ambient_mode;
                pres_s1  <= presence;
                blink_s1 <= blink;
            end if;
        end if;
    end process;

    process(clk_pixel)
        variable px, py    : integer;
        variable in_grid   : boolean;
        variable row_idx   : integer;
        variable col_idx   : integer;
        variable cell_x0   : integer;
        variable cell_y0   : integer;
        variable in_cell_x : integer;
        variable in_cell_y : integer;
        variable on_border : boolean;
        variable on_title  : std_logic;
        variable on_header : std_logic;
        variable on_rowlbl : std_logic;
        variable on_celltext : std_logic;

        variable live_row  : integer;
        variable cell_w_str : string(1 to 4);

        variable bg_r, bg_g, bg_b : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                red_r <= (others => '0');
                green_r <= (others => '0');
                blue_r <= (others => '0');
                active_r <= '0';
            else
                px := x_s1;
                py := y_s1;

                case amb_s1 is
                    when "11"   => live_row := 0;     -- BRIGHT
                    when "10"   => live_row := 1;     -- DAY
                    when "01"   => live_row := 2;     -- DIM
                    when others => live_row := 3;     -- NIGHT
                end case;

                -- Title.
                on_title := '0';
                for i in 0 to 10 loop
                    on_title := on_title or
                        glyph_lit(px, py,
                                  COL_LBL_X + i * CHAR_W, TITLE_Y,
                                  SCALE,
                                  char_at(LBL_TITLE, i+1));
                end loop;

                -- Column header "NO / YES" centred over its column.
                on_header := '0';
                for i in 0 to 1 loop
                    on_header := on_header or
                        glyph_lit(px, py,
                                  DATA_X0 + i * CHAR_W + (CELL_W - 2*CHAR_W)/2,
                                  HDR_Y,
                                  SCALE,
                                  char_at(LBL_NO, i+1));
                end loop;
                for i in 0 to 2 loop
                    on_header := on_header or
                        glyph_lit(px, py,
                                  DATA_X0 + CELL_W + i * CHAR_W +
                                      (CELL_W - 3*CHAR_W)/2,
                                  HDR_Y,
                                  SCALE,
                                  char_at(LBL_YES, i+1));
                end loop;

                -- Data area: 4 rows x 2 cols.
                in_grid := (py >= ROWS_Y) and
                           (py <  ROWS_Y + 4 * ROW_H) and
                           (px >= 0)     and (px < PANEL_W);

                row_idx := -1; col_idx := -1;
                if in_grid then
                    row_idx := (py - ROWS_Y) / ROW_H;
                    if px >= DATA_X0 and px < DATA_X0 + CELL_W then
                        col_idx := 0;
                    elsif px >= DATA_X0 + CELL_W and
                          px <  DATA_X0 + 2 * CELL_W then
                        col_idx := 1;
                    end if;
                end if;

                -- Row labels on the left edge.
                on_rowlbl := '0';
                if in_grid then
                    case row_idx is
                        when 0 =>
                            for i in 0 to 5 loop
                                on_rowlbl := on_rowlbl or
                                    glyph_lit(px, py,
                                              COL_LBL_X + i * CHAR_W,
                                              ROWS_Y + (ROW_H - 8*SCALE)/2,
                                              SCALE,
                                              char_at(ROW_BRIGHT, i+1));
                            end loop;
                        when 1 =>
                            for i in 0 to 5 loop
                                on_rowlbl := on_rowlbl or
                                    glyph_lit(px, py,
                                              COL_LBL_X + i * CHAR_W,
                                              ROWS_Y + ROW_H +
                                                  (ROW_H - 8*SCALE)/2,
                                              SCALE,
                                              char_at(ROW_DAY, i+1));
                            end loop;
                        when 2 =>
                            for i in 0 to 5 loop
                                on_rowlbl := on_rowlbl or
                                    glyph_lit(px, py,
                                              COL_LBL_X + i * CHAR_W,
                                              ROWS_Y + 2 * ROW_H +
                                                  (ROW_H - 8*SCALE)/2,
                                              SCALE,
                                              char_at(ROW_DIM, i+1));
                            end loop;
                        when 3 =>
                            for i in 0 to 5 loop
                                on_rowlbl := on_rowlbl or
                                    glyph_lit(px, py,
                                              COL_LBL_X + i * CHAR_W,
                                              ROWS_Y + 3 * ROW_H +
                                                  (ROW_H - 8*SCALE)/2,
                                              SCALE,
                                              char_at(ROW_NIGHT, i+1));
                            end loop;
                        when others => null;
                    end case;
                end if;

                -- Cell text + border + live-cell highlight.
                on_celltext := '0';
                on_border   := false;
                bg_r := x"08"; bg_g := x"10"; bg_b := x"08";

                if in_grid and col_idx >= 0 then
                    cell_x0 := DATA_X0 + col_idx * CELL_W;
                    cell_y0 := ROWS_Y + row_idx * ROW_H;
                    in_cell_x := px - cell_x0;
                    in_cell_y := py - cell_y0;

                    cell_w_str := cell_word(row_idx, col_idx);

                    -- 4 chars at scale 2 = 48 px wide; centre them.
                    for i in 0 to 3 loop
                        on_celltext := on_celltext or
                            glyph_lit(px, py,
                                      cell_x0 + (CELL_W - 4*CHAR_W)/2 + i*CHAR_W,
                                      cell_y0 + (ROW_H - 8*SCALE)/2,
                                      SCALE,
                                      char_at(cell_w_str, i+1));
                    end loop;

                    bg_r := cell_bg_r(row_idx, col_idx, blink_s1);
                    bg_g := cell_bg_g(row_idx, col_idx, blink_s1);
                    bg_b := cell_bg_b(row_idx, col_idx, blink_s1);

                    on_border := (in_cell_x = 0) or (in_cell_x = CELL_W-1) or
                                 (in_cell_y = 0) or (in_cell_y = ROW_H-1);

                    -- Live cell: 3 px white ring inside the cell.
                    if (row_idx = live_row) and
                       ((col_idx = 0 and pres_s1 = '0') or
                        (col_idx = 1 and pres_s1 = '1')) then
                        if in_cell_x < 3 or in_cell_x >= CELL_W-3 or
                           in_cell_y < 3 or in_cell_y >= ROW_H-3 then
                            on_border := true;
                            bg_r := x"FF"; bg_g := x"FF"; bg_b := x"FF";
                        end if;
                    end if;
                end if;

                if on_title = '1' or on_header = '1' or on_rowlbl = '1' then
                    red_r   <= x"50";
                    green_r <= x"FF";
                    blue_r  <= x"80";
                    active_r <= '1';
                elsif in_grid and col_idx >= 0 then
                    if on_border then
                        red_r   <= bg_r;
                        green_r <= bg_g;
                        blue_r  <= bg_b;
                        active_r <= '1';
                    elsif on_celltext = '1' then
                        red_r   <= x"FF";
                        green_r <= x"FF";
                        blue_r  <= x"FF";
                        active_r <= '1';
                    else
                        red_r   <= bg_r;
                        green_r <= bg_g;
                        blue_r  <= bg_b;
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
