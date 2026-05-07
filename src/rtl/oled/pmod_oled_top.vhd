-- ============================================================================
-- pmod_oled_top.vhd
--   Drives a Digilent Pmod OLED (SSD1306, 128x32) attached to JB.
--
--   In the perimeter-monitor build the OLED is a *secondary* status
--   panel; the HDMI console is the primary visualisation.  Layout:
--
--       Line 0:  STATE: <state>
--       Line 1:  MODE: <ambient>  C:<count>
--       Line 2:  LAST: <range>IN T-<age>S
--       Line 3:  SEV: <sev>    LIM:<near_th>
--
--   The OLED's compact summary is what an operator standing next to
--   the board glances at; everything else lives on the HDMI console.
--
--   The state machine that drives the SSD1306 (power-up, init ROM,
--   per-refresh framebuffer render, SPI streaming) is unchanged from
--   the previous build; only the text-fill sub-sequencer is new.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.oled_init_pkg.all;
use work.font_5x8_pkg.all;

entity pmod_oled_top is
    generic (
        SYS_HZ             : positive := 125_000_000;
        REFRESH_HZ         : positive := 30
    );
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;

        -- Live system status (from clk_sys top level).
        state_code    : in  std_logic_vector(2 downto 0);
        ambient_mode  : in  unsigned(1 downto 0);
        count         : in  unsigned(3 downto 0);
        last_valid    : in  std_logic;
        last_range_in : in  unsigned(7 downto 0);
        last_severity : in  unsigned(1 downto 0);
        last_t_log    : in  unsigned(15 downto 0);
        t_seconds     : in  unsigned(15 downto 0);
        near_th       : in  unsigned(7 downto 0);

        oled_cs_n    : out std_logic;
        oled_mosi    : out std_logic;
        oled_sclk    : out std_logic;
        oled_dc      : out std_logic;
        oled_res_n   : out std_logic;
        oled_vbat_n  : out std_logic;
        oled_vdd_n   : out std_logic
    );
end entity;

