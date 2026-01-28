-------------------------------------------------------------------------------
-- tb_etc_decoder.vhd
-- Testbench for ETC1/ETC2 Block Decoder
-- Tests the etc_block_decoder which outputs all 16 texels in parallel
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_etc_decoder is
end entity tb_etc_decoder;

architecture sim of tb_etc_decoder is

    constant CLK_PERIOD : time := 10 ns;
    
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    
    signal valid_in     : std_logic := '0';
    signal ready_out    : std_logic;
    signal format       : std_logic_vector(1 downto 0) := "00";
    signal block_rgb    : std_logic_vector(63 downto 0) := (others => '0');
    signal block_alpha  : std_logic_vector(63 downto 0) := (others => '0');
    
    signal valid_out    : std_logic;
    signal rgba_out     : std_logic_vector(16*32-1 downto 0);
    
    signal test_done    : boolean := false;
    
    -- Extract RGBA from output for texel at (x, y)
    function get_texel(data : std_logic_vector(16*32-1 downto 0); 
                       x, y : integer) return std_logic_vector is
        variable idx : integer;
    begin
        idx := y * 4 + x;
        return data((idx+1)*32-1 downto idx*32);
    end function;
    
    -- Extract individual channel
    function get_r(texel : std_logic_vector(31 downto 0)) return integer is
    begin
        return to_integer(unsigned(texel(31 downto 24)));
    end function;
    
    function get_g(texel : std_logic_vector(31 downto 0)) return integer is
    begin
        return to_integer(unsigned(texel(23 downto 16)));
    end function;
    
    function get_b(texel : std_logic_vector(31 downto 0)) return integer is
    begin
        return to_integer(unsigned(texel(15 downto 8)));
    end function;
    
    function get_a(texel : std_logic_vector(31 downto 0)) return integer is
    begin
        return to_integer(unsigned(texel(7 downto 0)));
    end function;

