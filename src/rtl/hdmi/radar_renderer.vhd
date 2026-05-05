-- ============================================================================
-- radar_renderer.vhd
--   Per-pixel rasteriser for the HDMI radar display.  Draws:
--     * Dark gray background.
--     * Cross-hair through the centre.
--     * Four concentric range rings (60/120/180/240 px).
--     * A rotating sweep ray.
--     * A bright target dot at angle = sweep, range = distance_in.
--
--   Inputs `distance_in` and `als_value` arrive from the system (125 MHz)
--   domain and have been re-synchronised to clk_pixel (25 MHz) by the
--   parent.  A frame-rate sweep counter advances at vsync.
--
--   sin / cos lookup uses a 64-entry quarter table, expanded by symmetry.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity radar_renderer is
    port (
        clk_pixel   : in  std_logic;
        rst         : in  std_logic;

        -- Timing in (from vga_timing_640x480)
        x_in        : in  unsigned(9 downto 0);
        y_in        : in  unsigned(9 downto 0);
        de_in       : in  std_logic;
        hsync_in    : in  std_logic;
        vsync_in    : in  std_logic;

        -- Live values (must be already in pixel-clock domain)
        distance_in : in  unsigned(15 downto 0);
        als_value   : in  unsigned(15 downto 0);

        -- Output pixel
        red         : out std_logic_vector(7 downto 0);
        green       : out std_logic_vector(7 downto 0);
        blue        : out std_logic_vector(7 downto 0);
        de_out      : out std_logic;
        hsync_out   : out std_logic;
        vsync_out   : out std_logic
    );
end entity;

architecture rtl of radar_renderer is

    -- Centre of the radar.
    constant CX : integer := 320;
    constant CY : integer := 400;

    -- Ring radii (squared, with a small tolerance band on each side).
    constant R1 : integer := 60;
    constant R2 : integer := 120;
    constant R3 : integer := 180;
    constant R4 : integer := 240;

    -- Pixels per inch for plotting the target.
    constant PX_PER_INCH : integer := 6;

    -- Quarter-sine LUT, 64 entries, Q15 (so range -32767..32767).
    type qsin_t is array (0 to 63) of signed(15 downto 0);
    function build_qsin return qsin_t is
        variable t : qsin_t;
    begin
        for i in 0 to 63 loop
            t(i) := to_signed(
                        integer(round(32767.0 * sin(real(i) * MATH_PI / 128.0))),
                        16);
        end loop;
        return t;
    end function;
    constant QSIN : qsin_t := build_qsin;

    -- Look up sin(theta) for an 8-bit theta covering 0..2*pi.
    function sin8 (theta : unsigned(7 downto 0)) return signed is
        variable q  : unsigned(1 downto 0);
        variable ix : integer range 0 to 63;
        variable v  : signed(15 downto 0);
    begin
        q  := theta(7 downto 6);
        case q is
            when "00" => ix := to_integer(theta(5 downto 0));               v :=  QSIN(ix);
            when "01" => ix := 63 - to_integer(theta(5 downto 0));          v :=  QSIN(ix);
            when "10" => ix := to_integer(theta(5 downto 0));               v := -QSIN(ix);
            when others => ix := 63 - to_integer(theta(5 downto 0));        v := -QSIN(ix);
        end case;
        return v;
    end function;

    function cos8 (theta : unsigned(7 downto 0)) return signed is
    begin
        return sin8(theta + to_unsigned(64, 8));
    end function;

    -- =========================================================================
    -- Frame-rate sweep counter and per-frame target position
    -- =========================================================================
    signal vsync_d        : std_logic := '1';
    signal sweep_theta    : unsigned(7 downto 0) := (others => '0');
    signal target_dx_q    : signed(15 downto 0) := (others => '0');
    signal target_dy_q    : signed(15 downto 0) := (others => '0');
    signal target_x_r     : signed(11 downto 0) := (others => '0');
    signal target_y_r     : signed(11 downto 0) := (others => '0');
    signal target_valid_r : std_logic := '0';

    -- Per-frame snapshot of the sin/cos values for sweep_theta.
    signal sin_theta_r    : signed(15 downto 0) := (others => '0');
    signal cos_theta_r    : signed(15 downto 0) := (others => '0');

    -- =========================================================================
    -- Pipeline registers
    -- =========================================================================
    signal x_s1, y_s1     : unsigned(9 downto 0) := (others => '0');
    signal de_s1, hs_s1, vs_s1 : std_logic := '0';
    signal dx_s1, dy_s1   : signed(11 downto 0) := (others => '0');

    signal x_s2, y_s2     : unsigned(9 downto 0) := (others => '0');
    signal de_s2, hs_s2, vs_s2 : std_logic := '0';
    signal r2_s2          : unsigned(23 downto 0) := (others => '0');
    signal swp_metric_s2  : signed(31 downto 0) := (others => '0');
    signal swp_forward_s2 : signed(31 downto 0) := (others => '0');

    -- =========================================================================
    -- Pixel decisions
    -- =========================================================================
    signal red_r, green_r, blue_r : std_logic_vector(7 downto 0) := (others => '0');
    signal de_r, hs_r, vs_r       : std_logic := '0';

