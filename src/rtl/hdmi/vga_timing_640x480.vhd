-- ============================================================================
-- vga_timing_640x480.vhd
--   640x480 @ 60 Hz pixel timing.
--      H total 800 = 640 act + 16 FP + 96 sync + 48 BP    (HSYNC negative)
--      V total 525 = 480 act + 10 FP +  2 sync + 33 BP    (VSYNC negative)
--   Pixel clock = 25 MHz.
--
--   Outputs:
--     x, y    pixel coordinates, valid only while de='1'
--     de      data-enable (active video)
--     hsync, vsync   raw sync pulses (active LOW)
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vga_timing_640x480 is
    port (
        clk_pixel : in  std_logic;
        rst       : in  std_logic;
        x         : out unsigned(9 downto 0);
        y         : out unsigned(9 downto 0);
        de        : out std_logic;
        hsync     : out std_logic;
        vsync     : out std_logic
    );
end entity;

architecture rtl of vga_timing_640x480 is
    constant H_ACT  : integer := 640;
    constant H_FP   : integer := 16;
    constant H_SYNC : integer := 96;
    constant H_BP   : integer := 48;
    constant H_TOT  : integer := H_ACT + H_FP + H_SYNC + H_BP;   -- 800

    constant V_ACT  : integer := 480;
    constant V_FP   : integer := 10;
    constant V_SYNC : integer := 2;
    constant V_BP   : integer := 33;
    constant V_TOT  : integer := V_ACT + V_FP + V_SYNC + V_BP;   -- 525

    signal hcnt : unsigned(9 downto 0) := (others => '0');
    signal vcnt : unsigned(9 downto 0) := (others => '0');
begin
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                hcnt <= (others => '0');
                vcnt <= (others => '0');
            else
                if hcnt = to_unsigned(H_TOT-1, hcnt'length) then
                    hcnt <= (others => '0');
                    if vcnt = to_unsigned(V_TOT-1, vcnt'length) then
                        vcnt <= (others => '0');
                    else
                        vcnt <= vcnt + 1;
                    end if;
                else
                    hcnt <= hcnt + 1;
                end if;
            end if;
        end if;
    end process;

    x  <= hcnt;
    y  <= vcnt;
    de <= '1' when (hcnt < to_unsigned(H_ACT, hcnt'length)) and
                   (vcnt < to_unsigned(V_ACT, vcnt'length))
              else '0';

    hsync <= '0' when (hcnt >= to_unsigned(H_ACT + H_FP,           hcnt'length)) and
                      (hcnt <  to_unsigned(H_ACT + H_FP + H_SYNC,  hcnt'length))
                 else '1';

    vsync <= '0' when (vcnt >= to_unsigned(V_ACT + V_FP,           vcnt'length)) and
                      (vcnt <  to_unsigned(V_ACT + V_FP + V_SYNC,  vcnt'length))
                 else '1';
end architecture;
