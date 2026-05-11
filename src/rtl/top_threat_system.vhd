-- top_threat_system.vhd
--   Top level for the after-hours perimeter monitor on Zybo Z7-10.
--   Brings up the clocks, debounces the buttons, runs the two sensors
--   through the moving-average filter, classifies the result, runs the
--   non-sticky alert FSM, keeps a rolling contact log, drives the OLED
--   status panel, and drives the HDMI console.
--
--   Three clock domains live in here:
--     clk_sys     125 MHz - sensors, FSM, contact log, OLED
--     clk_pixel    25 MHz - VGA timing + console renderer + TMDS encode
--     clk_serial  125 MHz - TMDS serializer (5x DDR pair with clk_pixel)
--   Slow data crossing into clk_pixel goes through 2-FF sync registers;
--   the FSM's 1-cycle log_pulse uses a toggle so the slower domain
--   can't miss it.

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

        -- SW0=ARM, SW1=SENS_HIGH, SW2=CLEAR, SW3=TEST_INJECT
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
        -- We drive the MaxSonar's RX line high from the FPGA so the
        -- sensor stays in free-run ranging mode. We do this from a
        -- registered '1' instead of a bare constant so the synthesis
        -- tool keeps the OBUF that actually drives the pin.
        sonar_rx       : out   std_logic;

        hdmi_tx_clk_p  : out   std_logic;
        hdmi_tx_clk_n  : out   std_logic;
        hdmi_tx_d_p    : out   std_logic_vector(2 downto 0);
        hdmi_tx_d_n    : out   std_logic_vector(2 downto 0);
        hdmi_tx_hpd    : out   std_logic;

        -- Zybo Rev B has a TPD12S016 HDMI level shifter that needs this
        -- enable held high or the on-board HDMI TX stays disabled.
        hdmi_tx_en     : out   std_logic
    );
end entity;

