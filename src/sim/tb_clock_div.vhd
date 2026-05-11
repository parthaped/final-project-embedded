-- tb_clock_div.vhd
--   Quick check that clock_div is a real divide-by-DIV counter:
--     * clk_en goes high one cycle every DIV ticks
--     * the high pulse is exactly one cycle wide
--     * en='0' suppresses pulses and resets the counter
--     * synchronous rst clears the counter and clk_en

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_clock_div is
end entity;

architecture sim of tb_clock_div is
    constant CLK_PERIOD : time     := 10 ns;
    constant DIV_VAL    : positive := 4;

    signal clk    : std_logic := '0';
    signal rst    : std_logic := '1';
    signal en     : std_logic := '1';
    signal clk_en : std_logic;

    signal pulse_count : integer := 0;
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.clock_div
        generic map ( DIV => DIV_VAL )
        port map ( clk => clk, rst => rst, en => en, clk_en => clk_en );

    counter : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pulse_count <= 0;
            elsif clk_en = '1' then
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

        procedure wait_pulse(timeout_cycles : integer) is
            variable elapsed : integer := 0;
        begin
            while clk_en /= '1' and elapsed < timeout_cycles loop
                wait until rising_edge(clk);
                elapsed := elapsed + 1;
            end loop;
            assert clk_en = '1'
                report "clock_div: timed out waiting for clk_en"
                severity failure;
        end procedure;
    begin
        tick(3);
        rst <= '0';

        wait_pulse(DIV_VAL + 2);
        assert pulse_count = 1
            report "clock_div: expected 1 pulse, got " &
                   integer'image(pulse_count)
            severity failure;

        tick(1);
        assert clk_en = '0'
            report "clock_div: clk_en wider than 1 cycle"
            severity failure;

        for i in 1 to 5 loop
            wait_pulse(DIV_VAL + 2);
            tick(1);
        end loop;
        assert pulse_count = 6
            report "clock_div: expected 6 pulses, got " &
                   integer'image(pulse_count)
            severity failure;

        en <= '0';
        tick(DIV_VAL * 4);
        assert pulse_count = 6
            report "clock_div: pulses fired while en='0'"
            severity failure;
        assert clk_en = '0'
            report "clock_div: clk_en stayed high while en='0'"
            severity failure;

        en <= '1';
        wait_pulse(DIV_VAL + 2);
        assert pulse_count = 7
            report "clock_div: expected 7 pulses after re-enable, got " &
                   integer'image(pulse_count)
            severity failure;

        rst <= '1';
        tick(2);
        assert clk_en = '0'
            report "clock_div: clk_en stayed high through reset"
            severity failure;
        assert pulse_count = 0
            report "clock_div: counter not cleared by reset"
            severity failure;

        report "tb_clock_div PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
