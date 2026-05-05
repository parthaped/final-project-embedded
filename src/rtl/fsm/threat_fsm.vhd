-- ============================================================================
-- threat_fsm.vhd
--   Six-state Moore FSM matching the slide:
--
--       Idle --start--> Monitor
--       Monitor --no trig--> Monitor
--       Monitor --trig--> Candidate
--       Candidate --T--> Verify             (T = dwell timer expires)
--       Verify --ok--> Classify             (multi-sensor agreement)
--       Verify --conf--> Alert              (single-sensor confirm)
--       Verify --T (no ok/conf)--> Monitor  (threat cleared during dwell)
--       Classify --sev--> Alert             (severity computed)
--       Alert --reset--> Monitor
--
--   Outputs:
--     state_code(2:0) - one-hot-ish encoding for downstream display drivers.
--                       000=IDLE, 001=MONITOR, 010=CANDIDATE, 011=VERIFY,
--                       100=ALERT, 101=CLASSIFY.
--     alert_active   - high while in ALERT.
--     severity(1:0)   - 00 if conf->Alert (sonar only),
--                       01 if ok->Classify->Alert (multi-sensor moderate),
--                       10/11 reserved for future expansion.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity threat_fsm is
    generic (
        -- Default 100 ms at 125 MHz.
        T_LIMIT_CYCLES : positive := 12_500_000
    );
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;

        start         : in  std_logic;     -- BTN0 pulse
        reset_btn     : in  std_logic;     -- BTN3 pulse
        trig          : in  std_logic;
        ok            : in  std_logic;
        conf          : in  std_logic;

        state_code    : out std_logic_vector(2 downto 0);
        alert_active  : out std_logic;
        severity      : out std_logic_vector(1 downto 0)
    );
end entity;

architecture rtl of threat_fsm is
    type state_t is (S_IDLE, S_MONITOR, S_CANDIDATE, S_VERIFY, S_ALERT, S_CLASSIFY);
    signal state, next_state : state_t := S_IDLE;

    signal dwell_cnt : unsigned(31 downto 0) := (others => '0');
    signal t_done    : std_logic;

    signal sev_r : std_logic_vector(1 downto 0) := (others => '0');
begin

    t_done <= '1' when dwell_cnt = to_unsigned(T_LIMIT_CYCLES-1, dwell_cnt'length) else '0';

    -- -------------------------------------------------------------------
    -- State register + dwell counter
    -- -------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state     <= S_IDLE;
                dwell_cnt <= (others => '0');
                sev_r     <= (others => '0');
            else
                if state /= next_state then
                    dwell_cnt <= (others => '0');
                else
                    if dwell_cnt /= to_unsigned(T_LIMIT_CYCLES-1, dwell_cnt'length) then
                        dwell_cnt <= dwell_cnt + 1;
                    end if;
                end if;

                -- Latch severity at the moment we leave Verify or Classify.
                -- Clearing in IDLE and MONITOR guarantees no stale alert value
                -- survives an Alert->Monitor reset.
                case state is
                    when S_VERIFY =>
                        if conf = '1' and ok = '0' then
                            sev_r <= "00";          -- single-sensor confirm
                        end if;
                    when S_CLASSIFY =>
                        sev_r <= "01";              -- multi-sensor classified
                    when S_IDLE | S_MONITOR =>
                        sev_r <= "00";
                    when others =>
                        null;
                end case;

                state <= next_state;
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------
    -- Next-state logic
    -- -------------------------------------------------------------------
    process(state, start, trig, ok, conf, t_done, reset_btn)
    begin
        next_state <= state;
        case state is
            when S_IDLE =>
                if start = '1' then
                    next_state <= S_MONITOR;
                end if;

            when S_MONITOR =>
                if trig = '1' then
                    next_state <= S_CANDIDATE;
                end if;

            when S_CANDIDATE =>
                -- Stay until the dwell timer "T" expires; then transition.
                if t_done = '1' then
                    next_state <= S_VERIFY;
                end if;

            when S_VERIFY =>
                -- Decide as soon as ok/conf are observed.  If neither asserts
                -- before the dwell timer expires (e.g. the trigger that put us
                -- here was a glitch and the sensors have returned to safe
                -- band), fall back to Monitor so the FSM cannot deadlock.
                if ok = '1' then
                    next_state <= S_CLASSIFY;
                elsif conf = '1' then
                    next_state <= S_ALERT;
                elsif t_done = '1' then
                    next_state <= S_MONITOR;
                end if;

            when S_CLASSIFY =>
                -- One pass through Classify computes severity and proceeds.
                if t_done = '1' then
                    next_state <= S_ALERT;
                end if;

            when S_ALERT =>
                if reset_btn = '1' then
                    next_state <= S_MONITOR;
                end if;
        end case;
    end process;

    -- -------------------------------------------------------------------
    -- Outputs
    -- -------------------------------------------------------------------
    with state select state_code <=
        "000" when S_IDLE,
        "001" when S_MONITOR,
        "010" when S_CANDIDATE,
        "011" when S_VERIFY,
        "100" when S_ALERT,
        "101" when S_CLASSIFY;

    alert_active <= '1' when state = S_ALERT else '0';
    severity     <= sev_r;

end architecture;