architecture rtl of top_threat_system is

    constant SYS_HZ        : positive := 125_000_000;
    constant CYCLES_PER_MS : positive := SYS_HZ / 1000;

    -- clocks + resets
    signal clk_sys    : std_logic;
    signal clk_pixel  : std_logic;
    signal clk_serial : std_logic;
    signal mmcm_locked : std_logic;

    signal rst_async  : std_logic := '1';
    signal rst_cnt    : unsigned(15 downto 0) := (others => '0');

    signal rst_sys    : std_logic;
    signal rst_pixel  : std_logic;
    signal rst_serial : std_logic;

    -- buttons / switches (clk_sys)
    signal start_lvl, start_pulse : std_logic;
    signal reset_lvl, reset_pulse : std_logic;

    signal arm_lvl   : std_logic;
    signal sens_lvl  : std_logic;
    signal clear_lvl, clear_pulse : std_logic;
    signal inject_lvl : std_logic;

    -- sensors (clk_sys)
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

    -- ambient + threshold (clk_sys)
    signal ambient_mode   : unsigned(1 downto 0);
    signal mode_change    : std_logic;

    signal sonar_alert    : std_logic;
    signal sonar_warn     : std_logic;
    signal trig_q         : std_logic;
    signal severity_now   : unsigned(1 downto 0);

    signal near_th_byte   : unsigned(7 downto 0);
    signal warn_th_byte   : unsigned(7 downto 0);

    -- Toggles on every real (non-watchdog) sonar reading. Driven onto
    -- LD3 when we're not in cooldown so the LED doubles as a sonar
    -- liveness indicator.
    signal sonar_heartbeat : std_logic := '0';

    signal sonar_rx_reg : std_logic := '1';

    -- FSM + contact log (clk_sys)
    signal state_code      : std_logic_vector(2 downto 0);
    signal log_pulse_sys   : std_logic;
    signal cooldown_active : std_logic;
    signal clear_log_sys   : std_logic;

    signal write_pulse_sys : std_logic;
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

    -- T+ since arm
    signal tick_60hz_sys : std_logic;
    signal t_seconds_sys : unsigned(15 downto 0);

    -- test inject (synthesises a fake contact about once a second when
    -- SW3 is on so the demo can show all four severity colours without
    -- choreographing the operator in front of the sensor)
    signal inj_tick    : std_logic;
    signal inj_idx     : unsigned(1 downto 0) := (others => '0');
    signal inj_pulse   : std_logic := '0';
    signal inj_range   : unsigned(7 downto 0) := (others => '0');
    signal inj_sev     : unsigned(1 downto 0) := (others => '0');
    signal inj_ambient : unsigned(1 downto 0) := (others => '0');

    -- LED helpers
    signal blink_tick    : std_logic;
    signal blink_quarter : std_logic := '0';

    -- CDC: clk_sys -> clk_pixel
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

    -- toggle CDC for log_pulse so a 1-cycle clk_sys pulse can't fall
    -- through the cracks of the slower clk_pixel domain
    signal log_tog_sys   : std_logic := '0';
    signal log_tog_a     : std_logic := '0';
    signal log_tog_b     : std_logic := '0';
    signal log_tog_pix_d : std_logic := '0';
    signal log_pulse_pix : std_logic := '0';

    signal sev_at_log_sys : unsigned(1 downto 0) := (others => '0');
    signal sev_log_pix_a, sev_log_pix_b : unsigned(1 downto 0) := (others => '0');

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of range_pix_a    : signal is "TRUE";
    attribute ASYNC_REG of range_pix_b    : signal is "TRUE";
    attribute ASYNC_REG of als_pix_a      : signal is "TRUE";
    attribute ASYNC_REG of als_pix_b      : signal is "TRUE";
    attribute ASYNC_REG of amb_pix_a      : signal is "TRUE";
    attribute ASYNC_REG of amb_pix_b      : signal is "TRUE";
    attribute ASYNC_REG of sev_pix_a      : signal is "TRUE";
    attribute ASYNC_REG of sev_pix_b      : signal is "TRUE";
    attribute ASYNC_REG of pres_pix_a     : signal is "TRUE";
    attribute ASYNC_REG of pres_pix_b     : signal is "TRUE";
    attribute ASYNC_REG of arm_pix_a      : signal is "TRUE";
    attribute ASYNC_REG of arm_pix_b      : signal is "TRUE";
    attribute ASYNC_REG of nth_pix_a      : signal is "TRUE";
    attribute ASYNC_REG of nth_pix_b      : signal is "TRUE";
    attribute ASYNC_REG of wth_pix_a      : signal is "TRUE";
    attribute ASYNC_REG of wth_pix_b      : signal is "TRUE";
    attribute ASYNC_REG of cnt_pix_a      : signal is "TRUE";
    attribute ASYNC_REG of cnt_pix_b      : signal is "TRUE";
    attribute ASYNC_REG of t_pix_a        : signal is "TRUE";
    attribute ASYNC_REG of t_pix_b        : signal is "TRUE";
    attribute ASYNC_REG of contacts_pix_a : signal is "TRUE";
    attribute ASYNC_REG of contacts_pix_b : signal is "TRUE";
    attribute ASYNC_REG of log_tog_a      : signal is "TRUE";
    attribute ASYNC_REG of log_tog_b      : signal is "TRUE";
    attribute ASYNC_REG of sev_log_pix_a  : signal is "TRUE";
    attribute ASYNC_REG of sev_log_pix_b  : signal is "TRUE";

