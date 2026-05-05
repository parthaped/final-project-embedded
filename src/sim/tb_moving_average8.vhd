-- ============================================================================
-- tb_moving_average8.vhd
--   Drives the 8-tap moving-average with known sequences and checks the
--   averaged output against a software model:
--     * Ramp-up from zero: after k valid samples of constant V, the
--       output equals (k*V)/8 (truncated).
--     * Steady-state: 8 consecutive samples of V give exactly V.
--     * Step response: a single new sample shifts the output by
--       (new - oldest)/8 each step.
--     * Reset clears the window and forces the output to 0.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_moving_average8 is
end entity;

architecture sim of tb_moving_average8 is
    constant CLK_PERIOD : time     := 10 ns;
    constant W          : positive := 16;

    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal valid_in  : std_logic := '0';
    signal data_in   : unsigned(W-1 downto 0) := (others => '0');
    signal valid_out : std_logic;
    signal data_out  : unsigned(W-1 downto 0);

    -- Software reference model: shadow window and running sum.
    type ref_window_t is array(0 to 7) of integer;
    signal ref_win : ref_window_t := (others => 0);
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.moving_average8
        generic map ( DATA_WIDTH => W )
        port map (
            clk       => clk,
            rst       => rst,
            valid_in  => valid_in,
            data_in   => data_in,
            valid_out => valid_out,
            data_out  => data_out );

    main : process
        variable saved : unsigned(W-1 downto 0);

        -- Push one sample on the next rising edge and update the reference
        -- window in lock-step. valid_out and data_out are registered on
        -- the same edge that consumes valid_in, so we check them
        -- immediately after that edge.
        procedure push(sample : integer) is
            variable s        : integer := 0;
            variable expected : integer;
        begin
            -- Expected post-shift average uses the *current* reference
            -- window (positions 0..6 will become positions 1..7) plus the
            -- new sample at position 0.
            s := sample;
            for i in 0 to 6 loop
                s := s + ref_win(i);
            end loop;
            expected := s / 8;

            -- Schedule the reference shift to happen at the next edge.
            for i in 7 downto 1 loop
                ref_win(i) <= ref_win(i-1);
            end loop;
            ref_win(0) <= sample;

            -- Drive the DUT.
            data_in  <= to_unsigned(sample, W);
            valid_in <= '1';
            wait until rising_edge(clk);
            valid_in <= '0';
            data_in  <= (others => '0');

            assert valid_out = '1'
                report "moving_average8: valid_out did not assert with valid_in"
                severity failure;
            assert to_integer(data_out) = expected
                report "moving_average8: average mismatch. got " &
                       integer'image(to_integer(data_out)) &
                       ", expected " & integer'image(expected)
                severity failure;
        end procedure;

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

        assert to_integer(data_out) = 0
            report "moving_average8: data_out not 0 after reset release"
            severity failure;

        -- ----------------------------------------------------------------
        -- 1) Ramp-up: feed eight samples of constant value 64. Average
        --    should rise from 64/8=8 up to 64.
        -- ----------------------------------------------------------------
        for i in 1 to 8 loop
            push(64);
            tick(2);    -- gap between pushes (valid_in stays low)
        end loop;
        assert to_integer(data_out) = 64
            report "moving_average8: steady-state of 64 not reached, got " &
                   integer'image(to_integer(data_out))
            severity failure;

        -- ----------------------------------------------------------------
        -- 2) Step response: replace the window contents with 0 and
        --    verify the average decays as the old 64s drop out.
        -- ----------------------------------------------------------------
        for i in 1 to 8 loop
            push(0);
            tick(2);
        end loop;
        assert to_integer(data_out) = 0
            report "moving_average8: did not return to 0 after 8 zero samples"
            severity failure;

        -- ----------------------------------------------------------------
        -- 3) Mixed sequence: software model handles the bookkeeping.
        --    Just push a non-trivial pattern and let push() assert.
        -- ----------------------------------------------------------------
        push(100); tick(1);
        push(200); tick(1);
        push(300); tick(1);
        push(400); tick(1);
        push( 50); tick(1);
        push(150); tick(1);
        push(250); tick(1);
        push(350); tick(1);
        push(  1); tick(1);
        push( 99); tick(1);

        -- ----------------------------------------------------------------
        -- 4) valid_in='0' must NOT change the output (no spurious updates).
        -- ----------------------------------------------------------------
        saved := data_out;
        valid_in <= '0';
        data_in  <= to_unsigned(65535, W);
        tick(20);
        assert data_out = saved
            report "moving_average8: output changed while valid_in='0'"
            severity failure;

        -- ----------------------------------------------------------------
        -- 5) Reset clears the window: after reset, output must be 0
        --    even if we previously had a non-zero average.
        -- ----------------------------------------------------------------
        rst <= '1';
        tick(3);
        rst <= '0';
        tick(2);
        assert to_integer(data_out) = 0
            report "moving_average8: window not cleared by reset"
            severity failure;

        report "tb_moving_average8 PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
