-------------------------------------------------------------------------------
-- tb_tile_rasterizer.vhd
-- Testbench: Tile-Based Rasterizer
-- Tests triangle rasterization with edge functions
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_tile_rasterizer is
end entity tb_tile_rasterizer;

architecture sim of tb_tile_rasterizer is
    
    constant CLK_PERIOD : time := 10 ns;
    constant TILE_SIZE : integer := 16;
    constant FRAC_BITS : integer := 16;
    
    -- DUT signals
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    
    -- Tile position
    signal tile_x       : std_logic_vector(7 downto 0) := (others => '0');
    signal tile_y       : std_logic_vector(7 downto 0) := (others => '0');
    
    -- Triangle input
    signal tri_valid    : std_logic := '0';
    signal tri_ready    : std_logic;
    
    -- Vertex positions (screen space, 16.16 fixed point)
    signal v0_x, v0_y, v0_z : std_logic_vector(31 downto 0) := (others => '0');
    signal v1_x, v1_y, v1_z : std_logic_vector(31 downto 0) := (others => '0');
    signal v2_x, v2_y, v2_z : std_logic_vector(31 downto 0) := (others => '0');
    
    -- Vertex attributes (texture coords)
    signal v0_u, v0_v   : std_logic_vector(31 downto 0) := (others => '0');
    signal v1_u, v1_v   : std_logic_vector(31 downto 0) := (others => '0');
    signal v2_u, v2_v   : std_logic_vector(31 downto 0) := (others => '0');
    
    -- Vertex colors
    signal v0_color     : std_logic_vector(31 downto 0) := x"FF0000FF";  -- Red
    signal v1_color     : std_logic_vector(31 downto 0) := x"00FF00FF";  -- Green
    signal v2_color     : std_logic_vector(31 downto 0) := x"0000FFFF";  -- Blue
    
    -- Fragment output
    signal frag_valid   : std_logic;
    signal frag_ready   : std_logic := '1';
    signal frag_x       : std_logic_vector(15 downto 0);
    signal frag_y       : std_logic_vector(15 downto 0);
    signal frag_z       : std_logic_vector(23 downto 0);
    signal frag_u       : std_logic_vector(31 downto 0);
    signal frag_v       : std_logic_vector(31 downto 0);
    signal frag_color   : std_logic_vector(31 downto 0);
    
    -- Status
    signal triangle_done : std_logic;
    signal fragments_out : std_logic_vector(15 downto 0);
    
    -- Control
    signal sim_done : boolean := false;
    
    -- Fragment counter
    signal frag_count : integer := 0;
    
    -- Helper: Convert integer to 16.16 fixed point
    function to_fixed(val : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(val * 65536, 32));
    end function;
    
    -- Helper: Convert real to 16.16 fixed point
    function to_fixed_real(val : real) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(integer(val * 65536.0), 32));
    end function;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not sim_done;
    
    -- DUT
    u_rasterizer : entity work.tile_rasterizer
        generic map (
            TILE_SIZE => TILE_SIZE,
            FRAC_BITS => FRAC_BITS
        )
        port map (
            clk          => clk,
            rst_n        => rst_n,
            tile_x       => tile_x,
            tile_y       => tile_y,
            tri_valid    => tri_valid,
            tri_ready    => tri_ready,
            v0_x         => v0_x,
            v0_y         => v0_y,
            v0_z         => v0_z,
            v1_x         => v1_x,
            v1_y         => v1_y,
            v1_z         => v1_z,
            v2_x         => v2_x,
            v2_y         => v2_y,
            v2_z         => v2_z,
            v0_u         => v0_u,
            v0_v         => v0_v,
            v1_u         => v1_u,
            v1_v         => v1_v,
            v2_u         => v2_u,
            v2_v         => v2_v,
            v0_color     => v0_color,
            v1_color     => v1_color,
            v2_color     => v2_color,
            frag_valid   => frag_valid,
            frag_ready   => frag_ready,
            frag_x       => frag_x,
            frag_y       => frag_y,
            frag_z       => frag_z,
            frag_u       => frag_u,
            frag_v       => frag_v,
            frag_color   => frag_color,
            triangle_done => triangle_done,
            fragments_out => fragments_out
        );
    
    -- Fragment counter process
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                frag_count <= 0;
            elsif frag_valid = '1' and frag_ready = '1' then
                frag_count <= frag_count + 1;
            end if;
        end if;
    end process;
    
    -- Test process
    process
    begin
        report "=== Tile Rasterizer Test ===" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 1: Small triangle in tile 0,0
        -- Triangle with vertices at (2,2), (14,2), (8,12)
        -- Should cover roughly half the 16x16 tile
        -----------------------------------------------------------------------
        report "--- Test 1: Small Triangle ---" severity note;
        
        tile_x <= x"00";
        tile_y <= x"00";
        
        -- Set triangle vertices (16.16 fixed point)
        v0_x <= to_fixed(2);   v0_y <= to_fixed(2);   v0_z <= to_fixed(100);
        v1_x <= to_fixed(14);  v1_y <= to_fixed(2);   v1_z <= to_fixed(100);
        v2_x <= to_fixed(8);   v2_y <= to_fixed(12);  v2_z <= to_fixed(100);
        
        -- Set texture coordinates
        v0_u <= to_fixed(0);  v0_v <= to_fixed(0);
        v1_u <= to_fixed(1);  v1_v <= to_fixed(0);
        v2_u <= to_fixed_real(0.5);  v2_v <= to_fixed(1);
        
        -- Set colors (RGB)
        v0_color <= x"FF0000FF";  -- Red
        v1_color <= x"00FF00FF";  -- Green
        v2_color <= x"0000FFFF";  -- Blue
        
        -- Start triangle
        wait until tri_ready = '1';
        tri_valid <= '1';
        wait for CLK_PERIOD;
        tri_valid <= '0';
        
        -- Wait for completion
        wait until triangle_done = '1' for CLK_PERIOD * 1000;
        
        report "Test 1: Generated " & integer'image(to_integer(unsigned(fragments_out))) & " fragments"
            severity note;
        
        -- A triangle with vertices (2,2), (14,2), (8,12) should generate
        -- approximately (base * height / 2) = (12 * 10 / 2) = 60 pixels
        if to_integer(unsigned(fragments_out)) > 20 then
            report "PASS: Test 1 - Rasterized triangle" severity note;
        else
            report "FAIL: Test 1 - Too few fragments" severity error;
        end if;
        
        wait for CLK_PERIOD * 10;
        
        -----------------------------------------------------------------------
        -- Test 2: Full tile triangle
        -- Triangle that covers the entire tile
        -----------------------------------------------------------------------
        report "--- Test 2: Full Tile Triangle ---" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        tile_x <= x"00";
        tile_y <= x"00";
        
        -- Large triangle covering entire tile
        v0_x <= to_fixed(-5);  v0_y <= to_fixed(-5);  v0_z <= to_fixed(50);
        v1_x <= to_fixed(20);  v1_y <= to_fixed(-5);  v1_z <= to_fixed(50);
        v2_x <= to_fixed(8);   v2_y <= to_fixed(20);  v2_z <= to_fixed(50);
        
        v0_u <= to_fixed(0);  v0_v <= to_fixed(0);
        v1_u <= to_fixed(1);  v1_v <= to_fixed(0);
        v2_u <= to_fixed_real(0.5);  v2_v <= to_fixed(1);
        
        wait until tri_ready = '1';
        tri_valid <= '1';
        wait for CLK_PERIOD;
        tri_valid <= '0';
        
        wait until triangle_done = '1' for CLK_PERIOD * 1000;
        
        report "Test 2: Generated " & integer'image(to_integer(unsigned(fragments_out))) & " fragments"
            severity note;
        
        -- Large triangle should cover most of the 16x16 = 256 pixel tile
        if to_integer(unsigned(fragments_out)) > 200 then
            report "PASS: Test 2 - Full tile coverage" severity note;
        else
            report "FAIL: Test 2 - Expected more coverage" severity error;
        end if;
        
        wait for CLK_PERIOD * 10;
        
        -----------------------------------------------------------------------
        -- Test 3: Triangle outside tile (should generate 0 fragments)
        -----------------------------------------------------------------------
        report "--- Test 3: Triangle Outside Tile ---" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        tile_x <= x"00";
        tile_y <= x"00";
        
        -- Triangle entirely outside tile 0,0 (in tile 2,2)
        v0_x <= to_fixed(32);  v0_y <= to_fixed(32);  v0_z <= to_fixed(50);
        v1_x <= to_fixed(48);  v1_y <= to_fixed(32);  v1_z <= to_fixed(50);
        v2_x <= to_fixed(40);  v2_y <= to_fixed(48);  v2_z <= to_fixed(50);
        
        wait until tri_ready = '1';
        tri_valid <= '1';
        wait for CLK_PERIOD;
        tri_valid <= '0';
        
        wait until triangle_done = '1' for CLK_PERIOD * 1000;
        
        report "Test 3: Generated " & integer'image(to_integer(unsigned(fragments_out))) & " fragments"
            severity note;
        
        if to_integer(unsigned(fragments_out)) = 0 then
            report "PASS: Test 3 - No fragments for outside triangle" severity note;
        else
            report "FAIL: Test 3 - Should have 0 fragments" severity error;
        end if;
        
        wait for CLK_PERIOD * 10;
        
        -----------------------------------------------------------------------
        -- Test 4: Degenerate triangle (line)
        -----------------------------------------------------------------------
        report "--- Test 4: Degenerate Triangle ---" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        tile_x <= x"00";
        tile_y <= x"00";
        
        -- Line (degenerate triangle)
        v0_x <= to_fixed(2);  v0_y <= to_fixed(2);  v0_z <= to_fixed(50);
        v1_x <= to_fixed(14); v1_y <= to_fixed(14); v1_z <= to_fixed(50);
        v2_x <= to_fixed(8);  v2_y <= to_fixed(8);  v2_z <= to_fixed(50);
        
        wait until tri_ready = '1';
        tri_valid <= '1';
        wait for CLK_PERIOD;
        tri_valid <= '0';
        
        wait until triangle_done = '1' for CLK_PERIOD * 1000;
        
        report "Test 4: Generated " & integer'image(to_integer(unsigned(fragments_out))) & " fragments"
            severity note;
        
        -- Degenerate triangle has zero area, should generate 0 fragments
        if to_integer(unsigned(fragments_out)) = 0 then
            report "PASS: Test 4 - Degenerate triangle handled" severity note;
        else
            report "WARN: Test 4 - Degenerate may produce some fragments" severity warning;
        end if;
        
        -----------------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------------
        wait for CLK_PERIOD * 5;
        report "=== Tile Rasterizer Test Complete ===" severity note;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
