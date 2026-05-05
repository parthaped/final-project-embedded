-- ============================================================================
-- tb_pulse_gen.vhd
--   Verifies pulse_gen with a small PERIOD_CYCLES:
--     * Emits exactly one pulse every PERIOD_CYCLES clocks.
--     * Pulse width is exactly one cycle.
--     * en='0' suppresses pulses and resets the internal counter.
--     * Synchronous reset clears the counter and pulse output.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pulse_gen is
end entity;

architecture sim of tb_pulse_gen is
    constant CLK_PERIOD : time     := 10 ns;
    constant PERIOD     : positive := 4;     -- pulse every 4 clocks

    signal clk    : std_logic := '0';
    signal rst    : std_logic := '1';
    signal en     : std_logic := '1';
    signal pulse  : std_logic;

    signal pulse_count : integer := 0;
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.pulse_gen
        generic map ( PERIOD_CYCLES => PERIOD )
        port map ( clk => clk, rst => rst, en => en, pulse => pulse );

    -- Free-running pulse counter for sanity checks.
    counter : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pulse_count <= 0;
            elsif pulse = '1' then
                pulse_count <= pulse_count + 1;
            end if;
        end if;
    end process;

    main : process
        procedure tick(n : integer := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- Wait for the next rising edge of pulse, with a timeout in cycles.
        procedure wait_pulse(timeout_cycles : integer) is
            variable elapsed : integer := 0;
        begin
            while pulse /= '1' and elapsed < timeout_cycles loop
                wait until rising_edge(clk);
                elapsed := elapsed + 1;
            end loop;
            assert pulse = '1'
                report "pulse_gen: timed out waiting for pulse"
                severity failure;
        end procedure;
    begin
        tick(3);
        rst <= '0';

        -- ----------------------------------------------------------------
        -- 1) Verify the very first pulse arrives at the expected time.
        --    With PERIOD=4 and reset released, the counter goes 0..3 and
        --    pulse asserts on the cycle after cnt reaches PERIOD-1.
        -- ----------------------------------------------------------------
        wait_pulse(PERIOD + 2);
        assert pulse_count = 1
            report "pulse_gen: expected exactly 1 pulse, got " &
                   integer'image(pulse_count)
            severity failure;

        -- Pulse must be only one cycle wide.
        tick(1);
        assert pulse = '0'
            report "pulse_gen: pulse was wider than 1 cycle"
            severity failure;

        -- ----------------------------------------------------------------
        -- 2) Run for many periods and verify the pulse rate.
        -- ----------------------------------------------------------------
        for i in 1 to 5 loop
            wait_pulse(PERIOD + 2);
            tick(1);
        end loop;
        assert pulse_count = 6
            report "pulse_gen: expected 6 pulses, got " &
                   integer'image(pulse_count)
            severity failure;

        -- ----------------------------------------------------------------
        -- 3) Disable: en='0' must suppress all pulses, even after PERIOD
        --    cycles, and reset the internal counter.
        -- ----------------------------------------------------------------
        en <= '0';
        tick(PERIOD * 4);
        assert pulse_count = 6
            report "pulse_gen: pulses fired while en='0'"
            severity failure;
        assert pulse = '0'
            report "pulse_gen: pulse high while en='0'"
            severity failure;

        -- Re-enable: counter should restart from zero, so the next pulse
        -- arrives PERIOD cycles later.
        en <= '1';
        wait_pulse(PERIOD + 2);
        assert pulse_count = 7
            report "pulse_gen: expected 7 pulses after re-enable, got " &
                   integer'image(pulse_count)
            severity failure;

        -- ----------------------------------------------------------------
        -- 4) Synchronous reset clears the counter and the pulse output.
        -- ----------------------------------------------------------------
        rst <= '1';
        tick(2);
        assert pulse = '0'
            report "pulse_gen: pulse stayed high through reset"
            severity failure;
        assert pulse_count = 0
            report "pulse_gen: counter not cleared by reset"
            severity failure;

        report "tb_pulse_gen PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
