-- threat_fsm.vhd
--   5-state Moore FSM for the alert pipeline. Same shape as the UART
--   RX FSM from class (idle / busyA / busyB / busyC), just with my own
--   state names:
--
--       Idle      --start-------> Monitor
--       Monitor   --trig---------> Candidate
--       Candidate --t_done-------> Verify
--       Verify    --trig still 1-> Contact          (1 cycle, log_pulse=1)
--       Verify    --trig dropped-> Monitor          (glitch fallback)
--       Contact   --next clock---> Cooldown
--       Cooldown  --t_done-------> Monitor
--
--   Severity is no longer computed in here -- threshold_detect produces
--   severity_now combinationally and the contact_log captures it on the
--   same cycle as log_pulse, so reaching MED/HIGH/CRIT doesn't depend on
--   walking through a separate FSM state.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity threat_fsm is
    generic (
        T_LIMIT_CYCLES    : positive := 12_500_000;   -- 100 ms at 125 MHz
        T_COOLDOWN_CYCLES : positive := 31_250_000    -- 250 ms at 125 MHz
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

    -- State register and dwell counter. Reset the counter every time
    -- we switch states so we can reuse the same counter for candidate,
    -- verify, and cooldown timing.
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state     <= S_IDLE;
                dwell_cnt <= (others => '0');
            else
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

    -- Next-state logic. arm=0 force-holds IDLE so the slide switch is a
    -- hardware "armed/disarmed" lever. reset_btn drops back to MONITOR
    -- from anywhere except IDLE.
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
                        next_state <= S_MONITOR;
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
                    -- We only log a contact if the trigger is still up
                    -- after the candidate dwell. If trig drops we fall
                    -- back to MONITOR, so a glitch can't put us in the
                    -- log.
                    if reset_btn = '1' then
                        next_state <= S_MONITOR;
                    elsif trig = '0' then
                        next_state <= S_MONITOR;
                    elsif t_dwell = '1' then
                        next_state <= S_CONTACT;
                    end if;

                when S_CONTACT =>
                    -- One-cycle "contact logged" state. Its only job
                    -- is to emit a 1-cycle log_pulse.
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
