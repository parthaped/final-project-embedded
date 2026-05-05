-- ============================================================================
-- tb_pmod_als_spi.vhd
--   Testbench for pmod_als_spi.  Models a tiny ADC081S021-like slave that
--   drives MISO with a programmable 8-bit value while CS is low, and checks
--   that the captured byte matches.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmod_als_spi is
end entity;

architecture sim of tb_pmod_als_spi is
    constant CLK_PERIOD : time := 10 ns;          -- 100 MHz
    constant SCLK_HALF  : positive := 4;          -- speed sim up: SCLK = 12.5 MHz

    signal clk         : std_logic := '0';
    signal rst         : std_logic := '1';
    signal sample_tick : std_logic := '0';
    signal busy        : std_logic;
    signal data_out    : std_logic_vector(7 downto 0);
    signal data_valid  : std_logic;

    signal cs_n  : std_logic;
    signal sclk  : std_logic;
    signal miso  : std_logic := '0';

    -- Slave-side scoreboard: pattern shifted out MSB-first over 16 SCLK
    -- cycles.  Bits 13..6 of the 16-bit pattern are the 8-bit data
    -- (mirroring the ADC081S021 leading-3-zeros convention; with the
    -- master grabbing bits 11..4 we end up reading shifted_pattern>>2).
    signal slave_pattern : std_logic_vector(15 downto 0) := (others => '0');
    signal expected_byte : std_logic_vector(7 downto 0)  := (others => '0');

begin
    -- Clock
    clk <= not clk after CLK_PERIOD/2;

    -- DUT
    dut : entity work.pmod_als_spi
        generic map ( SCLK_HALF_CYCLES => SCLK_HALF )
        port map (
            clk         => clk,
            rst         => rst,
            sample_tick => sample_tick,
            busy        => busy,
            data_out    => data_out,
            data_valid  => data_valid,
            spi_cs_n    => cs_n,
            spi_sclk    => sclk,
            spi_miso    => miso
        );

    -- Tiny slave: when CS is low, drive MISO from slave_pattern MSB-first,
    -- shifting on every SCLK falling edge (so the master's rising-edge
    -- sample picks up the bit that has just settled).
    slave_proc : process
        variable bit_idx : integer;
    begin
        miso <= '0';
        wait until rst = '0';
        loop
            wait until falling_edge(cs_n);
            for i in 15 downto 0 loop
                miso <= slave_pattern(i);
                wait until falling_edge(sclk) for 100 us;
            end loop;
            wait until rising_edge(cs_n);
        end loop;
    end process;

    -- Stimulus
    main : process
        procedure run_xfer (data : std_logic_vector(7 downto 0)) is
        begin
            -- Position `data` in bits 11..4 of the slave's 16-bit pattern,
            -- matching the ADC081S021 frame format the master decodes.
            slave_pattern <= "0000" & data & "0000";
            expected_byte <= data;
            wait for CLK_PERIOD * 4;
            sample_tick <= '1';
            wait for CLK_PERIOD;
            sample_tick <= '0';
            wait until data_valid = '1';
            assert data_out = data
                report "ALS SPI mismatch: expected 0x" &
                       to_hstring(unsigned(data)) &
                       " got 0x" & to_hstring(unsigned(data_out))
                severity failure;
            wait for CLK_PERIOD * 50;
        end procedure;
    begin
        wait for CLK_PERIOD * 5;
        rst <= '0';
        wait for CLK_PERIOD * 5;

        run_xfer(x"55");
        run_xfer(x"AA");
        run_xfer(x"00");
        run_xfer(x"FF");
        run_xfer(x"81");

        report "tb_pmod_als_spi PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
