-------------------------------------------------------------------------------
-- tb_rasterizer.vhd
-- Testbench for Triangle Rasterizer
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rasterizer is
end entity tb_rasterizer;

architecture sim of tb_rasterizer is

    -- Constants
    constant CLK_PERIOD : time := 10 ns;
    constant FRAC_BITS  : integer := 16;
    
    -- DUT signals
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    
    -- Triangle input
    signal tri_valid    : std_logic := '0';
    signal tri_ready    : std_logic;
    
    signal v0_x, v0_y, v0_z : std_logic_vector(31 downto 0);
    signal v1_x, v1_y, v1_z : std_logic_vector(31 downto 0);
    signal v2_x, v2_y, v2_z : std_logic_vector(31 downto 0);
    
    signal v0_u, v0_v : std_logic_vector(31 downto 0);
    signal v1_u, v1_v : std_logic_vector(31 downto 0);
    signal v2_u, v2_v : std_logic_vector(31 downto 0);
    
    signal v0_color, v1_color, v2_color : std_logic_vector(31 downto 0);
    
    -- Fragment output
    signal frag_valid   : std_logic;
    signal frag_ready   : std_logic := '1';
    signal frag_x       : std_logic_vector(15 downto 0);
    signal frag_y       : std_logic_vector(15 downto 0);
    signal frag_z       : std_logic_vector(31 downto 0);
    signal frag_u       : std_logic_vector(31 downto 0);
    signal frag_v       : std_logic_vector(31 downto 0);
    signal frag_color   : std_logic_vector(31 downto 0);
    
    -- Status
    signal busy         : std_logic;
    signal triangles_in : std_logic_vector(15 downto 0);
    signal fragments_out: std_logic_vector(31 downto 0);
    
    -- Helper function: Convert integer to fixed point
    function to_fixed(val : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(val * (2**FRAC_BITS), 32));
    end function;
    
    -- Fragment counter
    signal frag_count   : integer := 0;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD / 2;
    
    -- DUT instantiation
    dut: entity work.rasterizer
        generic map (
            SCREEN_WIDTH    => 640,
            SCREEN_HEIGHT   => 480,
            TILE_SIZE       => 16,
            FRAC_BITS       => FRAC_BITS,
            TRI_QUEUE_DEPTH => 32
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            
            tri_valid       => tri_valid,
            tri_ready       => tri_ready,
            
            v0_x            => v0_x,
            v0_y            => v0_y,
            v0_z            => v0_z,
            v1_x            => v1_x,
            v1_y            => v1_y,
            v1_z            => v1_z,
            v2_x            => v2_x,
            v2_y            => v2_y,
            v2_z            => v2_z,
            
            v0_u            => v0_u,
            v0_v            => v0_v,
            v1_u            => v1_u,
            v1_v            => v1_v,
            v2_u            => v2_u,
            v2_v            => v2_v,
            
            v0_color        => v0_color,
            v1_color        => v1_color,
            v2_color        => v2_color,
            
            frag_valid      => frag_valid,
            frag_ready      => frag_ready,
            frag_x          => frag_x,
            frag_y          => frag_y,
            frag_z          => frag_z,
            frag_u          => frag_u,
            frag_v          => frag_v,
            frag_color      => frag_color,
            
            busy            => busy,
            triangles_in    => triangles_in,
            fragments_out   => fragments_out
        );
    
    -- Fragment counter
    process(clk)
    begin
        if rising_edge(clk) then
            if frag_valid = '1' and frag_ready = '1' then
                frag_count <= frag_count + 1;
                report "Fragment " & integer'image(frag_count) & 
                       " at (" & integer'image(to_integer(unsigned(frag_x))) & 
                       ", " & integer'image(to_integer(unsigned(frag_y))) & ")";
            end if;
        end if;
    end process;
    
    -- Stimulus process
    stim_proc: process
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 10;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;
        
        report "=== Rasterizer Testbench Started ===";
        
        ---------------------------------------------------------------------------
        -- Test 1: Small triangle in center of screen
        ---------------------------------------------------------------------------
        report "Test 1: Small triangle";
        
        -- Triangle vertices (screen coordinates, fixed point)
        -- Vertex 0: (100, 100)
        v0_x <= to_fixed(100);
        v0_y <= to_fixed(100);
        v0_z <= to_fixed(50);
        
        -- Vertex 1: (150, 100)
        v1_x <= to_fixed(150);
        v1_y <= to_fixed(100);
        v1_z <= to_fixed(50);
        
        -- Vertex 2: (125, 150)
        v2_x <= to_fixed(125);
        v2_y <= to_fixed(150);
        v2_z <= to_fixed(50);
        
        -- Texture coordinates
        v0_u <= to_fixed(0);
        v0_v <= to_fixed(0);
        v1_u <= to_fixed(1);
        v1_v <= to_fixed(0);
        v2_u <= x"00008000";  -- 0.5 in fixed point
        v2_v <= to_fixed(1);
        
        -- Vertex colors (RGBA)
        v0_color <= x"FF0000FF";  -- Red
        v1_color <= x"00FF00FF";  -- Green
        v2_color <= x"0000FFFF";  -- Blue
        
        -- Submit triangle
        wait until rising_edge(clk);
        tri_valid <= '1';
        wait until rising_edge(clk) and tri_ready = '1';
        tri_valid <= '0';
        
        -- Wait for rasterization to complete
        wait until busy = '0';
        wait for CLK_PERIOD * 10;
        
        report "Test 1 complete: Generated " & integer'image(frag_count) & " fragments";
        
        ---------------------------------------------------------------------------
        -- Test 2: Larger triangle
        ---------------------------------------------------------------------------
        report "Test 2: Larger triangle";
        frag_count <= 0;
        
        -- Vertex 0: (50, 50)
        v0_x <= to_fixed(50);
        v0_y <= to_fixed(50);
        v0_z <= to_fixed(100);
        
        -- Vertex 1: (200, 50)
        v1_x <= to_fixed(200);
        v1_y <= to_fixed(50);
        v1_z <= to_fixed(100);
        
        -- Vertex 2: (125, 200)
        v2_x <= to_fixed(125);
        v2_y <= to_fixed(200);
        v2_z <= to_fixed(100);
        
        -- Submit triangle
        wait until rising_edge(clk);
        tri_valid <= '1';
        wait until rising_edge(clk) and tri_ready = '1';
        tri_valid <= '0';
        
        -- Wait for rasterization to complete
        wait until busy = '0';
        wait for CLK_PERIOD * 10;
        
        report "Test 2 complete: Generated " & integer'image(frag_count) & " fragments";
        
        ---------------------------------------------------------------------------
        -- Test 3: Degenerate triangle (zero area)
        ---------------------------------------------------------------------------
        report "Test 3: Degenerate triangle (collinear points)";
        frag_count <= 0;
        
        -- All points on a line
        v0_x <= to_fixed(100);
        v0_y <= to_fixed(100);
        v0_z <= to_fixed(50);
        
        v1_x <= to_fixed(150);
        v1_y <= to_fixed(100);
        v1_z <= to_fixed(50);
        
        v2_x <= to_fixed(200);
        v2_y <= to_fixed(100);
        v2_z <= to_fixed(50);
        
        -- Submit triangle
        wait until rising_edge(clk);
        tri_valid <= '1';
        wait until rising_edge(clk) and tri_ready = '1';
        tri_valid <= '0';
        
        -- Wait a bit (should reject quickly)
        wait for CLK_PERIOD * 20;
        
        report "Test 3 complete: Generated " & integer'image(frag_count) & " fragments (expected 0)";
        
        ---------------------------------------------------------------------------
        -- Done
        ---------------------------------------------------------------------------
        report "=== Rasterizer Testbench Complete ===";
        report "Total fragments output: " & integer'image(to_integer(unsigned(fragments_out)));
        
        wait for CLK_PERIOD * 100;
        std.env.stop;
    end process;

end architecture sim;
