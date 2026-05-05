-- ============================================================================
-- tb_threat_fsm.vhd
--   Walks the FSM through every transition shown in the slide and asserts
--   the resulting state codes.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_threat_fsm is
end entity;

architecture sim of tb_threat_fsm is
    constant CLK_PERIOD : time := 10 ns;
    constant T_LIM      : positive := 8;        -- short dwell for sim

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal start        : std_logic := '0';
    signal reset_btn    : std_logic := '0';
    signal trig         : std_logic := '0';
    signal ok           : std_logic := '0';
    signal conf         : std_logic := '0';
    signal state_code   : std_logic_vector(2 downto 0);
    signal alert_active : std_logic;
    signal severity     : std_logic_vector(1 downto 0);

    constant C_IDLE      : std_logic_vector(2 downto 0) := "000";
    constant C_MONITOR   : std_logic_vector(2 downto 0) := "001";
    constant C_CANDIDATE : std_logic_vector(2 downto 0) := "010";
    constant C_VERIFY    : std_logic_vector(2 downto 0) := "011";
    constant C_ALERT     : std_logic_vector(2 downto 0) := "100";
    constant C_CLASSIFY  : std_logic_vector(2 downto 0) := "101";
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.threat_fsm
        generic map ( T_LIMIT_CYCLES => T_LIM )
        port map (
            clk          => clk,
            rst          => rst,
            start        => start,
            reset_btn    => reset_btn,
            trig         => trig,
            ok           => ok,
            conf         => conf,
            state_code   => state_code,
            alert_active => alert_active,
            severity     => severity );

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
    begin
        rst <= '1'; tick(5);
        rst <= '0'; tick(2);
        check_state(C_IDLE, "after-reset");

        ----------------------------------------------------------------
        -- Path A:  Idle -> Monitor -> Candidate -> Verify -> Alert (conf)
        --                                         -> Monitor (reset)
        ----------------------------------------------------------------
        start <= '1'; tick; start <= '0'; tick;
        check_state(C_MONITOR, "Idle->Monitor");

        trig  <= '1'; tick(2);
        check_state(C_CANDIDATE, "Monitor->Candidate");

        tick(T_LIM + 2);
        check_state(C_VERIFY, "Candidate->Verify (T)");

        -- Single-sensor confirm: conf=1, ok=0
        conf <= '1'; ok <= '0'; tick(2);
        check_state(C_ALERT, "Verify->Alert (conf)");
        assert alert_active = '1' report "alert_active should be '1' in ALERT" severity failure;

        conf <= '0';
        reset_btn <= '1'; tick; reset_btn <= '0'; tick;
        check_state(C_MONITOR, "Alert->Monitor (reset)");

        ----------------------------------------------------------------
        -- Path B:  Monitor -> Candidate -> Verify -> Classify -> Alert (sev)
        ----------------------------------------------------------------
        trig <= '1'; tick(2);
        check_state(C_CANDIDATE, "Monitor->Candidate (B)");
        tick(T_LIM + 2);
        check_state(C_VERIFY, "Candidate->Verify (B)");

        ok <= '1'; tick(2);
        check_state(C_CLASSIFY, "Verify->Classify (ok)");
        ok <= '0';

        tick(T_LIM + 2);
        check_state(C_ALERT, "Classify->Alert (sev)");
        assert severity = "01"
            report "expected severity=01 after classify, got " & to_string(severity)
            severity failure;

        reset_btn <= '1'; tick; reset_btn <= '0'; tick;
        check_state(C_MONITOR, "Alert->Monitor (reset, B)");

        -- After Alert->Monitor reset, severity must be cleared so a stale
        -- value cannot leak into a future read.
        assert severity = "00"
            report "expected severity=00 after Alert->Monitor reset, got " &
                   to_string(severity)
            severity failure;

        ----------------------------------------------------------------
        -- Path C: Monitor self-loop on no-trig
        ----------------------------------------------------------------
        trig <= '0'; tick(20);
        check_state(C_MONITOR, "Monitor self-loop (no-trig)");

        ----------------------------------------------------------------
        -- Path D: Verify timeout fallback.  Brief trig glitch enters
        -- Candidate; by the time we reach Verify the sensors have
        -- returned to safe band (ok=conf=0).  The FSM must time out and
        -- return to Monitor instead of deadlocking in Verify.
        ----------------------------------------------------------------
        trig <= '1'; tick(2);
        check_state(C_CANDIDATE, "Monitor->Candidate (D)");

        -- Drop trig immediately; ok and conf stay '0'.
        trig <= '0'; ok <= '0'; conf <= '0';

        tick(T_LIM + 2);
        check_state(C_VERIFY, "Candidate->Verify (D)");

        -- Now wait for the Verify dwell to expire.  Without the timeout
        -- fix the FSM would sit here forever.
        tick(T_LIM + 2);
        check_state(C_MONITOR, "Verify->Monitor (timeout, D)");

        report "tb_threat_fsm PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
