-- ============================================================================
-- top_threat_system.vhd  --  PHASE 5 FINAL TOP
--
-- Final integration: brings online the MMCM-derived clock tree, the OLED
-- and the HDMI radar pipeline alongside the sensors + FSM from earlier
-- phases.
--
-- Clock domains:
--   clk_sys     125 MHz (sensors, FSM, OLED, threshold logic)
--   clk_pixel    25 MHz (VGA timing, radar renderer, TMDS encoders)
--   clk_serial  125 MHz (TMDS serializer high-speed input)
--
-- Sensor values produced in clk_sys are re-synchronised through a 2-stage
-- register chain into clk_pixel before they reach the radar renderer.
-- Because the values change very slowly relative to either clock, a
-- multi-bit synchroniser is safe here.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity top_threat_system is
    port (
        sysclk         : in    std_logic;
        btn_start      : in    std_logic;
        btn_reset      : in    std_logic;

        led            : out   std_logic_vector(3 downto 0);

        oled_cs_n      : out   std_logic;
        oled_mosi      : out   std_logic;
        oled_sclk      : out   std_logic;
        oled_dc        : out   std_logic;
        oled_res_n     : out   std_logic;
        oled_vbat_n    : out   std_logic;
        oled_vdd_n     : out   std_logic;

        als_cs_n       : out   std_logic;
        als_miso       : in    std_logic;
        als_sclk       : out   std_logic;

        sonar_pw       : in    std_logic;
        -- Pmod MaxSonar RX pin (J1 pin 2 = JE2 on the standard Pmod).
        -- Driven high from the FPGA so the MB1010 stays in free-run
        -- ranging mode; Vivado's default pull-down on unconstrained
        -- pins otherwise wins against the sensor's weak internal pull-
        -- up and freezes PW low.
        sonar_rx       : out   std_logic;

        hdmi_tx_clk_p  : out   std_logic;
        hdmi_tx_clk_n  : out   std_logic;
        hdmi_tx_d_p    : out   std_logic_vector(2 downto 0);
        hdmi_tx_d_n    : out   std_logic_vector(2 downto 0);
        hdmi_tx_hpd    : out   std_logic;

        -- TPD12S016 HDMI level-shifter enable (Zybo Rev B only).  Must be
        -- driven high or the on-board HDMI TX buffer stays disabled.
        hdmi_tx_en     : out   std_logic
    );
end entity;

architecture rtl of top_threat_system is

    constant SYS_HZ        : positive := 125_000_000;
    constant CYCLES_PER_MS : positive := SYS_HZ / 1000;

    -- =========================================================================
    -- Clocks + resets
    -- =========================================================================
    signal clk_sys    : std_logic;
    signal clk_pixel  : std_logic;
    signal clk_serial : std_logic;
    signal mmcm_locked : std_logic;

    signal rst_async  : std_logic := '1';
    signal rst_cnt    : unsigned(15 downto 0) := (others => '0');

    signal rst_sys    : std_logic;
    signal rst_pixel  : std_logic;
    signal rst_serial : std_logic;

    -- =========================================================================
    -- Buttons (clk_sys)
    -- =========================================================================
    signal start_lvl, start_pulse : std_logic;
    signal reset_lvl, reset_pulse : std_logic;

    -- =========================================================================
    -- Sensors (clk_sys)
    -- =========================================================================
    signal als_tick       : std_logic;
    signal als_byte       : std_logic_vector(7 downto 0);
    signal als_valid      : std_logic;
    signal als_filt_in    : unsigned(15 downto 0);
    signal als_filt_out   : unsigned(15 downto 0);
    signal als_filt_valid : std_logic;

    signal sonar_dist     : unsigned(15 downto 0);
    signal sonar_valid    : std_logic;
    signal sonar_filt_out : unsigned(15 downto 0);
    signal sonar_filt_valid : std_logic;

    signal trig, sonar_trig, als_trig, ok_sig, conf_sig : std_logic;

    signal state_code   : std_logic_vector(2 downto 0);
    signal alert_active : std_logic;
    signal severity     : std_logic_vector(1 downto 0);

    signal blink_tick : std_logic;
    signal blink      : std_logic := '0';

    -- Sonar liveness indicator: toggles on every *real* sonar reading
    -- (i.e. data_valid pulses where the distance is non-zero, so the
    -- watchdog "no pulse" reading does not count).  Routed to LED3
    -- whenever the FSM is not in ALERT, so it doubles as a "PW signal
    -- is reaching the FPGA" probe.
    signal sonar_heartbeat : std_logic := '0';

    -- Raw PW debug.  A 2-stage synchroniser samples the JE4 pin in
    -- clk_sys, and the synchronised level is driven straight onto LED3
    -- (when not in ALERT).  This bypasses the entire pulse-width
    -- driver pipeline so we can see whether the pin is even toggling:
    --   * fully dark           -> pin floating/low, no signal arriving
    --   * solid bright         -> pin stuck high (sensor in fault state)
    --   * visible duty/flicker -> pulses are arriving, driver bug is
    --                              somewhere downstream
    signal sonar_pw_dbg : std_logic;

    -- Registered '1' driver for the MaxSonar RX (range start) line.
    -- Driving this from a register with KEEP/DONT_TOUCH stops Vivado
    -- from collapsing it into a tied-off constant during synthesis,
    -- guaranteeing the OBUF on the JE2 pin actively drives 3.3 V.  The
    -- MB1010's RX input has a weak internal pull-up; we still want
    -- this strong external drive so the sensor cannot fall into
    -- skip-ranging mode if the FPGA pin's default state ever flips
    -- to PULLDOWN.
    signal sonar_rx_reg : std_logic := '1';
    attribute KEEP        : string;
    attribute KEEP        of sonar_rx_reg : signal is "TRUE";
    attribute DONT_TOUCH  : string;
    attribute DONT_TOUCH  of sonar_rx_reg : signal is "TRUE";

    -- =========================================================================
    -- CDC: clk_sys -> clk_pixel for the live sensor values
    -- =========================================================================
    signal dist_pix_a, dist_pix_b : unsigned(15 downto 0) := (others => '0');
    signal als_pix_a,  als_pix_b  : unsigned(15 downto 0) := (others => '0');

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of dist_pix_a : signal is "TRUE";
    attribute ASYNC_REG of dist_pix_b : signal is "TRUE";
    attribute ASYNC_REG of als_pix_a  : signal is "TRUE";
    attribute ASYNC_REG of als_pix_b  : signal is "TRUE";

