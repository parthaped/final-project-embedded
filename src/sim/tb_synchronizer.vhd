-- tb_synchronizer.vhd
--   Sanity-check the slim 2-FF synchronizer and the matching reset
--   synchronizer:
--     * data synchronizer powers up at '0', drives '0' during reset,
--       and forwards an async input with exactly 2 cycles of latency
--     * synchronizer_rst powers up at '1' (no reset port), and a low
--       on its d_in propagates after 2 cycles

library ieee;
use ieee.std_logic_1164.all;

entity tb_synchronizer is
end entity;

architecture sim of tb_synchronizer is
    constant CLK_PERIOD : time := 10 ns;

    signal clk     : std_logic := '0';

    signal rst_d   : std_logic := '1';
    signal d_in_d  : std_logic := '0';
    signal d_out_d : std_logic;

    signal d_in_r  : std_logic := '1';
    signal d_out_r : std_logic;
begin
    clk <= not clk after CLK_PERIOD/2;

    dut_data : entity work.synchronizer
        port map ( clk => clk, rst => rst_d,
                   d_in => d_in_d, d_out => d_out_d );

    dut_rst : entity work.synchronizer_rst
        port map ( clk => clk, d_in => d_in_r, d_out => d_out_r );

    main : process
        procedure tick(n : integer := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;
    begin
        tick(4);

        assert d_out_d = '0'
            report "synchronizer: should drive d_out='0' during reset"
            severity failure;

        assert d_out_r = '1'
            report "synchronizer_rst: should power up at '1'"
            severity failure;

        rst_d <= '0';
        tick(1);

        d_in_d <= '1';
        tick(1);
        assert d_out_d = '0'
            report "synchronizer: output rose too early (after 1 cycle)"
            severity failure;
        tick(1);
        assert d_out_d = '1'
            report "synchronizer: output did not propagate after 2 cycles"
            severity failure;

        d_in_d <= '0';
        tick(1);
        assert d_out_d = '1'
            report "synchronizer: output fell too early"
            severity failure;
        tick(1);
        assert d_out_d = '0'
            report "synchronizer: did not return to '0' after 2 cycles"
            severity failure;

        d_in_r <= '0';
        tick(1);
        assert d_out_r = '1'
            report "synchronizer_rst: fell after 1 cycle (should take 2)"
            severity failure;
        tick(1);
        assert d_out_r = '0'
            report "synchronizer_rst: did not propagate '0' after 2 cycles"
            severity failure;

        rst_d <= '1';
        tick(1);
        assert d_out_d = '0'
            report "synchronizer: did not return to '0' on reset"
            severity failure;

        report "tb_synchronizer PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
