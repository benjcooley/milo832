-------------------------------------------------------------------------------
-- tb_render_cube.vhd
-- Rotating Solid Cube Render
-- Renders a 3D cube with colored faces, outputs animation frames
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity tb_render_cube is
end entity tb_render_cube;

architecture sim of tb_render_cube is
    
    constant CLK_PERIOD : time := 10 ns;
    constant TILE_SIZE : integer := 16;
    constant FB_WIDTH : integer := 128;
    constant FB_HEIGHT : integer := 128;
    constant FRAC_BITS : integer := 16;
    constant NUM_FRAMES : integer := 30;
    
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
    signal v0_color     : std_logic_vector(31 downto 0) := (others => '0');
    signal v1_color     : std_logic_vector(31 downto 0) := (others => '0');
    signal v2_color     : std_logic_vector(31 downto 0) := (others => '0');
    
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
    
    -- 3D vertex type
    type vertex_3d_t is record
        x, y, z : real;
    end record;
    type vertex_array_t is array (natural range <>) of vertex_3d_t;
    
    -- Cube vertices
    constant CUBE_VERTS : vertex_array_t(0 to 7) := (
        (x => -1.0, y => -1.0, z => -1.0),
        (x =>  1.0, y => -1.0, z => -1.0),
        (x =>  1.0, y =>  1.0, z => -1.0),
        (x => -1.0, y =>  1.0, z => -1.0),
        (x => -1.0, y => -1.0, z =>  1.0),
        (x =>  1.0, y => -1.0, z =>  1.0),
        (x =>  1.0, y =>  1.0, z =>  1.0),
        (x => -1.0, y =>  1.0, z =>  1.0)
    );
    
    -- Face indices (2 triangles per face)
    type face_indices_t is array (0 to 5) of integer;
    type face_array_t is array (0 to 5) of face_indices_t;
    constant CUBE_FACES : face_array_t := (
        (4, 5, 6, 4, 6, 7),  -- Front
        (1, 0, 3, 1, 3, 2),  -- Back
        (0, 4, 7, 0, 7, 3),  -- Left
        (5, 1, 2, 5, 2, 6),  -- Right
        (7, 6, 2, 7, 2, 3),  -- Top
        (0, 1, 5, 0, 5, 4)   -- Bottom
    );
    
    -- Face colors
    type color_array_t is array (0 to 5) of std_logic_vector(31 downto 0);
    constant FACE_COLORS : color_array_t := (
        x"FF4444FF", x"44FF44FF", x"4444FFFF",
        x"FFFF44FF", x"FF44FFFF", x"44FFFFFF"
    );
    
    -- Framebuffer types
    type color_buffer_t is array (0 to FB_WIDTH*FB_HEIGHT-1) of std_logic_vector(23 downto 0);
    type depth_buffer_t is array (0 to FB_WIDTH*FB_HEIGHT-1) of integer;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done;
    
    u_rasterizer : entity work.tile_rasterizer
        generic map (TILE_SIZE => TILE_SIZE, FRAC_BITS => FRAC_BITS)
        port map (
            clk => clk, rst_n => rst_n,
            tile_x => tile_x, tile_y => tile_y,
            tri_valid => tri_valid, tri_ready => tri_ready,
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
    
    -- Single process for everything
    process
        file ppm_file : text;
        variable line_buf : line;
        variable r, g, b : integer;
        
        -- Framebuffers as variables (single process owns them)
        variable color_buffer : color_buffer_t;
        variable depth_buffer : depth_buffer_t;
        variable total_frags : integer := 0;
        
        -- Transform variables
        variable transformed : vertex_array_t(0 to 7);
        variable angle_x, angle_y : real;
        variable sin_x, cos_x, sin_y, cos_y : real;
        variable temp_x, temp_y, temp_z, proj_x, proj_y, proj_z : real;
        variable sx0, sy0, sz0, sx1, sy1, sz1, sx2, sy2, sz2 : integer;
        variable nz : real;
        
        function to_fixed(val : integer) return std_logic_vector is
        begin
            return std_logic_vector(to_signed(val * 65536, 32));
        end function;
        
        procedure render_triangle(
            x0, y0, z0, x1, y1, z1, x2, y2, z2 : integer;
            color : std_logic_vector(31 downto 0)
        ) is
            variable min_x, max_x, min_y, max_y : integer;
            variable min_tile_x, max_tile_x, min_tile_y, max_tile_y : integer;
            variable px, py, idx, frag_depth : integer;
        begin
            min_x := minimum(minimum(x0, x1), x2);
            max_x := maximum(maximum(x0, x1), x2);
            min_y := minimum(minimum(y0, y1), y2);
            max_y := maximum(maximum(y0, y1), y2);
            
            if max_x < 0 or min_x >= FB_WIDTH or max_y < 0 or min_y >= FB_HEIGHT then
                return;
            end if;
            
            if min_x < 0 then min_x := 0; end if;
            if max_x >= FB_WIDTH then max_x := FB_WIDTH - 1; end if;
            if min_y < 0 then min_y := 0; end if;
            if max_y >= FB_HEIGHT then max_y := FB_HEIGHT - 1; end if;
            
            min_tile_x := min_x / TILE_SIZE;
            max_tile_x := max_x / TILE_SIZE;
            min_tile_y := min_y / TILE_SIZE;
            max_tile_y := max_y / TILE_SIZE;
            
            v0_x <= to_fixed(x0); v0_y <= to_fixed(y0); v0_z <= to_fixed(z0);
            v1_x <= to_fixed(x1); v1_y <= to_fixed(y1); v1_z <= to_fixed(z1);
            v2_x <= to_fixed(x2); v2_y <= to_fixed(y2); v2_z <= to_fixed(z2);
            v0_color <= color; v1_color <= color; v2_color <= color;
            
            for ty in min_tile_y to max_tile_y loop
                for tx in min_tile_x to max_tile_x loop
                    tile_x <= std_logic_vector(to_unsigned(tx, 8));
                    tile_y <= std_logic_vector(to_unsigned(ty, 8));
                    
                    if tri_ready /= '1' then
                        wait until tri_ready = '1';
                    end if;
                    
                    wait until rising_edge(clk);
                    tri_valid <= '1';
                    wait until rising_edge(clk);
                    tri_valid <= '0';
                    
                    -- Collect fragments while rasterizing
                    while triangle_done /= '1' loop
                        wait until rising_edge(clk);
                        if frag_valid = '1' then
                            px := to_integer(unsigned(frag_x));
                            py := to_integer(unsigned(frag_y));
                            idx := py * FB_WIDTH + px;
                            frag_depth := to_integer(unsigned(frag_z));
                            
                            if idx >= 0 and idx < FB_WIDTH*FB_HEIGHT then
                                if frag_depth > depth_buffer(idx) then
                                    color_buffer(idx) := frag_color(31 downto 8);
                                    depth_buffer(idx) := frag_depth;
                                end if;
                                total_frags := total_frags + 1;
                            end if;
                        end if;
                    end loop;
                    
                    wait until rising_edge(clk);
                end loop;
            end loop;
        end procedure;
        
        procedure write_frame(frame_num : integer) is
            variable fname : string(1 to 25);
            variable d0, d1, d2 : integer;
        begin
            fname := "frames/cube_frame_000.ppm";
            d0 := frame_num / 100;
            d1 := (frame_num / 10) mod 10;
            d2 := frame_num mod 10;
            fname(19) := character'val(character'pos('0') + d0);
            fname(20) := character'val(character'pos('0') + d1);
            fname(21) := character'val(character'pos('0') + d2);
            
            file_open(ppm_file, fname, write_mode);
            write(line_buf, string'("P3")); writeline(ppm_file, line_buf);
            write(line_buf, FB_WIDTH); write(line_buf, string'(" ")); 
            write(line_buf, FB_HEIGHT); writeline(ppm_file, line_buf);
            write(line_buf, string'("255")); writeline(ppm_file, line_buf);
            
            for y in 0 to FB_HEIGHT-1 loop
                for x in 0 to FB_WIDTH-1 loop
                    r := to_integer(unsigned(color_buffer(y * FB_WIDTH + x)(23 downto 16)));
                    g := to_integer(unsigned(color_buffer(y * FB_WIDTH + x)(15 downto 8)));
                    b := to_integer(unsigned(color_buffer(y * FB_WIDTH + x)(7 downto 0)));
                    write(line_buf, r); write(line_buf, string'(" "));
                    write(line_buf, g); write(line_buf, string'(" "));
                    write(line_buf, b); write(line_buf, string'(" "));
                end loop;
                writeline(ppm_file, line_buf);
            end loop;
            file_close(ppm_file);
        end procedure;
        
    begin
        report "=== Rotating Cube Render ===" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        for frame in 0 to NUM_FRAMES-1 loop
            report "Frame " & integer'image(frame) severity note;
            
            -- Clear buffers
            for i in 0 to FB_WIDTH*FB_HEIGHT-1 loop
                color_buffer(i) := x"1A1A2E";
                depth_buffer(i) := -1000000;
            end loop;
            
            -- Rotation
            angle_y := real(frame) * 12.0 * MATH_PI / 180.0;  -- Full rotation in 30 frames
            angle_x := real(frame) * 4.0 * MATH_PI / 180.0;
            sin_x := sin(angle_x); cos_x := cos(angle_x);
            sin_y := sin(angle_y); cos_y := cos(angle_y);
            
            -- Transform vertices
            for i in 0 to 7 loop
                temp_x := CUBE_VERTS(i).x;
                temp_y := CUBE_VERTS(i).y;
                temp_z := CUBE_VERTS(i).z;
                
                proj_x := temp_x * cos_y + temp_z * sin_y;
                proj_z := -temp_x * sin_y + temp_z * cos_y;
                temp_x := proj_x; temp_z := proj_z;
                
                proj_y := temp_y * cos_x - temp_z * sin_x;
                proj_z := temp_y * sin_x + temp_z * cos_x;
                temp_y := proj_y; temp_z := proj_z;
                
                temp_z := temp_z + 4.0;
                if temp_z > 0.1 then
                    proj_x := temp_x * 50.0 / temp_z;
                    proj_y := temp_y * 50.0 / temp_z;
                else
                    proj_x := temp_x * 500.0;
                    proj_y := temp_y * 500.0;
                end if;
                
                transformed(i).x := proj_x + real(FB_WIDTH/2);
                transformed(i).y := proj_y + real(FB_HEIGHT/2);
                transformed(i).z := temp_z * 100.0;
            end loop;
            
            -- Render faces
            for face in 0 to 5 loop
                sx0 := integer(transformed(CUBE_FACES(face)(0)).x);
                sy0 := integer(transformed(CUBE_FACES(face)(0)).y);
                sz0 := integer(transformed(CUBE_FACES(face)(0)).z);
                sx1 := integer(transformed(CUBE_FACES(face)(1)).x);
                sy1 := integer(transformed(CUBE_FACES(face)(1)).y);
                sz1 := integer(transformed(CUBE_FACES(face)(1)).z);
                sx2 := integer(transformed(CUBE_FACES(face)(2)).x);
                sy2 := integer(transformed(CUBE_FACES(face)(2)).y);
                sz2 := integer(transformed(CUBE_FACES(face)(2)).z);
                
                nz := real((sx1 - sx0) * (sy2 - sy0) - (sy1 - sy0) * (sx2 - sx0));
                
                if nz > 0.0 then
                    render_triangle(sx0, sy0, sz0, sx1, sy1, sz1, sx2, sy2, sz2, FACE_COLORS(face));
                    
                    sx0 := integer(transformed(CUBE_FACES(face)(3)).x);
                    sy0 := integer(transformed(CUBE_FACES(face)(3)).y);
                    sz0 := integer(transformed(CUBE_FACES(face)(3)).z);
                    sx1 := integer(transformed(CUBE_FACES(face)(4)).x);
                    sy1 := integer(transformed(CUBE_FACES(face)(4)).y);
                    sz1 := integer(transformed(CUBE_FACES(face)(4)).z);
                    sx2 := integer(transformed(CUBE_FACES(face)(5)).x);
                    sy2 := integer(transformed(CUBE_FACES(face)(5)).y);
                    sz2 := integer(transformed(CUBE_FACES(face)(5)).z);
                    
                    render_triangle(sx0, sy0, sz0, sx1, sy1, sz1, sx2, sy2, sz2, FACE_COLORS(face));
                end if;
            end loop;
            
            write_frame(frame);
        end loop;
        
        report "=== Complete ===" severity note;
        report "Total frags: " & integer'image(total_frags) severity note;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
