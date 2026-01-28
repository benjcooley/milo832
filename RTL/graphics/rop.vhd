-------------------------------------------------------------------------------
-- rop.vhd
-- Raster Operations Pipeline (ROP)
-- Handles depth testing, alpha blending, and framebuffer writes
--
-- New component for Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rop is
    generic (
        -- Framebuffer parameters
        FB_WIDTH        : integer := 640;
        FB_HEIGHT       : integer := 480;
        
        -- Depth buffer precision
        DEPTH_BITS      : integer := 24
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Fragment input interface
        frag_valid      : in  std_logic;
        frag_ready      : out std_logic;
        frag_x          : in  std_logic_vector(15 downto 0);
        frag_y          : in  std_logic_vector(15 downto 0);
        frag_z          : in  std_logic_vector(31 downto 0);
        frag_color      : in  std_logic_vector(31 downto 0);  -- RGBA
        
        -- Configuration
        depth_test_en   : in  std_logic;
        depth_write_en  : in  std_logic;
        depth_func      : in  std_logic_vector(2 downto 0);   -- Comparison function
        
        blend_en        : in  std_logic;
        blend_src_rgb   : in  std_logic_vector(3 downto 0);   -- Source RGB factor
        blend_dst_rgb   : in  std_logic_vector(3 downto 0);   -- Dest RGB factor
        blend_src_a     : in  std_logic_vector(3 downto 0);   -- Source Alpha factor
        blend_dst_a     : in  std_logic_vector(3 downto 0);   -- Dest Alpha factor
        
        color_mask      : in  std_logic_vector(3 downto 0);   -- RGBA write mask
        
        -- Depth buffer interface
        depth_rd_addr   : out std_logic_vector(31 downto 0);
        depth_rd_data   : in  std_logic_vector(23 downto 0);
        depth_rd_valid  : in  std_logic;
        
        depth_wr_valid  : out std_logic;
        depth_wr_addr   : out std_logic_vector(31 downto 0);
        depth_wr_data   : out std_logic_vector(23 downto 0);
        
        -- Color buffer interface
        color_rd_addr   : out std_logic_vector(31 downto 0);
        color_rd_data   : in  std_logic_vector(31 downto 0);
        color_rd_valid  : in  std_logic;
        
        color_wr_valid  : out std_logic;
        color_wr_addr   : out std_logic_vector(31 downto 0);
        color_wr_data   : out std_logic_vector(31 downto 0);
        
        -- Status
        pixels_written  : out std_logic_vector(31 downto 0);
        pixels_killed   : out std_logic_vector(31 downto 0)
    );
end entity rop;

