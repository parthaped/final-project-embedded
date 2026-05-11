-- tmds_encoder.vhd
--   8b/10b TMDS encoder for one DVI/HDMI colour channel.
--   ref: DVI 1.0 specification section 3.2.2 (transition-minimised then
--        DC-balanced); fpga4fun.com "HDMI from VGA RGB" walkthrough was
--        the readable version I worked from.
--
--   For active video we minimise transitions (XOR or XNOR the byte into
--   q_m), then pick whether to invert q_m so the running DC bias stays
--   near zero. During blanking we send one of four fixed control
--   symbols, where the D0 (Blue) channel carries hsync/vsync as c0/c1.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tmds_encoder is
    port (
        clk_pixel : in  std_logic;
        rst       : in  std_logic;
        d         : in  std_logic_vector(7 downto 0);
        c0        : in  std_logic;
        c1        : in  std_logic;
        de        : in  std_logic;
        q_out     : out std_logic_vector(9 downto 0)
    );
end entity;

architecture rtl of tmds_encoder is

    function popcount8 (v : std_logic_vector(7 downto 0)) return integer is
        variable n : integer := 0;
    begin
        for i in 0 to 7 loop
            if v(i) = '1' then n := n + 1; end if;
        end loop;
        return n;
    end function;

    signal bias  : signed(4 downto 0) := (others => '0');
    signal q_r   : std_logic_vector(9 downto 0) := (others => '0');

begin

    process(clk_pixel)
        variable d_v        : std_logic_vector(7 downto 0);
        variable n1d        : integer range 0 to 8;
        variable use_xnor   : boolean;
        variable q_m        : std_logic_vector(8 downto 0);
        variable n1q, n0q   : integer range 0 to 8;
        variable diff_qm    : signed(4 downto 0);
        variable q_o        : std_logic_vector(9 downto 0);
        variable b          : signed(4 downto 0);
    begin
        if rising_edge(clk_pixel) then
            if rst = '1' then
                bias <= (others => '0');
                q_r  <= (others => '0');
            else
                if de = '0' then
                    case std_logic_vector'(c1 & c0) is
                        when "00"   => q_o := "1101010100";
                        when "01"   => q_o := "0010101011";
                        when "10"   => q_o := "0101010100";
                        when others => q_o := "1010101011";
                    end case;
                    bias <= (others => '0');
                    q_r  <= q_o;
                else
                    d_v := d;
                    n1d := popcount8(d_v);

                    if n1d > 4 or (n1d = 4 and d_v(0) = '0') then
                        use_xnor := true;
                    else
                        use_xnor := false;
                    end if;

                    q_m(0) := d_v(0);
                    if use_xnor then
                        for i in 1 to 7 loop
                            q_m(i) := q_m(i-1) xnor d_v(i);
                        end loop;
                        q_m(8) := '0';
                    else
                        for i in 1 to 7 loop
                            q_m(i) := q_m(i-1) xor d_v(i);
                        end loop;
                        q_m(8) := '1';
                    end if;

                    n1q := popcount8(q_m(7 downto 0));
                    n0q := 8 - n1q;
                    diff_qm := to_signed(n1q - n0q, 5);
                    b       := bias;

                    if b = 0 or n1q = n0q then
                        q_o(9) := not q_m(8);
                        q_o(8) := q_m(8);
                        if q_m(8) = '0' then
                            q_o(7 downto 0) := not q_m(7 downto 0);
                            b := b + (-diff_qm);
                        else
                            q_o(7 downto 0) := q_m(7 downto 0);
                            b := b + diff_qm;
                        end if;
                    elsif (b > 0 and n1q > n0q) or (b < 0 and n0q > n1q) then
                        q_o(9) := '1';
                        q_o(8) := q_m(8);
                        q_o(7 downto 0) := not q_m(7 downto 0);
                        if q_m(8) = '1' then
                            b := b + to_signed(2, 5) + (-diff_qm);
                        else
                            b := b + (-diff_qm);
                        end if;
                    else
                        q_o(9) := '0';
                        q_o(8) := q_m(8);
                        q_o(7 downto 0) := q_m(7 downto 0);
                        if q_m(8) = '0' then
                            b := b - to_signed(2, 5) + diff_qm;
                        else
                            b := b + diff_qm;
                        end if;
                    end if;

                    bias <= b;
                    q_r  <= q_o;
                end if;
            end if;
        end if;
    end process;

    q_out <= q_r;

end architecture;
