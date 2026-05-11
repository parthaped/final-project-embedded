-- strip_chart_renderer.vhd
--   Dual-trace 10 s history strip chart. The 640x160 panel is split:
--     y=  0..79  RANGE trace. Background is a three-band gradient
--                (red ALERT, amber WARN, green SAFE) whose splits
--                follow the live near_th / warn_th, so the bands
--                visibly slide when SW1 is toggled.
--     y= 80..159 LIGHT trace. Background is the ambient mode the
--                sample was taken in (NIGHT/DIM/DAY/BRIGHT colours).
--   Foreground traces are 2 px thick. A vertical "event tick" coloured
--   by severity lights up any column that had a contact.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity strip_chart_renderer is
    generic (
        PANEL_W     : positive := 640;
        PANEL_H     : positive := 160;
        RANGE_MAX_IN : positive := 80
    );
    port (
        clk_pixel    : in  std_logic;
        rst          : in  std_logic;

        x_in         : in  unsigned(9 downto 0);
        y_in         : in  unsigned(9 downto 0);

        -- Read from history_buffer one column ahead (parent has
        -- already issued rd_col = x_in - 1 to absorb BRAM latency).
        h_range      : in  unsigned(7 downto 0);
        h_als        : in  unsigned(7 downto 0);
        h_ambient    : in  unsigned(1 downto 0);
        h_severity   : in  unsigned(1 downto 0);
        h_event      : in  std_logic;

        near_th      : in  unsigned(7 downto 0);
        warn_th      : in  unsigned(7 downto 0);

        red          : out std_logic_vector(7 downto 0);
        green        : out std_logic_vector(7 downto 0);
        blue         : out std_logic_vector(7 downto 0);
        active       : out std_logic
    );
end entity;

