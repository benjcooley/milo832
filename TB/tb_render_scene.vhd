-------------------------------------------------------------------------------
-- tb_render_scene.vhd
-- Full Scene Render Test
-- Renders multiple triangles to a 64x64 framebuffer and outputs PPM
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_render_scene is
end entity tb_render_scene;

architecture sim of tb_render_scene is
    
    constant CLK_PERIOD : time := 10 ns;
    constant TILE_SIZE : integer := 16;
    constant FB_WIDTH : integer := 64;
    constant FB_HEIGHT : integer := 64;
    constant FRAC_BITS : integer := 16;
    
    -- DUT signals
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    
    signal tile_x       : std_logic_vector(7 downto 0) := (others => '0');
    signal tile_y       : std_logic_vector(7 downto 0) := (others => '0');
    signal tri_valid    : std_logic := '0';
    signal tri_ready    : std_logic;
    
    signal v0_x, v0_y, v0_z : std_logic_vector(31 downto 0) := (others => '0');
    signal v1_x, v1_y, v1_z : std_logic_vector(31 downto 0) := (others => '0');
    signal v2_x, v2_y, v2_z : std_logic_vector(31 downto 0) := (others => '0');
    signal v0_u, v0_v   : std_logic_vector(31 downto 0) := (others => '0');
    signal v1_u, v1_v   : std_logic_vector(31 downto 0) := (others => '0');
    signal v2_u, v2_v   : std_logic_vector(31 downto 0) := (others => '0');
    signal v0_color     : std_logic_vector(31 downto 0) := x"FF0000FF";
    signal v1_color     : std_logic_vector(31 downto 0) := x"00FF00FF";
    signal v2_color     : std_logic_vector(31 downto 0) := x"0000FFFF";
    
    signal frag_valid   : std_logic;
    signal frag_ready   : std_logic := '1';
    signal frag_x       : std_logic_vector(15 downto 0);
    signal frag_y       : std_logic_vector(15 downto 0);
    signal frag_z       : std_logic_vector(23 downto 0);
    signal frag_u       : std_logic_vector(31 downto 0);
    signal frag_v       : std_logic_vector(31 downto 0);
    signal frag_color   : std_logic_vector(31 downto 0);
    signal triangle_done : std_logic;
    signal fragments_out : std_logic_vector(15 downto 0);
    
    signal sim_done : boolean := false;
    signal total_frags : integer := 0;
    
    -- Full framebuffer (64x64 RGB)
    type framebuffer_t is array (0 to FB_WIDTH*FB_HEIGHT-1) of std_logic_vector(23 downto 0);
    signal framebuffer : framebuffer_t := (others => x"202040");  -- Dark blue background
    
    -- Helper: Convert integer to 16.16 fixed point
    function to_fixed(val : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(val * 65536, 32));
    end function;
    
    -- Triangle data type
    type triangle_t is record
        x0, y0, x1, y1, x2, y2 : integer;
        c0, c1, c2 : std_logic_vector(31 downto 0);
    end record;

