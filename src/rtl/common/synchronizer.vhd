-- synchronizer.vhd
--   Two-flop synchronizer for an async 1-bit input. Same idea as the
--   shift register from Lab 1 part 2: line up an outside signal with our
--   clock by sending it through two registers in a row before any logic
--   reads it. Init value is '0' which is the right pick for "data" type
--   inputs (button raw level, MISO, sonar PW). For an active-high reset
--   signal that needs to come up as '1' on power-up, use the matching
--   synchronizer_rst entity.

library ieee;
use ieee.std_logic_1164.all;

entity synchronizer is
    port (
        clk    : in  std_logic;
        rst    : in  std_logic;
        d_in   : in  std_logic;
        d_out  : out std_logic
    );
end entity;

architecture rtl of synchronizer is
    signal sync_reg : std_logic_vector(1 downto 0) := (others => '0');
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sync_reg : signal is "TRUE";
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sync_reg <= (others => '0');
            else
                sync_reg <= sync_reg(0) & d_in;
            end if;
        end if;
    end process;

    d_out <= sync_reg(1);
end architecture;
