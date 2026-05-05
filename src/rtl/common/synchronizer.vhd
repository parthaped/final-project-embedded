-- ============================================================================
-- synchronizer.vhd
--   Two-flop synchronizer for an asynchronous single-bit input.  Use one
--   instance per crossing; do NOT cross multi-bit buses with this block alone.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity synchronizer is
    generic (
        STAGES   : positive := 2;
        RST_VAL  : std_logic := '0'
    );
    port (
        clk    : in  std_logic;
        rst    : in  std_logic;     -- synchronous active-high reset
        d_in   : in  std_logic;
        d_out  : out std_logic
    );
end entity;

architecture rtl of synchronizer is
    signal sync_reg : std_logic_vector(STAGES-1 downto 0) := (others => RST_VAL);
    -- Tell Vivado not to merge these flops, and treat as ASYNC_REG.
    attribute ASYNC_REG       : string;
    attribute ASYNC_REG of sync_reg : signal is "TRUE";
    attribute SHREG_EXTRACT   : string;
    attribute SHREG_EXTRACT of sync_reg : signal is "NO";
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sync_reg <= (others => RST_VAL);
            else
                sync_reg <= sync_reg(STAGES-2 downto 0) & d_in;
            end if;
        end if;
    end process;

    d_out <= sync_reg(STAGES-1);
end architecture;
