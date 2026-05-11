-- synchronizer_rst.vhd
--   Two-flop synchronizer that powers up as '1'. Same shape as the
--   regular synchronizer but used for active-high reset distribution
--   into a clock domain: we want every flop to come out of configuration
--   already holding "in reset", and only relax once the upstream signal
--   has been low for two clocks of this domain.

library ieee;
use ieee.std_logic_1164.all;

entity synchronizer_rst is
    port (
        clk   : in  std_logic;
        d_in  : in  std_logic;
        d_out : out std_logic
    );
end entity;

architecture rtl of synchronizer_rst is
    signal sync_reg : std_logic_vector(1 downto 0) := (others => '1');
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sync_reg : signal is "TRUE";
begin
    process(clk)
    begin
        if rising_edge(clk) then
            sync_reg <= sync_reg(0) & d_in;
        end if;
    end process;

    d_out <= sync_reg(1);
end architecture;