begin

    -- clocking
    clk_wiz_i : entity work.clk_wiz_hdmi
        port map (
            clk_in     => sysclk,
            rst_in     => '0',
            clk_sys    => clk_sys,
            clk_pixel  => clk_pixel,
            clk_serial => clk_serial,
            locked     => mmcm_locked );

    -- Hold the global reset asserted for 65k clk_sys cycles after the
    -- MMCM locks so every flop has come out of config before we let
    -- anything go.
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

    rst_sys_sync : entity work.synchronizer_rst
        port map ( clk => clk_sys,    d_in => rst_async, d_out => rst_sys );

    rst_pix_sync : entity work.synchronizer_rst
        port map ( clk => clk_pixel,  d_in => rst_async, d_out => rst_pixel );

    rst_ser_sync : entity work.synchronizer_rst
        port map ( clk => clk_serial, d_in => rst_async, d_out => rst_serial );

    -- buttons + switches
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

    -- SW1 picks the alert/warn range thresholds: low = standard
    -- (24/48 in), high = paranoid (36/72 in).
    near_th_byte <= to_unsigned(24, 8) when sens_lvl = '0' else
                    to_unsigned(36, 8);
    warn_th_byte <= to_unsigned(48, 8) when sens_lvl = '0' else
                    to_unsigned(72, 8);

    -- sensors + filters
    als_tick_gen : entity work.clock_div
        generic map ( DIV => CYCLES_PER_MS )
        port map ( clk => clk_sys, rst => rst_sys, en => '1', clk_en => als_tick );

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

    -- ambient mode + threshold detect
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

    -- FSM
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

    -- Latch the live severity at the moment of contact so the CDC
    -- copy that goes into clk_pixel sees a stable value.
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

    -- T+ since arm
    sysclk_inst : entity work.system_clock
        generic map ( TICK_PERIOD_CYCLES => SYS_HZ / 60 )
        port map ( clk => clk_sys, rst => rst_sys,
                   arm => arm_lvl,
                   tick_60hz => tick_60hz_sys,
                   t_seconds => t_seconds_sys );

    -- test inject: every ~1 s while SW3 is on, emit a synthetic
    -- contact walking range = 8/12/16/20 in and severity LOW->MED->
    -- HIGH->CRIT
    inj_tick_gen : entity work.clock_div
        generic map ( DIV => SYS_HZ )
        port map ( clk => clk_sys, rst => rst_sys,
                   en => inject_lvl, clk_en => inj_tick );

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

    -- The real FSM wins on a simultaneous write.
    write_pulse_sys <= log_pulse_sys or inj_pulse;
    in_range_in <= sonar_filt_out(7 downto 0)  when log_pulse_sys = '1' else inj_range;
    in_severity <= severity_now                when log_pulse_sys = '1' else inj_sev;
    in_ambient  <= ambient_mode                when log_pulse_sys = '1' else inj_ambient;

    -- contact log
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

    -- Held severity: keeps the OLED severity field readable across the
    -- gap between contacts.
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

    -- LEDs
    blink_gen : entity work.clock_div
        generic map ( DIV => CYCLES_PER_MS * 250 )
        port map ( clk => clk_sys, rst => rst_sys, en => '1', clk_en => blink_tick );

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

    -- LD0 ARM     : armed AND not parked in IDLE
    -- LD1 AMBIENT : lit when NIGHT or DIM
    -- LD2 CONTACT : any valid log slot
    -- LD3 ALERT   : blinks during cooldown, otherwise mirrors the sonar
    --               heartbeat so we can see the sensor is live
    led(0) <= '1' when arm_lvl = '1' and state_code /= "000" else '0';
    led(1) <= '1' when ambient_mode = "00" or ambient_mode = "01" else '0';
    led(2) <= '1' when count_sys /= to_unsigned(0, 4) else '0';
    led(3) <= blink_quarter when cooldown_active = '1' else
              sonar_heartbeat;

    -- OLED status panel
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

    -- CDC: clk_sys -> clk_pixel for the HDMI console
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            range_pix_a    <= sonar_filt_out(7 downto 0);
            range_pix_b    <= range_pix_a;
            als_pix_a      <= als_filt_out(7 downto 0);
            als_pix_b      <= als_pix_a;
            amb_pix_a      <= ambient_mode;
            amb_pix_b      <= amb_pix_a;
            sev_pix_a      <= severity_now;
            sev_pix_b      <= sev_pix_a;
            pres_pix_a     <= sonar_alert;
            pres_pix_b     <= pres_pix_a;
            arm_pix_a      <= arm_lvl;
            arm_pix_b      <= arm_pix_a;
            nth_pix_a      <= near_th_byte;
            nth_pix_b      <= nth_pix_a;
            wth_pix_a      <= warn_th_byte;
            wth_pix_b      <= wth_pix_a;
            cnt_pix_a      <= count_sys;
            cnt_pix_b      <= cnt_pix_a;
            t_pix_a        <= t_seconds_sys;
            t_pix_b        <= t_pix_a;
            contacts_pix_a <= contacts_sys;
            contacts_pix_b <= contacts_pix_a;
            sev_log_pix_a  <= sev_at_log_sys;
            sev_log_pix_b  <= sev_log_pix_a;

            log_tog_a     <= log_tog_sys;
            log_tog_b     <= log_tog_a;
            log_tog_pix_d <= log_tog_b;
            log_pulse_pix <= log_tog_b xor log_tog_pix_d;
        end if;
    end process;

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

    -- HDMI console
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

    -- Hold the MaxSonar RX line high so the sensor free-runs.
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            sonar_rx_reg <= '1';
        end if;
    end process;

    sonar_rx <= sonar_rx_reg;

end architecture;
