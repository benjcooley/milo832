-------------------------------------------------------------------------------
-- texture_unit.vhd
-- SIMT-Integrated Texture Unit with Block Cache and Coalescing
-- Supports 32 parallel texture samples per warp
--
-- Key optimization: ETC blocks are decoded once and shared by all threads
-- that need texels from the same 4x4 block
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.simt_pkg.all;

entity texture_unit is
    generic (
        WARP_SIZE       : integer := 32;
        BLOCK_CACHE_SIZE: integer := 16;     -- Number of decoded blocks to cache
        MAX_TEX_DIM     : integer := 2048;
        MAX_MIP_LEVELS  : integer := 11
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -----------------------------------------------------------------------
        -- SIMT Pipeline Interface (from Operand Collector)
        -----------------------------------------------------------------------
        req_valid       : in  std_logic;
        req_ready       : out std_logic;
        req_warp        : in  std_logic_vector(4 downto 0);
        req_mask        : in  std_logic_vector(WARP_SIZE-1 downto 0);
        req_op          : in  std_logic_vector(1 downto 0);  -- 00=TEX, 01=TXL, 10=TXB
        
        -- UV coordinates for all 32 threads (fixed point 16.16)
        req_u           : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        req_v           : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        req_lod         : in  std_logic_vector(WARP_SIZE*8-1 downto 0);
        
        -- Texture descriptor
        tex_base_addr   : in  std_logic_vector(31 downto 0);
        tex_width       : in  std_logic_vector(11 downto 0);
        tex_height      : in  std_logic_vector(11 downto 0);
        tex_format      : in  std_logic_vector(3 downto 0);
        tex_wrap_mode   : in  std_logic_vector(3 downto 0);   -- [3:2]=V, [1:0]=U
        tex_filter      : in  std_logic;                       -- 0=nearest, 1=bilinear
        tex_mip_count   : in  std_logic_vector(3 downto 0);
        tex_palette_addr: in  std_logic_vector(31 downto 0);
        
        -----------------------------------------------------------------------
        -- Writeback Interface (to Register File)
        -----------------------------------------------------------------------
        wb_valid        : out std_logic;
        wb_warp         : out std_logic_vector(4 downto 0);
        wb_mask         : out std_logic_vector(WARP_SIZE-1 downto 0);
        wb_data         : out std_logic_vector(WARP_SIZE*32-1 downto 0);
        
        -----------------------------------------------------------------------
        -- Memory Interface
        -----------------------------------------------------------------------
        mem_req_valid   : out std_logic;
        mem_req_addr    : out std_logic_vector(31 downto 0);
        mem_req_ready   : in  std_logic;
        
        mem_resp_valid  : in  std_logic;
        mem_resp_data   : in  std_logic_vector(63 downto 0);  -- 64 bits = 1 ETC block
        
        -----------------------------------------------------------------------
        -- Status
        -----------------------------------------------------------------------
        busy            : out std_logic;
        cache_hits      : out std_logic_vector(31 downto 0);
        cache_misses    : out std_logic_vector(31 downto 0)
    );
end entity texture_unit;

