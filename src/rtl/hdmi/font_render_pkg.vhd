-- ============================================================================
-- font_render_pkg.vhd
--   Helpers for rendering scaled text on the HDMI console using the
--   existing 5x8 OLED font (`font_5x8_pkg`).  All helpers return a
--   single bit ("is this pixel lit?") so the panel renderers can
--   compose them with logic-OR to build complete strings, then
--   colour the result downstream.
--
--   Pixel coordinates are passed as integers because the renderers
--   already promote x_in/y_in to integers for layout arithmetic.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.font_5x8_pkg.all;

package font_render_pkg is

    -- '1' iff the query pixel (px, py) lands on a lit pixel of the
    -- 5x8 glyph for `asc` when the glyph is drawn at top-left (sx,sy)
    -- with integer pixel scale `scale` (1 = native, 2 = 2x, ..., 8 = 8x).
    -- Spacer column (idx 5) and any pixel outside the 5x8 grid return '0'.
    function glyph_lit (
        px, py  : integer;
        sx, sy  : integer;
        scale   : positive;
        asc     : std_logic_vector(7 downto 0)
    ) return std_logic;

    -- ASCII byte for a literal character.  Saves typing x"..." for
    -- string constants.
    function asc_of (c : character) return std_logic_vector;

    -- Convert one BCD digit (0..9) to its ASCII byte.
    function digit_asc (d : integer) return std_logic_vector;

    -- Return ASCII byte for a single character of a fixed-width status
    -- word.  The renderers pull in word arrays (severity, ambient,
    -- state) and ask for the i-th character; this is the glue.
    function char_at (s : string; i : integer) return std_logic_vector;

    -- Decompose an 8-bit value into hundreds / tens / ones digits
    -- (each 0..9 in a 4-bit nibble).  Returns (h, t, o).
    type bcd3_t is record
        h, t, o : unsigned(3 downto 0);
    end record;

    function to_bcd3 (v : unsigned(7 downto 0)) return bcd3_t;

    -- Same but for 16-bit values, returning up to 5 digits.
    type bcd5_t is record
        ten_thou, thou, hund, tens, ones : unsigned(3 downto 0);
    end record;

    function to_bcd5 (v : unsigned(15 downto 0)) return bcd5_t;

end package;

package body font_render_pkg is

    function glyph_lit (
        px, py  : integer;
        sx, sy  : integer;
        scale   : positive;
        asc     : std_logic_vector(7 downto 0)
    ) return std_logic is
        variable rel_x, rel_y : integer;
        variable col, row : integer;
        variable g : glyph_t;
    begin
        rel_x := px - sx;
        rel_y := py - sy;
        if rel_x < 0 or rel_y < 0 then return '0'; end if;
        if rel_x >= 5 * scale then return '0'; end if;
        if rel_y >= 8 * scale then return '0'; end if;
        col := rel_x / scale;
        row := rel_y / scale;
        if col < 0 or col > 4 then return '0'; end if;
        if row < 0 or row > 7 then return '0'; end if;
        g := font_glyph(asc);
        return g(col)(row);
    end function;

    function asc_of (c : character) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(character'pos(c), 8));
    end function;

    function digit_asc (d : integer) return std_logic_vector is
        variable d_clip : integer;
    begin
        if d < 0 then
            d_clip := 0;
        elsif d > 9 then
            d_clip := 9;
        else
            d_clip := d;
        end if;
        return std_logic_vector(to_unsigned(character'pos('0') + d_clip, 8));
    end function;

    function char_at (s : string; i : integer) return std_logic_vector is
    begin
        if i < s'low or i > s'high then
            return asc_of(' ');
        else
            return std_logic_vector(to_unsigned(character'pos(s(i)), 8));
        end if;
    end function;

    function to_bcd3 (v : unsigned(7 downto 0)) return bcd3_t is
        variable n : integer range 0 to 255;
        variable r : bcd3_t;
    begin
        n := to_integer(v);
        r.h := to_unsigned( n / 100,         4);
        r.t := to_unsigned((n / 10)  mod 10, 4);
        r.o := to_unsigned( n        mod 10, 4);
        return r;
    end function;

    function to_bcd5 (v : unsigned(15 downto 0)) return bcd5_t is
        variable n : integer range 0 to 65535;
        variable r : bcd5_t;
    begin
        n := to_integer(v);
        r.ten_thou := to_unsigned( n / 10000,           4);
        r.thou     := to_unsigned((n / 1000)  mod 10,   4);
        r.hund     := to_unsigned((n / 100)   mod 10,   4);
        r.tens     := to_unsigned((n / 10)    mod 10,   4);
        r.ones     := to_unsigned( n          mod 10,   4);
        return r;
    end function;

end package body;
