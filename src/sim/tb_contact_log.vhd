-- ============================================================================
-- tb_contact_log.vhd
--   Drives the contact_log through:
--     1. Single write -> slot 0 captures inputs, others stay invalid.
--     2. Eight writes -> all slots full, newest at index 0.
--     3. Ninth write  -> oldest evicted (slot 7 of the previous state).
--     4. clear_all    -> all valid bits drop to 0.
--     5. Aging        -> with MAX_AGE_SECONDS small, tick_60hz expires slots.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.contact_pkg.all;

entity tb_contact_log is
end entity;

architecture sim of tb_contact_log is
    constant CLK_PERIOD : time := 10 ns;
    constant MAX_AGE    : positive := 5;     -- short for sim

    signal clk           : std_logic := '0';
    signal rst           : std_logic := '1';
    signal write_pulse   : std_logic := '0';
    signal clear_all     : std_logic := '0';
    signal tick_60hz     : std_logic := '0';

    signal in_range_in   : unsigned(7 downto 0) := (others => '0');
    signal in_severity   : unsigned(1 downto 0) := (others => '0');
    signal in_ambient    : unsigned(1 downto 0) := (others => '0');
    signal t_seconds     : unsigned(15 downto 0) := (others => '0');

    signal contacts      : contact_array_t;
    signal count         : unsigned(3 downto 0);

    signal last_valid    : std_logic;
    signal last_range_in : unsigned(7 downto 0);
    signal last_severity : unsigned(1 downto 0);
    signal last_ambient  : unsigned(1 downto 0);
    signal last_t_log    : unsigned(15 downto 0);
begin
    clk <= not clk after CLK_PERIOD/2;

    dut : entity work.contact_log
        generic map ( MAX_AGE_SECONDS => MAX_AGE )
        port map (
            clk           => clk,
            rst           => rst,
            write_pulse   => write_pulse,
            clear_all     => clear_all,
            tick_60hz     => tick_60hz,
            in_range_in   => in_range_in,
            in_severity   => in_severity,
            in_ambient    => in_ambient,
            t_seconds     => t_seconds,
            contacts      => contacts,
            count         => count,
            last_valid    => last_valid,
            last_range_in => last_range_in,
            last_severity => last_severity,
            last_ambient  => last_ambient,
            last_t_log    => last_t_log );

    main : process
        procedure tick(n : integer := 1) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure do_write (
            r : integer; sev : integer; amb : integer; t : integer
        ) is
        begin
            in_range_in <= to_unsigned(r,   8);
            in_severity <= to_unsigned(sev, 2);
            in_ambient  <= to_unsigned(amb, 2);
            t_seconds   <= to_unsigned(t,  16);
            write_pulse <= '1';
            tick;
            write_pulse <= '0';
            tick;
        end procedure;
    begin
        rst <= '1'; tick(3);
        rst <= '0'; tick(2);

        ------------------------------------------------------------------
        -- 1. Empty after reset.
        ------------------------------------------------------------------
        assert count = to_unsigned(0, 4)
            report "after reset count expected 0 got " & to_string(count)
            severity failure;
        assert last_valid = '0'
            report "after reset last_valid should be 0" severity failure;

        ------------------------------------------------------------------
        -- 2. Single write lands in slot 0; nothing else valid.
        ------------------------------------------------------------------
        do_write(r => 18, sev => 2, amb => 0, t => 100);
        assert count = to_unsigned(1, 4)
            report "after 1 write count expected 1" severity failure;
        assert last_valid = '1' and last_range_in = to_unsigned(18, 8)
            report "slot0 not populated correctly" severity failure;
        assert contacts(0).severity_score = "10" and contacts(0).ambient = "00"
            report "slot0 sev/ambient mismatch" severity failure;
        assert contacts(0).t_log = to_unsigned(100, 16)
            report "slot0 t_log mismatch" severity failure;
        for i in 1 to 7 loop
            assert contacts(i).valid = '0'
                report "slot " & integer'image(i) & " should be invalid"
                severity failure;
        end loop;

        ------------------------------------------------------------------
        -- 3. Eight writes -> all slots valid; newest=18 in slot 0,
        --    oldest first-write at slot 7.
        ------------------------------------------------------------------
        do_write(r => 20, sev => 1, amb => 1, t => 110);
        do_write(r => 22, sev => 0, amb => 2, t => 120);
        do_write(r => 24, sev => 3, amb => 3, t => 130);
        do_write(r => 26, sev => 2, amb => 0, t => 140);
        do_write(r => 28, sev => 1, amb => 1, t => 150);
        do_write(r => 30, sev => 0, amb => 2, t => 160);
        do_write(r => 32, sev => 3, amb => 3, t => 170);
        assert count = to_unsigned(8, 4)
            report "after 8 writes count expected 8 got " & to_string(count)
            severity failure;
        assert contacts(0).range_in = to_unsigned(32, 8)
            report "slot0 should be newest (32)" severity failure;
        assert contacts(7).range_in = to_unsigned(18, 8)
            report "slot7 should be oldest (18) got " &
                   to_string(contacts(7).range_in)
            severity failure;

        ------------------------------------------------------------------
        -- 4. Ninth write -> oldest (range=18) evicted; range=32 moves
        --    to slot 1; new write at slot 0.
        ------------------------------------------------------------------
        do_write(r => 34, sev => 0, amb => 0, t => 180);
        assert contacts(0).range_in = to_unsigned(34, 8)
            report "after 9th write slot0 should be 34" severity failure;
        assert contacts(1).range_in = to_unsigned(32, 8)
            report "after 9th write slot1 should be 32" severity failure;
        assert contacts(7).range_in = to_unsigned(20, 8)
            report "after 9th write slot7 should be 20 (oldest 18 evicted)"
            severity failure;

        ------------------------------------------------------------------
        -- 5. clear_all wipes every valid bit.
        ------------------------------------------------------------------
        clear_all <= '1'; tick(2); clear_all <= '0'; tick;
        assert count = to_unsigned(0, 4)
            report "clear_all should drop count to 0" severity failure;
        for i in 0 to 7 loop
            assert contacts(i).valid = '0'
                report "clear_all slot " & integer'image(i) & " still valid"
                severity failure;
        end loop;

        ------------------------------------------------------------------
        -- 6. Aging.  Write at t=200, advance t_seconds beyond
        --    t_log + MAX_AGE, pulse tick_60hz, slot must invalidate.
        ------------------------------------------------------------------
        do_write(r => 40, sev => 2, amb => 0, t => 200);
        assert count = 1 report "post-clear write should give count=1" severity failure;

        -- Inside the age window: tick should NOT invalidate.
        t_seconds <= to_unsigned(202, 16);
        tick;
        tick_60hz <= '1'; tick; tick_60hz <= '0'; tick;
        assert count = 1 report "still inside age window, count should be 1" severity failure;

        -- Past the age window: tick should invalidate.
        t_seconds <= to_unsigned(206, 16);
        tick;
        tick_60hz <= '1'; tick; tick_60hz <= '0'; tick;
        assert count = 0
            report "past age window, count should drop to 0 (got " &
                   to_string(count) & ")"
            severity failure;

        report "tb_contact_log PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
