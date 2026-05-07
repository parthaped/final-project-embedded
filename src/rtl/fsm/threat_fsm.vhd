-- ============================================================================
-- threat_fsm.vhd
--   Reworked five-state Moore FSM for the perimeter monitor.  The
--   previous build had a sticky S_ALERT state that "held the alert"
--   forever and a separate S_CLASSIFY state that only ever produced
--   severity 00 in practice.  This version is non-sticky: instead of
--   parking in an alert state, we emit a single-cycle `log_pulse` at
--   the moment of contact and let `contact_log` keep the running list
--   of recent events.  The system then returns to monitoring after a
--   short cooldown.
--
--       Idle      --start-------> Monitor
--       Monitor   --trig---------> Candidate
--       Candidate --t_done-------> Verify
--       Verify    --trig still 1-> Contact          (1 cycle, log_pulse=1)
--       Verify    --t_done & ~trig-> Monitor        (glitch fallback)
--       Contact   --always next--> Cooldown         (immediate)
--       Cooldown  --t_done-------> Monitor          (no re-trigger during this)
--
--   Severity is no longer computed inside the FSM -- threshold_detect
--   produces `severity_now` combinationally from (sonar band, ambient
--   mode), and the contact_log captures it on the same cycle as
--   log_pulse.  This is what fixes the "severity stuck at 00" bug:
--   reaching MED/HIGH/CRIT no longer requires walking through a
--   separate FSM state.
--
--   Inputs
--     start      : BTN0 pulse to leave IDLE.
--     reset_btn  : BTN3 / SW2 pulse, returns to MONITOR and pulses
--                  `clear_log` so the upstream contact log can wipe.
--     arm        : SW0 level.  When low, force-holds the FSM in IDLE
--                  regardless of the rest of the inputs (a hardware
--                  "armed/disarmed" toggle).
--     trig       : qualified trigger from threshold_detect.
--
--   Outputs
--     state_code      : encoded current state (see below).
--     log_pulse       : single-cycle pulse in S_CONTACT.  Top level
--                       wires this to contact_log.write_pulse.
--     cooldown_active : '1' while in S_COOLDOWN.  Top level uses this
--                       to drive the "alert flash" LED and to gate
--                       re-entry into S_CANDIDATE.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity threat_fsm is
    generic (
        -- Default 100 ms at 125 MHz (used for candidate dwell + verify
        -- timeout).
        T_LIMIT_CYCLES    : positive := 12_500_000;
        -- Cooldown after a contact.  Default 250 ms at 125 MHz.
        T_COOLDOWN_CYCLES : positive := 31_250_000
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        start           : in  std_logic;
        reset_btn       : in  std_logic;
        arm             : in  std_logic;
        trig            : in  std_logic;

        state_code      : out std_logic_vector(2 downto 0);
        log_pulse       : out std_logic;
        cooldown_active : out std_logic;
        clear_log       : out std_logic
    );
end entity;

architecture rtl of threat_fsm is
    type state_t is (S_IDLE, S_MONITOR, S_CANDIDATE, S_VERIFY,
                     S_CONTACT, S_COOLDOWN);
    signal state, next_state : state_t := S_IDLE;

    signal dwell_cnt : unsigned(31 downto 0) := (others => '0');
    signal t_dwell   : std_logic;
    signal t_cool    : std_logic;
begin

    t_dwell <= '1' when dwell_cnt = to_unsigned(T_LIMIT_CYCLES-1,
                                                dwell_cnt'length) else '0';
    t_cool  <= '1' when dwell_cnt = to_unsigned(T_COOLDOWN_CYCLES-1,
                                                dwell_cnt'length) else '0';

    -- -------------------------------------------------------------------
    -- State register + dwell counter
    -- -------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state     <= S_IDLE;
                dwell_cnt <= (others => '0');
            else
                -- Reset dwell on every state change so each new state
                -- starts with cnt=0; this lets us share `dwell_cnt`
                -- between candidate dwell, verify timeout, and
                -- cooldown.
                if state /= next_state then
                    dwell_cnt <= (others => '0');
                else
                    if dwell_cnt /= to_unsigned(T_COOLDOWN_CYCLES-1,
                                                dwell_cnt'length) then
                        dwell_cnt <= dwell_cnt + 1;
                    end if;
                end if;

                state <= next_state;
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------
    -- Next-state logic
    --
    -- The arm input force-holds IDLE.  reset_btn is a global "back to
    -- MONITOR (or IDLE if disarmed)" override.  trig is the qualified
    -- single-line trigger from threshold_detect.
    -- -------------------------------------------------------------------
    process(state, start, trig, t_dwell, t_cool, reset_btn, arm)
    begin
        next_state <= state;

        if arm = '0' then
            next_state <= S_IDLE;
        else
            case state is
                when S_IDLE =>
                    if start = '1' then
                        next_state <= S_MONITOR;
                    end if;

                when S_MONITOR =>
                    if reset_btn = '1' then
                        next_state <= S_MONITOR;       -- explicit clear; stay in monitor
                    elsif trig = '1' then
                        next_state <= S_CANDIDATE;
                    end if;

                when S_CANDIDATE =>
                    if reset_btn = '1' then
                        next_state <= S_MONITOR;
                    elsif t_dwell = '1' then
                        next_state <= S_VERIFY;
                    end if;

                when S_VERIFY =>
                    -- We get to log a contact iff the trigger has
                    -- survived the candidate dwell.  Otherwise we fall
                    -- back to MONITOR (glitch rejection).  Falling back
                    -- on the dwell-timeout edge avoids deadlocking when
                    -- the trigger drops mid-verify.
                    if reset_btn = '1' then
                        next_state <= S_MONITOR;
                    elsif trig = '0' then
                        next_state <= S_MONITOR;
                    elsif t_dwell = '1' then
                        next_state <= S_CONTACT;
                    end if;

                when S_CONTACT =>
                    -- Single-cycle "contact logged" state.  Its only
                    -- purpose is to emit a 1-cycle log_pulse.
                    next_state <= S_COOLDOWN;

                when S_COOLDOWN =>
                    if reset_btn = '1' then
                        next_state <= S_MONITOR;
                    elsif t_cool = '1' then
                        next_state <= S_MONITOR;
                    end if;

            end case;
        end if;
    end process;

    -- -------------------------------------------------------------------
    -- Outputs
    -- -------------------------------------------------------------------
    with state select state_code <=
        "000" when S_IDLE,
        "001" when S_MONITOR,
        "010" when S_CANDIDATE,
        "011" when S_VERIFY,
        "100" when S_CONTACT,
        "101" when S_COOLDOWN;

    log_pulse       <= '1' when state = S_CONTACT  else '0';
    cooldown_active <= '1' when state = S_COOLDOWN else '0';
    clear_log       <= reset_btn;

end architecture;
