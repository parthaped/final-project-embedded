-- ============================================================================
-- tb_debouncer.vhd
--   Verifies the debouncer with a small STABLE_CYCLES generic:
--     * Bouncing input (rapid 0/1 toggles) does not change btn_level.
--     * A stable '1' eventually drives btn_level high and emits a single-
--       cycle pulse on btn_pulse.
--     * A stable '0' returns btn_level low without emitting a pulse.
--     * Synchronous reset clears the level and pulse outputs.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_debouncer is
end entity;

architecture sim of tb_debouncer is
    constant CLK_PERIOD : time     := 10 ns;
    constant STABLE     : positive := 8;     -- short stability window for sim

    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal btn_in     : std_logic := '0';
    signal btn_level  : std_logic;
    signal btn_pulse  : std_logic;

    signal pulse_count : integer := 0;
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.debouncer
        generic map ( STABLE_CYCLES => STABLE )
        port map ( clk => clk, rst => rst,
                   btn_in => btn_in,
                   btn_level => btn_level,
                   btn_pulse => btn_pulse );

    counter : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pulse_count <= 0;
            elsif btn_pulse = '1' then
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
    begin
        tick(4);
        rst <= '0';
        tick(2);

        assert btn_level = '0' and btn_pulse = '0'
            report "debouncer: outputs not '0' after reset release"
            severity failure;

        -- ----------------------------------------------------------------
        -- 1) Bouncing input: alternate 1/0 every cycle for a window much
        --    shorter than STABLE. btn_level must stay '0' and no pulse
        --    must fire.
        -- ----------------------------------------------------------------
        for i in 1 to 6 loop
            btn_in <= '1'; tick(1);
            btn_in <= '0'; tick(1);
        end loop;
        btn_in <= '0';
        tick(STABLE + 4);
        assert btn_level = '0'
            report "debouncer: level rose under bouncing input"
            severity failure;
        assert pulse_count = 0
            report "debouncer: pulse fired under bouncing input"
            severity failure;

        -- ----------------------------------------------------------------
        -- 2) Stable press: hold btn_in high for plenty of cycles and
        --    expect btn_level=1 and exactly one btn_pulse.
        -- ----------------------------------------------------------------
        btn_in <= '1';
        -- 2 sync flops + STABLE counter + a handful of safety cycles.
        tick(STABLE + 8);
        assert btn_level = '1'
            report "debouncer: level did not rise on stable press"
            severity failure;
        assert pulse_count = 1
            report "debouncer: expected exactly 1 pulse on rising edge, got " &
                   integer'image(pulse_count)
            severity failure;

        -- Holding the button longer must not generate further pulses.
        tick(STABLE * 4);
        assert pulse_count = 1
            report "debouncer: extra pulses while holding press"
            severity failure;

        -- ----------------------------------------------------------------
        -- 3) Stable release: btn_in goes low, level should follow but no
        --    new pulse should fire (pulse is rising-edge only).
        -- ----------------------------------------------------------------
        btn_in <= '0';
        tick(STABLE + 8);
        assert btn_level = '0'
            report "debouncer: level did not return to '0' on release"
            severity failure;
        assert pulse_count = 1
            report "debouncer: pulse fired on release (should be rising-edge only)"
            severity failure;

        -- ----------------------------------------------------------------
        -- 4) Reset clears the outputs.
        -- ----------------------------------------------------------------
        btn_in <= '1';
        tick(STABLE + 4);
        assert btn_level = '1'
            report "debouncer: level didn't rise before final reset test"
            severity failure;

        rst <= '1';
        tick(3);
        assert btn_level = '0' and btn_pulse = '0'
            report "debouncer: outputs not cleared by reset"
            severity failure;

        report "tb_debouncer PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
