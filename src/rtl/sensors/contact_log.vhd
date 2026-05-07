-- ============================================================================
-- contact_log.vhd
--   Eight-slot contact log for the perimeter monitor.  Slot 0 is always
--   the most-recent contact; on every `write_pulse`, all existing
--   entries shift one slot toward the tail and the new entry is
--   inserted at slot 0 (so the oldest contact falls off when the log
--   is full -- newest-first eviction).  This gives the HDMI event-log
--   renderer a free youngest-first ordering.
--
--   On every `tick_60hz` the module sweeps the eight slots and
--   invalidates any whose age (current `t_seconds` minus stored
--   `t_log`) has exceeded MAX_AGE_SECONDS.  The slot's storage is left
--   alone, only its `valid` bit is cleared, so a stale entry won't
--   reappear and the count drops.
--
--   `clear_all` (driven by BTN3 / SW2 in the top level) wipes every
--   slot atomically.
--
--   Outputs:
--     contacts        - full 8-slot record array (newest at index 0)
--     count           - number of currently-valid slots (0..8)
--     last_*          - convenience aliases of slots(0) for OLED wiring
--                       and the risk banner's "PRESENCE" line.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.contact_pkg.all;

entity contact_log is
    generic (
        -- Default 600 s = 10 minutes, big enough that a normal demo
        -- never sees an entry expire mid-presentation but small enough
        -- that an idle log eventually cleans itself up.
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

    -- Counts as a sum of std_logic 0/1 by converting to integers.  Eight
    -- slots fit comfortably in a 4-bit count.
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
        -- Wraparound is fine because the seconds counter saturates at
        -- 0xFFFF in system_clock; in practice ages are well under that.
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
                -- Shift slots N-1..1 down one (slot N-1 falls off if it
                -- was valid -- newest-first eviction), insert new entry
                -- at slot 0.
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
                -- Aging sweep.  Mutually exclusive with write_pulse so
                -- a simultaneous write isn't lost; if both fire on the
                -- same cycle the next tick_60hz will catch the aging
                -- pass.
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
