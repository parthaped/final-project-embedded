-- ============================================================================
-- pmod_oled_top.vhd
--   Drives a Digilent Pmod OLED (SSD1306, 128x32) attached to JB.
--
--   * Sequences the SSD1306 power-up:
--         VDD on  ->  RES low  ->  RES high  ->  send pre-charge-pump init
--      ->  VBAT on  ->  send post-charge-pump init  ->  display on.
--   * Maintains a 4 x 21-character text buffer that mirrors the live
--     state_code, distance_in, als_value and severity inputs.
--   * Renders the text buffer into a 512-byte BRAM framebuffer using the
--     5x8 font.
--   * Streams the framebuffer to the OLED at ~30 Hz over the simple
--     `oled_spi_master`.
--
--   The whole thing is a single composite FSM so that timing between the
--   power supplies, reset, and the SPI traffic stays unambiguous.
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
        clk          : in  std_logic;
        rst          : in  std_logic;

        state_code   : in  std_logic_vector(2 downto 0);
        distance_in  : in  unsigned(15 downto 0);
        als_value    : in  unsigned(15 downto 0);
        severity     : in  std_logic_vector(1 downto 0);

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
    -- =========================================================================
    -- Constants
    -- =========================================================================
    constant CYCLES_PER_MS  : positive := SYS_HZ / 1000;
    constant T_VDD_WAIT     : positive := CYCLES_PER_MS * 1;     -- 1 ms
    constant T_RES_LOW      : positive := CYCLES_PER_MS * 1;     -- 1 ms
    constant T_RES_HIGH     : positive := CYCLES_PER_MS * 1;     -- 1 ms
    constant T_VBAT_WAIT    : positive := CYCLES_PER_MS * 100;   -- 100 ms
    constant T_REFRESH      : positive := SYS_HZ / REFRESH_HZ;

    -- The init ROM splits at INIT_PRE_END:
    --   indices 0..INIT_PRE_END-1 are sent before VBAT comes on.
    --   indices INIT_PRE_END..INIT_LEN-1 are sent after VBAT comes on.
    constant INIT_PRE_END   : integer := 10;     -- through "charge pump enable"

    constant CHARS_PER_LINE : integer := 21;
    constant LINES          : integer := 4;
    constant TBUF_LEN       : integer := CHARS_PER_LINE * LINES; -- 84

    -- =========================================================================
    -- Top-level sequencer FSM
    -- =========================================================================
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

    -- =========================================================================
    -- Power outputs (registered)
    -- =========================================================================
    signal vdd_n_r  : std_logic := '1';
    signal vbat_n_r : std_logic := '1';
    signal res_n_r  : std_logic := '0';

    -- =========================================================================
    -- Timer (one big counter, reused for every wait period)
    -- =========================================================================
    signal timer    : unsigned(31 downto 0) := (others => '0');
    signal timer_target : unsigned(31 downto 0) := (others => '0');

    -- Refresh tick generator
    signal refresh_pulse : std_logic;

    -- =========================================================================
    -- ROM byte streamer pointer
    -- =========================================================================
    signal rom_idx     : integer range 0 to ROM_LEN := 0;
    signal rom_idx_end : integer range 0 to ROM_LEN := 0;

    -- =========================================================================
    -- SPI master interface
    -- =========================================================================
    signal spi_start : std_logic := '0';
    signal spi_dc    : std_logic := '0';
    signal spi_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal spi_busy  : std_logic;

    -- =========================================================================
    -- Text buffer (84 chars)
    -- =========================================================================
    type tbuf_t is array (0 to TBUF_LEN-1) of std_logic_vector(7 downto 0);
    signal tbuf : tbuf_t := (others => x"20");          -- spaces

    -- The static template; positions 7..14 of line 0, 9..11 of line 1,
    -- 7..9 of line 2, and 7 of line 3 are overwritten with live data.
    type tbuf_const_t is array (0 to TBUF_LEN-1) of character;
    constant TEMPLATE : tbuf_const_t := (
        -- Line 0: "STATE:                "  (positions 7..14 are state name)
        'S','T','A','T','E',':',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',
        -- Line 1: "DIST:    XXX IN     "  (positions 9..11 are digits, 13..14 = "IN")
        'D','I','S','T',':',' ',' ',' ',' ',' ',' ',' ',' ','I','N',' ',' ',' ',' ',' ',' ',
        -- Line 2: "LUX:   XXX           "  (positions 7..9 are digits)
        'L','U','X',':',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',
        -- Line 3: "SEV:   X             "  (position 7 is severity)
        'S','E','V',':',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' '
    );

    -- =========================================================================
    -- Framebuffer interface
    -- =========================================================================
    signal fb_we    : std_logic := '0';
    signal fb_waddr : unsigned(8 downto 0) := (others => '0');
    signal fb_wdata : std_logic_vector(7 downto 0) := (others => '0');
    signal fb_raddr : unsigned(8 downto 0) := (others => '0');
    signal fb_rdata : std_logic_vector(7 downto 0);

    -- =========================================================================
    -- FILL sub-sequencer (computes text into tbuf)
    -- =========================================================================
    signal fill_cnt : integer range 0 to 31 := 0;
    -- Decimal-conversion scratch
    signal dist_q   : unsigned(15 downto 0) := (others => '0');
    signal dist_h   : unsigned(3 downto 0)  := (others => '0');
    signal dist_t   : unsigned(3 downto 0)  := (others => '0');
    signal dist_o   : unsigned(3 downto 0)  := (others => '0');
    signal lux_q    : unsigned(15 downto 0) := (others => '0');
    signal lux_h    : unsigned(3 downto 0)  := (others => '0');
    signal lux_t    : unsigned(3 downto 0)  := (others => '0');
    signal lux_o    : unsigned(3 downto 0)  := (others => '0');

    -- =========================================================================
    -- CLEAR / RENDER sub-counters
    -- =========================================================================
    signal clr_cnt   : unsigned(9 downto 0) := (others => '0');   -- 0..512
    signal rnd_page  : integer range 0 to 3 := 0;
    signal rnd_char  : integer range 0 to CHARS_PER_LINE := 0;
    signal rnd_col   : integer range 0 to 4 := 0;

    -- =========================================================================
    -- DATA streamer (read-from-FB / send) sub-counters
    -- =========================================================================
    signal data_cnt  : unsigned(9 downto 0) := (others => '0');   -- 0..512
    signal data_phase : unsigned(1 downto 0) := (others => '0');  -- read latency tracker

    -- =========================================================================
    -- Helpers
    -- =========================================================================
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
            when "100" => s := ('A','L','E','R','T',' ',' ',' ');
            when "101" => s := ('C','L','A','S','S','I','F','Y');
            when others => s := ('?',' ',' ',' ',' ',' ',' ',' ');
        end case;
        return std_logic_vector(to_unsigned(character'pos(s(idx)), 8));
    end function;

    function ascii_digit (d : unsigned(3 downto 0)) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(character'pos('0') + to_integer(d), 8));
    end function;

begin

    -- =========================================================================
    -- Refresh-tick generator
    -- =========================================================================
    refresh_gen : entity work.pulse_gen
        generic map ( PERIOD_CYCLES => T_REFRESH )
        port map ( clk => clk, rst => rst, en => '1', pulse => refresh_pulse );

    -- =========================================================================
    -- SPI master
    -- =========================================================================
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

    -- =========================================================================
    -- Framebuffer
    -- =========================================================================
    fb_inst : entity work.oled_framebuffer
        port map (
            clk   => clk,
            we    => fb_we,
            waddr => fb_waddr,
            wdata => fb_wdata,
            raddr => fb_raddr,
            rdata => fb_rdata );

    -- Power outputs
    oled_vdd_n  <= vdd_n_r;
    oled_vbat_n <= vbat_n_r;
    oled_res_n  <= res_n_r;

    -- =========================================================================
    -- Decimal conversion (combinational; small enough for 8-bit / 16-bit)
    -- =========================================================================
    process(distance_in, als_value)
        variable d : integer;
        variable l : integer;
    begin
        d := to_integer(distance_in);
        if d > 999 then d := 999; end if;
        dist_h <= to_unsigned(d / 100, 4);
        dist_t <= to_unsigned((d / 10) mod 10, 4);
        dist_o <= to_unsigned(d mod 10, 4);

        l := to_integer(als_value);
        if l > 999 then l := 999; end if;
        lux_h <= to_unsigned(l / 100, 4);
        lux_t <= to_unsigned((l / 10) mod 10, 4);
        lux_o <= to_unsigned(l mod 10, 4);
    end process;

    -- =========================================================================
    -- Main sequencer
    -- =========================================================================
    process(clk)
        variable next_idx : integer;
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
                tbuf          <= (others => x"20");
                -- Initialize tbuf with TEMPLATE
                for i in 0 to TBUF_LEN-1 loop
                    tbuf(i) <=
                        std_logic_vector(to_unsigned(character'pos(TEMPLATE(i)), 8));
                end loop;
            else
                spi_start <= '0';
                fb_we     <= '0';

                case state is

                    -- ----------------------------------------------------
                    -- Power-up sequencing
                    -- ----------------------------------------------------
                    when S_RESET_HOLD =>
                        vdd_n_r  <= '1';
                        vbat_n_r <= '1';
                        res_n_r  <= '0';
                        if timer = timer_target - 1 then
                            timer        <= (others => '0');
                            timer_target <= to_unsigned(T_VDD_WAIT, 32);
                            vdd_n_r      <= '0';      -- VDD on
                            state        <= S_VDD_ON;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_VDD_ON =>
                        if timer = timer_target - 1 then
                            timer        <= (others => '0');
                            timer_target <= to_unsigned(T_RES_LOW, 32);
                            res_n_r      <= '0';      -- pulse RES low
                            state        <= S_RES_LOW;
                        else
                            timer <= timer + 1;
                        end if;

                    when S_RES_LOW =>
                        if timer = timer_target - 1 then
                            timer        <= (others => '0');
                            timer_target <= to_unsigned(T_RES_HIGH, 32);
                            res_n_r      <= '1';      -- release RES
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

                    -- ----------------------------------------------------
                    -- Send init bytes 0..INIT_PRE_END-1 (commands)
                    -- ----------------------------------------------------
                    when S_TX_INIT_PRE_LOAD =>
                        if rom_idx = rom_idx_end then
                            -- finished pre-init; turn on VBAT and wait.
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

                    -- ----------------------------------------------------
                    -- Send init bytes INIT_PRE_END..INIT_LEN-1
                    -- ----------------------------------------------------
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
                    -- Run loop:  wait tick -> fill text -> clear FB ->
                    --            render -> send prefix -> send data -> tick
                    -- ----------------------------------------------------
                    when S_RUN_WAIT_TICK =>
                        if refresh_pulse = '1' then
                            fill_cnt <= 0;
                            state    <= S_RUN_FILL_TEXT;
                        end if;

                    when S_RUN_FILL_TEXT =>
                        case fill_cnt is
                            -- State name: 8 chars at line0 positions 7..14
                            when 0 =>  tbuf(7)  <= state_name(state_code, 0);
                            when 1 =>  tbuf(8)  <= state_name(state_code, 1);
                            when 2 =>  tbuf(9)  <= state_name(state_code, 2);
                            when 3 =>  tbuf(10) <= state_name(state_code, 3);
                            when 4 =>  tbuf(11) <= state_name(state_code, 4);
                            when 5 =>  tbuf(12) <= state_name(state_code, 5);
                            when 6 =>  tbuf(13) <= state_name(state_code, 6);
                            when 7 =>  tbuf(14) <= state_name(state_code, 7);
                            -- Distance: 3 digits at line1 positions 9..11
                            when 8  => tbuf(21 + 9)  <= ascii_digit(dist_h);
                            when 9  => tbuf(21 + 10) <= ascii_digit(dist_t);
                            when 10 => tbuf(21 + 11) <= ascii_digit(dist_o);
                            -- Lux: 3 digits at line2 positions 7..9
                            when 11 => tbuf(42 + 7)  <= ascii_digit(lux_h);
                            when 12 => tbuf(42 + 8)  <= ascii_digit(lux_t);
                            when 13 => tbuf(42 + 9)  <= ascii_digit(lux_o);
                            -- Severity: 1 digit at line3 position 7
                            when 14 => tbuf(63 + 7)  <=
                                std_logic_vector(to_unsigned(
                                    character'pos('0') + to_integer(unsigned(severity)), 8));
                            when others => null;
                        end case;
                        if fill_cnt = 15 then
                            clr_cnt <= (others => '0');
                            state   <= S_RUN_CLEAR_FB;
                        else
                            fill_cnt <= fill_cnt + 1;
                        end if;

                    -- Clear all 512 FB bytes to zero.
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

                    -- Walk (page, char, col) writing 5 glyph cols per char.
                    -- Spacing column (col 5) is left as 0 from the clear.
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
                                    -- Done rendering.
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

                    -- Send the per-frame prefix (col addr + page addr cmds).
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

                    -- Stream 512 bytes from FB to SSD1306 (DC=1 = data).
                    -- Use data_phase to handle the BRAM read latency:
                    --   phase 0:  set fb_raddr = data_cnt
                    --   phase 1:  byte appears on fb_rdata; latch + start SPI
                    --   phase 2:  wait for SPI not busy; bump data_cnt
                    when S_RUN_TX_DATA_LOAD =>
                        if data_cnt = to_unsigned(512, data_cnt'length) then
                            state <= S_RUN_WAIT_TICK;
                        else
                            case data_phase is
                                when "00" =>
                                    fb_raddr   <= data_cnt(8 downto 0);
                                    data_phase <= "01";
                                when "01" =>
                                    -- BRAM read latency = 1 cycle, so rdata
                                    -- is now valid.  Issue SPI transfer.
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