begin

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
            v0_x => v0_x, v0_y => v0_y, v0_z => v0_z,
            v1_x => v1_x, v1_y => v1_y, v1_z => v1_z,
            v2_x => v2_x, v2_y => v2_y, v2_z => v2_z,
            v0_u => v0_u, v0_v => v0_v,
            v1_u => v1_u, v1_v => v1_v,
            v2_u => v2_u, v2_v => v2_v,
            v0_color => v0_color, v1_color => v1_color, v2_color => v2_color,
            frag_valid => frag_valid, frag_ready => frag_ready,
            frag_x => frag_x, frag_y => frag_y, frag_z => frag_z,
            frag_u => frag_u, frag_v => frag_v, frag_color => frag_color,
            triangle_done => triangle_done, fragments_out => fragments_out
        );
    
    -- Fragment capture process
    process(clk)
        variable px, py, idx : integer;
    begin
        if rising_edge(clk) then
            if frag_valid = '1' and frag_ready = '1' then
                px := to_integer(unsigned(frag_x));
                py := to_integer(unsigned(frag_y));
                idx := py * FB_WIDTH + px;
                if idx >= 0 and idx < FB_WIDTH*FB_HEIGHT then
                    framebuffer(idx) <= frag_color(31 downto 8);
                    total_frags <= total_frags + 1;
                end if;
            end if;
        end if;
    end process;
    
    -- Test process
    process
        file ppm_file : text;
        variable line_buf : line;
        variable pixel : std_logic_vector(23 downto 0);
        variable r, g, b : integer;
        variable tx, ty : integer;
        
        -- Procedure to render a triangle across all tiles it overlaps
        procedure render_triangle(
            x0, y0, x1, y1, x2, y2 : integer;
            c0, c1, c2 : std_logic_vector(31 downto 0)
        ) is
            variable min_x, max_x, min_y, max_y : integer;
            variable min_tile_x, max_tile_x, min_tile_y, max_tile_y : integer;
        begin
            -- Find bounding box
            min_x := minimum(minimum(x0, x1), x2);
            max_x := maximum(maximum(x0, x1), x2);
            min_y := minimum(minimum(y0, y1), y2);
            max_y := maximum(maximum(y0, y1), y2);
            
            -- Convert to tile coordinates
            min_tile_x := min_x / TILE_SIZE;
            max_tile_x := max_x / TILE_SIZE;
            min_tile_y := min_y / TILE_SIZE;
            max_tile_y := max_y / TILE_SIZE;
            
            -- Clamp to framebuffer
            if min_tile_x < 0 then min_tile_x := 0; end if;
            if max_tile_x >= FB_WIDTH/TILE_SIZE then max_tile_x := FB_WIDTH/TILE_SIZE - 1; end if;
            if min_tile_y < 0 then min_tile_y := 0; end if;
            if max_tile_y >= FB_HEIGHT/TILE_SIZE then max_tile_y := FB_HEIGHT/TILE_SIZE - 1; end if;
            
            -- Set vertex data
            v0_x <= to_fixed(x0); v0_y <= to_fixed(y0); v0_z <= to_fixed(100);
            v1_x <= to_fixed(x1); v1_y <= to_fixed(y1); v1_z <= to_fixed(100);
            v2_x <= to_fixed(x2); v2_y <= to_fixed(y2); v2_z <= to_fixed(100);
            v0_color <= c0; v1_color <= c1; v2_color <= c2;
            
            -- Render to each overlapping tile
            for ty in min_tile_y to max_tile_y loop
                for tx in min_tile_x to max_tile_x loop
                    tile_x <= std_logic_vector(to_unsigned(tx, 8));
                    tile_y <= std_logic_vector(to_unsigned(ty, 8));
                    
                    -- Wait for ready
                    if tri_ready /= '1' then
                        wait until tri_ready = '1';
                    end if;
                    
                    -- Submit triangle
                    wait until rising_edge(clk);
                    tri_valid <= '1';
                    wait until rising_edge(clk);
                    tri_valid <= '0';
                    
                    -- Wait for completion
                    wait until triangle_done = '1' for CLK_PERIOD * 2000;
                    
                    if triangle_done /= '1' then
                        report "Timeout on tile " & integer'image(tx) & "," & integer'image(ty) severity warning;
                    end if;
                    
                    wait until rising_edge(clk);
                end loop;
            end loop;
        end procedure;
        
    begin
        report "=== Full Scene Render Test ===" severity note;
        report "Framebuffer: " & integer'image(FB_WIDTH) & "x" & integer'image(FB_HEIGHT) severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -- Triangle 1: Large red/green/blue triangle in center
        report "Rendering triangle 1: RGB gradient" severity note;
        render_triangle(
            32, 4,    -- top center
            4, 56,    -- bottom left  
            60, 56,   -- bottom right
            x"FF0000FF",  -- Red
            x"00FF00FF",  -- Green
            x"0000FFFF"   -- Blue
        );
        
        -- Triangle 2: Yellow triangle top-left
        report "Rendering triangle 2: Yellow" severity note;
        render_triangle(
            2, 2,
            2, 20,
            20, 20,
            x"FFFF00FF",  -- Yellow
            x"FF8800FF",  -- Orange
            x"FFAA00FF"   -- Gold
        );
        
        -- Triangle 3: Cyan triangle top-right
        report "Rendering triangle 3: Cyan" severity note;
        render_triangle(
            62, 2,
            44, 20,
            62, 20,
            x"00FFFFFF",  -- Cyan
            x"00AAFFFF",  -- Light blue
            x"00FFAAFF"   -- Aqua
        );
        
        -- Triangle 4: Magenta small triangle
        report "Rendering triangle 4: Magenta" severity note;
        render_triangle(
            28, 25,
            24, 35,
            36, 35,
            x"FF00FFFF",  -- Magenta
            x"AA00AAFF",  -- Purple
            x"FF44FFFF"   -- Pink
        );
        
        -- Triangle 5: White triangle
        report "Rendering triangle 5: White" severity note;
        render_triangle(
            48, 30,
            40, 45,
            56, 45,
            x"FFFFFFFF",  -- White
            x"CCCCCCFF",  -- Light gray
            x"EEEEEEFF"   -- Near white
        );
        
        report "Total fragments rendered: " & integer'image(total_frags) severity note;
        
        wait for CLK_PERIOD * 10;
        
        -- Write PPM output
        report "Writing PPM file..." severity note;
        file_open(ppm_file, "rendered_scene.ppm", write_mode);
        
        write(line_buf, string'("P3"));
        writeline(ppm_file, line_buf);
        write(line_buf, FB_WIDTH);
        write(line_buf, string'(" "));
        write(line_buf, FB_HEIGHT);
        writeline(ppm_file, line_buf);
        write(line_buf, string'("255"));
        writeline(ppm_file, line_buf);
        
        for y in 0 to FB_HEIGHT-1 loop
            for x in 0 to FB_WIDTH-1 loop
                pixel := framebuffer(y * FB_WIDTH + x);
                r := to_integer(unsigned(pixel(23 downto 16)));
                g := to_integer(unsigned(pixel(15 downto 8)));
                b := to_integer(unsigned(pixel(7 downto 0)));
                write(line_buf, r);
                write(line_buf, string'(" "));
                write(line_buf, g);
                write(line_buf, string'(" "));
                write(line_buf, b);
                write(line_buf, string'(" "));
            end loop;
            writeline(ppm_file, line_buf);
        end loop;
        
        file_close(ppm_file);
        
        report "=== Render Complete ===" severity note;
        report "Output: rendered_scene.ppm (" & integer'image(FB_WIDTH) & "x" & integer'image(FB_HEIGHT) & ")" severity note;
        report "Total fragments: " & integer'image(total_frags) severity note;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
