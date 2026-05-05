-- ============================================================================
-- oled_init_rom.vhd
--   ROM holding the SSD1306 init byte sequence for the 128x32 Pmod OLED,
--   followed by the page+column-window setup that we send before every
--   frame.  Each entry is 9 bits:
--       bit 8     = D/C          (0 = command, 1 = data)
--       bits 7..0 = byte payload
--
--   `addr` is a free-running counter driven by pmod_oled_top.  When `addr`
--   reaches INIT_END the consumer stops the init phase; when it reaches
--   FRAME_PREFIX_END the consumer stops the per-frame prefix.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package oled_init_pkg is
    -- The init sequence (commands only).  Tuned for the 128x32 SSD1306.
    constant INIT_LEN : integer := 26;

    -- The per-frame prefix that re-sets column/page address windows.
    constant PREFIX_LEN : integer := 6;

    -- Total payload.
    constant ROM_LEN : integer := INIT_LEN + PREFIX_LEN;

    type rom_t is array (0 to ROM_LEN-1) of std_logic_vector(8 downto 0);

    constant OLED_ROM : rom_t := (
        -- ----- INIT (commands) -------------------------------------------
        0  => '0' & x"AE",     -- display off
        1  => '0' & x"D5",     -- set display clock divide
        2  => '0' & x"80",     --   ratio 0x80
        3  => '0' & x"A8",     -- set multiplex ratio
        4  => '0' & x"1F",     --   31 (32-row panel)
        5  => '0' & x"D3",     -- set display offset
        6  => '0' & x"00",     --   0
        7  => '0' & x"40",     -- set start line 0
        8  => '0' & x"8D",     -- charge pump
        9  => '0' & x"14",     --   enable
        10 => '0' & x"20",     -- memory addressing mode
        11 => '0' & x"00",     --   horizontal
        12 => '0' & x"A1",     -- segment remap (column 127 mapped to SEG0)
        13 => '0' & x"C8",     -- COM scan direction (remapped)
        14 => '0' & x"DA",     -- COM pins config
        15 => '0' & x"02",     --   sequential, no remap, for 128x32
        16 => '0' & x"81",     -- contrast
        17 => '0' & x"8F",     --   0x8F
        18 => '0' & x"D9",     -- precharge
        19 => '0' & x"F1",     --   0xF1
        20 => '0' & x"DB",     -- VCOMH deselect
        21 => '0' & x"40",     --   0x40
        22 => '0' & x"A4",     -- entire display from RAM
        23 => '0' & x"A6",     -- normal (non-inverted) display
        24 => '0' & x"2E",     -- deactivate scroll
        25 => '0' & x"AF",     -- display on

        -- ----- per-frame prefix (commands) -------------------------------
        26 => '0' & x"21",     -- column address
        27 => '0' & x"00",     --   start 0
        28 => '0' & x"7F",     --   end 127
        29 => '0' & x"22",     -- page address
        30 => '0' & x"00",     --   start page 0
        31 => '0' & x"03"      --   end page 3
    );
end package;