begin

    -- =========================================================================
    -- Clocking
    -- =========================================================================
    clk_wiz_i : entity work.clk_wiz_hdmi
        port map (
            clk_in     => sysclk,
            rst_in     => '0',
            clk_sys    => clk_sys,
            clk_pixel  => clk_pixel,
            clk_serial => clk_serial,
            locked     => mmcm_locked );

    -- Power-on async reset stretcher (~512 us at 125 MHz).
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if mmcm_locked = '0' then
                rst_async <= '1';
                rst_cnt   <= (others => '0');
            elsif rst_cnt /= x"FFFF" then
                rst_cnt <= rst_cnt + 1;
                rst_async <= '1';
            else
                rst_async <= '0';
            end if;
        end if;
    end process;

    -- Per-domain synchronised resets.
    rst_sys_sync : entity work.synchronizer
        generic map ( STAGES => 2, RST_VAL => '1' )
        port map ( clk => clk_sys,    rst => '0', d_in => rst_async, d_out => rst_sys );

    rst_pix_sync : entity work.synchronizer
        generic map ( STAGES => 3, RST_VAL => '1' )
        port map ( clk => clk_pixel,  rst => '0', d_in => rst_async, d_out => rst_pixel );

    rst_ser_sync : entity work.synchronizer
        generic map ( STAGES => 3, RST_VAL => '1' )
        port map ( clk => clk_serial, rst => '0', d_in => rst_async, d_out => rst_serial );

    -- =========================================================================
    -- Buttons
    -- =========================================================================
    deb_start : entity work.debouncer
        generic map ( STABLE_CYCLES => CYCLES_PER_MS * 20 )
        port map ( clk => clk_sys, rst => rst_sys, btn_in => btn_start,
                   btn_level => start_lvl, btn_pulse => start_pulse );

    deb_reset : entity work.debouncer
        generic map ( STABLE_CYCLES => CYCLES_PER_MS * 20 )
        port map ( clk => clk_sys, rst => rst_sys, btn_in => btn_reset,
                   btn_level => reset_lvl, btn_pulse => reset_pulse );

    -- =========================================================================
    -- Sensors + filters
    -- =========================================================================
    als_tick_gen : entity work.pulse_gen
        generic map ( PERIOD_CYCLES => CYCLES_PER_MS )
        port map ( clk => clk_sys, rst => rst_sys, en => '1', pulse => als_tick );

    als_inst : entity work.pmod_als_spi
        generic map ( SCLK_HALF_CYCLES => 63 )
        port map ( clk => clk_sys, rst => rst_sys,
                   sample_tick => als_tick, busy => open,
                   data_out => als_byte, data_valid => als_valid,
                   spi_cs_n => als_cs_n, spi_sclk => als_sclk, spi_miso => als_miso );

    als_filt_in <= resize(unsigned(als_byte), als_filt_in'length);

    als_filter : entity work.moving_average8
        generic map ( DATA_WIDTH => 16 )
        port map ( clk => clk_sys, rst => rst_sys,
                   valid_in => als_valid, data_in => als_filt_in,
                   valid_out => als_filt_valid, data_out => als_filt_out );

    sonar_inst : entity work.pmod_maxsonar_pw
        generic map (
            RECIP_MUL       => 913,
            RECIP_SHIFT     => 24,
            WATCHDOG_CYCLES => CYCLES_PER_MS * 100 )
        port map ( clk => clk_sys, rst => rst_sys, pw_in => sonar_pw,
                   distance_in => sonar_dist, data_valid => sonar_valid );

    sonar_filter : entity work.moving_average8
        generic map ( DATA_WIDTH => 16 )
        port map ( clk => clk_sys, rst => rst_sys,
                   valid_in => sonar_valid, data_in => sonar_dist,
                   valid_out => sonar_filt_valid, data_out => sonar_filt_out );

    -- =========================================================================
    -- Thresholds + FSM
    -- =========================================================================
    th_inst : entity work.threshold_detect
        generic map ( SONAR_NEAR_TH => 24, ALS_DARK_TH => 32, ALS_BRIGHT_TH => 220 )
        port map ( clk => clk_sys, rst => rst_sys,
                   als_value => als_filt_out, sonar_in => sonar_filt_out,
                   trig => trig, sonar_trig => sonar_trig, als_trig => als_trig,
                   ok => ok_sig, conf => conf_sig );

    fsm_inst : entity work.threat_fsm
        generic map ( T_LIMIT_CYCLES => 12_500_000 )
        port map ( clk => clk_sys, rst => rst_sys,
                   start => start_pulse, reset_btn => reset_pulse,
                   trig => trig, ok => ok_sig, conf => conf_sig,
                   state_code => state_code,
                   alert_active => alert_active,
                   severity => severity );

    -- =========================================================================
    -- LEDs
    -- =========================================================================
    blink_gen : entity work.pulse_gen
        generic map ( PERIOD_CYCLES => CYCLES_PER_MS * 250 )
        port map ( clk => clk_sys, rst => rst_sys, en => '1', pulse => blink_tick );

    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if rst_sys = '1' then
                blink <= '0';
            elsif blink_tick = '1' then
                blink <= not blink;
            end if;
        end if;
    end process;

    -- Sonar heartbeat: toggle on each real (non-watchdog) sonar reading.
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if rst_sys = '1' then
                sonar_heartbeat <= '0';
            elsif sonar_valid = '1' and sonar_dist /= 0 then
                sonar_heartbeat <= not sonar_heartbeat;
            end if;
        end if;
    end process;

    -- Raw PW level debug: synchronise the JE4 pin into clk_sys, drive
    -- the level onto LED3 directly so we can probe the pin without
    -- depending on the driver / multiply / filter pipeline being
    -- correct.
    sync_sonar_pw_dbg : entity work.synchronizer
        generic map ( STAGES => 2, RST_VAL => '0' )
        port map ( clk => clk_sys, rst => '0',
                   d_in => sonar_pw, d_out => sonar_pw_dbg );

    led(0) <= '1' when state_code = "000" else '0';
    led(1) <= '1' when state_code = "001" else
              '1' when state_code = "010" else '0';
    led(2) <= '1' when state_code = "011" else
              '1' when state_code = "101" else '0';
    led(3) <= blink        when state_code = "100" else
              sonar_pw_dbg;

    -- =========================================================================
    -- OLED
    -- =========================================================================
    oled_inst : entity work.pmod_oled_top
        generic map ( SYS_HZ => SYS_HZ, REFRESH_HZ => 30 )
        port map (
            clk          => clk_sys,
            rst          => rst_sys,
            state_code   => state_code,
            distance_in  => sonar_filt_out,
            als_value    => als_filt_out,
            severity     => severity,
            oled_cs_n    => oled_cs_n,
            oled_mosi    => oled_mosi,
            oled_sclk    => oled_sclk,
            oled_dc      => oled_dc,
            oled_res_n   => oled_res_n,
            oled_vbat_n  => oled_vbat_n,
            oled_vdd_n   => oled_vdd_n );

    -- =========================================================================
    -- CDC: sensor values -> pixel domain (slow-changing data)
    -- =========================================================================
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            dist_pix_a <= sonar_filt_out;
            dist_pix_b <= dist_pix_a;
            als_pix_a  <= als_filt_out;
            als_pix_b  <= als_pix_a;
        end if;
    end process;

    -- =========================================================================
    -- HDMI radar
    -- =========================================================================
    hdmi_inst : entity work.hdmi_top
        port map (
            clk_pixel    => clk_pixel,
            clk_serial   => clk_serial,
            rst          => rst_pixel,
            distance_in  => dist_pix_b,
            als_value    => als_pix_b,
            hdmi_tx_clk_p => hdmi_tx_clk_p,
            hdmi_tx_clk_n => hdmi_tx_clk_n,
            hdmi_tx_d_p   => hdmi_tx_d_p,
            hdmi_tx_d_n   => hdmi_tx_d_n,
            hdmi_tx_hpd   => hdmi_tx_hpd );

    hdmi_tx_en <= '1';

    -- Hold the MaxSonar RX line high so the sensor free-runs.  See
    -- the signal-declaration comment above for why we drive this from
    -- a KEEP'd register instead of a bare constant assignment.
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            sonar_rx_reg <= '1';
        end if;
    end process;

    sonar_rx <= sonar_rx_reg;

end architecture;
