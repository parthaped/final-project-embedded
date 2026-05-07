-- ============================================================================
-- tb_threat_fsm.vhd
--   Walks the reworked perimeter-monitor FSM through every transition
--   in the new state diagram and asserts the resulting state codes,
--   log_pulse, and cooldown_active outputs.
--
--   New states (encoded into state_code 2:0):
--       000=IDLE  001=MONITOR  010=CANDIDATE  011=VERIFY
--       100=CONTACT  101=COOLDOWN
--
--   Severity is no longer produced by the FSM; the contact_log captures
--   `severity_now` directly when log_pulse fires.  This testbench just
--   confirms the FSM emits log_pulse for one cycle in S_CONTACT and
--   then returns to MONITOR after cooldown.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_threat_fsm is
end entity;

architecture sim of tb_threat_fsm is
    constant CLK_PERIOD : time := 10 ns;
    constant T_LIM      : positive := 8;
    constant T_COOL     : positive := 12;

    signal clk             : std_logic := '0';
    signal rst             : std_logic := '1';
    signal start           : std_logic := '0';
    signal reset_btn       : std_logic := '0';
    signal arm             : std_logic := '1';
    signal trig            : std_logic := '0';

    signal state_code      : std_logic_vector(2 downto 0);
    signal log_pulse       : std_logic;
    signal cooldown_active : std_logic;
    signal clear_log       : std_logic;

    constant C_IDLE      : std_logic_vector(2 downto 0) := "000";
    constant C_MONITOR   : std_logic_vector(2 downto 0) := "001";
    constant C_CANDIDATE : std_logic_vector(2 downto 0) := "010";
    constant C_VERIFY    : std_logic_vector(2 downto 0) := "011";
    constant C_CONTACT   : std_logic_vector(2 downto 0) := "100";
    constant C_COOLDOWN  : std_logic_vector(2 downto 0) := "101";
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.threat_fsm
        generic map (
            T_LIMIT_CYCLES    => T_LIM,
            T_COOLDOWN_CYCLES => T_COOL )
        port map (
            clk             => clk,
            rst             => rst,
            start           => start,
            reset_btn       => reset_btn,
            arm             => arm,
            trig            => trig,
            state_code      => state_code,
            log_pulse       => log_pulse,
            cooldown_active => cooldown_active,
            clear_log       => clear_log );

    main : process
        procedure tick(n : integer := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure check_state(expected : std_logic_vector(2 downto 0); tag : string) is
        begin
            assert state_code = expected
                report "FSM: at " & tag &
                       " expected " & to_string(expected) &
                       " got "      & to_string(state_code)
                severity failure;
        end procedure;

        variable log_count : integer := 0;
    begin
        rst <= '1'; tick(5);
        rst <= '0'; tick(2);
        check_state(C_IDLE, "after-reset");

        ----------------------------------------------------------------
        -- Path A:  Idle -> Monitor -> Candidate -> Verify -> Contact ->
        --          Cooldown -> Monitor (full happy path)
        ----------------------------------------------------------------
        start <= '1'; tick; start <= '0'; tick;
        check_state(C_MONITOR, "Idle->Monitor");

        trig  <= '1'; tick(2);
        check_state(C_CANDIDATE, "Monitor->Candidate");

        tick(T_LIM + 2);
        check_state(C_VERIFY, "Candidate->Verify (T)");

        -- trig still high through verify -> Contact
        tick(T_LIM + 2);
        check_state(C_CONTACT, "Verify->Contact (trig held)");

        -- log_pulse must be high in S_CONTACT for exactly one cycle.
        assert log_pulse = '1'
            report "log_pulse should be '1' in S_CONTACT" severity failure;

        tick;
        check_state(C_COOLDOWN, "Contact->Cooldown (1 cycle)");
        assert log_pulse = '0'
            report "log_pulse should drop after S_CONTACT" severity failure;
        assert cooldown_active = '1'
            report "cooldown_active should be '1' in COOLDOWN" severity failure;

        -- During cooldown trig must NOT cause a re-trigger.
        trig <= '1';
        tick(T_COOL);
        check_state(C_COOLDOWN, "Cooldown holds against re-trigger");

        trig <= '0';
        tick(3);
        check_state(C_MONITOR, "Cooldown->Monitor (T_cool)");

        ----------------------------------------------------------------
        -- Path B:  Verify timeout fallback (glitch).  trig drops before
        -- Verify completes -> back to Monitor without logging.
        ----------------------------------------------------------------
        trig <= '1'; tick(2);
        check_state(C_CANDIDATE, "Monitor->Candidate (B)");

        tick(T_LIM + 2);
        check_state(C_VERIFY, "Candidate->Verify (B)");

        -- Trig drops; Verify must fall back to Monitor immediately.
        trig <= '0'; tick(2);
        check_state(C_MONITOR, "Verify->Monitor (glitch)");

        ----------------------------------------------------------------
        -- Path C:  reset_btn from any state -> Monitor + clear_log pulse.
        ----------------------------------------------------------------
        trig <= '1'; tick(2);
        check_state(C_CANDIDATE, "Monitor->Candidate (C)");

        reset_btn <= '1'; tick;
        assert clear_log = '1'
            report "clear_log should track reset_btn" severity failure;
        reset_btn <= '0'; tick;
        check_state(C_MONITOR, "reset_btn -> Monitor");

        ----------------------------------------------------------------
        -- Path D:  arm low force-holds IDLE.
        ----------------------------------------------------------------
        trig <= '0';
        arm <= '0'; tick(3);
        check_state(C_IDLE, "arm=0 -> IDLE");

        arm <= '1'; tick(2);
        check_state(C_IDLE, "arm restored, still IDLE");

        start <= '1'; tick; start <= '0'; tick(2);
        check_state(C_MONITOR, "Idle->Monitor (after re-arm)");

        report "tb_threat_fsm PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
