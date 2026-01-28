-------------------------------------------------------------------------------
-- tile_renderer.vhd
-- Top-Level Tile-Based Renderer Controller
-- Orchestrates binning, rasterization, shading, and tile writeback
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tile_renderer is
    generic (
        SCREEN_WIDTH    : integer := 640;
        SCREEN_HEIGHT   : integer := 480;
        TILE_SIZE       : integer := 16;
        WARP_SIZE       : integer := 32
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -----------------------------------------------------------------------
        -- Frame Control
        -----------------------------------------------------------------------
        start_frame     : in  std_logic;
        frame_done      : out std_logic;
        
        -- Clear values
        clear_color     : in  std_logic_vector(31 downto 0);
        clear_depth     : in  std_logic_vector(23 downto 0);
        
        -----------------------------------------------------------------------
        -- Triangle Input (from Vertex Shader)
        -----------------------------------------------------------------------
        tri_valid       : in  std_logic;
        tri_ready       : out std_logic;
        tri_last        : in  std_logic;  -- Last triangle in frame
        
        -- Vertex data
        v0_pos          : in  std_logic_vector(95 downto 0);  -- X,Y,Z (32-bit each)
        v1_pos          : in  std_logic_vector(95 downto 0);
        v2_pos          : in  std_logic_vector(95 downto 0);
        v0_uv           : in  std_logic_vector(63 downto 0);  -- U,V (32-bit each)
        v1_uv           : in  std_logic_vector(63 downto 0);
        v2_uv           : in  std_logic_vector(63 downto 0);
        v0_color        : in  std_logic_vector(31 downto 0);
        v1_color        : in  std_logic_vector(31 downto 0);
        v2_color        : in  std_logic_vector(31 downto 0);
        
        -----------------------------------------------------------------------
        -- SIMT Shader Interface (Fragment Shader Dispatch)
        -----------------------------------------------------------------------
        shader_warp_valid : out std_logic;
        shader_warp_ready : in  std_logic;
        shader_warp_mask  : out std_logic_vector(WARP_SIZE-1 downto 0);
        shader_warp_x     : out std_logic_vector(WARP_SIZE*16-1 downto 0);
        shader_warp_y     : out std_logic_vector(WARP_SIZE*16-1 downto 0);
        shader_warp_z     : out std_logic_vector(WARP_SIZE*24-1 downto 0);
        shader_warp_u     : out std_logic_vector(WARP_SIZE*32-1 downto 0);
        shader_warp_v     : out std_logic_vector(WARP_SIZE*32-1 downto 0);
        shader_warp_color : out std_logic_vector(WARP_SIZE*32-1 downto 0);
        
        -- Shader results (back from Fragment Shader)
        shader_result_valid : in  std_logic;
        shader_result_mask  : in  std_logic_vector(WARP_SIZE-1 downto 0);
        shader_result_x     : in  std_logic_vector(WARP_SIZE*16-1 downto 0);
        shader_result_y     : in  std_logic_vector(WARP_SIZE*16-1 downto 0);
        shader_result_z     : in  std_logic_vector(WARP_SIZE*24-1 downto 0);
        shader_result_color : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        
        -----------------------------------------------------------------------
        -- Framebuffer Memory Interface
        -----------------------------------------------------------------------
        fb_wr_valid     : out std_logic;
        fb_wr_addr      : out std_logic_vector(31 downto 0);
        fb_wr_data      : out std_logic_vector(31 downto 0);
        fb_wr_ready     : in  std_logic;
        
        -----------------------------------------------------------------------
        -- Triangle Storage Memory Interface
        -----------------------------------------------------------------------
        tri_mem_wr_valid : out std_logic;
        tri_mem_wr_addr  : out std_logic_vector(15 downto 0);
        tri_mem_wr_data  : out std_logic_vector(511 downto 0);  -- Full triangle
        
        tri_mem_rd_addr  : out std_logic_vector(15 downto 0);
        tri_mem_rd_data  : in  std_logic_vector(511 downto 0);
        
        -----------------------------------------------------------------------
        -- Tile List Memory Interface
        -----------------------------------------------------------------------
        list_wr_valid   : out std_logic;
        list_wr_addr    : out std_logic_vector(23 downto 0);
        list_wr_data    : out std_logic_vector(15 downto 0);
        list_wr_ready   : in  std_logic;
        
        list_rd_addr    : out std_logic_vector(23 downto 0);
        list_rd_data    : in  std_logic_vector(15 downto 0);
        list_rd_valid   : in  std_logic;
        
        -----------------------------------------------------------------------
        -- Status
        -----------------------------------------------------------------------
        triangles_in    : out std_logic_vector(15 downto 0);
        fragments_gen   : out std_logic_vector(31 downto 0);
        tiles_rendered  : out std_logic_vector(15 downto 0);
        current_tile_x  : out std_logic_vector(7 downto 0);
        current_tile_y  : out std_logic_vector(7 downto 0)
    );