architecture rtl of strip_chart_renderer is
    constant RNG_TOP : integer := 0;
    constant RNG_BOT : integer := 79;
    constant RNG_H   : integer := RNG_BOT - RNG_TOP;

    constant LGT_TOP : integer := 80;
    constant LGT_BOT : integer := 159;
    constant LGT_H   : integer := LGT_BOT - LGT_TOP;

    signal x_s1, y_s1 : integer range 0 to 1023 := 0;
    signal h_range_s1, h_als_s1 : unsigned(7 downto 0) := (others => '0');
    signal h_amb_s1, h_sev_s1   : unsigned(1 downto 0) := (others => '0');
    signal h_event_s1           : std_logic := '0';
    signal near_s1, warn_s1     : unsigned(7 downto 0) := (others => '0');

    signal red_r, green_r, blue_r : std_logic_vector(7 downto 0) := (others => '0');
    signal active_r : std_logic := '0';

    function range_to_y (r : unsigned(7 downto 0)) return integer is
        variable rint : integer;
        variable yy   : integer;
    begin
        rint := to_integer(r);
        if rint > RANGE_MAX_IN then rint := RANGE_MAX_IN; end if;
        yy := RNG_TOP + (rint * RNG_H) / RANGE_MAX_IN;
        return yy;
    end function;

    function als_to_y (a : unsigned(7 downto 0)) return integer is
        variable yy : integer;
    begin
        yy := LGT_BOT - (to_integer(a) * LGT_H) / 255;
        return yy;
    end function;

    function ambient_color_r (a : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case a is
            when "00"   => return x"00";
            when "01"   => return x"00";
            when "10"   => return x"08";
            when others => return x"30";
        end case;
    end function;

    function ambient_color_g (a : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case a is
            when "00"   => return x"06";
            when "01"   => return x"18";
            when "10"   => return x"30";
            when others => return x"50";
        end case;
    end function;

    function ambient_color_b (a : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case a is
            when "00"   => return x"00";
            when "01"   => return x"08";
            when "10"   => return x"08";
            when others => return x"30";
        end case;
    end function;

    function sev_color_r (s : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case s is
            when "00"   => return x"FF";
            when "01"   => return x"FF";
            when "10"   => return x"FF";
            when others => return x"FF";
        end case;
    end function;

    function sev_color_g (s : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case s is
            when "00"   => return x"FF";
            when "01"   => return x"60";
            when "10"   => return x"00";
            when others => return x"00";
        end case;
    end function;

    function sev_color_b (s : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case s is
            when "00"   => return x"00";
            when others => return x"00";
        end case;
    end function;

begin

    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                x_s1 <= 0; y_s1 <= 0;
                h_range_s1 <= (others => '0');
                h_als_s1   <= (others => '0');
                h_amb_s1   <= (others => '0');
                h_sev_s1   <= (others => '0');
                h_event_s1 <= '0';
                near_s1    <= (others => '0');
                warn_s1    <= (others => '0');
            else
                x_s1       <= to_integer(x_in);
                y_s1       <= to_integer(y_in);
                h_range_s1 <= h_range;
                h_als_s1   <= h_als;
                h_amb_s1   <= h_ambient;
                h_sev_s1   <= h_severity;
                h_event_s1 <= h_event;
                near_s1    <= near_th;
                warn_s1    <= warn_th;
            end if;
        end if;
    end process;

    process(clk_pixel)
        variable px, py    : integer;
        variable y_rng     : integer;
        variable y_als     : integer;
        variable y_near    : integer;
        variable y_warn    : integer;
        variable in_top    : boolean;
        variable in_bot    : boolean;
        variable on_trace_r: boolean;
        variable on_trace_l: boolean;
        variable on_event  : boolean;
        variable on_baseline : boolean;
        variable bg_r, bg_g, bg_b : std_logic_vector(7 downto 0);
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                red_r   <= (others => '0');
                green_r <= (others => '0');
                blue_r  <= (others => '0');
                active_r <= '0';
            else
                px := x_s1;
                py := y_s1;

                in_top := (py >= RNG_TOP) and (py <= RNG_BOT);
                in_bot := (py >= LGT_TOP) and (py <= LGT_BOT);

                y_rng  := range_to_y(h_range_s1);
                y_als  := als_to_y(h_als_s1);
                y_near := range_to_y(resize(near_s1, 8));
                y_warn := range_to_y(resize(warn_s1, 8));

                on_trace_r := in_top and
                              (py >= y_rng - 1) and (py <= y_rng + 1) and
                              (to_integer(h_range_s1) /= 0);
                on_trace_l := in_bot and
                              (py >= y_als - 1) and (py <= y_als + 1);

                on_event := (h_event_s1 = '1');

                on_baseline := (py = RNG_BOT) or (py = LGT_TOP);

                if in_top then
                    -- Top of panel = closest -> red ALERT band; bottom
                    -- of panel = far -> SAFE green.
                    if py < y_near then
                        bg_r := x"40"; bg_g := x"00"; bg_b := x"00";
                    elsif py < y_warn then
                        bg_r := x"40"; bg_g := x"30"; bg_b := x"00";
                    else
                        bg_r := x"00"; bg_g := x"30"; bg_b := x"08";
                    end if;
                elsif in_bot then
                    bg_r := ambient_color_r(h_amb_s1);
                    bg_g := ambient_color_g(h_amb_s1);
                    bg_b := ambient_color_b(h_amb_s1);
                else
                    bg_r := (others => '0');
                    bg_g := (others => '0');
                    bg_b := (others => '0');
                end if;

                -- Priority: event tick > trace > baseline > band > none.
                if (in_top or in_bot) and on_event then
                    red_r   <= sev_color_r(h_sev_s1);
                    green_r <= sev_color_g(h_sev_s1);
                    blue_r  <= sev_color_b(h_sev_s1);
                    active_r <= '1';
                elsif on_trace_r then
                    red_r   <= x"40"; green_r <= x"FF"; blue_r <= x"FF";
                    active_r <= '1';
                elsif on_trace_l then
                    red_r   <= x"FF"; green_r <= x"FF"; blue_r <= x"FF";
                    active_r <= '1';
                elsif (in_top or in_bot) and on_baseline then
                    red_r   <= x"60"; green_r <= x"60"; blue_r <= x"60";
                    active_r <= '1';
                elsif in_top or in_bot then
                    red_r   <= bg_r;
                    green_r <= bg_g;
                    blue_r  <= bg_b;
                    active_r <= '1';
                else
                    red_r <= (others => '0');
                    green_r <= (others => '0');
                    blue_r <= (others => '0');
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
