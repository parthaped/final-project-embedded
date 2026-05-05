-- ============================================================================
-- oled_spi_master.vhd
--   Minimal write-only 8-bit SPI master for the SSD1306 on the Pmod OLED.
--   Mode 0 (CPOL=0, CPHA=0), MSB first.  DC is just a level signal that
--   accompanies the byte (data vs command).
--
--   start                 1-cycle pulse latches `dc_in` + `byte_in` and
--                         begins a transfer.
--   busy                  high while the transfer is in progress.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity oled_spi_master is
    generic (
        -- 12 cycles at 125 MHz -> ~5.2 MHz SCLK (well under SSD1306 max).
        SCLK_HALF_CYCLES : positive := 12
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;

        start      : in  std_logic;
        dc_in      : in  std_logic;
        byte_in    : in  std_logic_vector(7 downto 0);
        busy       : out std_logic;

        spi_cs_n   : out std_logic;
        spi_sclk   : out std_logic;
        spi_mosi   : out std_logic;
        spi_dc     : out std_logic
    );
end entity;

architecture rtl of oled_spi_master is
    type state_t is (S_IDLE, S_BIT_SETUP, S_BIT_HIGH, S_TAIL);
    signal state : state_t := S_IDLE;

    signal half_cnt : unsigned(15 downto 0) := (others => '0');
    signal bit_cnt  : unsigned(3 downto 0)  := (others => '0');
    signal sr       : std_logic_vector(7 downto 0) := (others => '0');
    signal dc_r     : std_logic := '0';
    signal sclk_r   : std_logic := '0';
    signal csn_r    : std_logic := '1';
begin
    spi_cs_n <= csn_r;
    spi_sclk <= sclk_r;
    spi_mosi <= sr(7);
    spi_dc   <= dc_r;
    busy     <= '0' when state = S_IDLE else '1';

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state    <= S_IDLE;
                half_cnt <= (others => '0');
                bit_cnt  <= (others => '0');
                sr       <= (others => '0');
                dc_r     <= '0';
                sclk_r   <= '0';
                csn_r    <= '1';
            else
                case state is
                    when S_IDLE =>
                        sclk_r <= '0';
                        csn_r  <= '1';
                        if start = '1' then
                            sr       <= byte_in;
                            dc_r     <= dc_in;
                            csn_r    <= '0';
                            bit_cnt  <= (others => '0');
                            half_cnt <= (others => '0');
                            state    <= S_BIT_SETUP;
                        end if;

                    when S_BIT_SETUP =>
                        -- SCLK=0, MOSI = sr(7); wait one half period for setup.
                        if half_cnt = to_unsigned(SCLK_HALF_CYCLES-1, half_cnt'length) then
                            half_cnt <= (others => '0');
                            sclk_r   <= '1';
                            state    <= S_BIT_HIGH;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;

                    when S_BIT_HIGH =>
                        if half_cnt = to_unsigned(SCLK_HALF_CYCLES-1, half_cnt'length) then
                            half_cnt <= (others => '0');
                            sclk_r   <= '0';
                            sr       <= sr(6 downto 0) & '0';
                            bit_cnt  <= bit_cnt + 1;
                            if bit_cnt = to_unsigned(7, bit_cnt'length) then
                                state <= S_TAIL;
                            else
                                state <= S_BIT_SETUP;
                            end if;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;

                    when S_TAIL =>
                        if half_cnt = to_unsigned(SCLK_HALF_CYCLES-1, half_cnt'length) then
                            half_cnt <= (others => '0');
                            csn_r    <= '1';
                            state    <= S_IDLE;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture;