begin

    ---------------------------------------------------------------------------
    -- DUT: ETC Block Decoder (16 texels parallel output)
    ---------------------------------------------------------------------------
    dut: entity work.etc_block_decoder
        port map (
            clk         => clk,
            rst_n       => rst_n,
            valid_in    => valid_in,
            ready_out   => ready_out,
            format      => format,
            block_rgb   => block_rgb,
            block_alpha => block_alpha,
            valid_out   => valid_out,
            rgba_out    => rgba_out
        );
    
    ---------------------------------------------------------------------------
    -- Clock Generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD/2 when not test_done else '0';
    
    ---------------------------------------------------------------------------
    -- Main Test Process
    ---------------------------------------------------------------------------
    process
        variable texel : std_logic_vector(31 downto 0);
        variable r, g, b, a : integer;
        
        procedure print_block is
        begin
            report "  4x4 Block decoded:";
            for y in 0 to 3 loop
                texel := get_texel(rgba_out, 0, y);
                report "    Row " & integer'image(y) & ": " &
                       "(" & integer'image(get_r(texel)) & "," &
                       integer'image(get_g(texel)) & "," &
                       integer'image(get_b(texel)) & ") " &
                       "(" & integer'image(get_r(get_texel(rgba_out, 1, y))) & "," &
                       integer'image(get_g(get_texel(rgba_out, 1, y))) & "," &
                       integer'image(get_b(get_texel(rgba_out, 1, y))) & ") " &
                       "(" & integer'image(get_r(get_texel(rgba_out, 2, y))) & "," &
                       integer'image(get_g(get_texel(rgba_out, 2, y))) & "," &
                       integer'image(get_b(get_texel(rgba_out, 2, y))) & ") " &
                       "(" & integer'image(get_r(get_texel(rgba_out, 3, y))) & "," &
                       integer'image(get_g(get_texel(rgba_out, 3, y))) & "," &
                       integer'image(get_b(get_texel(rgba_out, 3, y))) & ")";
            end loop;
        end procedure;
        
        procedure submit_block(blk : std_logic_vector(63 downto 0)) is
        begin
            wait until rising_edge(clk) and ready_out = '1';
            block_rgb <= blk;
            valid_in <= '1';
            wait until rising_edge(clk);
            valid_in <= '0';
            wait until rising_edge(clk) and valid_out = '1';
        end procedure;
        
    begin
        report "=== ETC Block Decoder Testbench ===" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 1: ETC1 Differential Mode - Solid color
        -----------------------------------------------------------------------
        report "Test 1: Differential mode - Bright red base" severity note;
        
        -- Differential mode (bit 33 = 1), no flip (bit 32 = 0)
        -- R0 = 31 (5-bit), dR = 0, G0 = 0, dG = 0, B0 = 0, dB = 0
        -- Table indices = 0 (smallest modifiers)
        -- All pixels use modifier index 0 (MSB=0, LSB=0) -> modifier = +2
        --
        -- Bits 63-59: R0 = 11111 = 31
        -- Bits 58-56: dR = 000 = 0
        -- Bits 55-51: G0 = 00000 = 0
        -- Bits 50-48: dG = 000 = 0
        -- Bits 47-43: B0 = 00000 = 0
        -- Bits 42-40: dB = 000 = 0
        -- Bits 39-37: Table0 = 000 = 0
        -- Bits 36-34: Table1 = 000 = 0
        -- Bit 33: Diff = 1
        -- Bit 32: Flip = 0
        -- Bits 31-16: MSBs = 0 (all modifier index MSB = 0)
        -- Bits 15-0: LSBs = 0 (all modifier index LSB = 0)
        
        format <= "00";  -- ETC1
        submit_block(x"F800000200000000");
        
        report "Test 1 Results:";
        print_block;
        
        -- Check corner texel (0,0)
        texel := get_texel(rgba_out, 0, 0);
        r := get_r(texel);
        g := get_g(texel);
        b := get_b(texel);
        a := get_a(texel);
        report "  Texel (0,0): R=" & integer'image(r) & " G=" & integer'image(g) & 
               " B=" & integer'image(b) & " A=" & integer'image(a);
        
        -- R should be bright (31 expanded to 8-bit = 255, + modifier 2 = 255 clamped)
        assert r > 200 report "Red channel too low!" severity warning;
        assert a = 255 report "Alpha should be 255 for ETC1" severity warning;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Test 2: ETC1 Individual Mode - Two different colors
        -----------------------------------------------------------------------
        report "Test 2: Individual mode - Green/Blue split" severity note;
        
        -- Individual mode (bit 33 = 0), flip = 0 (left/right)
        -- R0=0, G0=15, B0=0 (left half - green)
        -- R1=0, G1=0, B1=15 (right half - blue)
        --
        -- Bits 63-60: R0 = 0000
        -- Bits 59-56: R1 = 0000
        -- Bits 55-52: G0 = 1111 = 15
        -- Bits 51-48: G1 = 0000
        -- Bits 47-44: B0 = 0000
        -- Bits 43-40: B1 = 1111 = 15
        -- Bits 39-37: Table0 = 000
        -- Bits 36-34: Table1 = 000
        -- Bit 33: Diff = 0
        -- Bit 32: Flip = 0
        -- Bits 31-0: All zero (modifier index 0)
        
        format <= "00";
        submit_block(x"00F000F000000000");
        
        report "Test 2 Results:";
        print_block;
        
        -- Left side (x=0,1) should be greenish
        texel := get_texel(rgba_out, 0, 0);
        report "  Texel (0,0) LEFT: R=" & integer'image(get_r(texel)) & 
               " G=" & integer'image(get_g(texel)) & " B=" & integer'image(get_b(texel));
        
        -- Right side (x=2,3) should be bluish  
        texel := get_texel(rgba_out, 3, 0);
        report "  Texel (3,0) RIGHT: R=" & integer'image(get_r(texel)) & 
               " G=" & integer'image(get_g(texel)) & " B=" & integer'image(get_b(texel));
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Test 3: ETC1 with Flip bit - Top/Bottom split
        -----------------------------------------------------------------------
        report "Test 3: Differential mode with flip - Top/Bottom" severity note;
        
        -- Differential mode, flip = 1 (top/bottom split)
        -- Top half: white-ish (R=31, G=31, B=31)
        -- Bottom half: darker (R=31-4=27, G=31-4=27, B=31-4=27)
        --
        -- Bits 63-59: R0 = 11111 = 31
        -- Bits 58-56: dR = 100 = -4 (signed)
        -- Bits 55-51: G0 = 11111 = 31
        -- Bits 50-48: dG = 100 = -4
        -- Bits 47-43: B0 = 11111 = 31  
        -- Bits 42-40: dB = 100 = -4
        -- Bits 39-37: Table0 = 001 = 1
        -- Bits 36-34: Table1 = 001 = 1
        -- Bit 33: Diff = 1
        -- Bit 32: Flip = 1
        -- Bits 31-0: Zero (modifier 0)
        
        format <= "00";
        submit_block(x"FC7C7C2600000000");
        
        report "Test 3 Results:";
        print_block;
        
        -- Top (y=0,1) should be brighter than bottom (y=2,3)
        texel := get_texel(rgba_out, 0, 0);
        report "  Texel (0,0) TOP: R=" & integer'image(get_r(texel)) & 
               " G=" & integer'image(get_g(texel)) & " B=" & integer'image(get_b(texel));
        
        texel := get_texel(rgba_out, 0, 3);
        report "  Texel (0,3) BOTTOM: R=" & integer'image(get_r(texel)) & 
               " G=" & integer'image(get_g(texel)) & " B=" & integer'image(get_b(texel));
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Test 4: Verify modifier table application
        -----------------------------------------------------------------------
        report "Test 4: Modifier table variation" severity note;
        
        -- Differential mode, uniform color, but different pixel indices
        -- Base: mid-gray (R=16, G=16, B=16)
        -- Table index 4 has modifiers: 18, 60, -18, -60
        -- Pixel indices vary: 0=bright, 1=brighter, 2=dark, 3=darker
        --
        -- Set pixel indices to create visible gradient:
        -- Row 0: all index 0 (moderate bright)
        -- Row 1: all index 1 (very bright)
        -- Row 2: all index 2 (moderate dark)
        -- Row 3: all index 3 (very dark)
        
        format <= "00";
        -- R=16, dR=0, G=16, dG=0, B=16, dB=0, Table=4, Diff=1, Flip=0
        -- Pixel MSBs: 0000 0000 1111 1111 (rows 2,3 have MSB=1)
        -- Pixel LSBs: 0000 1111 0000 1111 (rows 1,3 have LSB=1)
        submit_block(x"8421094200FF00FF");
        
        report "Test 4 Results (gradient from modifiers):";
        print_block;
        
        -----------------------------------------------------------------------
        -- Done
        -----------------------------------------------------------------------
        wait for CLK_PERIOD * 10;
        
        report "=== ETC Block Decoder Tests Complete ===" severity note;
        
        test_done <= true;
        wait;
    end process;

end architecture sim;
