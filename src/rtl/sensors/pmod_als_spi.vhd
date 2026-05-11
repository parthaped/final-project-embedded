-- pmod_als_spi.vhd
--   SPI master for the Digilent Pmod ALS (ADC081S021).
--   ref: ADC081S021 datasheet; Digilent Pmod ALS reference manual.
--
--   The ADC needs 16 SCLK cycles per conversion in mode 0 (CPOL=0,
--   CPHA=0). The 8 data bits show up MSB-first on MISO during cycles
--   4..11, so we shift everything into a 16-bit register and pull out
--   bits 11..4 at the end. SCLK is built from the system clock by
--   counting half-periods, the same divider trick as Lab 1's clock_div.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pmod_als_spi is
    generic (
        SCLK_HALF_CYCLES : positive := 50
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        sample_tick  : in  std_logic;
        busy         : out std_logic;
        data_out     : out std_logic_vector(7 downto 0);
        data_valid   : out std_logic;

        spi_cs_n     : out std_logic;
        spi_sclk     : out std_logic;
        spi_miso     : in  std_logic
    );
end entity;

architecture rtl of pmod_als_spi is
    type state_t is (S_IDLE, S_LEAD_IN, S_BIT_LOW, S_BIT_HIGH, S_TAIL, S_DONE);
    signal state : state_t := S_IDLE;

    constant N_BITS : positive := 16;

    signal half_cnt : unsigned(15 downto 0) := (others => '0');
    signal bit_cnt  : unsigned(4 downto 0)  := (others => '0');
    signal sr       : std_logic_vector(15 downto 0) := (others => '0');

    signal miso_sync : std_logic;

    signal sclk_r : std_logic := '0';
    signal csn_r  : std_logic := '1';
begin
    miso_sync_i : entity work.synchronizer
        port map ( clk => clk, rst => rst, d_in => spi_miso, d_out => miso_sync );

    spi_cs_n <= csn_r;
    spi_sclk <= sclk_r;
    busy     <= '0' when state = S_IDLE else '1';

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state      <= S_IDLE;
                half_cnt   <= (others => '0');
                bit_cnt    <= (others => '0');
                sr         <= (others => '0');
                sclk_r     <= '0';
                csn_r      <= '1';
                data_out   <= (others => '0');
                data_valid <= '0';
            else
                data_valid <= '0';

                case state is

                    when S_IDLE =>
                        sclk_r <= '0';
                        csn_r  <= '1';
                        if sample_tick = '1' then
                            csn_r    <= '0';
                            bit_cnt  <= (others => '0');
                            half_cnt <= (others => '0');
                            sr       <= (others => '0');
                            state    <= S_LEAD_IN;
                        end if;

                    when S_LEAD_IN =>
                        if half_cnt = to_unsigned(SCLK_HALF_CYCLES-1, half_cnt'length) then
                            half_cnt <= (others => '0');
                            sclk_r   <= '1';
                            sr       <= sr(14 downto 0) & miso_sync;
                            state    <= S_BIT_HIGH;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;

                    when S_BIT_HIGH =>
                        if half_cnt = to_unsigned(SCLK_HALF_CYCLES-1, half_cnt'length) then
                            half_cnt <= (others => '0');
                            sclk_r   <= '0';
                            bit_cnt  <= bit_cnt + 1;
                            if bit_cnt = to_unsigned(N_BITS-1, bit_cnt'length) then
                                state <= S_TAIL;
                            else
                                state <= S_BIT_LOW;
                            end if;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;

                    when S_BIT_LOW =>
                        if half_cnt = to_unsigned(SCLK_HALF_CYCLES-1, half_cnt'length) then
                            half_cnt <= (others => '0');
                            sclk_r   <= '1';
                            sr       <= sr(14 downto 0) & miso_sync;
                            state    <= S_BIT_HIGH;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;

                    when S_TAIL =>
                        if half_cnt = to_unsigned(SCLK_HALF_CYCLES-1, half_cnt'length) then
                            half_cnt <= (others => '0');
                            csn_r    <= '1';
                            state    <= S_DONE;
                        else
                            half_cnt <= half_cnt + 1;
                        end if;

                    when S_DONE =>
                        -- Datasheet says the 8 result bits land in sr(11..4)
                        -- (3 leading zeros, then DB7..DB0, then trailing
                        -- zeros) once we sample MSB-first on the rising
                        -- SCLK edges, so this is just a slice.
                        data_out   <= sr(11 downto 4);
                        data_valid <= '1';
                        state      <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture;