begin

    -- =========================================================================
    -- Per-frame update of sweep angle + target position.
    -- =========================================================================
    process(clk_pixel)
        variable target_r_px  : integer;
        variable prod_x       : signed(33 downto 0);
        variable prod_y       : signed(33 downto 0);
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                vsync_d        <= '1';
                sweep_theta    <= (others => '0');
                target_dx_q    <= (others => '0');
                target_dy_q    <= (others => '0');
                target_x_r     <= to_signed(CX, 12);
                target_y_r     <= to_signed(CY, 12);
                target_valid_r <= '0';
                sin_theta_r    <= (others => '0');
                cos_theta_r    <= (others => '0');
            else
                vsync_d <= vsync_in;

                -- On vsync falling edge (i.e. *start* of vsync, since vsync
                -- is active LOW), advance sweep + recompute target.
                if vsync_d = '1' and vsync_in = '0' then
                    sweep_theta <= sweep_theta + to_unsigned(2, 8);  -- ~2 deg/frame

                    sin_theta_r <= sin8(sweep_theta);
                    cos_theta_r <= cos8(sweep_theta);

                    -- Range in pixels (clip to 250 px).
                    target_r_px := to_integer(distance_in) * PX_PER_INCH;
                    if target_r_px > 250 then target_r_px := 250; end if;
                    if to_integer(distance_in) = 0 then
                        target_valid_r <= '0';
                    else
                        target_valid_r <= '1';
                    end if;

                    prod_x := to_signed(target_r_px, 18) * cos8(sweep_theta);
                    prod_y := to_signed(target_r_px, 18) * sin8(sweep_theta);
                    target_dx_q <= resize(shift_right(prod_x, 15), 16);
                    target_dy_q <= resize(shift_right(prod_y, 15), 16);
                end if;

                -- Project onto pixel coordinates (cy - dy because y is down).
                target_x_r <= to_signed(CX, 12) + resize(target_dx_q, 12);
                target_y_r <= to_signed(CY, 12) - resize(target_dy_q, 12);
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Stage 1 - compute dx, dy, propagate sync signals.
    -- =========================================================================
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                x_s1 <= (others => '0'); y_s1 <= (others => '0');
                de_s1 <= '0'; hs_s1 <= '1'; vs_s1 <= '1';
                dx_s1 <= (others => '0'); dy_s1 <= (others => '0');
            else
                x_s1  <= x_in;
                y_s1  <= y_in;
                de_s1 <= de_in;
                hs_s1 <= hsync_in;
                vs_s1 <= vsync_in;

                dx_s1 <= signed('0' & std_logic_vector(x_in)) -
                         to_signed(CX, 12);
                dy_s1 <= to_signed(CY, 12) -
                         signed('0' & std_logic_vector(y_in));
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Stage 2 - compute r^2 and sweep metrics.
    -- =========================================================================
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                x_s2 <= (others => '0'); y_s2 <= (others => '0');
                de_s2 <= '0'; hs_s2 <= '1'; vs_s2 <= '1';
                r2_s2          <= (others => '0');
                swp_metric_s2  <= (others => '0');
                swp_forward_s2 <= (others => '0');
            else
                x_s2  <= x_s1;
                y_s2  <= y_s1;
                de_s2 <= de_s1;
                hs_s2 <= hs_s1;
                vs_s2 <= vs_s1;

                r2_s2 <= unsigned(resize(dx_s1 * dx_s1 + dy_s1 * dy_s1, 24));

                -- sweep_metric = dx*sin - dy*cos      (perpendicular distance)
                -- swp_forward  = dx*cos + dy*sin      (positive => forward)
                swp_metric_s2  <= resize(dx_s1, 16) * sin_theta_r -
                                  resize(dy_s1, 16) * cos_theta_r;
                swp_forward_s2 <= resize(dx_s1, 16) * cos_theta_r +
                                  resize(dy_s1, 16) * sin_theta_r;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Stage 3 - decide pixel color.
    -- =========================================================================
    process(clk_pixel)
        variable r2v       : unsigned(23 downto 0);
        variable bg_r, bg_g, bg_b : integer;
        variable on_ring   : boolean;
        variable on_cross  : boolean;
        variable on_sweep  : boolean;
        variable on_target : boolean;

        constant SWEEP_BAND : signed(31 downto 0) := to_signed(32768 * 2, 32);
                                                    -- ~2 px wide perp band
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                red_r <= (others => '0');
                green_r <= (others => '0');
                blue_r <= (others => '0');
                de_r <= '0'; hs_r <= '1'; vs_r <= '1';
            else
                de_r <= de_s2;
                hs_r <= hs_s2;
                vs_r <= vs_s2;

                r2v := r2_s2;

                -- Default background: very dark gray.
                bg_r := 8; bg_g := 12; bg_b := 8;

                -- Rings: |r^2 - R^2| <= R   (=> ~1 px wide).
                on_ring :=
                    (r2v >= to_unsigned(R1*R1 - R1, 24) and
                     r2v <= to_unsigned(R1*R1 + R1, 24)) or
                    (r2v >= to_unsigned(R2*R2 - R2, 24) and
                     r2v <= to_unsigned(R2*R2 + R2, 24)) or
                    (r2v >= to_unsigned(R3*R3 - R3, 24) and
                     r2v <= to_unsigned(R3*R3 + R3, 24)) or
                    (r2v >= to_unsigned(R4*R4 - R4, 24) and
                     r2v <= to_unsigned(R4*R4 + R4, 24));

                -- Cross-hair: column == CX or row == CY.
                on_cross := (to_integer(x_s2) = CX) or
                            (to_integer(y_s2) = CY);

                -- Sweep ray: in the forward half-plane and within the band.
                on_sweep := (swp_forward_s2 > 0) and
                            (swp_metric_s2  > -SWEEP_BAND) and
                            (swp_metric_s2  <  SWEEP_BAND) and
                            (r2v < to_unsigned(R4*R4, 24));

                -- Target dot: 5x5 box centred on (target_x_r, target_y_r).
                on_target := target_valid_r = '1' and
                             (abs(signed('0' & std_logic_vector(x_s2)) -
                                  resize(target_x_r, 12)) < to_signed(3, 12)) and
                             (abs(signed('0' & std_logic_vector(y_s2)) -
                                  resize(target_y_r, 12)) < to_signed(3, 12));

                -- Pixel decision (target > sweep > rings > cross > bg).
                if de_s2 = '0' then
                    red_r   <= (others => '0');
                    green_r <= (others => '0');
                    blue_r  <= (others => '0');
                elsif on_target then
                    red_r   <= x"FF";
                    green_r <= x"30";
                    blue_r  <= x"30";
                elsif on_sweep then
                    red_r   <= x"30";
                    green_r <= x"FF";
                    blue_r  <= x"30";
                elsif on_ring then
                    red_r   <= x"00";
                    green_r <= x"80";
                    blue_r  <= x"00";
                elsif on_cross then
                    red_r   <= x"20";
                    green_r <= x"60";
                    blue_r  <= x"20";
                else
                    red_r   <= std_logic_vector(to_unsigned(bg_r, 8));
                    green_r <= std_logic_vector(to_unsigned(bg_g, 8));
                    blue_r  <= std_logic_vector(to_unsigned(bg_b, 8));
                end if;
            end if;
        end if;
    end process;

    red       <= red_r;
    green     <= green_r;
    blue      <= blue_r;
    de_out    <= de_r;
    hsync_out <= hs_r;
    vsync_out <= vs_r;

end architecture;
