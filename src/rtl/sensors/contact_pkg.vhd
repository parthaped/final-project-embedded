-- contact_pkg.vhd
--   Shared types for the contact log: one record per slot, an array of
--   eight slots, and a pre-built null array we use when the log is
--   reset. Pulled out into a package so the contact_log, the OLED, and
--   the HDMI event log can all reference the same definition.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package contact_pkg is
    constant N_CONTACT_SLOTS : positive := 8;

    type contact_t is record
        valid          : std_logic;
        range_in       : unsigned(7 downto 0);
        severity_score : unsigned(1 downto 0);
        ambient        : unsigned(1 downto 0);
        t_log          : unsigned(15 downto 0);
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