architecture rtl of rop is

    ---------------------------------------------------------------------------
    -- Depth Test Functions
    ---------------------------------------------------------------------------
    constant DEPTH_NEVER    : std_logic_vector(2 downto 0) := "000";
    constant DEPTH_LESS     : std_logic_vector(2 downto 0) := "001";
    constant DEPTH_EQUAL    : std_logic_vector(2 downto 0) := "010";
    constant DEPTH_LEQUAL   : std_logic_vector(2 downto 0) := "011";
    constant DEPTH_GREATER  : std_logic_vector(2 downto 0) := "100";
    constant DEPTH_NOTEQUAL : std_logic_vector(2 downto 0) := "101";
    constant DEPTH_GEQUAL   : std_logic_vector(2 downto 0) := "110";
    constant DEPTH_ALWAYS   : std_logic_vector(2 downto 0) := "111";
    
    ---------------------------------------------------------------------------
    -- Blend Factors
    ---------------------------------------------------------------------------
    constant BLEND_ZERO         : std_logic_vector(3 downto 0) := "0000";
    constant BLEND_ONE          : std_logic_vector(3 downto 0) := "0001";
    constant BLEND_SRC_COLOR    : std_logic_vector(3 downto 0) := "0010";
    constant BLEND_INV_SRC_COLOR: std_logic_vector(3 downto 0) := "0011";
    constant BLEND_DST_COLOR    : std_logic_vector(3 downto 0) := "0100";
    constant BLEND_INV_DST_COLOR: std_logic_vector(3 downto 0) := "0101";
    constant BLEND_SRC_ALPHA    : std_logic_vector(3 downto 0) := "0110";
    constant BLEND_INV_SRC_ALPHA: std_logic_vector(3 downto 0) := "0111";
    constant BLEND_DST_ALPHA    : std_logic_vector(3 downto 0) := "1000";
    constant BLEND_INV_DST_ALPHA: std_logic_vector(3 downto 0) := "1001";
    
    ---------------------------------------------------------------------------
    -- State Machine
    ---------------------------------------------------------------------------
    type state_t is (
        IDLE,
        READ_DEPTH,
        WAIT_DEPTH,
        DEPTH_TEST,
        READ_COLOR,
        WAIT_COLOR,
        BLEND,
        WRITE_OUTPUT
    );
    signal state : state_t := IDLE;
    
    ---------------------------------------------------------------------------
    -- Latched Fragment Data
    ---------------------------------------------------------------------------
    signal lat_x, lat_y : unsigned(15 downto 0);
    signal lat_z : unsigned(23 downto 0);
    signal lat_color : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Intermediate Results
    ---------------------------------------------------------------------------
    signal depth_pass : std_logic;
    signal blended_color : std_logic_vector(31 downto 0);
    signal fb_addr : unsigned(31 downto 0);
    
    -- Statistics
    signal written_count, killed_count : unsigned(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Helper function: Depth comparison
    ---------------------------------------------------------------------------
    function depth_compare(
        frag_z, buf_z : unsigned(23 downto 0);
        func : std_logic_vector(2 downto 0)
    ) return std_logic is
    begin
        case func is
            when DEPTH_NEVER    => return '0';
            when DEPTH_LESS     => return '1' when frag_z < buf_z else '0';
            when DEPTH_EQUAL    => return '1' when frag_z = buf_z else '0';
            when DEPTH_LEQUAL   => return '1' when frag_z <= buf_z else '0';
            when DEPTH_GREATER  => return '1' when frag_z > buf_z else '0';
            when DEPTH_NOTEQUAL => return '1' when frag_z /= buf_z else '0';
            when DEPTH_GEQUAL   => return '1' when frag_z >= buf_z else '0';
            when DEPTH_ALWAYS   => return '1';
            when others         => return '1';
        end case;
    end function;
    
    ---------------------------------------------------------------------------
    -- Helper function: Get blend factor
    ---------------------------------------------------------------------------
    function get_blend_factor(
        factor : std_logic_vector(3 downto 0);
        src_color, dst_color : std_logic_vector(31 downto 0)
    ) return unsigned is
        variable result : unsigned(7 downto 0);
    begin
        case factor is
            when BLEND_ZERO          => result := x"00";
            when BLEND_ONE           => result := x"FF";
            when BLEND_SRC_COLOR     => result := unsigned(src_color(31 downto 24));
            when BLEND_INV_SRC_COLOR => result := x"FF" - unsigned(src_color(31 downto 24));
            when BLEND_DST_COLOR     => result := unsigned(dst_color(31 downto 24));
            when BLEND_INV_DST_COLOR => result := x"FF" - unsigned(dst_color(31 downto 24));
            when BLEND_SRC_ALPHA     => result := unsigned(src_color(7 downto 0));
            when BLEND_INV_SRC_ALPHA => result := x"FF" - unsigned(src_color(7 downto 0));
            when BLEND_DST_ALPHA     => result := unsigned(dst_color(7 downto 0));
            when BLEND_INV_DST_ALPHA => result := x"FF" - unsigned(dst_color(7 downto 0));
            when others              => result := x"FF";
        end case;
        return result;
    end function;
    
    ---------------------------------------------------------------------------
    -- Helper function: Blend one channel
    ---------------------------------------------------------------------------
    function blend_channel(
        src, dst : unsigned(7 downto 0);
        src_factor, dst_factor : unsigned(7 downto 0)
    ) return std_logic_vector is
        variable src_term, dst_term : unsigned(15 downto 0);
        variable sum : unsigned(15 downto 0);
    begin
        src_term := src * src_factor;
        dst_term := dst * dst_factor;
        sum := src_term + dst_term;
        
        -- Clamp and return high byte
        if sum > x"FF00" then
            return x"FF";
        else
            return std_logic_vector(sum(15 downto 8));
        end if;
    end function;

begin

    -- Output assignments
    frag_ready <= '1' when state = IDLE else '0';
    pixels_written <= std_logic_vector(written_count);
    pixels_killed <= std_logic_vector(killed_count);
    
    ---------------------------------------------------------------------------
    -- Main ROP State Machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable src_factor_rgb, dst_factor_rgb : unsigned(7 downto 0);
        variable src_factor_a, dst_factor_a : unsigned(7 downto 0);
        variable final_r, final_g, final_b, final_a : std_logic_vector(7 downto 0);
        variable dst_color : std_logic_vector(31 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            depth_wr_valid <= '0';
            color_wr_valid <= '0';
            written_count <= (others => '0');
            killed_count <= (others => '0');
            depth_pass <= '0';
            
            depth_rd_addr <= (others => '0');
            depth_wr_addr <= (others => '0');
            depth_wr_data <= (others => '0');
            color_rd_addr <= (others => '0');
            color_wr_addr <= (others => '0');
            color_wr_data <= (others => '0');
            
        elsif rising_edge(clk) then
            -- Default: deassert write valids
            depth_wr_valid <= '0';
            color_wr_valid <= '0';
            
            case state is
                ---------------------------------------------------------------
                when IDLE =>
                    if frag_valid = '1' then
                        -- Latch fragment data
                        lat_x <= unsigned(frag_x);
                        lat_y <= unsigned(frag_y);
                        lat_z <= unsigned(frag_z(23 downto 0));
                        lat_color <= frag_color;
                        
                        -- Calculate framebuffer address
                        fb_addr <= resize(unsigned(frag_y) * FB_WIDTH + unsigned(frag_x), 32);
                        
                        if depth_test_en = '1' then
                            state <= READ_DEPTH;
                        else
                            depth_pass <= '1';
                            if blend_en = '1' then
                                state <= READ_COLOR;
                            else
                                state <= WRITE_OUTPUT;
                            end if;
                        end if;
                    end if;
                
                ---------------------------------------------------------------
                when READ_DEPTH =>
                    depth_rd_addr <= std_logic_vector(fb_addr);
                    state <= WAIT_DEPTH;
                
                ---------------------------------------------------------------
                when WAIT_DEPTH =>
                    if depth_rd_valid = '1' then
                        state <= DEPTH_TEST;
                    end if;
                
                ---------------------------------------------------------------
                when DEPTH_TEST =>
                    depth_pass <= depth_compare(lat_z, unsigned(depth_rd_data), depth_func);
                    
                    if depth_compare(lat_z, unsigned(depth_rd_data), depth_func) = '1' then
                        if blend_en = '1' then
                            state <= READ_COLOR;
                        else
                            state <= WRITE_OUTPUT;
                        end if;
                    else
                        -- Depth test failed
                        killed_count <= killed_count + 1;
                        state <= IDLE;
                    end if;
                
                ---------------------------------------------------------------
                when READ_COLOR =>
                    color_rd_addr <= std_logic_vector(fb_addr);
                    state <= WAIT_COLOR;
                
                ---------------------------------------------------------------
                when WAIT_COLOR =>
                    if color_rd_valid = '1' then
                        state <= BLEND;
                    end if;
                
                ---------------------------------------------------------------
                when BLEND =>
                    dst_color := color_rd_data;
                    
                    -- Get blend factors
                    src_factor_rgb := get_blend_factor(blend_src_rgb, lat_color, dst_color);
                    dst_factor_rgb := get_blend_factor(blend_dst_rgb, lat_color, dst_color);
                    src_factor_a := get_blend_factor(blend_src_a, lat_color, dst_color);
                    dst_factor_a := get_blend_factor(blend_dst_a, lat_color, dst_color);
                    
                    -- Blend each channel
                    final_r := blend_channel(
                        unsigned(lat_color(31 downto 24)),
                        unsigned(dst_color(31 downto 24)),
                        src_factor_rgb, dst_factor_rgb
                    );
                    
                    final_g := blend_channel(
                        unsigned(lat_color(23 downto 16)),
                        unsigned(dst_color(23 downto 16)),
                        src_factor_rgb, dst_factor_rgb
                    );
                    
                    final_b := blend_channel(
                        unsigned(lat_color(15 downto 8)),
                        unsigned(dst_color(15 downto 8)),
                        src_factor_rgb, dst_factor_rgb
                    );
                    
                    final_a := blend_channel(
                        unsigned(lat_color(7 downto 0)),
                        unsigned(dst_color(7 downto 0)),
                        src_factor_a, dst_factor_a
                    );
                    
                    blended_color <= final_r & final_g & final_b & final_a;
                    state <= WRITE_OUTPUT;
                
                ---------------------------------------------------------------
                when WRITE_OUTPUT =>
                    -- Write depth if enabled and passed
                    if depth_write_en = '1' and depth_pass = '1' then
                        depth_wr_valid <= '1';
                        depth_wr_addr <= std_logic_vector(fb_addr);
                        depth_wr_data <= std_logic_vector(lat_z);
                    end if;
                    
                    -- Write color with mask
                    color_wr_valid <= '1';
                    color_wr_addr <= std_logic_vector(fb_addr);
                    
                    if blend_en = '1' then
                        -- Apply color mask
                        if color_mask(3) = '1' then
                            color_wr_data(31 downto 24) <= blended_color(31 downto 24);
                        end if;
                        if color_mask(2) = '1' then
                            color_wr_data(23 downto 16) <= blended_color(23 downto 16);
                        end if;
                        if color_mask(1) = '1' then
                            color_wr_data(15 downto 8) <= blended_color(15 downto 8);
                        end if;
                        if color_mask(0) = '1' then
                            color_wr_data(7 downto 0) <= blended_color(7 downto 0);
                        end if;
                    else
                        -- No blending, direct color
                        if color_mask(3) = '1' then
                            color_wr_data(31 downto 24) <= lat_color(31 downto 24);
                        end if;
                        if color_mask(2) = '1' then
                            color_wr_data(23 downto 16) <= lat_color(23 downto 16);
                        end if;
                        if color_mask(1) = '1' then
                            color_wr_data(15 downto 8) <= lat_color(15 downto 8);
                        end if;
                        if color_mask(0) = '1' then
                            color_wr_data(7 downto 0) <= lat_color(7 downto 0);
                        end if;
                    end if;
                    
                    written_count <= written_count + 1;
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