end entity tile_renderer;

architecture rtl of tile_renderer is

    constant TILES_X : integer := (SCREEN_WIDTH + TILE_SIZE - 1) / TILE_SIZE;
    constant TILES_Y : integer := (SCREEN_HEIGHT + TILE_SIZE - 1) / TILE_SIZE;
    constant TOTAL_TILES : integer := TILES_X * TILES_Y;
    
    ---------------------------------------------------------------------------
    -- Main State Machine
    ---------------------------------------------------------------------------
    type state_t is (
        IDLE,
        BINNING,            -- Receive triangles, bin to tiles
        BINNING_DONE,       -- All triangles binned
        START_TILE,         -- Begin processing a tile
        CLEAR_TILE,         -- Clear tile buffer
        LOAD_TRI_LIST,      -- Load triangle list for current tile
        FETCH_TRIANGLE,     -- Fetch triangle data from storage
        RASTERIZE,          -- Rasterize triangle into tile
        SHADE_FRAGMENTS,    -- Dispatch fragments to SIMT shader
        ROP_WRITEBACK,      -- Write shader results to tile buffer
        NEXT_TRIANGLE,      -- Move to next triangle in tile
        WRITE_TILE,         -- DMA tile to framebuffer
        NEXT_TILE,          -- Advance to next tile
        FRAME_DONE
    );
    signal state : state_t := IDLE;
    
    ---------------------------------------------------------------------------
    -- Triangle Storage
    ---------------------------------------------------------------------------
    signal tri_store_count : unsigned(15 downto 0) := (others => '0');
    signal tri_store_ptr : unsigned(15 downto 0);
    
    ---------------------------------------------------------------------------
    -- Current Tile State
    ---------------------------------------------------------------------------
    signal cur_tile_x, cur_tile_y : unsigned(7 downto 0);
    signal cur_tile_tri_count : unsigned(15 downto 0);
    signal cur_tile_tri_ptr : unsigned(15 downto 0);
    
    ---------------------------------------------------------------------------
    -- Tile Buffer Interface
    ---------------------------------------------------------------------------
    signal tile_clear : std_logic;
    signal tile_clear_done : std_logic;
    signal tile_rd_x, tile_rd_y : std_logic_vector(4 downto 0);
    signal tile_rd_color : std_logic_vector(31 downto 0);
    signal tile_rd_depth : std_logic_vector(23 downto 0);
    signal tile_wr_en : std_logic;
    signal tile_wr_x, tile_wr_y : std_logic_vector(4 downto 0);
    signal tile_wr_color : std_logic_vector(31 downto 0);
    signal tile_wr_depth : std_logic_vector(23 downto 0);
    signal tile_dirty_mask : std_logic_vector(TILE_SIZE*TILE_SIZE-1 downto 0);
    signal tile_readback_x, tile_readback_y : std_logic_vector(4 downto 0);
    signal tile_readback_color : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Rasterizer Interface
    ---------------------------------------------------------------------------
    signal rast_tri_valid, rast_tri_ready : std_logic;
    signal rast_frag_valid, rast_frag_ready : std_logic;
    signal rast_frag_x, rast_frag_y : std_logic_vector(15 downto 0);
    signal rast_frag_z : std_logic_vector(23 downto 0);
    signal rast_frag_u, rast_frag_v : std_logic_vector(31 downto 0);
    signal rast_frag_color : std_logic_vector(31 downto 0);
    signal rast_tri_done : std_logic;
    
    ---------------------------------------------------------------------------
    -- Fragment Batcher Interface
    ---------------------------------------------------------------------------
    signal batch_frag_ready : std_logic;
    signal batch_warp_valid : std_logic;
    signal batch_warp_ready : std_logic;
    signal batch_end_prim : std_logic;
    
    ---------------------------------------------------------------------------
    -- Tile Writeback State
    ---------------------------------------------------------------------------
    signal wb_pixel_x, wb_pixel_y : unsigned(4 downto 0);
    signal wb_screen_addr : unsigned(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Statistics
    ---------------------------------------------------------------------------
    signal stat_triangles : unsigned(15 downto 0);
    signal stat_fragments : unsigned(31 downto 0);
    signal stat_tiles : unsigned(15 downto 0);
    
    ---------------------------------------------------------------------------
    -- Latched Triangle for Rasterizer
    ---------------------------------------------------------------------------
    signal lat_v0_x, lat_v0_y, lat_v0_z : std_logic_vector(31 downto 0);
    signal lat_v1_x, lat_v1_y, lat_v1_z : std_logic_vector(31 downto 0);
    signal lat_v2_x, lat_v2_y, lat_v2_z : std_logic_vector(31 downto 0);
    signal lat_v0_u, lat_v0_v : std_logic_vector(31 downto 0);
    signal lat_v1_u, lat_v1_v : std_logic_vector(31 downto 0);
    signal lat_v2_u, lat_v2_v : std_logic_vector(31 downto 0);
    signal lat_v0_color, lat_v1_color, lat_v2_color : std_logic_vector(31 downto 0);

begin

    -- Status outputs
    triangles_in <= std_logic_vector(stat_triangles);
    fragments_gen <= std_logic_vector(stat_fragments);
    tiles_rendered <= std_logic_vector(stat_tiles);
    current_tile_x <= std_logic_vector(cur_tile_x);
    current_tile_y <= std_logic_vector(cur_tile_y);
    
    ---------------------------------------------------------------------------
    -- Tile Buffer Instance
    ---------------------------------------------------------------------------
    u_tile_buffer : entity work.tile_buffer
        generic map (
            TILE_SIZE   => TILE_SIZE,
            COLOR_BITS  => 32,
            DEPTH_BITS  => 24
        )
        port map (
            clk         => clk,
            rst_n       => rst_n,
            clear       => tile_clear,
            clear_color => clear_color,
            clear_depth => clear_depth,
            clear_done  => tile_clear_done,
            rd_x        => tile_rd_x,
            rd_y        => tile_rd_y,
            rd_color    => tile_rd_color,
            rd_depth    => tile_rd_depth,
            wr_en       => tile_wr_en,
            wr_x        => tile_wr_x,
            wr_y        => tile_wr_y,
            wr_color    => tile_wr_color,
            wr_depth    => tile_wr_depth,
            wr_color_mask => "1111",
            wr_depth_en => '1',
            readback_x  => tile_readback_x,
            readback_y  => tile_readback_y,
            readback_color => tile_readback_color,
            dirty_mask  => tile_dirty_mask
        );
    
    ---------------------------------------------------------------------------
    -- Tile Rasterizer Instance
    ---------------------------------------------------------------------------
    u_rasterizer : entity work.tile_rasterizer
        generic map (
            TILE_SIZE   => TILE_SIZE,
            FRAC_BITS   => 16
        )
        port map (
            clk         => clk,
            rst_n       => rst_n,
            tile_x      => std_logic_vector(cur_tile_x),
            tile_y      => std_logic_vector(cur_tile_y),
            tri_valid   => rast_tri_valid,
            tri_ready   => rast_tri_ready,
            v0_x        => lat_v0_x,
            v0_y        => lat_v0_y,
            v0_z        => lat_v0_z,
            v1_x        => lat_v1_x,
            v1_y        => lat_v1_y,
            v1_z        => lat_v1_z,
            v2_x        => lat_v2_x,
            v2_y        => lat_v2_y,
            v2_z        => lat_v2_z,
            v0_u        => lat_v0_u,
            v0_v        => lat_v0_v,
            v1_u        => lat_v1_u,
            v1_v        => lat_v1_v,
            v2_u        => lat_v2_u,
            v2_v        => lat_v2_v,
            v0_color    => lat_v0_color,
            v1_color    => lat_v1_color,
            v2_color    => lat_v2_color,
            frag_valid  => rast_frag_valid,
            frag_ready  => rast_frag_ready,
            frag_x      => rast_frag_x,
            frag_y      => rast_frag_y,
            frag_z      => rast_frag_z,
            frag_u      => rast_frag_u,
            frag_v      => rast_frag_v,
            frag_color  => rast_frag_color,
            triangle_done => rast_tri_done,
            fragments_out => open
        );
    
    ---------------------------------------------------------------------------
    -- Fragment Batcher Instance
    ---------------------------------------------------------------------------
    u_batcher : entity work.fragment_batcher
        generic map (
            WARP_SIZE   => WARP_SIZE
        )
        port map (
            clk         => clk,
            rst_n       => rst_n,
            frag_valid  => rast_frag_valid,
            frag_ready  => batch_frag_ready,
            frag_x      => rast_frag_x,
            frag_y      => rast_frag_y,
            frag_z      => rast_frag_z,
            frag_u      => rast_frag_u,
            frag_v      => rast_frag_v,
            frag_r      => rast_frag_color(31 downto 24),
            frag_g      => rast_frag_color(23 downto 16),
            frag_b      => rast_frag_color(15 downto 8),
            frag_a      => rast_frag_color(7 downto 0),
            end_primitive => batch_end_prim,
            warp_valid  => batch_warp_valid,
            warp_ready  => batch_warp_ready,
            warp_mask   => shader_warp_mask,
            warp_count  => open,
            warp_x      => shader_warp_x,
            warp_y      => shader_warp_y,
            warp_z      => shader_warp_z,
            warp_u      => shader_warp_u,
            warp_v      => shader_warp_v,
            warp_color  => shader_warp_color,
            fragments_in => open,
            warps_out   => open
        );
    
    rast_frag_ready <= batch_frag_ready;
    shader_warp_valid <= batch_warp_valid;
    batch_warp_ready <= shader_warp_ready;
    
    ---------------------------------------------------------------------------
    -- Main State Machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state <= IDLE;
            frame_done <= '0';
            tri_ready <= '0';
            tile_clear <= '0';
            rast_tri_valid <= '0';
            batch_end_prim <= '0';
            tile_wr_en <= '0';
            fb_wr_valid <= '0';
            tri_mem_wr_valid <= '0';
            list_wr_valid <= '0';
            
            stat_triangles <= (others => '0');
            stat_fragments <= (others => '0');
            stat_tiles <= (others => '0');
            
        elsif rising_edge(clk) then
            -- Default outputs
            frame_done <= '0';
            tile_clear <= '0';
            rast_tri_valid <= '0';
            batch_end_prim <= '0';
            tile_wr_en <= '0';
            fb_wr_valid <= '0';
            tri_mem_wr_valid <= '0';
            list_wr_valid <= '0';
            
            case state is
                when IDLE =>
                    tri_ready <= '0';
                    
                    if start_frame = '1' then
                        stat_triangles <= (others => '0');
                        stat_fragments <= (others => '0');
                        stat_tiles <= (others => '0');
                        tri_store_count <= (others => '0');
                        state <= BINNING;
                    end if;
                
                when BINNING =>
                    tri_ready <= '1';
                    
                    if tri_valid = '1' then
                        -- Store triangle and bin it
                        -- (Simplified: actual impl needs binner integration)
                        tri_mem_wr_valid <= '1';
                        tri_mem_wr_addr <= std_logic_vector(tri_store_count);
                        tri_mem_wr_data <= v2_color & v1_color & v0_color &
                                          v2_uv & v1_uv & v0_uv &
                                          v2_pos & v1_pos & v0_pos;
                        
                        tri_store_count <= tri_store_count + 1;
                        stat_triangles <= stat_triangles + 1;
                        
                        if tri_last = '1' then
                            tri_ready <= '0';
                            state <= BINNING_DONE;
                        end if;
                    end if;
                
                when BINNING_DONE =>
                    -- Initialize tile traversal
                    cur_tile_x <= (others => '0');
                    cur_tile_y <= (others => '0');
                    state <= START_TILE;
                
                when START_TILE =>
                    state <= CLEAR_TILE;
                
                when CLEAR_TILE =>
                    tile_clear <= '1';
                    
                    if tile_clear_done = '1' then
                        tile_clear <= '0';
                        cur_tile_tri_ptr <= (others => '0');
                        state <= LOAD_TRI_LIST;
                    end if;
                
                when LOAD_TRI_LIST =>
                    -- For simplified implementation, iterate all triangles
                    -- Real impl would load from tile bin list
                    cur_tile_tri_count <= tri_store_count;
                    cur_tile_tri_ptr <= (others => '0');
                    
                    if tri_store_count = 0 then
                        state <= WRITE_TILE;
                    else
                        state <= FETCH_TRIANGLE;
                    end if;
                
                when FETCH_TRIANGLE =>
                    -- Fetch triangle from storage
                    tri_mem_rd_addr <= std_logic_vector(cur_tile_tri_ptr);
                    
                    -- Unpack triangle data (1 cycle delay assumed)
                    lat_v0_x <= tri_mem_rd_data(31 downto 0);
                    lat_v0_y <= tri_mem_rd_data(63 downto 32);
                    lat_v0_z <= tri_mem_rd_data(95 downto 64);
                    lat_v1_x <= tri_mem_rd_data(127 downto 96);
                    lat_v1_y <= tri_mem_rd_data(159 downto 128);
                    lat_v1_z <= tri_mem_rd_data(191 downto 160);
                    lat_v2_x <= tri_mem_rd_data(223 downto 192);
                    lat_v2_y <= tri_mem_rd_data(255 downto 224);
                    lat_v2_z <= tri_mem_rd_data(287 downto 256);
                    lat_v0_u <= tri_mem_rd_data(319 downto 288);
                    lat_v0_v <= tri_mem_rd_data(351 downto 320);
                    lat_v1_u <= tri_mem_rd_data(383 downto 352);
                    lat_v1_v <= tri_mem_rd_data(415 downto 384);
                    lat_v2_u <= tri_mem_rd_data(447 downto 416);
                    lat_v2_v <= tri_mem_rd_data(479 downto 448);
                    lat_v0_color <= tri_mem_rd_data(511 downto 480);
                    lat_v1_color <= tri_mem_rd_data(543 downto 512);
                    lat_v2_color <= tri_mem_rd_data(575 downto 544);
                    
                    state <= RASTERIZE;
                
                when RASTERIZE =>
                    rast_tri_valid <= '1';
                    
                    if rast_tri_ready = '1' then
                        rast_tri_valid <= '0';
                    end if;
                    
                    -- Wait for rasterization to complete
                    if rast_tri_done = '1' then
                        batch_end_prim <= '1';  -- Flush partial warp
                        state <= NEXT_TRIANGLE;
                    end if;
                
                when SHADE_FRAGMENTS =>
                    -- Handled by external SIMT shader
                    -- Results come back via shader_result interface
                    state <= ROP_WRITEBACK;
                
                when ROP_WRITEBACK =>
                    -- Write shader results to tile buffer
                    -- (Simplified: depth test happens here)
                    for i in 0 to WARP_SIZE-1 loop
                        if shader_result_mask(i) = '1' then
                            -- Extract local tile coordinates
                            tile_wr_x <= shader_result_x((i+1)*16-6 downto i*16);
                            tile_wr_y <= shader_result_y((i+1)*16-6 downto i*16);
                            tile_wr_color <= shader_result_color((i+1)*32-1 downto i*32);
                            tile_wr_depth <= shader_result_z((i+1)*24-1 downto i*24);
                            tile_wr_en <= '1';
                        end if;
                    end loop;
                    
                    stat_fragments <= stat_fragments + 1;
                    state <= NEXT_TRIANGLE;
                
                when NEXT_TRIANGLE =>
                    cur_tile_tri_ptr <= cur_tile_tri_ptr + 1;
                    
                    if cur_tile_tri_ptr + 1 >= cur_tile_tri_count then
                        state <= WRITE_TILE;
                    else
                        state <= FETCH_TRIANGLE;
                    end if;
                
                when WRITE_TILE =>
                    -- DMA tile buffer to framebuffer
                    wb_pixel_x <= (others => '0');
                    wb_pixel_y <= (others => '0');
                    
                    -- Calculate screen address for tile
                    wb_screen_addr <= resize(
                        (cur_tile_y * TILE_SIZE * SCREEN_WIDTH + cur_tile_x * TILE_SIZE) * 4, 
                        32);
                    
                    -- Simple sequential writeback (can be optimized with burst)
                    tile_readback_x <= (others => '0');
                    tile_readback_y <= (others => '0');
                    
                    fb_wr_valid <= '1';
                    fb_wr_addr <= std_logic_vector(wb_screen_addr);
                    fb_wr_data <= tile_readback_color;
                    
                    if fb_wr_ready = '1' then
                        if wb_pixel_x = TILE_SIZE - 1 then
                            wb_pixel_x <= (others => '0');
                            if wb_pixel_y = TILE_SIZE - 1 then
                                fb_wr_valid <= '0';
                                stat_tiles <= stat_tiles + 1;
                                state <= NEXT_TILE;
                            else
                                wb_pixel_y <= wb_pixel_y + 1;
                            end if;
                        else
                            wb_pixel_x <= wb_pixel_x + 1;
                        end if;
                        
                        -- Update addresses
                        tile_readback_x <= std_logic_vector(wb_pixel_x + 1);
                        tile_readback_y <= std_logic_vector(wb_pixel_y);
                        wb_screen_addr <= wb_screen_addr + 4;
                    end if;
                
                when NEXT_TILE =>
                    if cur_tile_x = TILES_X - 1 then
                        cur_tile_x <= (others => '0');
                        if cur_tile_y = TILES_Y - 1 then
                            state <= FRAME_DONE;
                        else
                            cur_tile_y <= cur_tile_y + 1;
                            state <= START_TILE;
                        end if;
                    else
                        cur_tile_x <= cur_tile_x + 1;
                        state <= START_TILE;
                    end if;
                
                when FRAME_DONE =>
                    frame_done <= '1';
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
