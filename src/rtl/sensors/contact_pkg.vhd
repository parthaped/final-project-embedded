-- ============================================================================
-- contact_pkg.vhd
--   Shared types for the perimeter-monitor contact log: the per-slot
--   record `contact_t` and the 8-element `contact_array_t`.  Pulled out
--   into a package so the contact_log module, the OLED status panel,
--   and the HDMI event_log_renderer all reference the same definition.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package contact_pkg is
    constant N_CONTACT_SLOTS : positive := 8;

    type contact_t is record
        valid          : std_logic;                -- '1' = slot occupied
        range_in       : unsigned(7 downto 0);     -- inches at the moment of contact
        severity_score : unsigned(1 downto 0);     -- 00 LOW / 01 MED / 10 HIGH / 11 CRIT
        ambient        : unsigned(1 downto 0);     -- ambient mode at moment of contact
        t_log          : unsigned(15 downto 0);    -- system_clock.t_seconds when logged
    end record;

    type contact_array_t is array (0 to N_CONTACT_SLOTS-1) of contact_t;

    constant CONTACT_NULL : contact_t := (
        valid          => '0',
        range_in       => (others => '0'),
        severity_score => (others => '0'),
        ambient        => (others => '0'),
        t_log          => (others => '0') );

    constant CONTACTS_NULL : contact_array_t := (others => CONTACT_NULL);
end package;
