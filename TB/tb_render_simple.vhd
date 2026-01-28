-------------------------------------------------------------------------------
-- tb_render_simple.vhd
-- Simplified testbench: Renders a single triangle tile and outputs PPM
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_render_simple is
end entity tb_render_simple;

architecture sim of tb_render_simple is
    
    constant CLK_PERIOD : time := 10 ns;
    constant TILE_SIZE : integer := 16;
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
    signal frag_count : integer := 0;
    
    -- 16x16 tile buffer (RGB)
    type tile_t is array (0 to 255) of std_logic_vector(23 downto 0);
    signal tile_buffer : tile_t := (others => x"000000");
    
    -- Helper: Convert integer to 16.16 fixed point
    function to_fixed(val : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(val * 65536, 32));
    end function;

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
                idx := py * TILE_SIZE + px;
                if idx >= 0 and idx < 256 then
                    tile_buffer(idx) <= frag_color(31 downto 8);
                    frag_count <= frag_count + 1;
                end if;
                report "Fragment at " & integer'image(px) & "," & integer'image(py) & 
                       " color=" & to_hstring(frag_color) severity note;
            end if;
        end if;
    end process;
    
    -- Test process
    process
        file ppm_file : text;
        variable line_buf : line;
        variable pixel : std_logic_vector(23 downto 0);
        variable r, g, b : integer;
    begin
        report "=== Simple Render Test ===" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -- Triangle covering most of tile 0,0 (16x16 pixels)
        -- Use integer coords within tile
        v0_x <= to_fixed(8);   v0_y <= to_fixed(2);   v0_z <= to_fixed(100);  -- Top center
        v1_x <= to_fixed(2);   v1_y <= to_fixed(14);  v1_z <= to_fixed(100);  -- Bottom left
        v2_x <= to_fixed(14);  v2_y <= to_fixed(14);  v2_z <= to_fixed(100);  -- Bottom right
        
        v0_color <= x"FF0000FF";  -- Red
        v1_color <= x"00FF00FF";  -- Green
        v2_color <= x"0000FFFF";  -- Blue
        
        tile_x <= x"00";
        tile_y <= x"00";
        
        report "Starting rasterization of tile 0,0" severity note;
        
        -- Wait for tri_ready (check if already high, otherwise wait for rising edge)
        if tri_ready /= '1' then
            wait until tri_ready = '1';
        end if;
        
        -- Assert tri_valid for one clock cycle
        wait until rising_edge(clk);
        tri_valid <= '1';
        wait until rising_edge(clk);
        tri_valid <= '0';
        
        -- Wait for completion with timeout
        wait until triangle_done = '1' for CLK_PERIOD * 1000;
        
        if triangle_done /= '1' then
            report "Timeout! Rasterizer did not complete" severity error;
        else
            report "Rasterization complete, " & integer'image(frag_count) & " fragments" severity note;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -- Write PPM output
        report "Writing PPM file..." severity note;
        file_open(ppm_file, "tb/output_tile.ppm", write_mode);
        
        write(line_buf, string'("P3"));
        writeline(ppm_file, line_buf);
        write(line_buf, TILE_SIZE);
        write(line_buf, string'(" "));
        write(line_buf, TILE_SIZE);
        writeline(ppm_file, line_buf);
        write(line_buf, string'("255"));
        writeline(ppm_file, line_buf);
        
        for y in 0 to TILE_SIZE-1 loop
            for x in 0 to TILE_SIZE-1 loop
                pixel := tile_buffer(y * TILE_SIZE + x);
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
        
        report "Output written to tb/output_tile.ppm" severity note;
        report "=== Test Complete ===" severity note;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