architecture rtl of pmod_oled_top is
    constant CYCLES_PER_MS  : positive := SYS_HZ / 1000;
    constant T_VDD_WAIT     : positive := CYCLES_PER_MS * 1;
    constant T_RES_LOW      : positive := CYCLES_PER_MS * 1;
    constant T_RES_HIGH     : positive := CYCLES_PER_MS * 1;
    constant T_VBAT_WAIT    : positive := CYCLES_PER_MS * 100;
    constant T_REFRESH      : positive := SYS_HZ / REFRESH_HZ;

    constant INIT_PRE_END   : integer := 10;

    constant CHARS_PER_LINE : integer := 21;
    constant LINES          : integer := 4;
    constant TBUF_LEN       : integer := CHARS_PER_LINE * LINES;

    type state_t is (
        S_RESET_HOLD,
        S_VDD_ON,
        S_RES_LOW,
        S_RES_HIGH,
        S_TX_INIT_PRE_LOAD,
        S_TX_INIT_PRE_WAIT,
        S_VBAT_ON,
        S_TX_INIT_POST_LOAD,
        S_TX_INIT_POST_WAIT,
        S_RUN_WAIT_TICK,
        S_RUN_FILL_TEXT,
        S_RUN_CLEAR_FB,
        S_RUN_RENDER,
        S_RUN_TX_PREFIX_LOAD,
        S_RUN_TX_PREFIX_WAIT,
        S_RUN_TX_DATA_LOAD,
        S_RUN_TX_DATA_WAIT
    );
    signal state : state_t := S_RESET_HOLD;

    signal vdd_n_r  : std_logic := '1';
    signal vbat_n_r : std_logic := '1';
    signal res_n_r  : std_logic := '0';

    signal timer    : unsigned(31 downto 0) := (others => '0');
    signal timer_target : unsigned(31 downto 0) := (others => '0');

    signal refresh_pulse : std_logic;

    signal rom_idx     : integer range 0 to ROM_LEN := 0;
    signal rom_idx_end : integer range 0 to ROM_LEN := 0;

    signal spi_start : std_logic := '0';
    signal spi_dc    : std_logic := '0';
    signal spi_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal spi_busy  : std_logic;

    type tbuf_t is array (0 to TBUF_LEN-1) of std_logic_vector(7 downto 0);
    signal tbuf : tbuf_t := (others => x"20");

    type tbuf_const_t is array (0 to TBUF_LEN-1) of character;
    constant TEMPLATE : tbuf_const_t := (
        -- Line 0: "STATE:               "  (positions 7..14 = state name)
        'S','T','A','T','E',':',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',
        -- Line 1: "MODE:        C:      "  (6..11=mode, 16=count digit)
        'M','O','D','E',':',' ',' ',' ',' ',' ',' ',' ',' ',' ','C',':',' ',' ',' ',' ',' ',
        -- Line 2: "LAST:    IN T-    S  "  (6..8=range, 14..16=age, 17='S')
        'L','A','S','T',':',' ',' ',' ',' ','I','N',' ','T','-',' ',' ',' ','S',' ',' ',' ',
        -- Line 3: "SEV:         LIM:    "  (5..8=sev, 17..18=near_th)
        'S','E','V',':',' ',' ',' ',' ',' ',' ',' ',' ',' ','L','I','M',':',' ',' ',' ',' '
    );

    signal fb_we    : std_logic := '0';
    signal fb_waddr : unsigned(8 downto 0) := (others => '0');
    signal fb_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal fb_raddr : unsigned(8 downto 0) := (others => '0');
    signal fb_rdata : std_logic_vector(7 downto 0);

    -- Snapshotted inputs (registered at the start of every refresh
    -- pulse so the per-line text computations work from a stable copy).
    signal state_code_q : std_logic_vector(2 downto 0) := (others => '0');
    signal mode_q       : unsigned(1 downto 0) := (others => '0');
    signal count_q      : unsigned(3 downto 0) := (others => '0');
    signal last_valid_q : std_logic := '0';
    signal range_q      : unsigned(7 downto 0) := (others => '0');
    signal sev_q        : unsigned(1 downto 0) := (others => '0');
    signal age_q        : unsigned(15 downto 0) := (others => '0');
    signal near_th_q    : unsigned(7 downto 0) := (others => '0');

    -- Pre-computed BCD digits.
    signal range_h, range_t, range_o : unsigned(3 downto 0) := (others => '0');
    signal age_h, age_t, age_o       : unsigned(3 downto 0) := (others => '0');
    signal nth_t, nth_o              : unsigned(3 downto 0) := (others => '0');

    signal fill_cnt : integer range 0 to 63 := 0;

    signal clr_cnt   : unsigned(9 downto 0) := (others => '0');
    signal rnd_page  : integer range 0 to 3 := 0;
    signal rnd_char  : integer range 0 to CHARS_PER_LINE := 0;
    signal rnd_col   : integer range 0 to 4 := 0;

    signal data_cnt  : unsigned(9 downto 0) := (others => '0');
    signal data_phase : unsigned(1 downto 0) := (others => '0');

    -- Helpers ---------------------------------------------------------
    function state_name (sc : std_logic_vector(2 downto 0); idx : integer)
        return std_logic_vector
    is
        type str8 is array (0 to 7) of character;
        variable s : str8;
    begin
        case sc is
            when "000" => s := ('I','D','L','E',' ',' ',' ',' ');
            when "001" => s := ('M','O','N','I','T','O','R',' ');
            when "010" => s := ('C','A','N','D','I','D','A','T');
            when "011" => s := ('V','E','R','I','F','Y',' ',' ');
            when "100" => s := ('C','O','N','T','A','C','T',' ');
            when "101" => s := ('C','O','O','L','D','O','W','N');
            when others => s := ('?',' ',' ',' ',' ',' ',' ',' ');
        end case;
        return std_logic_vector(to_unsigned(character'pos(s(idx)), 8));
    end function;

    function mode_name (m : unsigned(1 downto 0); idx : integer)
        return std_logic_vector
    is
        type str6 is array (0 to 5) of character;
        variable s : str6;
    begin
        case m is
            when "00"   => s := ('N','I','G','H','T',' ');
            when "01"   => s := (' ','D','I','M',' ',' ');
            when "10"   => s := (' ','D','A','Y',' ',' ');
            when others => s := ('B','R','I','G','H','T');
        end case;
        return std_logic_vector(to_unsigned(character'pos(s(idx)), 8));
    end function;

    function sev_name (sv : unsigned(1 downto 0); idx : integer)
        return std_logic_vector
    is
        type str4 is array (0 to 3) of character;
        variable s : str4;
    begin
        case sv is
            when "00"   => s := (' ','L','O','W');
            when "01"   => s := (' ','M','E','D');
            when "10"   => s := ('H','I','G','H');
            when others => s := ('C','R','I','T');
        end case;
        return std_logic_vector(to_unsigned(character'pos(s(idx)), 8));
    end function;

    function ascii_digit (d : unsigned(3 downto 0)) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(character'pos('0') + to_integer(d), 8));
    end function;

begin

    refresh_gen : entity work.pulse_gen
        generic map ( PERIOD_CYCLES => T_REFRESH )
        port map ( clk => clk, rst => rst, en => '1', pulse => refresh_pulse );

    spi_inst : entity work.oled_spi_master
        generic map ( SCLK_HALF_CYCLES => 12 )
        port map (
            clk      => clk,
            rst      => rst,
            start    => spi_start,
            dc_in    => spi_dc,
            byte_in  => spi_byte,
            busy     => spi_busy,
            spi_cs_n => oled_cs_n,
            spi_sclk => oled_sclk,
            spi_mosi => oled_mosi,
            spi_dc   => oled_dc );

    fb_inst : entity work.oled_framebuffer
        port map (
            clk   => clk,
            we    => fb_we,
            waddr => fb_waddr,
            wdata => fb_wdata,
            raddr => fb_raddr,
            rdata => fb_rdata );

    oled_vdd_n  <= vdd_n_r;
    oled_vbat_n <= vbat_n_r;
    oled_res_n  <= res_n_r;

    process(clk)
        variable rng_int : integer;
        variable age_int : integer;
        variable nth_int : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state         <= S_RESET_HOLD;
                vdd_n_r       <= '1';
                vbat_n_r      <= '1';
                res_n_r       <= '0';
                timer         <= (others => '0');
                timer_target  <= to_unsigned(T_VDD_WAIT, 32);
                rom_idx       <= 0;
                rom_idx_end   <= INIT_PRE_END;
                spi_start     <= '0';
                spi_dc        <= '0';
                spi_byte      <= (others => '0');
                fb_we         <= '0';
                fb_waddr      <= (others => '0');
                fb_wdata      <= (others => '0');
                fb_raddr      <= (others => '0');
                fill_cnt      <= 0;
                clr_cnt       <= (others => '0');
                rnd_page      <= 0;
                rnd_char      <= 0;
                rnd_col       <= 0;
                data_cnt      <= (others => '0');
                data_phase    <= (others => '0');
                state_code_q  <= (others => '0');
                mode_q        <= (others => '0');
                count_q       <= (others => '0');
                last_valid_q  <= '0';
                range_q       <= (others => '0');
                sev_q         <= (others => '0');
                age_q         <= (others => '0');
                near_th_q     <= (others => '0');
                range_h       <= (others => '0');
                range_t       <= (others => '0');
                range_o       <= (others => '0');
                age_h         <= (others => '0');
                age_t         <= (others => '0');
                age_o         <= (others => '0');
                nth_t         <= (others => '0');
                nth_o         <= (others => '0');
                tbuf          <= (others => x"20");
                for i in 0 to TBUF_LEN-1 loop
                    tbuf(i) <=
                        std_logic_vector(to_unsigned(character'pos(TEMPLATE(i)), 8));
                end loop;
            else
                spi_start <= '0';
                fb_we     <= '0';

                case state is
                    when S_RESET_HOLD =>
                        vdd_n_r  <= '1';
                        vbat_n_r <= '1';
                        res_n_r  <= '0';
                        if timer = timer_target - 1 then
                            timer        <= (others => '0');
                            timer_target <= to_unsigned(T_VDD_WAIT, 32);
                            vdd_n_r      <= '0';
                            state        <= S_VDD_ON;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_VDD_ON =>
                        if timer = timer_target - 1 then
                            timer        <= (others => '0');
                            timer_target <= to_unsigned(T_RES_LOW, 32);
                            res_n_r      <= '0';
                            state        <= S_RES_LOW;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_RES_LOW =>
                        if timer = timer_target - 1 then
                            timer        <= (others => '0');
                            timer_target <= to_unsigned(T_RES_HIGH, 32);
                            res_n_r      <= '1';
                            state        <= S_RES_HIGH;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_RES_HIGH =>
                        if timer = timer_target - 1 then
                            timer       <= (others => '0');
                            rom_idx     <= 0;
                            rom_idx_end <= INIT_PRE_END;
                            state       <= S_TX_INIT_PRE_LOAD;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_TX_INIT_PRE_LOAD =>
                        if rom_idx = rom_idx_end then
                            timer        <= (others => '0');
                            timer_target <= to_unsigned(T_VBAT_WAIT, 32);
                            vbat_n_r     <= '0';
                            state        <= S_VBAT_ON;
                        elsif spi_busy = '0' then
                            spi_byte  <= OLED_ROM(rom_idx)(7 downto 0);
                            spi_dc    <= OLED_ROM(rom_idx)(8);
                            spi_start <= '1';
                            state     <= S_TX_INIT_PRE_WAIT;
                        end if;

                    when S_TX_INIT_PRE_WAIT =>
                        if spi_busy = '0' and spi_start = '0' then
                            rom_idx <= rom_idx + 1;
                            state   <= S_TX_INIT_PRE_LOAD;
                        end if;

                    when S_VBAT_ON =>
                        if timer = timer_target - 1 then
                            timer       <= (others => '0');
                            rom_idx     <= INIT_PRE_END;
                            rom_idx_end <= INIT_LEN;
                            state       <= S_TX_INIT_POST_LOAD;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_TX_INIT_POST_LOAD =>
                        if rom_idx = rom_idx_end then
                            state <= S_RUN_WAIT_TICK;
                        elsif spi_busy = '0' then
                            spi_byte  <= OLED_ROM(rom_idx)(7 downto 0);
                            spi_dc    <= OLED_ROM(rom_idx)(8);
                            spi_start <= '1';
                            state     <= S_TX_INIT_POST_WAIT;
                        end if;

                    when S_TX_INIT_POST_WAIT =>
                        if spi_busy = '0' and spi_start = '0' then
                            rom_idx <= rom_idx + 1;
                            state   <= S_TX_INIT_POST_LOAD;
                        end if;

                    -- ----------------------------------------------------
                    -- Per-refresh: snapshot live data, compute BCD,
                    -- repaint tbuf, then re-render the framebuffer.
                    -- ----------------------------------------------------
                    when S_RUN_WAIT_TICK =>
                        if refresh_pulse = '1' then
                            state_code_q <= state_code;
                            mode_q       <= ambient_mode;
                            count_q      <= count;
                            last_valid_q <= last_valid;
                            near_th_q    <= near_th;
                            sev_q        <= last_severity;

                            if last_valid = '1' then
                                range_q <= last_range_in;
                                if t_seconds >= last_t_log then
                                    age_q <= t_seconds - last_t_log;
                                else
                                    age_q <= (others => '0');
                                end if;
                            else
                                range_q <= (others => '0');
                                age_q   <= (others => '0');
                            end if;

                            -- BCD conversion (synthesisable for 8-bit / 16-bit
                            -- with constant divisors).
                            rng_int := to_integer(last_range_in);
                            range_h <= to_unsigned(rng_int / 100,        4);
                            range_t <= to_unsigned((rng_int / 10) mod 10, 4);
                            range_o <= to_unsigned(rng_int mod 10,        4);

                            if last_valid = '1' and t_seconds >= last_t_log then
                                age_int := to_integer(t_seconds - last_t_log);
                            else
                                age_int := 0;
                            end if;
                            if age_int > 999 then age_int := 999; end if;
                            age_h <= to_unsigned(age_int / 100,           4);
                            age_t <= to_unsigned((age_int / 10) mod 10,   4);
                            age_o <= to_unsigned(age_int mod 10,          4);

                            nth_int := to_integer(near_th);
                            if nth_int > 99 then nth_int := 99; end if;
                            nth_t <= to_unsigned(nth_int / 10,            4);
                            nth_o <= to_unsigned(nth_int mod 10,          4);

                            fill_cnt <= 0;
                            state    <= S_RUN_FILL_TEXT;
                        end if;

                    when S_RUN_FILL_TEXT =>
                        case fill_cnt is
                            -- Line 0: state name at positions 7..14.
                            when 0  => tbuf(7)  <= state_name(state_code_q, 0);
                            when 1  => tbuf(8)  <= state_name(state_code_q, 1);
                            when 2  => tbuf(9)  <= state_name(state_code_q, 2);
                            when 3  => tbuf(10) <= state_name(state_code_q, 3);
                            when 4  => tbuf(11) <= state_name(state_code_q, 4);
                            when 5  => tbuf(12) <= state_name(state_code_q, 5);
                            when 6  => tbuf(13) <= state_name(state_code_q, 6);
                            when 7  => tbuf(14) <= state_name(state_code_q, 7);

                            -- Line 1: ambient at positions 6..11, count at 16.
                            when 8  => tbuf(21+6)  <= mode_name(mode_q, 0);
                            when 9  => tbuf(21+7)  <= mode_name(mode_q, 1);
                            when 10 => tbuf(21+8)  <= mode_name(mode_q, 2);
                            when 11 => tbuf(21+9)  <= mode_name(mode_q, 3);
                            when 12 => tbuf(21+10) <= mode_name(mode_q, 4);
                            when 13 => tbuf(21+11) <= mode_name(mode_q, 5);
                            when 14 => tbuf(21+16) <= ascii_digit(count_q);

                            -- Line 2: range at positions 6..8, age at 14..16.
                            when 15 => tbuf(42+6)  <= ascii_digit(range_h);
                            when 16 => tbuf(42+7)  <= ascii_digit(range_t);
                            when 17 => tbuf(42+8)  <= ascii_digit(range_o);
                            when 18 => tbuf(42+14) <= ascii_digit(age_h);
                            when 19 => tbuf(42+15) <= ascii_digit(age_t);
                            when 20 => tbuf(42+16) <= ascii_digit(age_o);

                            -- Line 3: severity at positions 5..8, LIM digits at 17..18.
                            when 21 => tbuf(63+5) <= sev_name(sev_q, 0);
                            when 22 => tbuf(63+6) <= sev_name(sev_q, 1);
                            when 23 => tbuf(63+7) <= sev_name(sev_q, 2);
                            when 24 => tbuf(63+8) <= sev_name(sev_q, 3);
                            when 25 => tbuf(63+17) <= ascii_digit(nth_t);
                            when 26 => tbuf(63+18) <= ascii_digit(nth_o);

                            when others => null;
                        end case;
                        if fill_cnt = 27 then
                            clr_cnt <= (others => '0');
                            state   <= S_RUN_CLEAR_FB;
                        else
                            fill_cnt <= fill_cnt + 1;
                        end if;

                    when S_RUN_CLEAR_FB =>
                        fb_we    <= '1';
                        fb_waddr <= clr_cnt(8 downto 0);
                        fb_wdata <= (others => '0');
                        if clr_cnt = to_unsigned(511, clr_cnt'length) then
                            clr_cnt <= (others => '0');
                            rnd_page <= 0;
                            rnd_char <= 0;
                            rnd_col  <= 0;
                            state    <= S_RUN_RENDER;
                        else
                            clr_cnt <= clr_cnt + 1;
                        end if;

                    when S_RUN_RENDER =>
                        fb_we    <= '1';
                        fb_waddr <= to_unsigned(rnd_page * 128 + rnd_char * 6 + rnd_col, 9);
                        fb_wdata <= font_glyph(
                                      tbuf(rnd_page * CHARS_PER_LINE + rnd_char))
                                      (rnd_col);
                        if rnd_col = 4 then
                            rnd_col <= 0;
                            if rnd_char = CHARS_PER_LINE - 1 then
                                rnd_char <= 0;
                                if rnd_page = 3 then
                                    rnd_page    <= 0;
                                    rom_idx     <= INIT_LEN;
                                    rom_idx_end <= ROM_LEN;
                                    state       <= S_RUN_TX_PREFIX_LOAD;
                                else
                                    rnd_page <= rnd_page + 1;
                                end if;
                            else
                                rnd_char <= rnd_char + 1;
                            end if;
                        else
                            rnd_col <= rnd_col + 1;
                        end if;

                    when S_RUN_TX_PREFIX_LOAD =>
                        if rom_idx = rom_idx_end then
                            data_cnt   <= (others => '0');
                            data_phase <= (others => '0');
                            state      <= S_RUN_TX_DATA_LOAD;
                        elsif spi_busy = '0' then
                            spi_byte  <= OLED_ROM(rom_idx)(7 downto 0);
                            spi_dc    <= OLED_ROM(rom_idx)(8);
                            spi_start <= '1';
                            state     <= S_RUN_TX_PREFIX_WAIT;
                        end if;

                    when S_RUN_TX_PREFIX_WAIT =>
                        if spi_busy = '0' and spi_start = '0' then
                            rom_idx <= rom_idx + 1;
                            state   <= S_RUN_TX_PREFIX_LOAD;
                        end if;

                    when S_RUN_TX_DATA_LOAD =>
                        if data_cnt = to_unsigned(512, data_cnt'length) then
                            state <= S_RUN_WAIT_TICK;
                        else
                            case data_phase is
                                when "00" =>
                                    fb_raddr   <= data_cnt(8 downto 0);
                                    data_phase <= "01";
                                when "01" =>
                                    if spi_busy = '0' then
                                        spi_byte   <= fb_rdata;
                                        spi_dc     <= '1';
                                        spi_start  <= '1';
                                        data_phase <= "10";
                                        state      <= S_RUN_TX_DATA_WAIT;
                                    end if;
                                when others => null;
                            end case;
                        end if;

                    when S_RUN_TX_DATA_WAIT =>
                        if spi_busy = '0' and spi_start = '0' then
                            data_cnt   <= data_cnt + 1;
                            data_phase <= "00";
                            state      <= S_RUN_TX_DATA_LOAD;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture;
