-- ============================================================================
-- history_buffer.vhd
--   640-deep one-sample-per-frame circular buffer of past sensor state.
--   Each entry packs:
--       bits  7..0  :  range_in (inches; 0 = no sample)
--       bits 15..8  :  als_value (lux 0..255)
--       bits 17..16 :  ambient_mode      ( 00 NIGHT  01 DIM  10 DAY  11 BRIGHT )
--       bits 19..18 :  severity of any contact event that landed in this column
--       bit  20     :  event flag        (1 = a contact was logged this frame)
--       bits 31..21 :  reserved (BRAM stores 32-bit words)
--   Total 32 b/entry x 640 = 20_480 b -> one 36 Kb BRAM (BRAM36).  The
--   read port latency (1 clk_pixel) is easily absorbed by the renderer
--   pipeline.
--
--   Lives entirely in `clk_pixel`.  All input signals are expected to
--   have been re-synchronised from `clk_sys` to `clk_pixel` by the
--   parent (top_threat_system).  `log_pulse_pixel` is a 1-cycle toggle
--   of the FSM's log_pulse already in pixel domain; `sev_value` is the
--   severity to record when that pulse fires.
--
--   The "frame tick" is the rising edge of `vsync_in`.  Each frame the
--   buffer writes the current sample at write_addr, then advances.  A
--   sticky `ev_pending` register captures *any* log pulse that occurred
--   during the active frame so a brief 1-cycle pulse can't fall through
--   the cracks.
--
--   Read port: column index 0..639.  Column 0 = oldest sample (left edge
--   of strip chart); column 639 = newest (right edge).  Entry at column
--   N maps to memory index (write_addr + N) mod 640.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity history_buffer is
    generic (
        N_COLS : positive := 640
    );
    port (
        clk_pixel        : in  std_logic;
        rst              : in  std_logic;

        -- Live sensor state (already CDC'd into clk_pixel).
        range_in         : in  unsigned(7 downto 0);
        als_value        : in  unsigned(7 downto 0);
        ambient_mode     : in  unsigned(1 downto 0);
        log_pulse_pixel  : in  std_logic;
        sev_value        : in  unsigned(1 downto 0);

        vsync_in         : in  std_logic;       -- VGA timing vsync (active low)

        -- Read port.  rd_data appears one clk_pixel cycle after rd_col
        -- changes (synchronous BRAM read).
        rd_col           : in  unsigned(9 downto 0);

        rd_range         : out unsigned(7 downto 0);
        rd_als           : out unsigned(7 downto 0);
        rd_ambient       : out unsigned(1 downto 0);
        rd_severity      : out unsigned(1 downto 0);
        rd_event         : out std_logic
    );
end entity;

architecture rtl of history_buffer is
    constant ADDR_BITS : positive := 10;       -- N_COLS <= 1024
    constant DATA_BITS : positive := 32;

    type ram_t is array (0 to N_COLS-1) of std_logic_vector(DATA_BITS-1 downto 0);
    signal ram : ram_t := (others => (others => '0'));

    signal wr_addr   : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
    signal vsync_d   : std_logic := '1';

    -- Sticky event captured during the active portion of the frame.
    signal ev_pending  : std_logic := '0';
    signal sev_pending : unsigned(1 downto 0) := (others => '0');

    -- Read pipeline.
    signal rd_addr_r : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
    signal rd_data_r : std_logic_vector(DATA_BITS-1 downto 0) := (others => '0');

    -- Tell the synthesizer to infer block-RAM rather than distributed.
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";
begin

    -- =========================================================================
    -- Write side: latch any log_pulse during the frame, write the
    -- current sample at end-of-frame (vsync rising edge), then advance.
    -- =========================================================================
    process(clk_pixel)
        variable wdat : std_logic_vector(DATA_BITS-1 downto 0);
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                wr_addr     <= (others => '0');
                vsync_d     <= '1';
                ev_pending  <= '0';
                sev_pending <= (others => '0');
            else
                vsync_d <= vsync_in;

                -- Latch event during the frame.  When two pulses arrive
                -- in the same frame, the latest severity wins -- which
                -- is fine for a strip-chart tick; the contact_log holds
                -- the authoritative event list anyway.
                if log_pulse_pixel = '1' then
                    ev_pending  <= '1';
                    sev_pending <= sev_value;
                end if;

                -- End of vsync pulse (low -> high) is "start of new
                -- frame" -- safe place to commit the previous frame's
                -- sample because timing/active-video is back to running.
                if vsync_d = '0' and vsync_in = '1' then
                    wdat(7 downto 0)   := std_logic_vector(range_in);
                    wdat(15 downto 8)  := std_logic_vector(als_value);
                    wdat(17 downto 16) := std_logic_vector(ambient_mode);
                    wdat(19 downto 18) := std_logic_vector(sev_pending);
                    wdat(20)           := ev_pending;
                    wdat(31 downto 21) := (others => '0');

                    ram(to_integer(wr_addr)) <= wdat;

                    if wr_addr = to_unsigned(N_COLS-1, ADDR_BITS) then
                        wr_addr <= (others => '0');
                    else
                        wr_addr <= wr_addr + 1;
                    end if;

                    ev_pending  <= '0';
                    sev_pending <= (others => '0');
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Read side: rd_col -> memory index = (wr_addr + rd_col) mod N_COLS
    -- Read addr is registered once for synthesis-friendly synchronous BRAM.
    -- =========================================================================
    process(clk_pixel)
        variable sum : unsigned(ADDR_BITS downto 0);
    begin
        if rising_edge(clk_pixel) then
            sum := resize(wr_addr, ADDR_BITS+1) + resize(rd_col, ADDR_BITS+1);
            if sum >= to_unsigned(N_COLS, ADDR_BITS+1) then
                rd_addr_r <= resize(sum - to_unsigned(N_COLS, ADDR_BITS+1),
                                    ADDR_BITS);
            else
                rd_addr_r <= resize(sum, ADDR_BITS);
            end if;

            rd_data_r <= ram(to_integer(rd_addr_r));
        end if;
    end process;

    rd_range    <= unsigned(rd_data_r(7 downto 0));
    rd_als      <= unsigned(rd_data_r(15 downto 8));
    rd_ambient  <= unsigned(rd_data_r(17 downto 16));
    rd_severity <= unsigned(rd_data_r(19 downto 18));
    rd_event    <= rd_data_r(20);

end architecture;
