-- ============================================================================
-- tb_pmod_maxsonar_pw.vhd
--   Drives the PW input with pulses of known width and verifies the
--   decoded distance (in inches).
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmod_maxsonar_pw is
end entity;

architecture sim of tb_pmod_maxsonar_pw is
    constant CLK_PERIOD : time := 10 ns;          -- 100 MHz
    constant CYC_PER_IN : integer := 14_700;      -- 147 us at 100 MHz

    signal clk         : std_logic := '0';
    signal rst         : std_logic := '1';
    signal pw_in       : std_logic := '0';
    signal distance_in : unsigned(15 downto 0);
    signal data_valid  : std_logic;
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.pmod_maxsonar_pw
        generic map (
            RECIP_MUL       => 1141,
            RECIP_SHIFT     => 24,
            WATCHDOG_CYCLES => 1_000_000_000     -- effectively disabled in this TB
        )
        port map (
            clk         => clk,
            rst         => rst,
            pw_in       => pw_in,
            distance_in => distance_in,
            data_valid  => data_valid
        );

    main : process
        procedure run_pulse(inches : integer; tol : integer := 1) is
            variable hold : time := CLK_PERIOD * CYC_PER_IN * inches;
        begin
            wait for CLK_PERIOD * 100;
            pw_in <= '1';
            wait for hold;
            pw_in <= '0';
            wait until data_valid = '1' for 50 ms;
            assert data_valid = '1'
                report "no data_valid for inches=" & integer'image(inches)
                severity failure;
            assert (to_integer(distance_in) >= inches - tol)
               and (to_integer(distance_in) <= inches + tol)
                report "decoded " & integer'image(to_integer(distance_in)) &
                       " inches, expected " & integer'image(inches)
                severity failure;
            wait for CLK_PERIOD * 50;
        end procedure;
    begin
        wait for CLK_PERIOD * 5;
        rst <= '0';
        wait for CLK_PERIOD * 10;

        run_pulse(6);
        run_pulse(12);
        run_pulse(36);
        run_pulse(120);
        run_pulse(254);

        report "tb_pmod_maxsonar_pw PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
