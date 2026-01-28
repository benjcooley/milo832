-------------------------------------------------------------------------------
-- tb_texture_sampler.vhd
-- Testbench: Texture Sampler with image load/save
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_texture_sampler is
end entity tb_texture_sampler;

architecture sim of tb_texture_sampler is
    
    constant CLK_PERIOD : time := 10 ns;
    constant TEXTURE_W  : integer := 16;
    constant TEXTURE_H  : integer := 16;
    
    -- DUT signals
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    
    -- Request interface
    signal req_valid    : std_logic := '0';
    signal req_ready    : std_logic;
    signal req_u        : std_logic_vector(31 downto 0) := (others => '0');
    signal req_v        : std_logic_vector(31 downto 0) := (others => '0');
    signal req_lod      : std_logic_vector(7 downto 0) := (others => '0');
    
    -- Texture config
    signal tex_base_addr : std_logic_vector(31 downto 0) := x"00000000";
    signal tex_width     : std_logic_vector(11 downto 0) := std_logic_vector(to_unsigned(TEXTURE_W, 12));
    signal tex_height    : std_logic_vector(11 downto 0) := std_logic_vector(to_unsigned(TEXTURE_H, 12));
    signal tex_format    : std_logic_vector(3 downto 0) := "0000";  -- RGBA8888
    signal tex_wrap_u    : std_logic_vector(1 downto 0) := "00";    -- Repeat
    signal tex_wrap_v    : std_logic_vector(1 downto 0) := "00";    -- Repeat
    signal tex_filter    : std_logic := '0';                        -- Nearest
    
    -- Sample output
    signal sample_valid  : std_logic;
    signal sample_color  : std_logic_vector(31 downto 0);
    
    -- Memory interface
    signal mem_req_valid : std_logic;
    signal mem_req_addr  : std_logic_vector(31 downto 0);
    signal mem_req_ready : std_logic := '1';
    signal mem_resp_valid: std_logic := '0';
    signal mem_resp_data : std_logic_vector(31 downto 0) := (others => '0');
    
    -- Statistics
    signal cache_hits    : std_logic_vector(31 downto 0);
    signal cache_misses  : std_logic_vector(31 downto 0);
    
    signal sim_done : boolean := false;
    
    -- Memory model signals
    signal mem_req_pending : std_logic := '0';
    signal mem_req_addr_lat : std_logic_vector(31 downto 0) := (others => '0');
    
    -- Texture memory (RGBA8888 format)
    type texture_mem_t is array (0 to TEXTURE_W*TEXTURE_H-1) of std_logic_vector(31 downto 0);
    signal texture_mem : texture_mem_t;
    
    -- Output framebuffer
    constant OUT_WIDTH  : integer := 32;
    constant OUT_HEIGHT : integer := 32;
    type framebuffer_t is array (0 to OUT_WIDTH*OUT_HEIGHT-1) of std_logic_vector(31 downto 0);
    signal framebuffer : framebuffer_t := (others => x"00000000");
    
    -- Helper: Convert integer to 16.16 fixed point
    function to_fixed(val : real) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(integer(val * 65536.0), 32));
    end function;
    
    -- Helper: Create gradient texture
    procedure create_gradient_texture(signal tex : out texture_mem_t) is
        variable r, g, b : integer;
    begin
        for y in 0 to TEXTURE_H-1 loop
            for x in 0 to TEXTURE_W-1 loop
                -- R increases with X, G increases with Y, B = 128
                r := (x * 255) / (TEXTURE_W - 1);
                g := (y * 255) / (TEXTURE_H - 1);
                b := 128;
                tex(y * TEXTURE_W + x) <= std_logic_vector(to_unsigned(r, 8)) &
                                          std_logic_vector(to_unsigned(g, 8)) &
                                          std_logic_vector(to_unsigned(b, 8)) &
                                          x"FF";
            end loop;
        end loop;
    end procedure;
    
    -- Helper: Create checkerboard texture
    procedure create_checker_texture(signal tex : out texture_mem_t) is
    begin
        for y in 0 to TEXTURE_H-1 loop
            for x in 0 to TEXTURE_W-1 loop
                if ((x / 4) + (y / 4)) mod 2 = 0 then
                    tex(y * TEXTURE_W + x) <= x"FF0000FF";  -- Red
                else
                    tex(y * TEXTURE_W + x) <= x"00FF00FF";  -- Green
                end if;
            end loop;
        end loop;
    end procedure;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done;
    
    -- DUT
    u_sampler : entity work.texture_sampler
        generic map (
            CACHE_SIZE_KB   => 1,
            CACHE_LINE_SIZE => 64,
            MAX_TEX_WIDTH   => 2048,
            MAX_TEX_HEIGHT  => 2048,
            MAX_MIP_LEVELS  => 11,
            COORD_FRAC_BITS => 16
        )
        port map (
            clk          => clk,
            rst_n        => rst_n,
            req_valid    => req_valid,
            req_ready    => req_ready,
            req_u        => req_u,
            req_v        => req_v,
            req_lod      => req_lod,
            tex_base_addr => tex_base_addr,
            tex_width    => tex_width,
            tex_height   => tex_height,
            tex_format   => tex_format,
            tex_wrap_u   => tex_wrap_u,
            tex_wrap_v   => tex_wrap_v,
            tex_filter   => tex_filter,
            sample_valid => sample_valid,
            sample_color => sample_color,
            mem_req_valid => mem_req_valid,
            mem_req_addr  => mem_req_addr,
            mem_req_ready => mem_req_ready,
            mem_resp_valid => mem_resp_valid,
            mem_resp_data  => mem_resp_data,
            cache_hits   => cache_hits,
            cache_misses => cache_misses
        );
    
    -- Memory model process with proper timing
    process(clk)
        variable addr : integer;
        variable texel_idx : integer;
    begin
        if rising_edge(clk) then
            mem_resp_valid <= '0';
            
            -- Stage 1: Capture request
            if mem_req_valid = '1' and mem_req_ready = '1' then
                mem_req_pending <= '1';
                mem_req_addr_lat <= mem_req_addr;
            end if;
            
            -- Stage 2: Respond (1 cycle later)
            if mem_req_pending = '1' then
                mem_req_pending <= '0';
                
                addr := to_integer(unsigned(mem_req_addr_lat));
                texel_idx := addr / 4;  -- Each texel is 4 bytes (RGBA8888)
                
                if texel_idx >= 0 and texel_idx < TEXTURE_W * TEXTURE_H then
                    mem_resp_data <= texture_mem(texel_idx);
                else
                    mem_resp_data <= x"FF00FFFF";  -- Magenta for out of bounds
                end if;
                mem_resp_valid <= '1';
            end if;
        end if;
    end process;
    
    -- Test process
    process
        variable out_x, out_y : integer;
        variable u, v : real;
        file ppm_file : text;
        variable line_buf : line;
        variable r, g, b : integer;
        variable sample_count : integer := 0;
    begin
        report "=== Texture Sampler Test ===" severity note;
        
        -- Initialize texture with gradient
        create_gradient_texture(texture_mem);
        
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 1: Nearest neighbor sampling (1:1 mapping)
        -----------------------------------------------------------------------
        report "Test 1: Nearest neighbor sampling" severity note;
        tex_filter <= '0';  -- Nearest
        
        for out_y in 0 to OUT_HEIGHT-1 loop
            for out_x in 0 to OUT_WIDTH-1 loop
                -- Map output coords to texture coords (scaled 2x)
                u := real(out_x) / real(OUT_WIDTH);
                v := real(out_y) / real(OUT_HEIGHT);
                
                req_u <= to_fixed(u);
                req_v <= to_fixed(v);
                
                -- Wait for ready
                if req_ready /= '1' then
                    wait until req_ready = '1';
                end if;
                
                -- Issue request
                wait until rising_edge(clk);
                req_valid <= '1';
                wait until rising_edge(clk);
                req_valid <= '0';
                
                -- Wait for result
                wait until sample_valid = '1' for CLK_PERIOD * 20;
                
                if sample_valid = '1' then
                    framebuffer(out_y * OUT_WIDTH + out_x) <= sample_color;
                    sample_count := sample_count + 1;
                else
                    report "Timeout waiting for sample at " & 
                           integer'image(out_x) & "," & integer'image(out_y) severity warning;
                end if;
                
                wait until rising_edge(clk);
            end loop;
        end loop;
        
        report "Nearest: " & integer'image(sample_count) & " samples" severity note;
        
        -- Write output image
        file_open(ppm_file, "tb/output_sampler_nearest.ppm", write_mode);
        write(line_buf, string'("P3"));
        writeline(ppm_file, line_buf);
        write(line_buf, OUT_WIDTH);
        write(line_buf, string'(" "));
        write(line_buf, OUT_HEIGHT);
        writeline(ppm_file, line_buf);
        write(line_buf, string'("255"));
        writeline(ppm_file, line_buf);
        
        for y in 0 to OUT_HEIGHT-1 loop
            for x in 0 to OUT_WIDTH-1 loop
                r := to_integer(unsigned(framebuffer(y * OUT_WIDTH + x)(31 downto 24)));
                g := to_integer(unsigned(framebuffer(y * OUT_WIDTH + x)(23 downto 16)));
                b := to_integer(unsigned(framebuffer(y * OUT_WIDTH + x)(15 downto 8)));
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
        report "Wrote tb/output_sampler_nearest.ppm" severity note;
        
        -----------------------------------------------------------------------
        -- Test 2: Bilinear filtering
        -----------------------------------------------------------------------
        report "Test 2: Bilinear filtering" severity note;
        tex_filter <= '1';  -- Bilinear
        sample_count := 0;
        
        for out_y in 0 to OUT_HEIGHT-1 loop
            for out_x in 0 to OUT_WIDTH-1 loop
                u := real(out_x) / real(OUT_WIDTH);
                v := real(out_y) / real(OUT_HEIGHT);
                
                req_u <= to_fixed(u);
                req_v <= to_fixed(v);
                
                if req_ready /= '1' then
                    wait until req_ready = '1';
                end if;
                
                wait until rising_edge(clk);
                req_valid <= '1';
                wait until rising_edge(clk);
                req_valid <= '0';
                
                wait until sample_valid = '1' for CLK_PERIOD * 50;
                
                if sample_valid = '1' then
                    framebuffer(out_y * OUT_WIDTH + out_x) <= sample_color;
                    sample_count := sample_count + 1;
                end if;
                
                wait until rising_edge(clk);
            end loop;
        end loop;
        
        report "Bilinear: " & integer'image(sample_count) & " samples" severity note;
        
        -- Write bilinear output
        file_open(ppm_file, "tb/output_sampler_bilinear.ppm", write_mode);
        write(line_buf, string'("P3"));
        writeline(ppm_file, line_buf);
        write(line_buf, OUT_WIDTH);
        write(line_buf, string'(" "));
        write(line_buf, OUT_HEIGHT);
        writeline(ppm_file, line_buf);
        write(line_buf, string'("255"));
        writeline(ppm_file, line_buf);
        
        for y in 0 to OUT_HEIGHT-1 loop
            for x in 0 to OUT_WIDTH-1 loop
                r := to_integer(unsigned(framebuffer(y * OUT_WIDTH + x)(31 downto 24)));
                g := to_integer(unsigned(framebuffer(y * OUT_WIDTH + x)(23 downto 16)));
                b := to_integer(unsigned(framebuffer(y * OUT_WIDTH + x)(15 downto 8)));
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
        report "Wrote tb/output_sampler_bilinear.ppm" severity note;
        
        -----------------------------------------------------------------------
        -- Test 3: Wrap modes with checker texture
        -----------------------------------------------------------------------
        report "Test 3: Wrap mode test" severity note;
        create_checker_texture(texture_mem);
        tex_filter <= '0';  -- Nearest
        tex_wrap_u <= "00";  -- Repeat
        tex_wrap_v <= "00";  -- Repeat
        sample_count := 0;
        
        for out_y in 0 to OUT_HEIGHT-1 loop
            for out_x in 0 to OUT_WIDTH-1 loop
                -- Sample with coords from -0.5 to 1.5 to test wrapping
                u := (real(out_x) / real(OUT_WIDTH)) * 2.0 - 0.5;
                v := (real(out_y) / real(OUT_HEIGHT)) * 2.0 - 0.5;
                
                req_u <= to_fixed(u);
                req_v <= to_fixed(v);
                
                if req_ready /= '1' then
                    wait until req_ready = '1';
                end if;
                
                wait until rising_edge(clk);
                req_valid <= '1';
                wait until rising_edge(clk);
                req_valid <= '0';
                
                wait until sample_valid = '1' for CLK_PERIOD * 20;
                
                if sample_valid = '1' then
                    framebuffer(out_y * OUT_WIDTH + out_x) <= sample_color;
                    sample_count := sample_count + 1;
                end if;
                
                wait until rising_edge(clk);
            end loop;
        end loop;
        
        report "Wrap test: " & integer'image(sample_count) & " samples" severity note;
        
        -- Write wrap test output
        file_open(ppm_file, "tb/output_sampler_wrap.ppm", write_mode);
        write(line_buf, string'("P3"));
        writeline(ppm_file, line_buf);
        write(line_buf, OUT_WIDTH);
        write(line_buf, string'(" "));
        write(line_buf, OUT_HEIGHT);
        writeline(ppm_file, line_buf);
        write(line_buf, string'("255"));
        writeline(ppm_file, line_buf);
        
        for y in 0 to OUT_HEIGHT-1 loop
            for x in 0 to OUT_WIDTH-1 loop
                r := to_integer(unsigned(framebuffer(y * OUT_WIDTH + x)(31 downto 24)));
                g := to_integer(unsigned(framebuffer(y * OUT_WIDTH + x)(23 downto 16)));
                b := to_integer(unsigned(framebuffer(y * OUT_WIDTH + x)(15 downto 8)));
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
        report "Wrote tb/output_sampler_wrap.ppm" severity note;
        
        -----------------------------------------------------------------------
        report "=== Texture Sampler Test Complete ===" severity note;
        report "Cache hits: " & integer'image(to_integer(unsigned(cache_hits))) severity note;
        report "Cache misses: " & integer'image(to_integer(unsigned(cache_misses))) severity note;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
