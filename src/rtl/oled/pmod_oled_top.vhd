-- pmod_oled_top.vhd
--   Drives the Digilent Pmod OLED (SSD1306, 128x32) on JB.
--   ref: SSD1306 controller datasheet; Digilent Pmod OLED reference
--        manual.
--
--   This is a small status panel that runs alongside the HDMI console.
--   Layout:
--       Line 0:  STATE: <state>
--       Line 1:  MODE:  <ambient>      C:<count>
--       Line 2:  LAST:  <range>IN T-<age>S
--       Line 3:  SEV:   <sev>          LIM:<near_th>
--
--   Internal flow:
--     power-up -> SSD1306 init ROM -> per-refresh framebuffer fill ->
--     stream framebuffer over SPI -> back to wait-for-next-tick.
--   The render path is split into two states (lookup, write) so we
--   never combine the tbuf array index AND the font_glyph case in the
--   same clock period.

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
        S_RUN_BCD,
        S_RUN_FILL_TEXT,
        S_RUN_CLEAR_FB,
        S_RENDER_LOOKUP,
        S_RENDER_WRITE,
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

    -- Build tbuf at startup from TEMPLATE so the FPGA boots up with
    -- the labels already in place and we never have to clear 84 bytes
    -- on reset. The S_RUN_FILL_TEXT step overwrites the variable
    -- fields before each refresh, so we don't need to touch tbuf in
    -- the reset branch.
    function tbuf_init return tbuf_t is
        variable r : tbuf_t;
    begin
        for i in 0 to TBUF_LEN-1 loop
            r(i) := std_logic_vector(
                        to_unsigned(character'pos(TEMPLATE(i)), 8));
        end loop;
        return r;
    end function;

    signal tbuf : tbuf_t := tbuf_init;

    signal fb_we    : std_logic := '0';
    signal fb_waddr : unsigned(8 downto 0) := (others => '0');
    signal fb_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal fb_raddr : unsigned(8 downto 0) := (others => '0');
    signal fb_rdata : std_logic_vector(7 downto 0);

    -- Latched copies of the live inputs. We capture them once when a
    -- refresh tick fires so the BCD converter and the text fill all
    -- see the same values for the whole frame.
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

    -- Iterative BCD converter working set.  S_RUN_WAIT_TICK loads
    -- range_q / age_q / near_th_q (already clipped); S_RUN_BCD walks
    -- through three sub-conversions (range -> age -> near_th), each cycle
    -- doing at most one 10-bit subtract+compare, which is the deepest
    -- combinational path in this state.  This replaces a single-cycle
    -- mass of /100, /10, mod 10 operations on 16-bit values that ate the
    -- entire 8 ns clk_sys budget on -1 silicon.
    signal bcd_in    : unsigned(9 downto 0) := (others => '0');
    signal bcd_h     : unsigned(3 downto 0) := (others => '0');
    signal bcd_t     : unsigned(3 downto 0) := (others => '0');
    signal bcd_phase : unsigned(2 downto 0) := (others => '0');

    signal fill_cnt : integer range 0 to 63 := 0;

    signal clr_cnt   : unsigned(9 downto 0) := (others => '0');
    signal rnd_page  : integer range 0 to 3 := 0;
    signal rnd_char  : integer range 0 to CHARS_PER_LINE := 0;
    signal rnd_col   : integer range 0 to 4 := 0;

    -- Registers between the two render states.
    -- tbuf_char_q : ASCII byte we just read out of tbuf
    -- addr_q      : framebuffer write address
    -- rnd_col_q   : which glyph column (0..4) we'll write next.
    signal tbuf_char_q : std_logic_vector(7 downto 0) := (others => '0');
    signal addr_q      : unsigned(8 downto 0) := (others => '0');
    signal rnd_col_q   : integer range 0 to 4 := 0;

    signal data_cnt  : unsigned(9 downto 0) := (others => '0');
    signal data_phase : unsigned(1 downto 0) := (others => '0');

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

    refresh_gen : entity work.clock_div
        generic map ( DIV => T_REFRESH )
        port map ( clk => clk, rst => rst, en => '1', clk_en => refresh_pulse );

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
                bcd_in        <= (others => '0');
                bcd_h         <= (others => '0');
                bcd_t         <= (others => '0');
                bcd_phase     <= (others => '0');
                -- tbuf intentionally NOT reset here: it is initialised at
                -- config time via tbuf_init and refreshed in S_RUN_FILL_TEXT
                -- before every render.  Resetting 84 bytes synchronously was
                -- the largest single source of high-fanout endpoints on
                -- clk_sys.
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

                    -- Snapshot the live data and clip to the BCD
                    -- range. The actual decimal conversion runs
                    -- iteratively over the next handful of cycles.
                    when S_RUN_WAIT_TICK =>
                        if refresh_pulse = '1' then
                            state_code_q <= state_code;
                            mode_q       <= ambient_mode;
                            count_q      <= count;
                            last_valid_q <= last_valid;
                            sev_q        <= last_severity;

                            if last_valid = '1' then
                                range_q <= last_range_in;
                                if t_seconds >= last_t_log then
                                    if (t_seconds - last_t_log) >
                                       to_unsigned(999, 16)
                                    then
                                        age_q <= to_unsigned(999, 16);
                                    else
                                        age_q <= t_seconds - last_t_log;
                                    end if;
                                else
                                    age_q <= (others => '0');
                                end if;
                            else
                                range_q <= (others => '0');
                                age_q   <= (others => '0');
                            end if;

                            if near_th > to_unsigned(99, 8) then
                                near_th_q <= to_unsigned(99, 8);
                            else
                                near_th_q <= near_th;
                            end if;

                            range_h   <= (others => '0');
                            range_t   <= (others => '0');
                            range_o   <= (others => '0');
                            age_h     <= (others => '0');
                            age_t     <= (others => '0');
                            age_o     <= (others => '0');
                            nth_t     <= (others => '0');
                            nth_o     <= (others => '0');
                            bcd_phase <= (others => '0');
                            state     <= S_RUN_BCD;
                        end if;

                    -- Iterative subtract-based decimal conversion.
                    -- Phases: 0 load range, 1 reduce; 2 load age,
                    -- 3 reduce; 4 load near_th, 5 reduce.
                    when S_RUN_BCD =>
                        case to_integer(bcd_phase) is
                            when 0 =>
                                bcd_in    <= resize(range_q, bcd_in'length);
                                bcd_h     <= (others => '0');
                                bcd_t     <= (others => '0');
                                bcd_phase <= to_unsigned(1, bcd_phase'length);

                            when 1 =>
                                if bcd_in >= to_unsigned(100, bcd_in'length) then
                                    bcd_in <= bcd_in
                                            - to_unsigned(100, bcd_in'length);
                                    bcd_h  <= bcd_h + 1;
                                elsif bcd_in >= to_unsigned(10, bcd_in'length) then
                                    bcd_in <= bcd_in
                                            - to_unsigned(10, bcd_in'length);
                                    bcd_t  <= bcd_t + 1;
                                else
                                    range_h   <= bcd_h;
                                    range_t   <= bcd_t;
                                    range_o   <= bcd_in(3 downto 0);
                                    bcd_phase <= to_unsigned(2, bcd_phase'length);
                                end if;

                            when 2 =>
                                bcd_in    <= resize(age_q(9 downto 0),
                                                    bcd_in'length);
                                bcd_h     <= (others => '0');
                                bcd_t     <= (others => '0');
                                bcd_phase <= to_unsigned(3, bcd_phase'length);

                            when 3 =>
                                if bcd_in >= to_unsigned(100, bcd_in'length) then
                                    bcd_in <= bcd_in
                                            - to_unsigned(100, bcd_in'length);
                                    bcd_h  <= bcd_h + 1;
                                elsif bcd_in >= to_unsigned(10, bcd_in'length) then
                                    bcd_in <= bcd_in
                                            - to_unsigned(10, bcd_in'length);
                                    bcd_t  <= bcd_t + 1;
                                else
                                    age_h     <= bcd_h;
                                    age_t     <= bcd_t;
                                    age_o     <= bcd_in(3 downto 0);
                                    bcd_phase <= to_unsigned(4, bcd_phase'length);
                                end if;

                            when 4 =>
                                bcd_in    <= resize(near_th_q, bcd_in'length);
                                bcd_h     <= (others => '0');
                                bcd_t     <= (others => '0');
                                bcd_phase <= to_unsigned(5, bcd_phase'length);

                            when 5 =>
                                if bcd_in >= to_unsigned(10, bcd_in'length) then
                                    bcd_in <= bcd_in
                                            - to_unsigned(10, bcd_in'length);
                                    bcd_t  <= bcd_t + 1;
                                else
                                    -- LIM only needs two digits.
                                    nth_t    <= bcd_t;
                                    nth_o    <= bcd_in(3 downto 0);
                                    fill_cnt <= 0;
                                    state    <= S_RUN_FILL_TEXT;
                                end if;

                            when others =>
                                state <= S_RUN_FILL_TEXT;
                        end case;

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

                            -- Line 1: ambient at 6..11, count at 16.
                            when 8  => tbuf(21+6)  <= mode_name(mode_q, 0);
                            when 9  => tbuf(21+7)  <= mode_name(mode_q, 1);
                            when 10 => tbuf(21+8)  <= mode_name(mode_q, 2);
                            when 11 => tbuf(21+9)  <= mode_name(mode_q, 3);
                            when 12 => tbuf(21+10) <= mode_name(mode_q, 4);
                            when 13 => tbuf(21+11) <= mode_name(mode_q, 5);
                            when 14 => tbuf(21+16) <= ascii_digit(count_q);

                            -- Line 2: range at 6..8, age at 14..16.
                            when 15 => tbuf(42+6)  <= ascii_digit(range_h);
                            when 16 => tbuf(42+7)  <= ascii_digit(range_t);
                            when 17 => tbuf(42+8)  <= ascii_digit(range_o);
                            when 18 => tbuf(42+14) <= ascii_digit(age_h);
                            when 19 => tbuf(42+15) <= ascii_digit(age_t);
                            when 20 => tbuf(42+16) <= ascii_digit(age_o);

                            -- Line 3: severity at 5..8, LIM digits at 17..18.
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
                            state    <= S_RENDER_LOOKUP;
                        else
                            clr_cnt <= clr_cnt + 1;
                        end if;

                    -- Render runs in two clocks. First we read the
                    -- character byte out of tbuf and figure out the
                    -- framebuffer address. Then we use that latched
                    -- character to pick the right glyph column and
                    -- write the framebuffer. Doing both in one cycle
                    -- combined the tbuf array index AND the 256-way
                    -- font_glyph case in one path which was just too
                    -- much logic to fit in 8 ns.
                    when S_RENDER_LOOKUP =>
                        tbuf_char_q <= tbuf(rnd_page * CHARS_PER_LINE + rnd_char);
                        addr_q      <= to_unsigned(rnd_page * 128 + rnd_char * 6 + rnd_col, 9);
                        rnd_col_q   <= rnd_col;

                        if rnd_col = 4 then
                            rnd_col <= 0;
                            if rnd_char = CHARS_PER_LINE - 1 then
                                rnd_char <= 0;
                                if rnd_page = 3 then
                                    rnd_page <= 0;
                                else
                                    rnd_page <= rnd_page + 1;
                                end if;
                            else
                                rnd_char <= rnd_char + 1;
                            end if;
                        else
                            rnd_col <= rnd_col + 1;
                        end if;

                        state <= S_RENDER_WRITE;

                    when S_RENDER_WRITE =>
                        fb_we    <= '1';
                        fb_waddr <= addr_q;
                        fb_wdata <= font_glyph(tbuf_char_q)(rnd_col_q);

                        -- Done iff the counters wrapped back to (0,0,0).
                        if rnd_col = 0 and rnd_char = 0 and rnd_page = 0 then
                            rom_idx     <= INIT_LEN;
                            rom_idx_end <= ROM_LEN;
                            state       <= S_RUN_TX_PREFIX_LOAD;
                        else
                            state       <= S_RENDER_LOOKUP;
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
