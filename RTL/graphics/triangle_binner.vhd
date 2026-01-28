-------------------------------------------------------------------------------
-- triangle_binner.vhd
-- Triangle Binning Unit
-- Assigns triangles to tiles they overlap
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity triangle_binner is
    generic (
        SCREEN_WIDTH    : integer := 640;
        SCREEN_HEIGHT   : integer := 480;
        TILE_SIZE       : integer := 16;
        MAX_TRIANGLES   : integer := 4096;
        MAX_TRIS_PER_TILE : integer := 64
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Control
        start_frame     : in  std_logic;
        binning_done    : out std_logic;
        
        -- Triangle input (from vertex shader output)
        tri_valid       : in  std_logic;
        tri_ready       : out std_logic;
        tri_index       : in  std_logic_vector(15 downto 0);
        
        -- Screen-space vertex positions (16.16 fixed point)
        v0_x, v0_y      : in  std_logic_vector(31 downto 0);
        v1_x, v1_y      : in  std_logic_vector(31 downto 0);
        v2_x, v2_y      : in  std_logic_vector(31 downto 0);
        
        -- Tile list memory interface (write)
        list_wr_valid   : out std_logic;
        list_wr_tile_x  : out std_logic_vector(7 downto 0);
        list_wr_tile_y  : out std_logic_vector(7 downto 0);
        list_wr_tri_idx : out std_logic_vector(15 downto 0);
        list_wr_ready   : in  std_logic;
        
        -- Status
        triangles_binned: out std_logic_vector(15 downto 0);
        tiles_touched   : out std_logic_vector(15 downto 0)
    );
end entity triangle_binner;

architecture rtl of triangle_binner is

    constant TILES_X : integer := (SCREEN_WIDTH + TILE_SIZE - 1) / TILE_SIZE;
    constant TILES_Y : integer := (SCREEN_HEIGHT + TILE_SIZE - 1) / TILE_SIZE;
    constant FRAC_BITS : integer := 16;
    
    type state_t is (
        IDLE,
        CALC_BBOX,
        BIN_TILES,
        WRITE_TILE,
        NEXT_TILE,
        DONE
    );
    signal state : state_t := IDLE;
    
    -- Latched triangle data
    signal lat_tri_idx : std_logic_vector(15 downto 0);
    signal lat_v0_x, lat_v0_y : signed(31 downto 0);
    signal lat_v1_x, lat_v1_y : signed(31 downto 0);
    signal lat_v2_x, lat_v2_y : signed(31 downto 0);
    
    -- Bounding box (in tile coordinates)
    signal bbox_tile_min_x, bbox_tile_max_x : unsigned(7 downto 0);
    signal bbox_tile_min_y, bbox_tile_max_y : unsigned(7 downto 0);
    
    -- Current tile being written
    signal cur_tile_x, cur_tile_y : unsigned(7 downto 0);
    
    -- Statistics
    signal tri_count : unsigned(15 downto 0);
    signal tile_count : unsigned(15 downto 0);
    
    -- Helper function: clamp to screen bounds and convert to tile coords
    function to_tile_coord(pixel : signed(31 downto 0); max_pixels : integer) return unsigned is
        variable pixel_int : integer;
        variable tile : integer;
    begin
        pixel_int := to_integer(shift_right(pixel, FRAC_BITS));
        
        if pixel_int < 0 then
            tile := 0;
        elsif pixel_int >= max_pixels then
            tile := (max_pixels - 1) / TILE_SIZE;
        else
            tile := pixel_int / TILE_SIZE;
        end if;
        
        return to_unsigned(tile, 8);
    end function;

begin

    triangles_binned <= std_logic_vector(tri_count);
    tiles_touched <= std_logic_vector(tile_count);
    
    process(clk, rst_n)
        variable min_x, max_x, min_y, max_y : signed(31 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            tri_ready <= '0';
            list_wr_valid <= '0';
            binning_done <= '0';
            tri_count <= (others => '0');
            tile_count <= (others => '0');
            
        elsif rising_edge(clk) then
            -- Default outputs
            list_wr_valid <= '0';
            binning_done <= '0';
            
            case state is
                when IDLE =>
                    tri_ready <= '1';
                    
                    if start_frame = '1' then
                        tri_count <= (others => '0');
                        tile_count <= (others => '0');
                    end if;
                    
                    if tri_valid = '1' then
                        -- Latch triangle
                        lat_tri_idx <= tri_index;
                        lat_v0_x <= signed(v0_x);
                        lat_v0_y <= signed(v0_y);
                        lat_v1_x <= signed(v1_x);
                        lat_v1_y <= signed(v1_y);
                        lat_v2_x <= signed(v2_x);
                        lat_v2_y <= signed(v2_y);
                        
                        tri_ready <= '0';
                        state <= CALC_BBOX;
                    end if;
                
                when CALC_BBOX =>
                    -- Calculate bounding box
                    -- Min X
                    min_x := lat_v0_x;
                    if lat_v1_x < min_x then min_x := lat_v1_x; end if;
                    if lat_v2_x < min_x then min_x := lat_v2_x; end if;
                    
                    -- Max X
                    max_x := lat_v0_x;
                    if lat_v1_x > max_x then max_x := lat_v1_x; end if;
                    if lat_v2_x > max_x then max_x := lat_v2_x; end if;
                    
                    -- Min Y
                    min_y := lat_v0_y;
                    if lat_v1_y < min_y then min_y := lat_v1_y; end if;
                    if lat_v2_y < min_y then min_y := lat_v2_y; end if;
                    
                    -- Max Y
                    max_y := lat_v0_y;
                    if lat_v1_y > max_y then max_y := lat_v1_y; end if;
                    if lat_v2_y > max_y then max_y := lat_v2_y; end if;
                    
                    -- Convert to tile coordinates
                    bbox_tile_min_x <= to_tile_coord(min_x, SCREEN_WIDTH);
                    bbox_tile_max_x <= to_tile_coord(max_x, SCREEN_WIDTH);
                    bbox_tile_min_y <= to_tile_coord(min_y, SCREEN_HEIGHT);
                    bbox_tile_max_y <= to_tile_coord(max_y, SCREEN_HEIGHT);
                    
                    -- Start at min corner
                    cur_tile_x <= to_tile_coord(min_x, SCREEN_WIDTH);
                    cur_tile_y <= to_tile_coord(min_y, SCREEN_HEIGHT);
                    
                    state <= BIN_TILES;
                
                when BIN_TILES =>
                    -- Check if we're done with all tiles
                    if cur_tile_y > bbox_tile_max_y then
                        tri_count <= tri_count + 1;
                        state <= IDLE;
                    else
                        state <= WRITE_TILE;
                    end if;
                
                when WRITE_TILE =>
                    -- Write this tile entry
                    list_wr_valid <= '1';
                    list_wr_tile_x <= std_logic_vector(cur_tile_x);
                    list_wr_tile_y <= std_logic_vector(cur_tile_y);
                    list_wr_tri_idx <= lat_tri_idx;
                    
                    if list_wr_ready = '1' then
                        list_wr_valid <= '0';
                        tile_count <= tile_count + 1;
                        state <= NEXT_TILE;
                    end if;
                
                when NEXT_TILE =>
                    -- Move to next tile
                    if cur_tile_x < bbox_tile_max_x then
                        cur_tile_x <= cur_tile_x + 1;
                    else
                        cur_tile_x <= bbox_tile_min_x;
                        cur_tile_y <= cur_tile_y + 1;
                    end if;
                    
                    state <= BIN_TILES;
                
                when DONE =>
                    binning_done <= '1';
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
