-- ============================================================================
-- top_threat_system.vhd  --  PERIMETER MONITOR TOP
--
-- Top-level for the after-hours perimeter monitor.  Brings online the
-- MMCM clock tree, the OLED status panel, the HDMI surveillance
-- console, the ALS + sonar sensor pipelines, the contact log, and the
-- non-sticky FSM.
--
-- Clock domains:
--   clk_sys     125 MHz : sensors, FSM, contact log, OLED
--   clk_pixel    25 MHz : VGA timing, console renderer, TMDS encoders
--   clk_serial  125 MHz : TMDS serializer high-speed input
--
-- Slow-changing buses (range, ALS byte, ambient_mode, severity, FSM
-- state, contact array, t_seconds, runtime thresholds) cross
-- clk_sys -> clk_pixel through 2-stage ASYNC_REG synchronisers.  The
-- single-cycle FSM `log_pulse` crosses through a toggle handshake so
-- the slower clk_pixel cannot miss it.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

use work.contact_pkg.all;

entity top_threat_system is
    port (
        sysclk         : in    std_logic;
        btn_start      : in    std_logic;
        btn_reset      : in    std_logic;

        -- Slide switches: SW0=ARM, SW1=SENS_HIGH, SW2=CLEAR, SW3=TEST_INJECT
        sw             : in    std_logic_vector(3 downto 0);

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
        -- pins otherwise wins against the sensor's weak internal
        -- pull-up and freezes PW low.
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
    -- Buttons / switches (clk_sys)
    -- =========================================================================
    signal start_lvl, start_pulse : std_logic;
    signal reset_lvl, reset_pulse : std_logic;

    signal arm_lvl   : std_logic;
    signal sens_lvl  : std_logic;
    signal clear_lvl, clear_pulse : std_logic;
    signal inject_lvl : std_logic;

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

    -- =========================================================================
    -- Ambient + threshold (clk_sys)
    -- =========================================================================
    signal ambient_mode   : unsigned(1 downto 0);
    signal mode_change    : std_logic;

    signal sonar_alert    : std_logic;
    signal sonar_warn     : std_logic;
    signal trig_q         : std_logic;
    signal severity_now   : unsigned(1 downto 0);

    signal near_th_byte   : unsigned(7 downto 0);
    signal warn_th_byte   : unsigned(7 downto 0);

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
    -- FSM + contact log (clk_sys)
    -- =========================================================================
    signal state_code      : std_logic_vector(2 downto 0);
    signal log_pulse_sys   : std_logic;
    signal cooldown_active : std_logic;
    signal clear_log_sys   : std_logic;

    signal write_pulse_sys : std_logic;        -- log_pulse OR test inject
    signal in_range_in     : unsigned(7 downto 0);
    signal in_severity     : unsigned(1 downto 0);
    signal in_ambient      : unsigned(1 downto 0);

    signal contacts_sys    : contact_array_t := CONTACTS_NULL;
    signal count_sys       : unsigned(3 downto 0);

    signal last_valid_sys    : std_logic;
    signal last_range_sys    : unsigned(7 downto 0);
    signal last_severity_sys : unsigned(1 downto 0);
    signal last_ambient_sys  : unsigned(1 downto 0);
    signal last_t_log_sys    : unsigned(15 downto 0);

    signal sev_held_sys      : unsigned(1 downto 0) := (others => '0');

    -- =========================================================================
    -- System clock (T+ since arm)
    -- =========================================================================
    signal tick_60hz_sys : std_logic;
    signal t_seconds_sys : unsigned(15 downto 0);

    -- =========================================================================
    -- Test inject generator (clk_sys)
    --   While inject_lvl='1', emit a 1-cycle write_pulse approximately
    --   once a second, with a synthetic range walking through 8/16/24/32
    --   inches and a severity walking through LOW->MED->HIGH->CRIT so
    --   the demo can show the entire severity table without choreographing
    --   the operator in front of the sensor.
    -- =========================================================================
    signal inj_tick    : std_logic;
    signal inj_idx     : unsigned(1 downto 0) := (others => '0');
    signal inj_pulse   : std_logic := '0';
    signal inj_range   : unsigned(7 downto 0) := (others => '0');
    signal inj_sev     : unsigned(1 downto 0) := (others => '0');
    signal inj_ambient : unsigned(1 downto 0) := (others => '0');

    -- =========================================================================
    -- LED helpers
    -- =========================================================================
    signal blink_tick    : std_logic;
    signal blink_quarter : std_logic := '0';

    signal sonar_heartbeat : std_logic := '0';
    signal sonar_pw_dbg    : std_logic;

    -- Registered '1' driver for the MaxSonar RX line; KEEP/DONT_TOUCH
    -- prevents Vivado from collapsing the OBUF.
    signal sonar_rx_reg : std_logic := '1';
    attribute KEEP        : string;
    attribute KEEP        of sonar_rx_reg : signal is "TRUE";
    attribute DONT_TOUCH  : string;
    attribute DONT_TOUCH  of sonar_rx_reg : signal is "TRUE";

    -- =========================================================================
    -- CDC: clk_sys -> clk_pixel for the HDMI console.
    -- =========================================================================
    signal range_pix_a, range_pix_b : unsigned(7 downto 0) := (others => '0');
    signal als_pix_a, als_pix_b     : unsigned(7 downto 0) := (others => '0');
    signal amb_pix_a, amb_pix_b     : unsigned(1 downto 0) := (others => '0');
    signal sev_pix_a, sev_pix_b     : unsigned(1 downto 0) := (others => '0');
    signal pres_pix_a, pres_pix_b   : std_logic := '0';
    signal arm_pix_a, arm_pix_b     : std_logic := '0';
    signal nth_pix_a, nth_pix_b     : unsigned(7 downto 0) := (others => '0');
    signal wth_pix_a, wth_pix_b     : unsigned(7 downto 0) := (others => '0');
    signal cnt_pix_a, cnt_pix_b     : unsigned(3 downto 0) := (others => '0');
    signal t_pix_a, t_pix_b         : unsigned(15 downto 0) := (others => '0');
    signal contacts_pix_a, contacts_pix_b : contact_array_t := CONTACTS_NULL;

    -- log_pulse toggle CDC.
    signal log_tog_sys   : std_logic := '0';
    signal log_tog_a     : std_logic := '0';
    signal log_tog_b     : std_logic := '0';
    signal log_tog_pix_d : std_logic := '0';
    signal log_pulse_pix : std_logic := '0';

    -- Severity captured at log_pulse (latched in clk_sys, CDC'd here).
    signal sev_at_log_sys : unsigned(1 downto 0) := (others => '0');
    signal sev_log_pix_a, sev_log_pix_b : unsigned(1 downto 0) := (others => '0');

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of range_pix_a : signal is "TRUE";
    attribute ASYNC_REG of range_pix_b : signal is "TRUE";
    attribute ASYNC_REG of als_pix_a   : signal is "TRUE";
    attribute ASYNC_REG of als_pix_b   : signal is "TRUE";
    attribute ASYNC_REG of amb_pix_a   : signal is "TRUE";
    attribute ASYNC_REG of amb_pix_b   : signal is "TRUE";
    attribute ASYNC_REG of sev_pix_a   : signal is "TRUE";
    attribute ASYNC_REG of sev_pix_b   : signal is "TRUE";
    attribute ASYNC_REG of pres_pix_a  : signal is "TRUE";
    attribute ASYNC_REG of pres_pix_b  : signal is "TRUE";
    attribute ASYNC_REG of arm_pix_a   : signal is "TRUE";
    attribute ASYNC_REG of arm_pix_b   : signal is "TRUE";
    attribute ASYNC_REG of nth_pix_a   : signal is "TRUE";
    attribute ASYNC_REG of nth_pix_b   : signal is "TRUE";
    attribute ASYNC_REG of wth_pix_a   : signal is "TRUE";
    attribute ASYNC_REG of wth_pix_b   : signal is "TRUE";
    attribute ASYNC_REG of cnt_pix_a   : signal is "TRUE";
    attribute ASYNC_REG of cnt_pix_b   : signal is "TRUE";
    attribute ASYNC_REG of t_pix_a     : signal is "TRUE";
    attribute ASYNC_REG of t_pix_b     : signal is "TRUE";
    attribute ASYNC_REG of contacts_pix_a : signal is "TRUE";
    attribute ASYNC_REG of contacts_pix_b : signal is "TRUE";
    attribute ASYNC_REG of log_tog_a   : signal is "TRUE";
    attribute ASYNC_REG of log_tog_b   : signal is "TRUE";
    attribute ASYNC_REG of sev_log_pix_a : signal is "TRUE";
    attribute ASYNC_REG of sev_log_pix_b : signal is "TRUE";

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

    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if mmcm_locked = '0' then
                rst_async <= '1';
                rst_cnt   <= (others => '0');
            elsif rst_cnt /= x"FFFF" then
                rst_cnt   <= rst_cnt + 1;
                rst_async <= '1';
            else
                rst_async <= '0';
            end if;
        end if;
    end process;

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
    -- Buttons + slide switches
    -- =========================================================================
    deb_start : entity work.debouncer
        generic map ( STABLE_CYCLES => CYCLES_PER_MS * 20 )
        port map ( clk => clk_sys, rst => rst_sys, btn_in => btn_start,
                   btn_level => start_lvl, btn_pulse => start_pulse );

    deb_reset : entity work.debouncer
        generic map ( STABLE_CYCLES => CYCLES_PER_MS * 20 )
        port map ( clk => clk_sys, rst => rst_sys, btn_in => btn_reset,
                   btn_level => reset_lvl, btn_pulse => reset_pulse );

    deb_arm : entity work.debouncer
        generic map ( STABLE_CYCLES => CYCLES_PER_MS * 5 )
        port map ( clk => clk_sys, rst => rst_sys, btn_in => sw(0),
                   btn_level => arm_lvl, btn_pulse => open );

    deb_sens : entity work.debouncer
        generic map ( STABLE_CYCLES => CYCLES_PER_MS * 5 )
        port map ( clk => clk_sys, rst => rst_sys, btn_in => sw(1),
                   btn_level => sens_lvl, btn_pulse => open );

    deb_clear : entity work.debouncer
        generic map ( STABLE_CYCLES => CYCLES_PER_MS * 5 )
        port map ( clk => clk_sys, rst => rst_sys, btn_in => sw(2),
                   btn_level => clear_lvl, btn_pulse => clear_pulse );

    deb_inject : entity work.debouncer
        generic map ( STABLE_CYCLES => CYCLES_PER_MS * 5 )
        port map ( clk => clk_sys, rst => rst_sys, btn_in => sw(3),
                   btn_level => inject_lvl, btn_pulse => open );

    -- =========================================================================
    -- Runtime thresholds: SW1 low = standard (24/48), high = paranoid (36/72).
    -- =========================================================================
    near_th_byte <= to_unsigned(24, 8) when sens_lvl = '0' else
                    to_unsigned(36, 8);
    warn_th_byte <= to_unsigned(48, 8) when sens_lvl = '0' else
                    to_unsigned(72, 8);

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
    -- Ambient mode + threshold detect
    -- =========================================================================
    amb_inst : entity work.ambient_mode_detect
        port map ( clk => clk_sys, rst => rst_sys,
                   als_value => als_filt_out,
                   ambient_mode => ambient_mode,
                   mode_change => mode_change );

    th_inst : entity work.threshold_detect
        port map ( clk => clk_sys, rst => rst_sys,
                   sonar_in      => sonar_filt_out,
                   ambient_mode  => ambient_mode,
                   sonar_near_th => near_th_byte,
                   sonar_warn_th => warn_th_byte,
                   sonar_alert   => sonar_alert,
                   sonar_warn    => sonar_warn,
                   trig          => trig_q,
                   severity_now  => severity_now );

    -- =========================================================================
    -- FSM
    -- =========================================================================
    fsm_inst : entity work.threat_fsm
        generic map (
            T_LIMIT_CYCLES    => 12_500_000,
            T_COOLDOWN_CYCLES => 31_250_000 )
        port map (
            clk             => clk_sys,
            rst             => rst_sys,
            start           => start_pulse,
            reset_btn       => reset_pulse or clear_pulse,
            arm             => arm_lvl,
            trig            => trig_q,
            state_code      => state_code,
            log_pulse       => log_pulse_sys,
            cooldown_active => cooldown_active,
            clear_log       => clear_log_sys );

    -- Latch the live severity at the moment of contact so any
    -- downstream consumer (CDC into clk_pixel) sees a stable value.
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if rst_sys = '1' then
                sev_at_log_sys <= (others => '0');
            elsif log_pulse_sys = '1' then
                sev_at_log_sys <= severity_now;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- System clock (T+ since arm)
    -- =========================================================================
    sysclk_inst : entity work.system_clock
        generic map ( TICK_PERIOD_CYCLES => SYS_HZ / 60 )
        port map ( clk => clk_sys, rst => rst_sys,
                   arm => arm_lvl,
                   tick_60hz => tick_60hz_sys,
                   t_seconds => t_seconds_sys );

    -- =========================================================================
    -- Test inject (synthesises a fake contact every ~1 s when SW3 high)
    -- =========================================================================
    inj_tick_gen : entity work.pulse_gen
        generic map ( PERIOD_CYCLES => SYS_HZ )            -- once per second
        port map ( clk => clk_sys, rst => rst_sys,
                   en => inject_lvl, pulse => inj_tick );

    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if rst_sys = '1' or inject_lvl = '0' then
                inj_idx     <= (others => '0');
                inj_pulse   <= '0';
                inj_range   <= (others => '0');
                inj_sev     <= (others => '0');
                inj_ambient <= (others => '0');
            else
                inj_pulse <= '0';
                if inj_tick = '1' and log_pulse_sys = '0' then
                    inj_pulse <= '1';
                    inj_idx   <= inj_idx + 1;

                    case inj_idx is
                        when "00" =>
                            inj_range   <= to_unsigned(8,  8);
                            inj_sev     <= "00";
                            inj_ambient <= "10";    -- DAY    -> LOW
                        when "01" =>
                            inj_range   <= to_unsigned(12, 8);
                            inj_sev     <= "01";
                            inj_ambient <= "01";    -- DIM    -> MED
                        when "10" =>
                            inj_range   <= to_unsigned(16, 8);
                            inj_sev     <= "10";
                            inj_ambient <= "00";    -- NIGHT  -> HIGH
                        when others =>
                            inj_range   <= to_unsigned(20, 8);
                            inj_sev     <= "11";
                            inj_ambient <= "11";    -- BRIGHT -> CRIT
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- Real FSM has priority on simultaneous writes.
    write_pulse_sys <= log_pulse_sys or inj_pulse;
    in_range_in <= sonar_filt_out(7 downto 0)  when log_pulse_sys = '1' else inj_range;
    in_severity <= severity_now                when log_pulse_sys = '1' else inj_sev;
    in_ambient  <= ambient_mode                when log_pulse_sys = '1' else inj_ambient;

    -- =========================================================================
    -- Contact log
    -- =========================================================================
    cl_inst : entity work.contact_log
        port map (
            clk           => clk_sys,
            rst           => rst_sys,
            write_pulse   => write_pulse_sys,
            clear_all     => clear_log_sys or clear_pulse,
            tick_60hz     => tick_60hz_sys,
            in_range_in   => in_range_in,
            in_severity   => in_severity,
            in_ambient    => in_ambient,
            t_seconds     => t_seconds_sys,
            contacts      => contacts_sys,
            count         => count_sys,
            last_valid    => last_valid_sys,
            last_range_in => last_range_sys,
            last_severity => last_severity_sys,
            last_ambient  => last_ambient_sys,
            last_t_log    => last_t_log_sys );

    -- A "held severity" register that survives the moment of presence
    -- so the OLED keeps showing the most recent contact's severity.
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if rst_sys = '1' or clear_log_sys = '1' or clear_pulse = '1' then
                sev_held_sys <= (others => '0');
            elsif log_pulse_sys = '1' then
                sev_held_sys <= severity_now;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- LEDs.  New mapping per the project plan.
    -- =========================================================================
    blink_gen : entity work.pulse_gen
        generic map ( PERIOD_CYCLES => CYCLES_PER_MS * 250 )
        port map ( clk => clk_sys, rst => rst_sys, en => '1', pulse => blink_tick );

    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if rst_sys = '1' then
                blink_quarter <= '0';
            elsif blink_tick = '1' then
                blink_quarter <= not blink_quarter;
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

    -- LD0 ARM: armed AND not parked in IDLE.
    led(0) <= '1' when arm_lvl = '1' and state_code /= "000" else '0';

    -- LD1 AMBIENT: lit when NIGHT or DIM.
    led(1) <= '1' when ambient_mode = "00" or ambient_mode = "01" else '0';

    -- LD2 CONTACT: any valid slot.
    led(2) <= '1' when count_sys /= to_unsigned(0, 4) else '0';

    -- LD3 ALERT FLASH: blink during cooldown, otherwise show PW
    -- heartbeat so the LED still tells you the sonar is alive.
    led(3) <= blink_quarter when cooldown_active = '1' else
              sonar_pw_dbg;

    -- =========================================================================
    -- OLED secondary status panel
    -- =========================================================================
    oled_inst : entity work.pmod_oled_top
        generic map ( SYS_HZ => SYS_HZ, REFRESH_HZ => 30 )
        port map (
            clk           => clk_sys,
            rst           => rst_sys,
            state_code    => state_code,
            ambient_mode  => ambient_mode,
            count         => count_sys,
            last_valid    => last_valid_sys,
            last_range_in => last_range_sys,
            last_severity => last_severity_sys,
            last_t_log    => last_t_log_sys,
            t_seconds     => t_seconds_sys,
            near_th       => near_th_byte,
            oled_cs_n    => oled_cs_n,
            oled_mosi    => oled_mosi,
            oled_sclk    => oled_sclk,
            oled_dc      => oled_dc,
            oled_res_n   => oled_res_n,
            oled_vbat_n  => oled_vbat_n,
            oled_vdd_n   => oled_vdd_n );

    -- =========================================================================
    -- CDC: clk_sys -> clk_pixel
    -- =========================================================================
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            range_pix_a <= sonar_filt_out(7 downto 0);
            range_pix_b <= range_pix_a;
            als_pix_a   <= als_filt_out(7 downto 0);
            als_pix_b   <= als_pix_a;
            amb_pix_a   <= ambient_mode;
            amb_pix_b   <= amb_pix_a;
            sev_pix_a   <= severity_now;
            sev_pix_b   <= sev_pix_a;
            pres_pix_a  <= sonar_alert;
            pres_pix_b  <= pres_pix_a;
            arm_pix_a   <= arm_lvl;
            arm_pix_b   <= arm_pix_a;
            nth_pix_a   <= near_th_byte;
            nth_pix_b   <= nth_pix_a;
            wth_pix_a   <= warn_th_byte;
            wth_pix_b   <= wth_pix_a;
            cnt_pix_a   <= count_sys;
            cnt_pix_b   <= cnt_pix_a;
            t_pix_a     <= t_seconds_sys;
            t_pix_b     <= t_pix_a;
            contacts_pix_a <= contacts_sys;
            contacts_pix_b <= contacts_pix_a;
            sev_log_pix_a <= sev_at_log_sys;
            sev_log_pix_b <= sev_log_pix_a;

            -- Toggle handshake for log_pulse.
            log_tog_a <= log_tog_sys;
            log_tog_b <= log_tog_a;
            log_tog_pix_d <= log_tog_b;
            log_pulse_pix <= log_tog_b xor log_tog_pix_d;
        end if;
    end process;

    -- Toggle the source flop on each FSM log_pulse.
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if rst_sys = '1' then
                log_tog_sys <= '0';
            elsif log_pulse_sys = '1' or inj_pulse = '1' then
                log_tog_sys <= not log_tog_sys;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- HDMI console
    -- =========================================================================
    hdmi_inst : entity work.hdmi_top
        port map (
            clk_pixel       => clk_pixel,
            clk_serial      => clk_serial,
            rst             => rst_pixel,
            range_in        => range_pix_b,
            als_value       => als_pix_b,
            ambient_mode    => amb_pix_b,
            severity_now    => sev_pix_b,
            presence        => pres_pix_b,
            log_pulse_pixel => log_pulse_pix,
            sev_value       => sev_log_pix_b,
            contacts        => contacts_pix_b,
            count           => cnt_pix_b,
            t_seconds       => t_pix_b,
            arm             => arm_pix_b,
            near_th         => nth_pix_b,
            warn_th         => wth_pix_b,
            hdmi_tx_clk_p   => hdmi_tx_clk_p,
            hdmi_tx_clk_n   => hdmi_tx_clk_n,
            hdmi_tx_d_p     => hdmi_tx_d_p,
            hdmi_tx_d_n     => hdmi_tx_d_n,
            hdmi_tx_hpd     => hdmi_tx_hpd );

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