architecture rtl of texture_unit is

    ---------------------------------------------------------------------------
    -- Texture Format Constants
    ---------------------------------------------------------------------------
    constant FMT_RGBA8888   : std_logic_vector(3 downto 0) := "1000";
    constant FMT_ETC1       : std_logic_vector(3 downto 0) := "0101";
    constant FMT_ETC2_RGB   : std_logic_vector(3 downto 0) := "0110";
    constant FMT_ETC2_RGBA  : std_logic_vector(3 downto 0) := "0111";
    
    ---------------------------------------------------------------------------
    -- Wrap Mode Constants
    ---------------------------------------------------------------------------
    constant WRAP_REPEAT    : std_logic_vector(1 downto 0) := "00";
    constant WRAP_CLAMP     : std_logic_vector(1 downto 0) := "01";
    constant WRAP_MIRROR    : std_logic_vector(1 downto 0) := "10";
    
    ---------------------------------------------------------------------------
    -- State Machine
    ---------------------------------------------------------------------------
    type state_t is (
        IDLE,
        CALC_COORDS,        -- Calculate texel coordinates for all threads
        CALC_BLOCKS,        -- Calculate block addresses, find unique blocks
        CACHE_CHECK,        -- Check cache for current block
        FETCH_BLOCK,        -- Issue memory request for block
        WAIT_MEM,           -- Wait for memory response
        DECODE_BLOCK,       -- Decode ETC block (all 16 texels)
        NEXT_BLOCK,         -- Move to next unique block
        GATHER_TEXELS,      -- Scatter decoded texels to threads
        FILTER,             -- Apply bilinear filtering
        WRITEBACK           -- Write results
    );
    signal state : state_t := IDLE;
    
    ---------------------------------------------------------------------------
    -- Request Latches
    ---------------------------------------------------------------------------
    signal lat_warp     : std_logic_vector(4 downto 0);
    signal lat_mask     : std_logic_vector(WARP_SIZE-1 downto 0);
    signal lat_filter   : std_logic;
    signal lat_format   : std_logic_vector(3 downto 0);
    signal lat_base     : unsigned(31 downto 0);
    signal lat_width    : unsigned(11 downto 0);
    signal lat_height   : unsigned(11 downto 0);
    signal lat_wrap_u   : std_logic_vector(1 downto 0);
    signal lat_wrap_v   : std_logic_vector(1 downto 0);
    
    ---------------------------------------------------------------------------
    -- Per-Thread Coordinates
    ---------------------------------------------------------------------------
    type coord_array_t is array (0 to WARP_SIZE-1) of unsigned(11 downto 0);
    type frac_array_t is array (0 to WARP_SIZE-1) of unsigned(7 downto 0);
    type block_addr_array_t is array (0 to WARP_SIZE-1) of unsigned(31 downto 0);
    type local_coord_array_t is array (0 to WARP_SIZE-1) of unsigned(1 downto 0);
    
    -- Texel coordinates (integer part)
    signal texel_u, texel_v : coord_array_t;
    -- Fractional parts for bilinear (8-bit)
    signal frac_u, frac_v : frac_array_t;
    -- Block address for each thread's texel
    signal thread_block_addr : block_addr_array_t;
    -- Position within 4x4 block (0-3)
    signal thread_local_x, thread_local_y : local_coord_array_t;
    
    ---------------------------------------------------------------------------
    -- Unique Block Queue
    ---------------------------------------------------------------------------
    constant MAX_UNIQUE_BLOCKS : integer := 32;  -- Worst case: all threads need different blocks
    
    type unique_block_t is record
        valid       : std_logic;
        addr        : unsigned(31 downto 0);
        decoded     : std_logic;
        texels      : std_logic_vector(16*32-1 downto 0);  -- All 16 decoded texels
    end record;
    
    type unique_blocks_t is array (0 to MAX_UNIQUE_BLOCKS-1) of unique_block_t;
    signal unique_blocks : unique_blocks_t;
    signal num_unique_blocks : integer range 0 to MAX_UNIQUE_BLOCKS;
    signal current_block_idx : integer range 0 to MAX_UNIQUE_BLOCKS;
    
    -- Mapping from thread to unique block index
    type thread_block_map_t is array (0 to WARP_SIZE-1) of integer range 0 to MAX_UNIQUE_BLOCKS-1;
    signal thread_to_block : thread_block_map_t;
    
    ---------------------------------------------------------------------------
    -- Block Cache (LRU, stores decoded blocks)
    ---------------------------------------------------------------------------
    type cache_entry_t is record
        valid   : std_logic;
        addr    : unsigned(31 downto 0);
        texels  : std_logic_vector(16*32-1 downto 0);
        age     : unsigned(3 downto 0);  -- For LRU
    end record;
    
    type block_cache_t is array (0 to BLOCK_CACHE_SIZE-1) of cache_entry_t;
    signal block_cache : block_cache_t;
    
    ---------------------------------------------------------------------------
    -- ETC Decoder Interface
    ---------------------------------------------------------------------------
    signal etc_valid_in     : std_logic;
    signal etc_ready        : std_logic;
    signal etc_format       : std_logic_vector(1 downto 0);
    signal etc_block_rgb    : std_logic_vector(63 downto 0);
    signal etc_block_alpha  : std_logic_vector(63 downto 0);
    signal etc_valid_out    : std_logic;
    signal etc_rgba_out     : std_logic_vector(16*32-1 downto 0);
    
    ---------------------------------------------------------------------------
    -- Filtered Results
    ---------------------------------------------------------------------------
    type texel_array_t is array (0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    signal thread_texels : texel_array_t;
    signal filtered_results : texel_array_t;
    
    ---------------------------------------------------------------------------
    -- Statistics
    ---------------------------------------------------------------------------
    signal hit_count, miss_count : unsigned(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Memory Response Latch
    ---------------------------------------------------------------------------
    signal mem_data_lat : std_logic_vector(63 downto 0);
    
    ---------------------------------------------------------------------------
    -- Helper Functions
    ---------------------------------------------------------------------------
    
    function apply_wrap(
        coord : signed(31 downto 0);
        size  : unsigned(11 downto 0);
        mode  : std_logic_vector(1 downto 0)
    ) return unsigned is
        variable texel : integer;
        variable size_int : integer;
    begin
        size_int := to_integer(size);
        if size_int = 0 then
            return to_unsigned(0, 12);
        end if;
        
        -- Convert from 16.16 fixed point to integer texel coordinate
        texel := to_integer(shift_right(coord, 16));
        
        case mode is
            when WRAP_REPEAT =>
                texel := texel mod size_int;
                if texel < 0 then texel := texel + size_int; end if;
            when WRAP_CLAMP =>
                if texel < 0 then texel := 0;
                elsif texel >= size_int then texel := size_int - 1; end if;
            when WRAP_MIRROR =>
                texel := texel mod (2 * size_int);
                if texel < 0 then texel := texel + 2 * size_int; end if;
                if texel >= size_int then texel := 2 * size_int - 1 - texel; end if;
            when others =>
                if texel < 0 then texel := 0;
                elsif texel >= size_int then texel := size_int - 1; end if;
        end case;
        
        return to_unsigned(texel, 12);
    end function;
    
    -- Bilinear interpolation for one channel
    function bilinear_channel(
        c00, c10, c01, c11 : unsigned(7 downto 0);
        fu, fv : unsigned(7 downto 0)
    ) return unsigned is
        variable inv_fu, inv_fv : unsigned(7 downto 0);
        variable w00, w10, w01, w11 : unsigned(15 downto 0);
        variable sum : unsigned(15 downto 0);
    begin
        inv_fu := 255 - fu;
        inv_fv := 255 - fv;
        
        -- Compute weights (8.8 fixed point intermediate)
        w00 := resize(c00 * inv_fu, 16);
        w10 := resize(c10 * fu, 16);
        w01 := resize(c01 * inv_fu, 16);
        w11 := resize(c11 * fu, 16);
        
        -- Interpolate rows then combine
        sum := resize(shift_right(w00 + w10, 8) * inv_fv + 
                      shift_right(w01 + w11, 8) * fv, 16);
        
        return sum(15 downto 8);
    end function;

begin

    ---------------------------------------------------------------------------
    -- ETC Block Decoder Instance
    ---------------------------------------------------------------------------
    etc_decoder_inst: entity work.etc_block_decoder
        port map (
            clk         => clk,
            rst_n       => rst_n,
            valid_in    => etc_valid_in,
            ready_out   => etc_ready,
            format      => etc_format,
            block_rgb   => etc_block_rgb,
            block_alpha => etc_block_alpha,
            valid_out   => etc_valid_out,
            rgba_out    => etc_rgba_out
        );
    
    ---------------------------------------------------------------------------
    -- Output Assignments
    ---------------------------------------------------------------------------
    req_ready <= '1' when state = IDLE else '0';
    busy <= '0' when state = IDLE else '1';
    cache_hits <= std_logic_vector(hit_count);
    cache_misses <= std_logic_vector(miss_count);
    
    ---------------------------------------------------------------------------
    -- Main State Machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable thread_u_fp, thread_v_fp : signed(31 downto 0);
        variable block_x, block_y : unsigned(11 downto 0);
        variable blocks_per_row : unsigned(11 downto 0);
        variable block_addr : unsigned(31 downto 0);
        variable found : boolean;
        variable cache_hit_idx : integer;
        variable lru_idx : integer;
        variable max_age : unsigned(3 downto 0);
        variable local_idx : integer;
        variable texel_data : std_logic_vector(31 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            wb_valid <= '0';
            mem_req_valid <= '0';
            etc_valid_in <= '0';
            hit_count <= (others => '0');
            miss_count <= (others => '0');
            num_unique_blocks <= 0;
            current_block_idx <= 0;
            
            -- Initialize cache
            for i in 0 to BLOCK_CACHE_SIZE-1 loop
                block_cache(i).valid <= '0';
                block_cache(i).age <= (others => '0');
            end loop;
            
            -- Initialize unique blocks
            for i in 0 to MAX_UNIQUE_BLOCKS-1 loop
                unique_blocks(i).valid <= '0';
                unique_blocks(i).decoded <= '0';
            end loop;
            
        elsif rising_edge(clk) then
            wb_valid <= '0';
            mem_req_valid <= '0';
            etc_valid_in <= '0';
            
            case state is
                ---------------------------------------------------------------
                when IDLE =>
                    if req_valid = '1' then
                        -- Latch request parameters
                        lat_warp <= req_warp;
                        lat_mask <= req_mask;
                        lat_filter <= tex_filter;
                        lat_format <= tex_format;
                        lat_base <= unsigned(tex_base_addr);
                        lat_width <= unsigned(tex_width);
                        lat_height <= unsigned(tex_height);
                        lat_wrap_u <= tex_wrap_mode(1 downto 0);
                        lat_wrap_v <= tex_wrap_mode(3 downto 2);
                        
                        -- Clear unique blocks
                        num_unique_blocks <= 0;
                        for i in 0 to MAX_UNIQUE_BLOCKS-1 loop
                            unique_blocks(i).valid <= '0';
                            unique_blocks(i).decoded <= '0';
                        end loop;
                        
                        state <= CALC_COORDS;
                    end if;
                
                ---------------------------------------------------------------
                when CALC_COORDS =>
                    -- Calculate texel coordinates for all threads
                    for t in 0 to WARP_SIZE-1 loop
                        if lat_mask(t) = '1' then
                            thread_u_fp := signed(req_u((t+1)*32-1 downto t*32));
                            thread_v_fp := signed(req_v((t+1)*32-1 downto t*32));
                            
                            texel_u(t) <= apply_wrap(thread_u_fp, lat_width, lat_wrap_u);
                            texel_v(t) <= apply_wrap(thread_v_fp, lat_height, lat_wrap_v);
                            
                            -- Store fractional parts for bilinear
                            frac_u(t) <= unsigned(thread_u_fp(15 downto 8));
                            frac_v(t) <= unsigned(thread_v_fp(15 downto 8));
                        end if;
                    end loop;
                    
                    state <= CALC_BLOCKS;
                
                ---------------------------------------------------------------
                when CALC_BLOCKS =>
                    -- Calculate block address for each thread and find unique blocks
                    blocks_per_row := shift_right(lat_width + 3, 2);  -- ceil(width/4)
                    
                    for t in 0 to WARP_SIZE-1 loop
                        if lat_mask(t) = '1' then
                            -- Block coordinates (texel / 4)
                            block_x := shift_right(texel_u(t), 2);
                            block_y := shift_right(texel_v(t), 2);
                            
                            -- Local position within block (texel % 4)
                            thread_local_x(t) <= texel_u(t)(1 downto 0);
                            thread_local_y(t) <= texel_v(t)(1 downto 0);
                            
                            -- Block address (8 bytes per ETC1 block)
                            block_addr := lat_base + resize(
                                (resize(block_y, 32) * resize(blocks_per_row, 32) + resize(block_x, 32)) * 8, 
                                32);
                            thread_block_addr(t) <= block_addr;
                            
                            -- Check if this block is already in unique list
                            found := false;
                            for u in 0 to MAX_UNIQUE_BLOCKS-1 loop
                                if unique_blocks(u).valid = '1' and 
                                   unique_blocks(u).addr = block_addr then
                                    thread_to_block(t) <= u;
                                    found := true;
                                    exit;
                                end if;
                            end loop;
                            
                            -- Add new unique block if not found
                            if not found and num_unique_blocks < MAX_UNIQUE_BLOCKS then
                                unique_blocks(num_unique_blocks).valid <= '1';
                                unique_blocks(num_unique_blocks).addr <= block_addr;
                                unique_blocks(num_unique_blocks).decoded <= '0';
                                thread_to_block(t) <= num_unique_blocks;
                                num_unique_blocks <= num_unique_blocks + 1;
                            end if;
                        end if;
                    end loop;
                    
                    current_block_idx <= 0;
                    state <= CACHE_CHECK;
                
                ---------------------------------------------------------------
                when CACHE_CHECK =>
                    if current_block_idx < num_unique_blocks then
                        -- Check if block is in cache
                        cache_hit_idx := -1;
                        for c in 0 to BLOCK_CACHE_SIZE-1 loop
                            if block_cache(c).valid = '1' and 
                               block_cache(c).addr = unique_blocks(current_block_idx).addr then
                                cache_hit_idx := c;
                                exit;
                            end if;
                        end loop;
                        
                        if cache_hit_idx >= 0 then
                            -- Cache hit! Copy decoded texels
                            unique_blocks(current_block_idx).texels <= block_cache(cache_hit_idx).texels;
                            unique_blocks(current_block_idx).decoded <= '1';
                            
                            -- Update LRU
                            block_cache(cache_hit_idx).age <= (others => '0');
                            for c in 0 to BLOCK_CACHE_SIZE-1 loop
                                if c /= cache_hit_idx and block_cache(c).valid = '1' then
                                    block_cache(c).age <= block_cache(c).age + 1;
                                end if;
                            end loop;
                            
                            hit_count <= hit_count + 1;
                            state <= NEXT_BLOCK;
                        else
                            -- Cache miss - fetch from memory
                            miss_count <= miss_count + 1;
                            state <= FETCH_BLOCK;
                        end if;
                    else
                        -- All blocks processed
                        state <= GATHER_TEXELS;
                    end if;
                
                ---------------------------------------------------------------
                when FETCH_BLOCK =>
                    mem_req_valid <= '1';
                    mem_req_addr <= std_logic_vector(unique_blocks(current_block_idx).addr);
                    
                    if mem_req_ready = '1' then
                        mem_req_valid <= '0';
                        state <= WAIT_MEM;
                    end if;
                
                ---------------------------------------------------------------
                when WAIT_MEM =>
                    if mem_resp_valid = '1' then
                        mem_data_lat <= mem_resp_data;
                        
                        -- Check format and decode
                        if lat_format = FMT_ETC1 or lat_format = FMT_ETC2_RGB then
                            -- Start ETC decoder
                            etc_valid_in <= '1';
                            etc_format <= "00";  -- ETC1/ETC2_RGB
                            etc_block_rgb <= mem_resp_data;
                            etc_block_alpha <= (others => '1');  -- Opaque
                            state <= DECODE_BLOCK;
                        elsif lat_format = FMT_RGBA8888 then
                            -- For RGBA8888, data is direct (but we only get 2 texels per 64-bit read)
                            -- This is simplified - real impl would need multiple reads
                            unique_blocks(current_block_idx).texels(63 downto 0) <= mem_resp_data;
                            unique_blocks(current_block_idx).decoded <= '1';
                            state <= NEXT_BLOCK;
                        else
                            -- Other formats - treat as opaque for now
                            etc_valid_in <= '1';
                            etc_format <= "00";
                            etc_block_rgb <= mem_resp_data;
                            etc_block_alpha <= (others => '1');
                            state <= DECODE_BLOCK;
                        end if;
                    end if;
                
                ---------------------------------------------------------------
                when DECODE_BLOCK =>
                    -- Wait for ETC decoder to finish
                    if etc_valid_out = '1' then
                        unique_blocks(current_block_idx).texels <= etc_rgba_out;
                        unique_blocks(current_block_idx).decoded <= '1';
                        
                        -- Update cache (LRU replacement)
                        lru_idx := 0;
                        max_age := (others => '0');
                        for c in 0 to BLOCK_CACHE_SIZE-1 loop
                            if block_cache(c).valid = '0' then
                                lru_idx := c;
                                exit;
                            elsif block_cache(c).age > max_age then
                                max_age := block_cache(c).age;
                                lru_idx := c;
                            end if;
                        end loop;
                        
                        block_cache(lru_idx).valid <= '1';
                        block_cache(lru_idx).addr <= unique_blocks(current_block_idx).addr;
                        block_cache(lru_idx).texels <= etc_rgba_out;
                        block_cache(lru_idx).age <= (others => '0');
                        
                        state <= NEXT_BLOCK;
                    end if;
                
                ---------------------------------------------------------------
                when NEXT_BLOCK =>
                    current_block_idx <= current_block_idx + 1;
                    state <= CACHE_CHECK;
                
                ---------------------------------------------------------------
                when GATHER_TEXELS =>
                    -- Scatter decoded texels to threads
                    for t in 0 to WARP_SIZE-1 loop
                        if lat_mask(t) = '1' then
                            -- Calculate index within 4x4 block
                            local_idx := to_integer(thread_local_y(t)) * 4 + 
                                        to_integer(thread_local_x(t));
                            
                            -- Extract texel from decoded block
                            texel_data := unique_blocks(thread_to_block(t)).texels(
                                (local_idx+1)*32-1 downto local_idx*32);
                            
                            thread_texels(t) <= texel_data;
                        else
                            thread_texels(t) <= (others => '0');
                        end if;
                    end loop;
                    
                    if lat_filter = '1' then
                        state <= FILTER;
                    else
                        -- Nearest neighbor - use directly
                        for t in 0 to WARP_SIZE-1 loop
                            filtered_results(t) <= thread_texels(t);
                        end loop;
                        state <= WRITEBACK;
                    end if;
                
                ---------------------------------------------------------------
                when FILTER =>
                    -- Bilinear filtering would need 4 texels per thread
                    -- For now, simplified: just use nearest neighbor
                    -- TODO: Implement full bilinear with 4 block lookups
                    for t in 0 to WARP_SIZE-1 loop
                        filtered_results(t) <= thread_texels(t);
                    end loop;
                    
                    state <= WRITEBACK;
                
                ---------------------------------------------------------------
                when WRITEBACK =>
                    wb_valid <= '1';
                    wb_warp <= lat_warp;
                    wb_mask <= lat_mask;
                    
                    for t in 0 to WARP_SIZE-1 loop
                        wb_data((t+1)*32-1 downto t*32) <= filtered_results(t);
                    end loop;
                    
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
