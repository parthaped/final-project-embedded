-- ============================================================================
-- threshold_detect.vhd
--   Sonar-band classifier + combinational severity model.  This is the
--   single source of truth for "what severity should a contact have if
--   we logged it right now?", and it fixes the previous-build bug where
--   severity was hard-pinned at 00 because it depended on ALS being in
--   an extreme band that almost never occurred.
--
--   Inputs
--     sonar_in       : filtered range in inches (16-bit; 0 = no sample).
--     ambient_mode   : 2-bit ambient classification from
--                      `ambient_mode_detect`
--                        00 NIGHT  01 DIM  10 DAY  11 BRIGHT
--     sonar_near_th  : runtime "alert" range threshold (inches).  At/below
--                      this range, the FSM will treat the sample as a real
--                      contact.  Driven by SW1 in the top level (24 in
--                      "standard" / 36 in "paranoid").
--     sonar_warn_th  : runtime "warn" range threshold (inches).  In the
--                      gap [near_th .. warn_th) the sample is a "warn"
--                      hit; at night/dim ambient that's enough to trip
--                      the FSM.
--
--   Outputs (all registered for clean FSM sampling)
--     sonar_alert    : '1' iff (sonar_in > 0) AND (sonar_in < near_th)
--     sonar_warn     : '1' iff (near_th <= sonar_in < warn_th)
--     trig           : sonar_alert OR (sonar_warn AND ambient is dark)
--                      The FSM only ever needs this single qualified
--                      trigger, so we derive it here once.
--     severity_now   : combinational (latched into a per-cycle reg here)
--                      severity that the contact_log should record if a
--                      log_pulse fires this cycle.  Maps from
--                        (sonar_band, ambient_mode) -> {LOW,MED,HIGH,CRIT}
--                      per the table in the project plan.
--
--   The old als_trig / ok / conf outputs are gone -- they were only ever
--   consumed by the previous FSM, which is being reworked alongside this
--   module.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity threshold_detect is
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;

        sonar_in      : in  unsigned(15 downto 0);
        ambient_mode  : in  unsigned(1 downto 0);

        -- Runtime thresholds (driven from top level / SW1).  Eight bits
        -- is plenty -- the MaxSonar maxes out at 254 inches.
        sonar_near_th : in  unsigned(7 downto 0);
        sonar_warn_th : in  unsigned(7 downto 0);

        sonar_alert   : out std_logic;
        sonar_warn    : out std_logic;
        trig          : out std_logic;
        severity_now  : out unsigned(1 downto 0)
    );
end entity;

architecture rtl of threshold_detect is
    -- Severity codes (matches the rest of the system).
    constant SEV_LOW  : unsigned(1 downto 0) := "00";
    constant SEV_MED  : unsigned(1 downto 0) := "01";
    constant SEV_HIGH : unsigned(1 downto 0) := "10";
    constant SEV_CRIT : unsigned(1 downto 0) := "11";

    -- Ambient codes (must match ambient_mode_detect).
    constant A_NIGHT  : unsigned(1 downto 0) := "00";
    constant A_DIM    : unsigned(1 downto 0) := "01";
    constant A_DAY    : unsigned(1 downto 0) := "10";
    constant A_BRIGHT : unsigned(1 downto 0) := "11";

    -- Stage 1 : raw band classifier.
    signal son_alert_s1 : std_logic := '0';
    signal son_warn_s1  : std_logic := '0';

    -- Sample of sonar_in narrowed to the byte we actually care about.
    -- The MaxSonar driver fills only the low byte but the moving-average
    -- filter widens to 16; clip here.
    signal son_byte     : unsigned(7 downto 0) := (others => '0');

    -- Latched ambient mode for the severity table (one cycle of pipeline
    -- so it lines up with son_alert_s1/son_warn_s1).
    signal amb_s1       : unsigned(1 downto 0) := A_DAY;

    -- Stage 2 : combinational severity derivation from the stage-1 signals.
    signal sev_comb     : unsigned(1 downto 0);

    -- '1' iff stage-1 ambient is dark enough for a warn hit to count
    -- as an intrusion event.  Broken out as its own signal so the
    -- 'trig' OR-gate stays readable.
    signal amb_dark_s1  : std_logic;
begin

    -- =========================================================================
    -- Stage 1: clip sonar to a byte, classify into alert/warn bands,
    -- pipeline ambient_mode to keep stages aligned.
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                son_byte     <= (others => '0');
                son_alert_s1 <= '0';
                son_warn_s1  <= '0';
                amb_s1       <= A_DAY;
            else
                if sonar_in > to_unsigned(254, sonar_in'length) then
                    son_byte <= to_unsigned(254, son_byte'length);
                else
                    son_byte <= sonar_in(7 downto 0);
                end if;

                amb_s1 <= ambient_mode;

                -- Default low.
                son_alert_s1 <= '0';
                son_warn_s1  <= '0';

                if son_byte > to_unsigned(0, son_byte'length) then
                    if son_byte < sonar_near_th then
                        son_alert_s1 <= '1';
                    elsif son_byte < sonar_warn_th then
                        son_warn_s1 <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Severity table (combinational, fed by stage-1 registered signals).
    --
    --   alert + DAY     -> LOW    (routine close approach in good light)
    --   alert + DIM     -> MED    (approach in low light)
    --   alert + NIGHT   -> HIGH   (stealth intrusion)
    --   alert + BRIGHT  -> CRIT   (dazzle / tampering)
    --   warn  + DIM/NIGHT -> LOW  (perimeter brushed in poor light)
    --   warn  + DAY/BRIGHT -> SAFE-equivalent: severity 00, but trig=0
    --                         so contact_log never sees it.
    --
    --   When neither band is asserted, sev_comb is don't-care (the FSM
    --   only samples it on a log_pulse, which only fires after trig).
    -- =========================================================================
    sev_comb <=
        SEV_LOW  when son_alert_s1 = '1' and amb_s1 = A_DAY    else
        SEV_MED  when son_alert_s1 = '1' and amb_s1 = A_DIM    else
        SEV_HIGH when son_alert_s1 = '1' and amb_s1 = A_NIGHT  else
        SEV_CRIT when son_alert_s1 = '1' and amb_s1 = A_BRIGHT else
        SEV_LOW  when son_warn_s1  = '1' and (amb_s1 = A_NIGHT or amb_s1 = A_DIM) else
        SEV_LOW;

    amb_dark_s1 <= '1' when (amb_s1 = A_NIGHT or amb_s1 = A_DIM) else '0';

    -- =========================================================================
    -- Stage 2: register the public outputs.  trig is the qualified
    -- trigger the FSM uses to enter S_CANDIDATE: an "alert" hit always
    -- counts; a "warn" hit only counts when ambient is dark enough that
    -- the reduced range still constitutes an intrusion event.
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sonar_alert  <= '0';
                sonar_warn   <= '0';
                trig         <= '0';
                severity_now <= SEV_LOW;
            else
                sonar_alert  <= son_alert_s1;
                sonar_warn   <= son_warn_s1;

                trig <= son_alert_s1 or (son_warn_s1 and amb_dark_s1);

                severity_now <= sev_comb;
            end if;
        end if;
    end process;

end architecture;
