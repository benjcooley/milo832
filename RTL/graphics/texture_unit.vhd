-------------------------------------------------------------------------------
-- texture_unit.vhd
-- SIMT-Integrated Texture Unit with Cache and Coalescing
-- Supports 32 parallel texture samples per warp
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
        CACHE_SIZE_KB   : integer := 16;
        CACHE_LINE_BITS : integer := 512;   -- 64 bytes per line
        CACHE_WAYS      : integer := 4;
        PALETTE_SIZE    : integer := 256;
        MAX_TEX_DIM     : integer := 2048;
        MAX_MIP_LEVELS  : integer := 11
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -----------------------------------------------------------------------
        -- SIMT Pipeline Interface (from Operand Collector)
        -----------------------------------------------------------------------
        -- Request from warp (all 32 threads)
        req_valid       : in  std_logic;
        req_ready       : out std_logic;
        req_warp        : in  std_logic_vector(4 downto 0);
        req_mask        : in  std_logic_vector(WARP_SIZE-1 downto 0);
        req_op          : in  std_logic_vector(1 downto 0);  -- 00=TEX, 01=TXL, 10=TXB
        
        -- UV coordinates for all 32 threads (fixed point 16.16)
        req_u           : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        req_v           : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        req_lod         : in  std_logic_vector(WARP_SIZE*8-1 downto 0);  -- Per-thread LOD
        
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
        wb_data         : out std_logic_vector(WARP_SIZE*32-1 downto 0);  -- RGBA per thread
        
        -----------------------------------------------------------------------
        -- Memory Interface
        -----------------------------------------------------------------------
        mem_req_valid   : out std_logic;
        mem_req_addr    : out std_logic_vector(31 downto 0);
        mem_req_ready   : in  std_logic;
        
        mem_resp_valid  : in  std_logic;
        mem_resp_data   : in  std_logic_vector(CACHE_LINE_BITS-1 downto 0);
        
        -----------------------------------------------------------------------
        -- Palette Memory Interface (separate port for indexed textures)
        -----------------------------------------------------------------------
        pal_rd_addr     : out std_logic_vector(7 downto 0);
        pal_rd_data     : in  std_logic_vector(31 downto 0);
        
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
    constant FMT_MONO1      : std_logic_vector(3 downto 0) := "0000";
    constant FMT_PAL4       : std_logic_vector(3 downto 0) := "0001";
    constant FMT_PAL8       : std_logic_vector(3 downto 0) := "0010";
    constant FMT_RGBA4444   : std_logic_vector(3 downto 0) := "0011";
    constant FMT_RGB565     : std_logic_vector(3 downto 0) := "0100";
    constant FMT_ETC1       : std_logic_vector(3 downto 0) := "0101";
    constant FMT_ETC2_RGB   : std_logic_vector(3 downto 0) := "0110";
    constant FMT_ETC2_RGBA  : std_logic_vector(3 downto 0) := "0111";
    constant FMT_RGBA8888   : std_logic_vector(3 downto 0) := "1000";
    
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
        ADDR_GEN,           -- Generate texel addresses for all threads
        COALESCE,           -- Coalesce requests by cache line
        CACHE_LOOKUP,       -- Check cache for each unique request
        ISSUE_MISS,         -- Issue memory request for cache miss
        WAIT_MEM,           -- Wait for memory response
        DECODE_TEXELS,      -- Decode texture format
        FILTER,             -- Apply bilinear filtering
        WRITEBACK           -- Write results to register file
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
    -- Per-Thread Texel Coordinates (after address generation)
    ---------------------------------------------------------------------------
    type coord_array_t is array (0 to WARP_SIZE-1) of unsigned(11 downto 0);
    type frac_array_t is array (0 to WARP_SIZE-1) of unsigned(15 downto 0);
    
    -- For bilinear: each thread needs 4 texel coordinates
    signal texel_u0, texel_u1 : coord_array_t;
    signal texel_v0, texel_v1 : coord_array_t;
    signal frac_u, frac_v : frac_array_t;
    
    ---------------------------------------------------------------------------
    -- Coalesced Request Queue
    ---------------------------------------------------------------------------
    constant MAX_COALESCED : integer := 32;  -- Max unique cache line requests
    
    type coal_entry_t is record
        valid       : std_logic;
        addr        : unsigned(31 downto 0);
        thread_mask : std_logic_vector(WARP_SIZE-1 downto 0);  -- Which threads need this
        texel_idx   : std_logic_vector(1 downto 0);  -- Which of 4 texels (bilinear)
    end record;
    
    type coal_queue_t is array (0 to MAX_COALESCED-1) of coal_entry_t;
    signal coal_queue : coal_queue_t;
    signal coal_count : integer range 0 to MAX_COALESCED;
    signal coal_ptr   : integer range 0 to MAX_COALESCED;
    
    ---------------------------------------------------------------------------
    -- Cache
    ---------------------------------------------------------------------------
    constant CACHE_LINES : integer := (CACHE_SIZE_KB * 1024 * 8) / CACHE_LINE_BITS;
    constant CACHE_SETS  : integer := CACHE_LINES / CACHE_WAYS;
    constant SET_BITS    : integer := 6;  -- log2(CACHE_SETS)
    constant TAG_BITS    : integer := 32 - SET_BITS - 6;  -- 6 bits for 64-byte line offset
    
    type cache_tag_t is record
        valid : std_logic;
        tag   : std_logic_vector(TAG_BITS-1 downto 0);
    end record;
    
    type cache_tags_t is array (0 to CACHE_SETS-1, 0 to CACHE_WAYS-1) of cache_tag_t;
    type cache_data_t is array (0 to CACHE_SETS-1, 0 to CACHE_WAYS-1) of 
                         std_logic_vector(CACHE_LINE_BITS-1 downto 0);
    type cache_lru_t is array (0 to CACHE_SETS-1) of unsigned(CACHE_WAYS-1 downto 0);
    
    signal cache_tags : cache_tags_t;
    signal cache_data : cache_data_t;
    signal cache_lru  : cache_lru_t;
    
    signal cache_hit      : std_logic;
    signal cache_hit_way  : integer range 0 to CACHE_WAYS-1;
    signal cache_hit_data : std_logic_vector(CACHE_LINE_BITS-1 downto 0);
    
    ---------------------------------------------------------------------------
    -- Texel Data (after fetch and decode)
    ---------------------------------------------------------------------------
    type texel_rgba_t is array (0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    
    -- 4 texels per thread for bilinear
    signal texel_00, texel_10, texel_01, texel_11 : texel_rgba_t;
    
    -- Filtered results
    signal filtered_results : texel_rgba_t;
    
    ---------------------------------------------------------------------------
    -- Statistics
    ---------------------------------------------------------------------------
    signal hit_count, miss_count : unsigned(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Helper Functions
    ---------------------------------------------------------------------------
    
    -- Extract U coordinate for thread i
    function get_thread_u(u_flat : std_logic_vector; idx : integer) return signed is
    begin
        return signed(u_flat((idx+1)*32-1 downto idx*32));
    end function;
    
    -- Extract V coordinate for thread i
    function get_thread_v(v_flat : std_logic_vector; idx : integer) return signed is
    begin
        return signed(v_flat((idx+1)*32-1 downto idx*32));
    end function;
    
    -- Apply wrap mode
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
        
        -- Multiply normalized coord by size, extract integer part
        texel := to_integer(shift_right(coord * signed(resize(size, 32)), 16));
        
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
    
    -- Get bytes per pixel for format
    function get_bpp(fmt : std_logic_vector(3 downto 0)) return integer is
    begin
        case fmt is
            when FMT_MONO1      => return 1;  -- Actually 1/8, handled specially
            when FMT_PAL4       => return 1;  -- Actually 1/2
            when FMT_PAL8       => return 1;
            when FMT_RGBA4444   => return 2;
            when FMT_RGB565     => return 2;
            when FMT_ETC1       => return 8;  -- 64 bits per 4x4 block
            when FMT_ETC2_RGB   => return 8;
            when FMT_ETC2_RGBA  => return 16; -- 128 bits per 4x4 block
            when FMT_RGBA8888   => return 4;
            when others         => return 4;
        end case;
    end function;
    
    -- Calculate cache line address
    function get_cache_line_addr(addr : unsigned(31 downto 0)) return unsigned is
    begin
        return addr(31 downto 6) & "000000";  -- Align to 64-byte boundary
    end function;
    
    -- ETC1 block decompression (simplified)
    function decode_etc1_texel(
        block_data : std_logic_vector(63 downto 0);
        x, y : integer  -- Position within 4x4 block (0-3)
    ) return std_logic_vector is
        variable base_r, base_g, base_b : unsigned(7 downto 0);
        variable modifier : signed(7 downto 0);
        variable pixel_idx : integer;
        variable result : std_logic_vector(31 downto 0);
    begin
        -- Simplified ETC1 decode - real implementation is more complex
        -- This extracts base color and applies modifier table
        
        pixel_idx := y * 4 + x;
        
        -- Base color from block header (simplified - real ETC has two subblocks)
        base_r := unsigned(block_data(63 downto 60)) & "0000";
        base_g := unsigned(block_data(55 downto 52)) & "0000";
        base_b := unsigned(block_data(47 downto 44)) & "0000";
        
        -- Get 2-bit modifier index for this pixel
        -- Modifier tables would apply here
        
        result := std_logic_vector(base_r) & std_logic_vector(base_g) & 
                  std_logic_vector(base_b) & x"FF";
        return result;
    end function;
    
    -- Bilinear interpolation for one channel
    function bilinear_channel(
        c00, c10, c01, c11 : unsigned(7 downto 0);
        fu, fv : unsigned(15 downto 0)
    ) return unsigned is
        variable top, bot : unsigned(23 downto 0);
        variable result : unsigned(23 downto 0);
        variable inv_fu, inv_fv : unsigned(15 downto 0);
    begin
        inv_fu := x"FFFF" - fu;
        inv_fv := x"FFFF" - fv;
        
        -- Interpolate top row
        top := resize(c00 * inv_fu(15 downto 8), 24) + resize(c10 * fu(15 downto 8), 24);
        -- Interpolate bottom row
        bot := resize(c01 * inv_fu(15 downto 8), 24) + resize(c11 * fu(15 downto 8), 24);
        -- Interpolate between rows
        result := resize(top(23 downto 8) * inv_fv(15 downto 8), 24) + 
                  resize(bot(23 downto 8) * fv(15 downto 8), 24);
        
        return result(23 downto 16);
    end function;

begin

    -- Output assignments
    req_ready <= '1' when state = IDLE else '0';
    busy <= '0' when state = IDLE else '1';
    cache_hits <= std_logic_vector(hit_count);
    cache_misses <= std_logic_vector(miss_count);
    
    ---------------------------------------------------------------------------
    -- Main State Machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable thread_u, thread_v : signed(31 downto 0);
        variable set_idx : integer;
        variable tag_val : std_logic_vector(TAG_BITS-1 downto 0);
        variable hit_found : boolean;
        variable replace_way : integer;
    begin
        if rst_n = '0' then
            state <= IDLE;
            wb_valid <= '0';
            mem_req_valid <= '0';
            hit_count <= (others => '0');
            miss_count <= (others => '0');
            coal_count <= 0;
            coal_ptr <= 0;
            
            -- Initialize cache tags as invalid
            for s in 0 to CACHE_SETS-1 loop
                for w in 0 to CACHE_WAYS-1 loop
                    cache_tags(s, w).valid <= '0';
                end loop;
                cache_lru(s) <= (others => '0');
            end loop;
            
        elsif rising_edge(clk) then
            -- Default outputs
            wb_valid <= '0';
            mem_req_valid <= '0';
            
            case state is
                ---------------------------------------------------------------
                when IDLE =>
                    if req_valid = '1' then
                        -- Latch request
                        lat_warp <= req_warp;
                        lat_mask <= req_mask;
                        lat_filter <= tex_filter;
                        lat_format <= tex_format;
                        lat_base <= unsigned(tex_base_addr);
                        lat_width <= unsigned(tex_width);
                        lat_height <= unsigned(tex_height);
                        lat_wrap_u <= tex_wrap_mode(1 downto 0);
                        lat_wrap_v <= tex_wrap_mode(3 downto 2);
                        
                        state <= ADDR_GEN;
                    end if;
                
                ---------------------------------------------------------------
                when ADDR_GEN =>
                    -- Generate texel coordinates for all active threads
                    for t in 0 to WARP_SIZE-1 loop
                        if lat_mask(t) = '1' then
                            thread_u := get_thread_u(req_u, t);
                            thread_v := get_thread_v(req_v, t);
                            
                            -- Primary texel (for nearest) or top-left (for bilinear)
                            texel_u0(t) <= apply_wrap(thread_u, lat_width, lat_wrap_u);
                            texel_v0(t) <= apply_wrap(thread_v, lat_height, lat_wrap_v);
                            
                            if lat_filter = '1' then
                                -- Adjacent texels for bilinear
                                texel_u1(t) <= apply_wrap(thread_u + 65536, lat_width, lat_wrap_u);
                                texel_v1(t) <= apply_wrap(thread_v + 65536, lat_height, lat_wrap_v);
                                
                                -- Fractional parts
                                frac_u(t) <= unsigned(thread_u(15 downto 0));
                                frac_v(t) <= unsigned(thread_v(15 downto 0));
                            end if;
                        end if;
                    end loop;
                    
                    state <= COALESCE;
                
                ---------------------------------------------------------------
                when COALESCE =>
                    -- Build coalesced request queue
                    -- Group by cache line address
                    coal_count <= 0;
                    
                    -- TODO: Implement full coalescing logic
                    -- For now, simplified: one request per active thread's primary texel
                    for t in 0 to WARP_SIZE-1 loop
                        if lat_mask(t) = '1' then
                            coal_queue(coal_count).valid <= '1';
                            coal_queue(coal_count).addr <= lat_base + 
                                resize(texel_v0(t) * lat_width + texel_u0(t), 32) * 
                                to_unsigned(get_bpp(lat_format), 32);
                            coal_queue(coal_count).thread_mask <= (others => '0');
                            coal_queue(coal_count).thread_mask(t) <= '1';
                            coal_queue(coal_count).texel_idx <= "00";
                        end if;
                    end loop;
                    
                    coal_ptr <= 0;
                    state <= CACHE_LOOKUP;
                
                ---------------------------------------------------------------
                when CACHE_LOOKUP =>
                    if coal_ptr < coal_count then
                        -- Check cache for current coalesced request
                        set_idx := to_integer(coal_queue(coal_ptr).addr(SET_BITS+5 downto 6));
                        tag_val := std_logic_vector(coal_queue(coal_ptr).addr(31 downto SET_BITS+6));
                        
                        hit_found := false;
                        for w in 0 to CACHE_WAYS-1 loop
                            if cache_tags(set_idx, w).valid = '1' and 
                               cache_tags(set_idx, w).tag = tag_val then
                                -- Cache hit
                                hit_found := true;
                                cache_hit <= '1';
                                cache_hit_way <= w;
                                cache_hit_data <= cache_data(set_idx, w);
                                hit_count <= hit_count + 1;
                                exit;
                            end if;
                        end loop;
                        
                        if hit_found then
                            -- Process hit, move to next request
                            coal_ptr <= coal_ptr + 1;
                        else
                            -- Cache miss - need to fetch
                            cache_hit <= '0';
                            miss_count <= miss_count + 1;
                            state <= ISSUE_MISS;
                        end if;
                    else
                        -- All requests satisfied
                        state <= DECODE_TEXELS;
                    end if;
                
                ---------------------------------------------------------------
                when ISSUE_MISS =>
                    mem_req_valid <= '1';
                    mem_req_addr <= std_logic_vector(get_cache_line_addr(coal_queue(coal_ptr).addr));
                    
                    if mem_req_ready = '1' then
                        mem_req_valid <= '0';
                        state <= WAIT_MEM;
                    end if;
                
                ---------------------------------------------------------------
                when WAIT_MEM =>
                    if mem_resp_valid = '1' then
                        -- Fill cache
                        set_idx := to_integer(coal_queue(coal_ptr).addr(SET_BITS+5 downto 6));
                        tag_val := std_logic_vector(coal_queue(coal_ptr).addr(31 downto SET_BITS+6));
                        
                        -- Find replacement way (LRU)
                        replace_way := to_integer(cache_lru(set_idx));
                        
                        cache_tags(set_idx, replace_way).valid <= '1';
                        cache_tags(set_idx, replace_way).tag <= tag_val;
                        cache_data(set_idx, replace_way) <= mem_resp_data;
                        
                        -- Update LRU
                        cache_lru(set_idx) <= cache_lru(set_idx) + 1;
                        
                        -- Continue with next request
                        coal_ptr <= coal_ptr + 1;
                        state <= CACHE_LOOKUP;
                    end if;
                
                ---------------------------------------------------------------
                when DECODE_TEXELS =>
                    -- Decode texel data based on format
                    for t in 0 to WARP_SIZE-1 loop
                        if lat_mask(t) = '1' then
                            -- TODO: Full format decoding
                            -- For now, assume RGBA8888
                            texel_00(t) <= cache_hit_data(31 downto 0);
                            texel_10(t) <= cache_hit_data(63 downto 32);
                            texel_01(t) <= cache_hit_data(95 downto 64);
                            texel_11(t) <= cache_hit_data(127 downto 96);
                        end if;
                    end loop;
                    
                    if lat_filter = '1' then
                        state <= FILTER;
                    else
                        -- Nearest neighbor - use texel_00 directly
                        for t in 0 to WARP_SIZE-1 loop
                            filtered_results(t) <= texel_00(t);
                        end loop;
                        state <= WRITEBACK;
                    end if;
                
                ---------------------------------------------------------------
                when FILTER =>
                    -- Apply bilinear filtering
                    for t in 0 to WARP_SIZE-1 loop
                        if lat_mask(t) = '1' then
                            filtered_results(t)(31 downto 24) <= std_logic_vector(
                                bilinear_channel(
                                    unsigned(texel_00(t)(31 downto 24)),
                                    unsigned(texel_10(t)(31 downto 24)),
                                    unsigned(texel_01(t)(31 downto 24)),
                                    unsigned(texel_11(t)(31 downto 24)),
                                    frac_u(t), frac_v(t)
                                ));
                            filtered_results(t)(23 downto 16) <= std_logic_vector(
                                bilinear_channel(
                                    unsigned(texel_00(t)(23 downto 16)),
                                    unsigned(texel_10(t)(23 downto 16)),
                                    unsigned(texel_01(t)(23 downto 16)),
                                    unsigned(texel_11(t)(23 downto 16)),
                                    frac_u(t), frac_v(t)
                                ));
                            filtered_results(t)(15 downto 8) <= std_logic_vector(
                                bilinear_channel(
                                    unsigned(texel_00(t)(15 downto 8)),
                                    unsigned(texel_10(t)(15 downto 8)),
                                    unsigned(texel_01(t)(15 downto 8)),
                                    unsigned(texel_11(t)(15 downto 8)),
                                    frac_u(t), frac_v(t)
                                ));
                            filtered_results(t)(7 downto 0) <= std_logic_vector(
                                bilinear_channel(
                                    unsigned(texel_00(t)(7 downto 0)),
                                    unsigned(texel_10(t)(7 downto 0)),
                                    unsigned(texel_01(t)(7 downto 0)),
                                    unsigned(texel_11(t)(7 downto 0)),
                                    frac_u(t), frac_v(t)
                                ));
                        end if;
                    end loop;
                    
                    state <= WRITEBACK;
                
                ---------------------------------------------------------------
                when WRITEBACK =>
                    wb_valid <= '1';
                    wb_warp <= lat_warp;
                    wb_mask <= lat_mask;
                    
                    -- Pack results
                    for t in 0 to WARP_SIZE-1 loop
                        wb_data((t+1)*32-1 downto t*32) <= filtered_results(t);
                    end loop;
                    
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
