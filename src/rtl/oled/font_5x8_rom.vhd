-- font_5x8_rom.vhd
--   5x8 column-major bitmap font for the OLED. Each glyph is five
--   bytes; bit 0 of each byte is the top pixel. Only the characters
--   used by the OLED status strings are populated (space, digits 0-9,
--   ':', uppercase A-Z, '-' and '.'); anything else returns five zero
--   bytes. We expose this as a function so consumers can call
--   font_glyph(asc) and the synthesizer infers a small ROM from the
--   case statement.
--   ref: 5x7+descender pixel font tables from the SSD1306 community
--        examples (pulled the lit-pixel tables from the public-domain
--        Adafruit-style 5x7 table and zero-padded the bottom row).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package font_5x8_pkg is
    type glyph_t is array (0 to 4) of std_logic_vector(7 downto 0);

    function font_glyph (asc : std_logic_vector(7 downto 0)) return glyph_t;
end package;

package body font_5x8_pkg is

    function font_glyph (asc : std_logic_vector(7 downto 0)) return glyph_t is
        variable g : glyph_t := (others => x"00");
    begin
        case asc is
            -- Space
            when x"20" => g := (x"00", x"00", x"00", x"00", x"00");
            -- Digits 0..9
            when x"30" => g := (x"3E", x"51", x"49", x"45", x"3E");
            when x"31" => g := (x"00", x"42", x"7F", x"40", x"00");
            when x"32" => g := (x"42", x"61", x"51", x"49", x"46");
            when x"33" => g := (x"21", x"41", x"45", x"4B", x"31");
            when x"34" => g := (x"18", x"14", x"12", x"7F", x"10");
            when x"35" => g := (x"27", x"45", x"45", x"45", x"39");
            when x"36" => g := (x"3C", x"4A", x"49", x"49", x"30");
            when x"37" => g := (x"01", x"71", x"09", x"05", x"03");
            when x"38" => g := (x"36", x"49", x"49", x"49", x"36");
            when x"39" => g := (x"06", x"49", x"49", x"29", x"1E");
            -- Punctuation
            when x"3A" => g := (x"00", x"36", x"36", x"00", x"00");   -- :
            when x"2D" => g := (x"08", x"08", x"08", x"08", x"08");   -- -
            when x"2E" => g := (x"00", x"60", x"60", x"00", x"00");   -- .
            -- Uppercase A..Z
            when x"41" => g := (x"7E", x"11", x"11", x"11", x"7E");   -- A
            when x"42" => g := (x"7F", x"49", x"49", x"49", x"36");   -- B
            when x"43" => g := (x"3E", x"41", x"41", x"41", x"22");   -- C
            when x"44" => g := (x"7F", x"41", x"41", x"22", x"1C");   -- D
            when x"45" => g := (x"7F", x"49", x"49", x"49", x"41");   -- E
            when x"46" => g := (x"7F", x"09", x"09", x"09", x"01");   -- F
            when x"47" => g := (x"3E", x"41", x"49", x"49", x"7A");   -- G
            when x"48" => g := (x"7F", x"08", x"08", x"08", x"7F");   -- H
            when x"49" => g := (x"00", x"41", x"7F", x"41", x"00");   -- I
            when x"4A" => g := (x"20", x"40", x"41", x"3F", x"01");   -- J
            when x"4B" => g := (x"7F", x"08", x"14", x"22", x"41");   -- K
            when x"4C" => g := (x"7F", x"40", x"40", x"40", x"40");   -- L
            when x"4D" => g := (x"7F", x"02", x"0C", x"02", x"7F");   -- M
            when x"4E" => g := (x"7F", x"04", x"08", x"10", x"7F");   -- N
            when x"4F" => g := (x"3E", x"41", x"41", x"41", x"3E");   -- O
            when x"50" => g := (x"7F", x"09", x"09", x"09", x"06");   -- P
            when x"51" => g := (x"3E", x"41", x"51", x"21", x"5E");   -- Q
            when x"52" => g := (x"7F", x"09", x"19", x"29", x"46");   -- R
            when x"53" => g := (x"46", x"49", x"49", x"49", x"31");   -- S
            when x"54" => g := (x"01", x"01", x"7F", x"01", x"01");   -- T
            when x"55" => g := (x"3F", x"40", x"40", x"40", x"3F");   -- U
            when x"56" => g := (x"1F", x"20", x"40", x"20", x"1F");   -- V
            when x"57" => g := (x"7F", x"20", x"18", x"20", x"7F");   -- W
            when x"58" => g := (x"63", x"14", x"08", x"14", x"63");   -- X
            when x"59" => g := (x"03", x"04", x"78", x"04", x"03");   -- Y
            when x"5A" => g := (x"61", x"51", x"49", x"45", x"43");   -- Z
            when others =>
                g := (others => x"00");
        end case;
        return g;
    end function;

end package body;
