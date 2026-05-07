-- ============================================================================
-- console_renderer.vhd
--   Top-level composer for the perimeter monitor's HDMI console.
--   Replaces the old radar_renderer; instantiates one history_buffer
--   plus four panel renderers (risk_banner, risk_matrix, strip_chart,
--   event_log) and stitches them onto a 640x480 frame:
--
--       y =   0..23  : header strip       (PERIMETER MONITOR T+...)
--       y =  24..183 : risk banner (left half)
--                      risk matrix (right half)
--       y = 184..343 : dual strip chart   (range top, light bottom)
--       y = 344..463 : timestamped event log
--       y = 464..479 : status strip       (ARM / SENS / CONT  / clear hint)
--
--   On top of all that, the outer 4 px ring is painted as a severity
--   border (off in SAFE/LOW, amber in MED, red in HIGH, flashing
--   red+white in CRIT) so a viewer across the room can read the
--   threat level even before they see the banner text.
--
--   The composer also drives a slow `blink` signal (toggles every
--   ~0.5 s at 60 frames/s) shared with the risk_banner / risk_matrix
--   for CRIT-cell flashing.
--
--   Pipeline:
--       clk0  - x_in, y_in (raw VGA timing)
--       clk1  - x_s1, y_s1 registered; history_buffer addr issued
--       clk2  - panel input regs latched; BRAM output settled
--       clk3  - panel output regs settled
--       clk4  - composer mux + border + final RGB & sync delayed 4 cycles
--   Total = 4 clk_pixel cycles (matches a 25 MHz pipeline comfortably).
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.contact_pkg.all;
use work.font_5x8_pkg.all;
use work.font_render_pkg.all;

entity console_renderer is
    port (
        clk_pixel       : in  std_logic;
        rst             : in  std_logic;

        x_in            : in  unsigned(9 downto 0);
        y_in            : in  unsigned(9 downto 0);
        de_in           : in  std_logic;
        hsync_in        : in  std_logic;
        vsync_in        : in  std_logic;

        -- Live system state, already CDC'd to clk_pixel.
        range_in        : in  unsigned(7 downto 0);
        als_value       : in  unsigned(7 downto 0);
        ambient_mode    : in  unsigned(1 downto 0);
        severity_now    : in  unsigned(1 downto 0);
        presence        : in  std_logic;
        log_pulse_pixel : in  std_logic;
        sev_value       : in  unsigned(1 downto 0);
        contacts        : in  contact_array_t;
        count           : in  unsigned(3 downto 0);
        t_seconds       : in  unsigned(15 downto 0);
        arm             : in  std_logic;
        near_th         : in  unsigned(7 downto 0);
        warn_th         : in  unsigned(7 downto 0);

        red             : out std_logic_vector(7 downto 0);
        green           : out std_logic_vector(7 downto 0);
        blue            : out std_logic_vector(7 downto 0);
        de_out          : out std_logic;
        hsync_out       : out std_logic;
        vsync_out       : out std_logic
    );
end entity;

