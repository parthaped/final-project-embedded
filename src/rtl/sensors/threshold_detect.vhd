-- threshold_detect.vhd
--   Sonar-band classifier and severity mapping. We answer two
--   questions about the latest filtered range:
--     1) is it close enough to count as a real "alert" or "warn"?
--     2) given the live ambient mode, what severity should the FSM use
--        if it logs a contact this cycle?
--   Stage 1 clips the range to one byte and decides which band it is
--   in. Stage 2 turns the (band, ambient) pair into a 2-bit severity
--   and a single qualified trigger that the FSM watches.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity threshold_detect is
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;

        sonar_in      : in  unsigned(15 downto 0);
        ambient_mode  : in  unsigned(1 downto 0);

        sonar_near_th : in  unsigned(7 downto 0);
        sonar_warn_th : in  unsigned(7 downto 0);

        sonar_alert   : out std_logic;
        sonar_warn    : out std_logic;
        trig          : out std_logic;
        severity_now  : out unsigned(1 downto 0)
    );
end entity;

architecture rtl of threshold_detect is
    constant SEV_LOW  : unsigned(1 downto 0) := "00";
    constant SEV_MED  : unsigned(1 downto 0) := "01";
    constant SEV_HIGH : unsigned(1 downto 0) := "10";
    constant SEV_CRIT : unsigned(1 downto 0) := "11";

    constant A_NIGHT  : unsigned(1 downto 0) := "00";
    constant A_DIM    : unsigned(1 downto 0) := "01";
    constant A_DAY    : unsigned(1 downto 0) := "10";
    constant A_BRIGHT : unsigned(1 downto 0) := "11";

    signal son_alert_s1 : std_logic := '0';
    signal son_warn_s1  : std_logic := '0';
    signal son_byte     : unsigned(7 downto 0) := (others => '0');
    signal amb_s1       : unsigned(1 downto 0) := A_DAY;

    signal sev_comb     : unsigned(1 downto 0);
    signal amb_dark_s1  : std_logic;
begin

    -- Clip the 16-bit filtered sonar to a byte (the sensor maxes out at
    -- 254 in anyway), pipeline the ambient by one cycle so it lines up
    -- with the alert/warn band, and figure out which band we're in.
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                son_byte     <= (others => '0');
                son_alert_s1 <= '0';
                son_warn_s1  <= '0';
                amb_s1       <= A_DAY;
            else
                if sonar_in > to_unsigned(254, sonar_in'length) then
                    son_byte <= to_unsigned(254, son_byte'length);
                else
                    son_byte <= sonar_in(7 downto 0);
                end if;

                amb_s1 <= ambient_mode;

                son_alert_s1 <= '0';
                son_warn_s1  <= '0';

                if son_byte > to_unsigned(0, son_byte'length) then
                    if son_byte < sonar_near_th then
                        son_alert_s1 <= '1';
                    elsif son_byte < sonar_warn_th then
                        son_warn_s1 <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Severity table. An alert under bright daylight is just LOW (a
    -- pedestrian getting too close). The same close range at night is
    -- HIGH (someone sneaking up). A "warn" hit only counts at all when
    -- it's dark; in daylight a warn is a non-event, so trig stays low.
    sev_comb <=
        SEV_LOW  when son_alert_s1 = '1' and amb_s1 = A_DAY    else
        SEV_MED  when son_alert_s1 = '1' and amb_s1 = A_DIM    else
        SEV_HIGH when son_alert_s1 = '1' and amb_s1 = A_NIGHT  else
        SEV_CRIT when son_alert_s1 = '1' and amb_s1 = A_BRIGHT else
        SEV_LOW  when son_warn_s1  = '1' and (amb_s1 = A_NIGHT or amb_s1 = A_DIM) else
        SEV_LOW;

    amb_dark_s1 <= '1' when (amb_s1 = A_NIGHT or amb_s1 = A_DIM) else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sonar_alert  <= '0';
                sonar_warn   <= '0';
                trig         <= '0';
                severity_now <= SEV_LOW;
            else
                sonar_alert  <= son_alert_s1;
                sonar_warn   <= son_warn_s1;
                trig         <= son_alert_s1 or (son_warn_s1 and amb_dark_s1);
                severity_now <= sev_comb;
            end if;
        end if;
    end process;

end architecture;
