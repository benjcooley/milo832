-------------------------------------------------------------------------------
-- tb_render_image.vhd
-- Testbench: Renders triangles to a framebuffer and outputs PPM image
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_render_image is
end entity tb_render_image;

architecture sim of tb_render_image is
    
    constant CLK_PERIOD : time := 10 ns;
    constant TILE_SIZE : integer := 16;
    constant FRAC_BITS : integer := 16;
    constant FB_WIDTH : integer := 64;
    constant FB_HEIGHT : integer := 64;
    
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
    
    -- Framebuffer (RGB, 8 bits per channel)
    type fb_line_t is array (0 to FB_WIDTH-1) of std_logic_vector(23 downto 0);
    type fb_t is array (0 to FB_HEIGHT-1) of fb_line_t;
    signal framebuffer : fb_t := (others => (others => x"000000"));  -- Black background
    
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
    
    -- Procedure to write PPM file
    procedure write_ppm(
        constant filename : in string;
        signal fb : in fb_t
    ) is
        file ppm_file : text;
        variable line_buf : line;
        variable pixel : std_logic_vector(23 downto 0);
        variable r, g, b : integer;
    begin
        file_open(ppm_file, filename, write_mode);
        
        -- PPM header
        write(line_buf, string'("P3"));
        writeline(ppm_file, line_buf);
        write(line_buf, FB_WIDTH);
        write(line_buf, string'(" "));
        write(line_buf, FB_HEIGHT);
        writeline(ppm_file, line_buf);
        write(line_buf, string'("255"));
        writeline(ppm_file, line_buf);
        
        -- Pixel data
        for y in 0 to FB_HEIGHT-1 loop
            for x in 0 to FB_WIDTH-1 loop
                pixel := fb(y)(x);
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
    end procedure;

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
    
    -- Fragment to framebuffer process
    process(clk)
        variable px, py : integer;
    begin
        if rising_edge(clk) then
            if frag_valid = '1' and frag_ready = '1' then
                px := to_integer(unsigned(frag_x));
                py := to_integer(unsigned(frag_y));
                if px >= 0 and px < FB_WIDTH and py >= 0 and py < FB_HEIGHT then
                    -- Store RGB (skip alpha)
                    framebuffer(py)(px) <= frag_color(31 downto 8);
                end if;
            end if;
        end if;
    end process;
    
    -- Test process
    process
        variable tx, ty : integer;
    begin
        report "=== Render Image Test ===" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Render a colorful triangle
        -- Red at top, Green at bottom-left, Blue at bottom-right
        -----------------------------------------------------------------------
        report "Rendering gradient triangle..." severity note;
        
        -- Triangle vertices covering tiles 0-3 in X and Y
        v0_x <= to_fixed(32);  v0_y <= to_fixed(5);   v0_z <= to_fixed(100);  -- Top center
        v1_x <= to_fixed(5);   v1_y <= to_fixed(58);  v1_z <= to_fixed(100);  -- Bottom left
        v2_x <= to_fixed(58);  v2_y <= to_fixed(58);  v2_z <= to_fixed(100);  -- Bottom right
        
        v0_color <= x"FF0000FF";  -- Red
        v1_color <= x"00FF00FF";  -- Green
        v2_color <= x"0000FFFF";  -- Blue
        
        -- Render triangle to all tiles that could contain it
        for ty in 0 to FB_HEIGHT/TILE_SIZE - 1 loop
            for tx in 0 to FB_WIDTH/TILE_SIZE - 1 loop
                tile_x <= std_logic_vector(to_unsigned(tx, 8));
                tile_y <= std_logic_vector(to_unsigned(ty, 8));
                
                wait until tri_ready = '1';
                tri_valid <= '1';
                wait for CLK_PERIOD;
                tri_valid <= '0';
                
                wait until triangle_done = '1' for CLK_PERIOD * 500;
                
                if triangle_done /= '1' then
                    report "Timeout on tile " & integer'image(tx) & "," & integer'image(ty) severity warning;
                end if;
                
                wait for CLK_PERIOD * 2;
            end loop;
        end loop;
        
        report "Triangle rendered, writing PPM..." severity note;
        
        -- Write output image
        write_ppm("tb/output_triangle.ppm", framebuffer);
        
        report "Output written to tb/output_triangle.ppm" severity note;
        
        -----------------------------------------------------------------------
        -- Second triangle (yellow/cyan/magenta)
        -----------------------------------------------------------------------
        report "Rendering second triangle..." severity note;
        
        -- Clear framebuffer for second render
        for y in 0 to FB_HEIGHT-1 loop
            for x in 0 to FB_WIDTH-1 loop
                framebuffer(y)(x) <= x"202020";  -- Dark gray background
            end loop;
        end loop;
        wait for CLK_PERIOD;
        
        -- Different triangle
        v0_x <= to_fixed(10);  v0_y <= to_fixed(10);  v0_z <= to_fixed(50);
        v1_x <= to_fixed(50);  v1_y <= to_fixed(20);  v1_z <= to_fixed(50);
        v2_x <= to_fixed(30);  v2_y <= to_fixed(50);  v2_z <= to_fixed(50);
        
        v0_color <= x"FFFF00FF";  -- Yellow
        v1_color <= x"00FFFFFF";  -- Cyan
        v2_color <= x"FF00FFFF";  -- Magenta
        
        for ty in 0 to FB_HEIGHT/TILE_SIZE - 1 loop
            for tx in 0 to FB_WIDTH/TILE_SIZE - 1 loop
                tile_x <= std_logic_vector(to_unsigned(tx, 8));
                tile_y <= std_logic_vector(to_unsigned(ty, 8));
                
                wait until tri_ready = '1';
                tri_valid <= '1';
                wait for CLK_PERIOD;
                tri_valid <= '0';
                
                wait until triangle_done = '1' for CLK_PERIOD * 500;
                wait for CLK_PERIOD * 2;
            end loop;
        end loop;
        
        write_ppm("tb/output_triangle2.ppm", framebuffer);
        report "Second output written to tb/output_triangle2.ppm" severity note;
        
        -----------------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------------
        report "=== Render Image Test Complete ===" severity note;
        report "View images with: open tb/output_triangle.ppm tb/output_triangle2.ppm" severity note;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