architecture rtl of console_renderer is

    constant HDR_Y0    : integer := 0;
    constant HDR_H     : integer := 24;
    constant BANNER_Y0 : integer := 24;
    constant BANNER_W  : integer := 384;
    constant BANNER_X0 : integer := 0;
    constant MATRIX_X0 : integer := 384;
    constant MATRIX_Y0 : integer := 24;
    constant MATRIX_W  : integer := 256;
    constant PANEL_H   : integer := 160;
    constant STRIP_X0  : integer := 0;
    constant STRIP_Y0  : integer := 184;
    constant STRIP_W   : integer := 640;
    constant EVTS_X0   : integer := 0;
    constant EVTS_Y0   : integer := 344;
    constant EVTS_W    : integer := 640;
    constant EVTS_H    : integer := 120;
    constant STATUS_Y0 : integer := 464;
    constant STATUS_H  : integer := 16;
    constant BORDER_W  : integer := 4;

    -- Slow blink (~1 Hz at 60 vsync/s) shared with banner / matrix.
    signal vsync_d   : std_logic := '1';
    signal frame_cnt : unsigned(5 downto 0) := (others => '0');
    signal blink_r   : std_logic := '0';

    -- Stage 1 registers: x_in, y_in, sync.
    signal x_s1, y_s1   : unsigned(9 downto 0) := (others => '0');
    signal de_s1, hs_s1, vs_s1 : std_logic := '0';

    -- Stage 2 registers (track inputs).
    signal x_s2, y_s2   : unsigned(9 downto 0) := (others => '0');
    signal de_s2, hs_s2, vs_s2 : std_logic := '0';

    -- Stage 3 registers.
    signal x_s3, y_s3   : unsigned(9 downto 0) := (others => '0');
    signal de_s3, hs_s3, vs_s3 : std_logic := '0';

    -- Stage 4 sync (final output).
    signal de_s4, hs_s4, vs_s4 : std_logic := '0';

    -- History buffer outputs (BRAM read latency 1, valid at "stage 2").
    signal h_range, h_als : unsigned(7 downto 0);
    signal h_amb, h_sev   : unsigned(1 downto 0);
    signal h_event        : std_logic;

    -- Per-panel x/y in panel-local coords, ready at "stage 1".
    signal banner_x, banner_y : unsigned(9 downto 0) := (others => '0');
    signal matrix_x, matrix_y : unsigned(9 downto 0) := (others => '0');
    signal strip_x,  strip_y  : unsigned(9 downto 0) := (others => '0');
    signal evts_x,   evts_y   : unsigned(9 downto 0) := (others => '0');

    -- Panel outputs (registered at "stage 3").
    signal br_r, br_g, br_b : std_logic_vector(7 downto 0);
    signal br_a             : std_logic;
    signal mr_r, mr_g, mr_b : std_logic_vector(7 downto 0);
    signal mr_a             : std_logic;
    signal sr_r, sr_g, sr_b : std_logic_vector(7 downto 0);
    signal sr_a             : std_logic;
    signal er_r, er_g, er_b : std_logic_vector(7 downto 0);
    signal er_a             : std_logic;

    -- Final pixel.
    signal red_r, green_r, blue_r : std_logic_vector(7 downto 0) :=
        (others => '0');

    -- Header / status text registered ASCII rows.
    constant HDR_NCHARS : positive := 53;
    constant STA_NCHARS : positive := 53;
    type   hdr_chars_t is array (0 to HDR_NCHARS-1) of std_logic_vector(7 downto 0);
    type   sta_chars_t is array (0 to STA_NCHARS-1) of std_logic_vector(7 downto 0);
    signal hdr_chars : hdr_chars_t := (others => x"20");
    signal sta_chars : sta_chars_t := (others => x"20");

    -- Severity color palette for the border.
    function border_r (s : unsigned(1 downto 0); blnk : std_logic;
                       arm_q : std_logic) return std_logic_vector is
    begin
        if arm_q = '0' then return x"08"; end if;
        case s is
            when "00"   => return x"00";
            when "01"   => return x"40";
            when "10"   => return x"FF";
            when others =>
                if blnk = '1' then return x"FF"; else return x"40"; end if;
        end case;
    end function;

    function border_g (s : unsigned(1 downto 0); blnk : std_logic;
                       arm_q : std_logic) return std_logic_vector is
    begin
        if arm_q = '0' then return x"08"; end if;
        case s is
            when "00"   => return x"00";
            when "01"   => return x"30";
            when "10"   => return x"00";
            when others =>
                if blnk = '1' then return x"FF"; else return x"00"; end if;
        end case;
    end function;

    function border_b (s : unsigned(1 downto 0); blnk : std_logic;
                       arm_q : std_logic) return std_logic_vector is
    begin
        if arm_q = '0' then return x"08"; end if;
        case s is
            when "00"   => return x"00";
            when "01"   => return x"00";
            when "10"   => return x"00";
            when others =>
                if blnk = '1' then return x"FF"; else return x"00"; end if;
        end case;
    end function;

    -- Background tint depending on ambient mode.
    function bg_r (a : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case a is
            when "00"   => return x"00";   -- NIGHT  : near-black
            when "01"   => return x"00";   -- DIM    : darker green
            when "10"   => return x"00";   -- DAY    : warm green
            when others => return x"1A";   -- BRIGHT : washout
        end case;
    end function;

    function bg_g (a : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case a is
            when "00"   => return x"10";
            when "01"   => return x"1A";
            when "10"   => return x"30";
            when others => return x"3A";
        end case;
    end function;

    function bg_b (a : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case a is
            when "00"   => return x"00";
            when "01"   => return x"00";
            when "10"   => return x"00";
            when others => return x"2A";
        end case;
    end function;

    -- Pipelined live state (for stage-4 mux: severity, blink, arm).
    signal sev_s2 : unsigned(1 downto 0) := (others => '0');
    signal sev_s3 : unsigned(1 downto 0) := (others => '0');
    signal arm_s3 : std_logic := '1';
    signal amb_s3 : unsigned(1 downto 0) := (others => '0');
    signal blink_s3 : std_logic := '0';
    signal pres_s3  : std_logic := '0';

    -- Panel-active flag delayed an extra stage so the mux samples
    -- aligned with the registered colour outputs.
begin

    -- =========================================================================
    -- Slow blink: vsync gives 60 frames/s; toggle every 30 frames -> ~1 Hz.
    -- =========================================================================
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                vsync_d   <= '1';
                frame_cnt <= (others => '0');
                blink_r   <= '0';
            else
                vsync_d <= vsync_in;
                if vsync_d = '0' and vsync_in = '1' then
                    if frame_cnt = to_unsigned(29, frame_cnt'length) then
                        frame_cnt <= (others => '0');
                        blink_r   <= not blink_r;
                    else
                        frame_cnt <= frame_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Stage 1: register raw pixel coords + sync, derive panel-local xy.
    -- =========================================================================
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                x_s1 <= (others => '0'); y_s1 <= (others => '0');
                de_s1 <= '0'; hs_s1 <= '1'; vs_s1 <= '1';
            else
                x_s1  <= x_in;
                y_s1  <= y_in;
                de_s1 <= de_in;
                hs_s1 <= hsync_in;
                vs_s1 <= vsync_in;
            end if;
        end if;
    end process;

    -- Combinational panel-local mappings.  Out-of-panel pixels just
    -- get a wraparound coord; downstream gating handles "this isn't my
    -- panel".
    banner_x <= x_s1 - to_unsigned(BANNER_X0, x_s1'length)
                when x_s1 >= to_unsigned(BANNER_X0, x_s1'length)
                else (others => '0');
    banner_y <= y_s1 - to_unsigned(BANNER_Y0, y_s1'length)
                when y_s1 >= to_unsigned(BANNER_Y0, y_s1'length)
                else (others => '0');

    matrix_x <= x_s1 - to_unsigned(MATRIX_X0, x_s1'length)
                when x_s1 >= to_unsigned(MATRIX_X0, x_s1'length)
                else (others => '0');
    matrix_y <= y_s1 - to_unsigned(MATRIX_Y0, y_s1'length)
                when y_s1 >= to_unsigned(MATRIX_Y0, y_s1'length)
                else (others => '0');

    strip_x  <= x_s1;
    strip_y  <= y_s1 - to_unsigned(STRIP_Y0, y_s1'length)
                when y_s1 >= to_unsigned(STRIP_Y0, y_s1'length)
                else (others => '0');

    evts_x   <= x_s1;
    evts_y   <= y_s1 - to_unsigned(EVTS_Y0, y_s1'length)
                when y_s1 >= to_unsigned(EVTS_Y0, y_s1'length)
                else (others => '0');

    -- =========================================================================
    -- History buffer (lives in clk_pixel, written once per vsync).
    -- =========================================================================
    hist_i : entity work.history_buffer
        port map (
            clk_pixel       => clk_pixel,
            rst             => rst,
            range_in        => range_in,
            als_value       => als_value,
            ambient_mode    => ambient_mode,
            log_pulse_pixel => log_pulse_pixel,
            sev_value       => sev_value,
            vsync_in        => vsync_in,
            rd_col          => x_s1,
            rd_range        => h_range,
            rd_als          => h_als,
            rd_ambient      => h_amb,
            rd_severity     => h_sev,
            rd_event        => h_event );

    -- =========================================================================
    -- Panel renderers (each has 2-cycle internal pipeline).
    -- =========================================================================
    banner_i : entity work.risk_banner_renderer
        port map (
            clk_pixel    => clk_pixel,
            rst          => rst,
            x_in         => banner_x,
            y_in         => banner_y,
            severity_now => severity_now,
            presence     => presence,
            range_in     => range_in,
            ambient_mode => ambient_mode,
            als_value    => als_value,
            blink        => blink_r,
            arm          => arm,
            red          => br_r,
            green        => br_g,
            blue         => br_b,
            active       => br_a );

    matrix_i : entity work.risk_matrix_renderer
        port map (
            clk_pixel    => clk_pixel,
            rst          => rst,
            x_in         => matrix_x,
            y_in         => matrix_y,
            ambient_mode => ambient_mode,
            presence     => presence,
            blink        => blink_r,
            red          => mr_r,
            green        => mr_g,
            blue         => mr_b,
            active       => mr_a );

    strip_i : entity work.strip_chart_renderer
        port map (
            clk_pixel    => clk_pixel,
            rst          => rst,
            x_in         => strip_x,
            y_in         => strip_y,
            h_range      => h_range,
            h_als        => h_als,
            h_ambient    => h_amb,
            h_severity   => h_sev,
            h_event      => h_event,
            near_th      => near_th,
            warn_th      => warn_th,
            red          => sr_r,
            green        => sr_g,
            blue         => sr_b,
            active       => sr_a );

    events_i : entity work.event_log_renderer
        port map (
            clk_pixel => clk_pixel,
            rst       => rst,
            x_in      => evts_x,
            y_in      => evts_y,
            contacts  => contacts,
            t_seconds => t_seconds,
            red       => er_r,
            green     => er_g,
            blue      => er_b,
            active    => er_a );

    -- =========================================================================
    -- Stage 2 / 3 sync delays so the final mux lines up with panel
    -- outputs (panels output at "stage 3" relative to x_in).
    -- =========================================================================
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                x_s2 <= (others => '0'); y_s2 <= (others => '0');
                de_s2 <= '0'; hs_s2 <= '1'; vs_s2 <= '1';
                x_s3 <= (others => '0'); y_s3 <= (others => '0');
                de_s3 <= '0'; hs_s3 <= '1'; vs_s3 <= '1';
                de_s4 <= '0'; hs_s4 <= '1'; vs_s4 <= '1';
                sev_s2 <= (others => '0');
                sev_s3 <= (others => '0');
                arm_s3 <= '1';
                amb_s3 <= (others => '0');
                blink_s3 <= '0';
                pres_s3  <= '0';
            else
                x_s2  <= x_s1;  y_s2  <= y_s1;
                de_s2 <= de_s1; hs_s2 <= hs_s1; vs_s2 <= vs_s1;
                sev_s2 <= severity_now;

                x_s3  <= x_s2;  y_s3  <= y_s2;
                de_s3 <= de_s2; hs_s3 <= hs_s2; vs_s3 <= vs_s2;
                sev_s3 <= sev_s2;
                arm_s3 <= arm;
                amb_s3 <= ambient_mode;
                blink_s3 <= blink_r;
                pres_s3  <= presence;

                de_s4 <= de_s3; hs_s4 <= hs_s3; vs_s4 <= vs_s3;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Header and status row ASCII assembly (registered once per clock,
    -- but inputs change slowly so the register is mostly idle).
    -- =========================================================================
    process(clk_pixel)
        variable h_v : unsigned(15 downto 0);
        variable mins, secs : integer range 0 to 5999;
        variable rng_b   : bcd3_t;
        variable lux_b   : bcd3_t;
        variable cnt_int : integer range 0 to 15;
        variable nth_b   : bcd3_t;
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                hdr_chars <= (others => x"20");
                sta_chars <= (others => x"20");
            else
                -- "PERIMETER MONITOR T+HH:MM:SS  MODE:NIGHT  STATUS:ARM"
                -- 0         1111111111222222222233333333334444444444555
                -- 0123456789012345678901234567890123456789012345678901
                -- Layout (53 chars):
                --   0..16 : "PERIMETER MONITOR"
                --   17    : ' '
                --   18..19: "T+"
                --   20..21: HH (or 00..99 mins)
                --   22    : ':'
                --   23..24: MM
                --   25    : ':'
                --   26..27: SS
                --   28..29: "  "
                --   30..34: "MODE:"
                --   35..40: 6-char ambient
                --   41    : ' '
                --   42..47: "STATE:"
                --   48..52: 5-char status (ARMED/IDLE )
                hdr_chars(0)  <= asc_of('P');
                hdr_chars(1)  <= asc_of('E');
                hdr_chars(2)  <= asc_of('R');
                hdr_chars(3)  <= asc_of('I');
                hdr_chars(4)  <= asc_of('M');
                hdr_chars(5)  <= asc_of('E');
                hdr_chars(6)  <= asc_of('T');
                hdr_chars(7)  <= asc_of('E');
                hdr_chars(8)  <= asc_of('R');
                hdr_chars(9)  <= asc_of(' ');
                hdr_chars(10) <= asc_of('M');
                hdr_chars(11) <= asc_of('O');
                hdr_chars(12) <= asc_of('N');
                hdr_chars(13) <= asc_of('I');
                hdr_chars(14) <= asc_of('T');
                hdr_chars(15) <= asc_of('O');
                hdr_chars(16) <= asc_of('R');
                hdr_chars(17) <= asc_of(' ');
                hdr_chars(18) <= asc_of('T');
                hdr_chars(19) <= asc_of('+');

                -- T+ counter: HH:MM:SS where HH is hours of seconds
                -- saturated at 99.  At 1 s/tick this is up to 99:59:59.
                h_v := t_seconds;
                if h_v > to_unsigned(359999, 16) then
                    h_v := to_unsigned(359999, 16);
                end if;
                hdr_chars(20) <= digit_asc((to_integer(h_v) / 36000) mod 10);
                hdr_chars(21) <= digit_asc((to_integer(h_v) / 3600) mod 10);
                hdr_chars(22) <= asc_of(':');
                hdr_chars(23) <= digit_asc(((to_integer(h_v) / 60) mod 60) / 10);
                hdr_chars(24) <= digit_asc(((to_integer(h_v) / 60) mod 60) mod 10);
                hdr_chars(25) <= asc_of(':');
                hdr_chars(26) <= digit_asc((to_integer(h_v) mod 60) / 10);
                hdr_chars(27) <= digit_asc((to_integer(h_v) mod 60) mod 10);

                hdr_chars(28) <= asc_of(' ');
                hdr_chars(29) <= asc_of(' ');
                hdr_chars(30) <= asc_of('M');
                hdr_chars(31) <= asc_of('O');
                hdr_chars(32) <= asc_of('D');
                hdr_chars(33) <= asc_of('E');
                hdr_chars(34) <= asc_of(':');

                case ambient_mode is
                    when "00"   =>
                        hdr_chars(35) <= asc_of('N'); hdr_chars(36) <= asc_of('I');
                        hdr_chars(37) <= asc_of('G'); hdr_chars(38) <= asc_of('H');
                        hdr_chars(39) <= asc_of('T'); hdr_chars(40) <= asc_of(' ');
                    when "01"   =>
                        hdr_chars(35) <= asc_of(' '); hdr_chars(36) <= asc_of('D');
                        hdr_chars(37) <= asc_of('I'); hdr_chars(38) <= asc_of('M');
                        hdr_chars(39) <= asc_of(' '); hdr_chars(40) <= asc_of(' ');
                    when "10"   =>
                        hdr_chars(35) <= asc_of(' '); hdr_chars(36) <= asc_of('D');
                        hdr_chars(37) <= asc_of('A'); hdr_chars(38) <= asc_of('Y');
                        hdr_chars(39) <= asc_of(' '); hdr_chars(40) <= asc_of(' ');
                    when others =>
                        hdr_chars(35) <= asc_of('B'); hdr_chars(36) <= asc_of('R');
                        hdr_chars(37) <= asc_of('I'); hdr_chars(38) <= asc_of('G');
                        hdr_chars(39) <= asc_of('H'); hdr_chars(40) <= asc_of('T');
                end case;

                hdr_chars(41) <= asc_of(' ');
                hdr_chars(42) <= asc_of('S');
                hdr_chars(43) <= asc_of('T');
                hdr_chars(44) <= asc_of('A');
                hdr_chars(45) <= asc_of('T');
                hdr_chars(46) <= asc_of('E');
                hdr_chars(47) <= asc_of(':');
                if arm = '1' then
                    hdr_chars(48) <= asc_of('A');
                    hdr_chars(49) <= asc_of('R');
                    hdr_chars(50) <= asc_of('M');
                    hdr_chars(51) <= asc_of('E');
                    hdr_chars(52) <= asc_of('D');
                else
                    hdr_chars(48) <= asc_of('I');
                    hdr_chars(49) <= asc_of('D');
                    hdr_chars(50) <= asc_of('L');
                    hdr_chars(51) <= asc_of('E');
                    hdr_chars(52) <= asc_of(' ');
                end if;

                ----------------------------------------------------------
                -- Status strip:
                --   "ARM:Y   SENS:NNN IN  CONT:N        BTN3 CLEAR   "
                --    0   4   8        20    28          40
                ----------------------------------------------------------
                sta_chars <= (others => x"20");
                sta_chars(0) <= asc_of('A');
                sta_chars(1) <= asc_of('R');
                sta_chars(2) <= asc_of('M');
                sta_chars(3) <= asc_of(':');
                if arm = '1' then
                    sta_chars(4) <= asc_of('Y');
                else
                    sta_chars(4) <= asc_of('N');
                end if;

                sta_chars(8)  <= asc_of('S');
                sta_chars(9)  <= asc_of('E');
                sta_chars(10) <= asc_of('N');
                sta_chars(11) <= asc_of('S');
                sta_chars(12) <= asc_of(':');
                nth_b := to_bcd3(near_th);
                sta_chars(13) <= digit_asc(to_integer(nth_b.h));
                sta_chars(14) <= digit_asc(to_integer(nth_b.t));
                sta_chars(15) <= digit_asc(to_integer(nth_b.o));
                sta_chars(17) <= asc_of('I');
                sta_chars(18) <= asc_of('N');

                sta_chars(22) <= asc_of('C');
                sta_chars(23) <= asc_of('O');
                sta_chars(24) <= asc_of('N');
                sta_chars(25) <= asc_of('T');
                sta_chars(26) <= asc_of(':');
                cnt_int := to_integer(count);
                sta_chars(27) <= digit_asc(cnt_int);

                sta_chars(36) <= asc_of('B');
                sta_chars(37) <= asc_of('T');
                sta_chars(38) <= asc_of('N');
                sta_chars(39) <= asc_of('3');
                sta_chars(41) <= asc_of('C');
                sta_chars(42) <= asc_of('L');
                sta_chars(43) <= asc_of('E');
                sta_chars(44) <= asc_of('A');
                sta_chars(45) <= asc_of('R');
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Final pixel decision (stage 4).  Picks a colour from the active
    -- panel based on (x_s3, y_s3) and overlays the severity border.
    -- Also draws the inline header and status text.
    -- =========================================================================
    process(clk_pixel)
        variable px, py : integer;
        variable hdr_lit, sta_lit : std_logic;
        variable col, char_y0 : integer;
        variable asc : std_logic_vector(7 downto 0);
        variable on_border : boolean;
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                red_r   <= (others => '0');
                green_r <= (others => '0');
                blue_r  <= (others => '0');
            else
                px := to_integer(x_s3);
                py := to_integer(y_s3);

                -- Header text (scale 2).
                hdr_lit := '0';
                if py >= HDR_Y0 and py < HDR_Y0 + HDR_H then
                    char_y0 := HDR_Y0 + (HDR_H - 16)/2;
                    col := (px - 8) / 12;
                    if col >= 0 and col < HDR_NCHARS then
                        asc := hdr_chars(col);
                    else
                        asc := asc_of(' ');
                    end if;
                    hdr_lit := glyph_lit(px, py,
                                         8 + col * 12, char_y0,
                                         2, asc);
                end if;

                -- Status text (scale 2).
                sta_lit := '0';
                if py >= STATUS_Y0 and py < STATUS_Y0 + STATUS_H then
                    char_y0 := STATUS_Y0 + (STATUS_H - 16)/2;
                    if char_y0 < STATUS_Y0 then
                        char_y0 := STATUS_Y0;
                    end if;
                    col := (px - 8) / 12;
                    if col >= 0 and col < STA_NCHARS then
                        asc := sta_chars(col);
                    else
                        asc := asc_of(' ');
                    end if;
                    sta_lit := glyph_lit(px, py,
                                         8 + col * 12, char_y0,
                                         2, asc);
                end if;

                -- Severity border (outer 4 px ring).
                on_border := (px < BORDER_W) or (px >= 640 - BORDER_W) or
                             (py < BORDER_W) or (py >= 480 - BORDER_W);

                ----------------------------------------------------------
                -- Compose: priority is border > panel > header/status text > bg
                ----------------------------------------------------------
                if de_s3 = '0' then
                    red_r   <= (others => '0');
                    green_r <= (others => '0');
                    blue_r  <= (others => '0');

                elsif on_border and arm_s3 = '1' and
                      (sev_s3 = "01" or sev_s3 = "10" or sev_s3 = "11") and
                      pres_s3 = '1' then
                    -- Severity border only fires while there's a live
                    -- presence, so the screen edge isn't permanently
                    -- red after a contact.
                    red_r   <= border_r(sev_s3, blink_s3, arm_s3);
                    green_r <= border_g(sev_s3, blink_s3, arm_s3);
                    blue_r  <= border_b(sev_s3, blink_s3, arm_s3);

                elsif py >= HDR_Y0 and py < HDR_Y0 + HDR_H then
                    if hdr_lit = '1' then
                        red_r   <= x"FF";
                        green_r <= x"FF";
                        blue_r  <= x"FF";
                    else
                        red_r   <= x"08";
                        green_r <= x"30";
                        blue_r  <= x"08";
                    end if;

                elsif py >= STATUS_Y0 and py < STATUS_Y0 + STATUS_H then
                    if sta_lit = '1' then
                        red_r   <= x"FF";
                        green_r <= x"FF";
                        blue_r  <= x"FF";
                    else
                        red_r   <= x"08";
                        green_r <= x"30";
                        blue_r  <= x"08";
                    end if;

                elsif py >= BANNER_Y0 and py < BANNER_Y0 + PANEL_H and
                      px >= BANNER_X0 and px < BANNER_X0 + BANNER_W then
                    if br_a = '1' then
                        red_r <= br_r; green_r <= br_g; blue_r <= br_b;
                    else
                        red_r <= bg_r(amb_s3); green_r <= bg_g(amb_s3);
                        blue_r <= bg_b(amb_s3);
                    end if;

                elsif py >= MATRIX_Y0 and py < MATRIX_Y0 + PANEL_H and
                      px >= MATRIX_X0 and px < MATRIX_X0 + MATRIX_W then
                    if mr_a = '1' then
                        red_r <= mr_r; green_r <= mr_g; blue_r <= mr_b;
                    else
                        red_r <= bg_r(amb_s3); green_r <= bg_g(amb_s3);
                        blue_r <= bg_b(amb_s3);
                    end if;

                elsif py >= STRIP_Y0 and py < STRIP_Y0 + PANEL_H then
                    if sr_a = '1' then
                        red_r <= sr_r; green_r <= sr_g; blue_r <= sr_b;
                    else
                        red_r <= bg_r(amb_s3); green_r <= bg_g(amb_s3);
                        blue_r <= bg_b(amb_s3);
                    end if;

                elsif py >= EVTS_Y0 and py < EVTS_Y0 + EVTS_H then
                    if er_a = '1' then
                        red_r <= er_r; green_r <= er_g; blue_r <= er_b;
                    else
                        red_r <= bg_r(amb_s3); green_r <= bg_g(amb_s3);
                        blue_r <= bg_b(amb_s3);
                    end if;

                else
                    red_r <= bg_r(amb_s3);
                    green_r <= bg_g(amb_s3);
                    blue_r <= bg_b(amb_s3);
                end if;
            end if;
        end if;
    end process;

    red       <= red_r;
    green     <= green_r;
    blue      <= blue_r;
    de_out    <= de_s4;
    hsync_out <= hs_s4;
    vsync_out <= vs_s4;

end architecture;
