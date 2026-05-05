-- ============================================================================
-- tb_synchronizer.vhd
--   Verifies the two-flop / three-flop synchronizer:
--     * RST_VAL forces the output during reset.
--     * STAGES=2 -> 2 cycles of latency from input change to output change.
--     * STAGES=3 -> 3 cycles of latency.
--     * Synchronous reset reloads RST_VAL.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity tb_synchronizer is
end entity;

architecture sim of tb_synchronizer is
    constant CLK_PERIOD : time := 10 ns;

    signal clk     : std_logic := '0';
    signal rst2    : std_logic := '1';
    signal d_in2   : std_logic := '0';
    signal d_out2  : std_logic;

    signal rst3    : std_logic := '1';
    signal d_in3   : std_logic := '1';   -- start asserted to test RST_VAL='1'
    signal d_out3  : std_logic;
begin
    clk <= not clk after CLK_PERIOD/2;

    -- 2-stage, RST_VAL='0'
    dut2 : entity work.synchronizer
        generic map ( STAGES => 2, RST_VAL => '0' )
        port map ( clk => clk, rst => rst2, d_in => d_in2, d_out => d_out2 );

    -- 3-stage, RST_VAL='1' (output should hold high during reset)
    dut3 : entity work.synchronizer
        generic map ( STAGES => 3, RST_VAL => '1' )
        port map ( clk => clk, rst => rst3, d_in => d_in3, d_out => d_out3 );

    main : process
        procedure tick(n : integer := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;
    begin
        -- Hold both DUTs in reset for a few cycles.
        tick(4);
        assert d_out2 = '0'
            report "synchronizer: RST_VAL='0' should drive d_out='0' during reset"
            severity failure;
        assert d_out3 = '1'
            report "synchronizer: RST_VAL='1' should drive d_out='1' during reset"
            severity failure;

        -- Release reset.
        rst2 <= '0';
        rst3 <= '0';
        tick(1);

        -- ----------------------------------------------------------------
        -- Test STAGES=2: drive d_in2 high, expect d_out2 to follow after
        -- exactly 2 rising edges.
        -- ----------------------------------------------------------------
        d_in2 <= '1';
        tick(1);
        assert d_out2 = '0'
            report "synchronizer (STAGES=2): output rose too early (after 1 cycle)"
            severity failure;
        tick(1);
        assert d_out2 = '1'
            report "synchronizer (STAGES=2): output did not propagate after 2 cycles"
            severity failure;

        -- Falling edge should also take 2 cycles to propagate.
        d_in2 <= '0';
        tick(1);
        assert d_out2 = '1'
            report "synchronizer (STAGES=2): output fell too early"
            severity failure;
        tick(1);
        assert d_out2 = '0'
            report "synchronizer (STAGES=2): output did not return to '0' after 2 cycles"
            severity failure;

        -- ----------------------------------------------------------------
        -- Test STAGES=3: d_in3 was already high at reset release, so it
        -- takes 3 cycles for the '1' that was already on the input to
        -- propagate to a '1' output via the 3-flop chain (it was already
        -- '1' due to RST_VAL, but now we force a '0' and verify the 3-cycle
        -- latency on the falling edge).
        -- ----------------------------------------------------------------
        d_in3 <= '0';
        tick(1);
        assert d_out3 = '1'
            report "synchronizer (STAGES=3): fell after 1 cycle (should take 3)"
            severity failure;
        tick(1);
        assert d_out3 = '1'
            report "synchronizer (STAGES=3): fell after 2 cycles (should take 3)"
            severity failure;
        tick(1);
        assert d_out3 = '0'
            report "synchronizer (STAGES=3): did not propagate '0' after 3 cycles"
            severity failure;

        -- Re-assert reset and verify both outputs jump back to RST_VAL.
        rst2 <= '1';
        rst3 <= '1';
        tick(1);
        assert d_out2 = '0'
            report "synchronizer: did not return to RST_VAL='0' on reset"
            severity failure;
        assert d_out3 = '1'
            report "synchronizer: did not return to RST_VAL='1' on reset"
            severity failure;

        report "tb_synchronizer PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
