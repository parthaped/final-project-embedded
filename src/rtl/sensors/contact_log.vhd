-- contact_log.vhd
--   Eight-slot circular contact log. Slot 0 is always the newest
--   contact: every write_pulse shifts slots 0..N-2 down one and puts
--   the fresh entry at slot 0. If the log was full the oldest entry
--   falls off the end. The HDMI event log reads slots in order so this
--   gives newest-first display for free.
--
--   Once a second (driven by the 60 Hz tick) we sweep all eight slots
--   and clear any whose age has passed MAX_AGE_SECONDS. We only zero
--   the valid bit, not the rest of the record, so the slot just stops
--   being counted. clear_all wipes everything.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.contact_pkg.all;

entity contact_log is
    generic (
        MAX_AGE_SECONDS : positive := 600
    );
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;

        write_pulse   : in  std_logic;
        clear_all     : in  std_logic;
        tick_60hz     : in  std_logic;

        in_range_in   : in  unsigned(7 downto 0);
        in_severity   : in  unsigned(1 downto 0);
        in_ambient    : in  unsigned(1 downto 0);
        t_seconds     : in  unsigned(15 downto 0);

        contacts      : out contact_array_t;
        count         : out unsigned(3 downto 0);

        last_valid    : out std_logic;
        last_range_in : out unsigned(7 downto 0);
        last_severity : out unsigned(1 downto 0);
        last_ambient  : out unsigned(1 downto 0);
        last_t_log    : out unsigned(15 downto 0)
    );
end entity;

architecture rtl of contact_log is
    signal slots : contact_array_t := CONTACTS_NULL;

    -- Walk the slots once and add up how many are valid. Eight slots
    -- fit in a 4-bit count.
    function popcount8 (a : contact_array_t) return unsigned is
        variable n : unsigned(3 downto 0) := (others => '0');
    begin
        for i in 0 to N_CONTACT_SLOTS-1 loop
            if a(i).valid = '1' then
                n := n + 1;
            end if;
        end loop;
        return n;
    end function;

    function age_of (c : contact_t; tnow : unsigned(15 downto 0)) return unsigned is
    begin
        return tnow - c.t_log;
    end function;
begin

    process(clk)
        variable new_entry : contact_t;
    begin
        if rising_edge(clk) then
            if rst = '1' or clear_all = '1' then
                slots <= CONTACTS_NULL;
            elsif write_pulse = '1' then
                for i in N_CONTACT_SLOTS-1 downto 1 loop
                    slots(i) <= slots(i-1);
                end loop;

                new_entry := (
                    valid          => '1',
                    range_in       => in_range_in,
                    severity_score => in_severity,
                    ambient        => in_ambient,
                    t_log          => t_seconds );
                slots(0) <= new_entry;

            elsif tick_60hz = '1' then
                -- write has priority over the aging sweep
                for i in 0 to N_CONTACT_SLOTS-1 loop
                    if slots(i).valid = '1' and
                       age_of(slots(i), t_seconds) >=
                           to_unsigned(MAX_AGE_SECONDS, 16) then
                        slots(i).valid <= '0';
                    end if;
                end loop;
            end if;
        end if;
    end process;

    contacts <= slots;
    count    <= popcount8(slots);

    last_valid    <= slots(0).valid;
    last_range_in <= slots(0).range_in;
    last_severity <= slots(0).severity_score;
    last_ambient  <= slots(0).ambient;
    last_t_log    <= slots(0).t_log;

end architecture;
