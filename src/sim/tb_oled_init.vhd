-- ============================================================================
-- tb_oled_init.vhd
--   Brings the pmod_oled_top out of reset, watches the SPI lines, and
--   verifies that the first 26 bytes the master sends (after the power
--   sequence completes) match the SSD1306 init sequence stored in
--   oled_init_pkg.OLED_ROM.
--
--   To keep the simulation short, the testbench reduces SYS_HZ via a
--   smaller refresh divider, but the *power-up* timers in pmod_oled_top
--   are scaled with SYS_HZ so we set SYS_HZ very low here so the 1 ms /
--   100 ms waits become a handful of cycles.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.oled_init_pkg.all;

entity tb_oled_init is
end entity;

architecture sim of tb_oled_init is
    constant CLK_PERIOD : time := 10 ns;

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';

    signal state_code   : std_logic_vector(2 downto 0) := "000";
    signal distance_in  : unsigned(15 downto 0) := to_unsigned(42, 16);
    signal als_value    : unsigned(15 downto 0) := to_unsigned(123, 16);
    signal severity     : std_logic_vector(1 downto 0) := "00";

    signal cs_n   : std_logic;
    signal mosi   : std_logic;
    signal sclk   : std_logic;
    signal dc     : std_logic;
    signal res_n  : std_logic;
    signal vbat_n : std_logic;
    signal vdd_n  : std_logic;

    -- Sample MOSI on rising edge of SCLK and pack 8 bits into a byte.
    signal capt_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal bit_idx   : integer := 0;
    signal byte_done : std_logic := '0';
    signal cap_dc    : std_logic := '0';

    type byte_log_t is array (0 to ROM_LEN-1) of std_logic_vector(8 downto 0);
    signal byte_log : byte_log_t := (others => (others => '0'));
    signal log_idx  : integer := 0;
begin
    clk <= not clk after CLK_PERIOD/2;

    -- DUT: shrink SYS_HZ so the 1 ms / 100 ms waits collapse to a few
    -- microseconds.  The init logic is independent of SYS_HZ except for
    -- those wait counters.
    dut : entity work.pmod_oled_top
        generic map (
            SYS_HZ     => 100_000,
            REFRESH_HZ => 30 )
        port map (
            clk          => clk,
            rst          => rst,
            state_code   => state_code,
            distance_in  => distance_in,
            als_value    => als_value,
            severity     => severity,
            oled_cs_n    => cs_n,
            oled_mosi    => mosi,
            oled_sclk    => sclk,
            oled_dc      => dc,
            oled_res_n   => res_n,
            oled_vbat_n  => vbat_n,
            oled_vdd_n   => vdd_n );

    -- Bit / byte capture
    capture : process(clk)
        variable last_sclk : std_logic := '0';
    begin
        if rising_edge(clk) then
            byte_done <= '0';
            if cs_n = '1' then
                bit_idx   <= 0;
                capt_byte <= (others => '0');
            elsif last_sclk = '0' and sclk = '1' then
                capt_byte(7 - bit_idx) <= mosi;
                if bit_idx = 7 then
                    cap_dc    <= dc;
                    byte_done <= '1';
                    bit_idx   <= 0;
                else
                    bit_idx <= bit_idx + 1;
                end if;
            end if;
            last_sclk := sclk;
        end if;
    end process;

    logger : process(clk)
    begin
        if rising_edge(clk) then
            if byte_done = '1' and log_idx < ROM_LEN then
                byte_log(log_idx) <= cap_dc & capt_byte;
                log_idx           <= log_idx + 1;
            end if;
        end if;
    end process;

    main : process
    begin
        rst <= '1';
        wait for CLK_PERIOD * 10;
        rst <= '0';

        -- Wait long enough for power-up + 26 init bytes to flush.  At
        -- SYS_HZ=100k the 1 ms timer is 100 cycles; the 100 ms VBAT timer
        -- is 10000 cycles; plus 26 SPI bytes at ~200 cycles each.
        wait for 1 ms;

        -- Validate the 26 init bytes (entries 0..INIT_LEN-1 in OLED_ROM).
        for i in 0 to INIT_LEN-1 loop
            assert byte_log(i) = OLED_ROM(i)
                report "OLED init byte " & integer'image(i) &
                       " mismatch: expected " & to_string(OLED_ROM(i)) &
                       " got " & to_string(byte_log(i))
                severity failure;
        end loop;

        report "tb_oled_init PASSED" severity note;
        std.env.finish;
    end process;
end architecture;
