-- moving_average8.vhd
--   8-tap sliding average for an unsigned bus. On each valid_in we
--   shift the new sample into a small array, update a running sum
--   (subtract the oldest, add the new), and drive data_out = sum/8.
--   Doing the sum incrementally means we never need a multiplier and
--   the divide-by-8 is just a right shift. valid_out pulses one cycle
--   after the new sample is seen.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity moving_average8 is
    generic (
        DATA_WIDTH : positive := 16
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        valid_in   : in  std_logic;
        data_in    : in  unsigned(DATA_WIDTH-1 downto 0);
        valid_out  : out std_logic;
        data_out   : out unsigned(DATA_WIDTH-1 downto 0)
    );
end entity;

architecture rtl of moving_average8 is
    type sample_array_t is array (0 to 7) of unsigned(DATA_WIDTH-1 downto 0);
    signal samples : sample_array_t := (others => (others => '0'));
    signal sum     : unsigned(DATA_WIDTH+2 downto 0) := (others => '0');
begin
    process(clk)
        variable next_sum : unsigned(sum'range);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                samples   <= (others => (others => '0'));
                sum       <= (others => '0');
                valid_out <= '0';
                data_out  <= (others => '0');
            else
                valid_out <= '0';
                if valid_in = '1' then
                    next_sum := sum
                              - resize(samples(7), sum'length)
                              + resize(data_in,    sum'length);
                    sum <= next_sum;

                    for i in 7 downto 1 loop
                        samples(i) <= samples(i-1);
                    end loop;
                    samples(0) <= data_in;

                    data_out  <= resize(shift_right(next_sum, 3), DATA_WIDTH);
                    valid_out <= '1';
                end if;
            end if;
        end if;
    end process;
end architecture;
