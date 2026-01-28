-------------------------------------------------------------------------------
-- texture_unit_array.vhd
-- Multiple Texture Units with Request Arbitration
-- Distributes warp texture requests across N parallel texture units
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.simt_pkg.all;

entity texture_unit_array is
    generic (
        NUM_TEX_UNITS   : integer := 2;      -- Number of parallel texture units
        WARP_SIZE       : integer := 32;
        BLOCK_CACHE_SIZE: integer := 16;     -- Per-unit cache size
        MAX_TEX_DIM     : integer := 2048
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -----------------------------------------------------------------------
        -- SIMT Pipeline Interface (from Shader Core)
        -----------------------------------------------------------------------
        req_valid       : in  std_logic;
        req_ready       : out std_logic;
        req_warp        : in  std_logic_vector(4 downto 0);
        req_mask        : in  std_logic_vector(WARP_SIZE-1 downto 0);
        req_op          : in  std_logic_vector(1 downto 0);
        
        req_u           : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        req_v           : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        req_lod         : in  std_logic_vector(WARP_SIZE*8-1 downto 0);
        
        -- Texture descriptor
        tex_base_addr   : in  std_logic_vector(31 downto 0);
        tex_width       : in  std_logic_vector(11 downto 0);
        tex_height      : in  std_logic_vector(11 downto 0);
        tex_format      : in  std_logic_vector(3 downto 0);
        tex_wrap_mode   : in  std_logic_vector(3 downto 0);
        tex_filter      : in  std_logic;
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
        -- Memory Interface (shared, arbitrated)
        -----------------------------------------------------------------------
        mem_req_valid   : out std_logic;
        mem_req_addr    : out std_logic_vector(31 downto 0);
        mem_req_id      : out std_logic_vector(1 downto 0);  -- Which tex unit
        mem_req_ready   : in  std_logic;
        
        mem_resp_valid  : in  std_logic;
        mem_resp_id     : in  std_logic_vector(1 downto 0);
        mem_resp_data   : in  std_logic_vector(63 downto 0);
        
        -----------------------------------------------------------------------
        -- Status
        -----------------------------------------------------------------------
        busy            : out std_logic;
        total_cache_hits  : out std_logic_vector(31 downto 0);
        total_cache_misses: out std_logic_vector(31 downto 0)
    );
end entity texture_unit_array;

architecture rtl of texture_unit_array is

    ---------------------------------------------------------------------------
    -- Per-Unit Signals
    ---------------------------------------------------------------------------
    type unit_valid_t is array (0 to NUM_TEX_UNITS-1) of std_logic;
    type unit_warp_t is array (0 to NUM_TEX_UNITS-1) of std_logic_vector(4 downto 0);
    type unit_mask_t is array (0 to NUM_TEX_UNITS-1) of std_logic_vector(WARP_SIZE-1 downto 0);
    type unit_data_t is array (0 to NUM_TEX_UNITS-1) of std_logic_vector(WARP_SIZE*32-1 downto 0);
    type unit_addr_t is array (0 to NUM_TEX_UNITS-1) of std_logic_vector(31 downto 0);
    type unit_stats_t is array (0 to NUM_TEX_UNITS-1) of std_logic_vector(31 downto 0);
    
    -- Request interface to each unit
    signal unit_req_valid : unit_valid_t;
    signal unit_req_ready : unit_valid_t;
    
    -- Writeback from each unit
    signal unit_wb_valid : unit_valid_t;
    signal unit_wb_warp  : unit_warp_t;
    signal unit_wb_mask  : unit_mask_t;
    signal unit_wb_data  : unit_data_t;
    
    -- Memory interface from each unit
    signal unit_mem_req_valid : unit_valid_t;
    signal unit_mem_req_addr  : unit_addr_t;
    signal unit_mem_req_ready : unit_valid_t;
    signal unit_mem_resp_valid: unit_valid_t;
    
    -- Status from each unit
    signal unit_busy : unit_valid_t;
    signal unit_hits : unit_stats_t;
    signal unit_misses : unit_stats_t;
    
    ---------------------------------------------------------------------------
    -- Arbitration State
    ---------------------------------------------------------------------------
    signal next_unit : integer range 0 to NUM_TEX_UNITS-1 := 0;
    signal mem_arb_ptr : integer range 0 to NUM_TEX_UNITS-1 := 0;
    signal active_mem_unit : integer range 0 to NUM_TEX_UNITS-1 := 0;
    signal mem_req_pending : std_logic := '0';
    
    ---------------------------------------------------------------------------
    -- Writeback Arbitration
    ---------------------------------------------------------------------------
    signal wb_arb_ptr : integer range 0 to NUM_TEX_UNITS-1 := 0;

begin

    ---------------------------------------------------------------------------
    -- Texture Unit Instances
    ---------------------------------------------------------------------------
    gen_tex_units: for i in 0 to NUM_TEX_UNITS-1 generate
        tex_unit_i: entity work.texture_unit
            generic map (
                WARP_SIZE        => WARP_SIZE,
                BLOCK_CACHE_SIZE => BLOCK_CACHE_SIZE,
                MAX_TEX_DIM      => MAX_TEX_DIM
            )
            port map (
                clk              => clk,
                rst_n            => rst_n,
                
                -- Request (steered by arbiter)
                req_valid        => unit_req_valid(i),
                req_ready        => unit_req_ready(i),
                req_warp         => req_warp,
                req_mask         => req_mask,
                req_op           => req_op,
                req_u            => req_u,
                req_v            => req_v,
                req_lod          => req_lod,
                
                tex_base_addr    => tex_base_addr,
                tex_width        => tex_width,
                tex_height       => tex_height,
                tex_format       => tex_format,
                tex_wrap_mode    => tex_wrap_mode,
                tex_filter       => tex_filter,
                tex_mip_count    => tex_mip_count,
                tex_palette_addr => tex_palette_addr,
                
                -- Writeback
                wb_valid         => unit_wb_valid(i),
                wb_warp          => unit_wb_warp(i),
                wb_mask          => unit_wb_mask(i),
                wb_data          => unit_wb_data(i),
                
                -- Memory (per-unit, arbitrated externally)
                mem_req_valid    => unit_mem_req_valid(i),
                mem_req_addr     => unit_mem_req_addr(i),
                mem_req_ready    => unit_mem_req_ready(i),
                mem_resp_valid   => unit_mem_resp_valid(i),
                mem_resp_data    => mem_resp_data,
                
                -- Status
                busy             => unit_busy(i),
                cache_hits       => unit_hits(i),
                cache_misses     => unit_misses(i)
            );
    end generate;
    
    ---------------------------------------------------------------------------
    -- Request Steering (Round-Robin to Available Unit)
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable found : boolean;
        variable idx : integer;
    begin
        if rst_n = '0' then
            next_unit <= 0;
            for i in 0 to NUM_TEX_UNITS-1 loop
                unit_req_valid(i) <= '0';
            end loop;
            
        elsif rising_edge(clk) then
            -- Clear previous request
            for i in 0 to NUM_TEX_UNITS-1 loop
                unit_req_valid(i) <= '0';
            end loop;
            
            -- Route new request to first available unit (round-robin start)
            if req_valid = '1' then
                found := false;
                for offset in 0 to NUM_TEX_UNITS-1 loop
                    idx := (next_unit + offset) mod NUM_TEX_UNITS;
                    if not found and unit_req_ready(idx) = '1' then
                        unit_req_valid(idx) <= '1';
                        next_unit <= (idx + 1) mod NUM_TEX_UNITS;
                        found := true;
                    end if;
                end loop;
            end if;
        end if;
    end process;
    
    -- Ready if any unit is ready
    req_ready <= unit_req_ready(0) or unit_req_ready(1) when NUM_TEX_UNITS = 2 else
                 unit_req_ready(0);
    
    ---------------------------------------------------------------------------
    -- Memory Request Arbitration (Round-Robin)
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable found : boolean;
        variable grant_idx : integer;
    begin
        if rst_n = '0' then
            mem_arb_ptr <= 0;
            mem_req_pending <= '0';
            mem_req_valid <= '0';
            for i in 0 to NUM_TEX_UNITS-1 loop
                unit_mem_req_ready(i) <= '0';
            end loop;
            
        elsif rising_edge(clk) then
            -- Default: no grants
            for i in 0 to NUM_TEX_UNITS-1 loop
                unit_mem_req_ready(i) <= '0';
            end loop;
            
            if mem_req_pending = '0' then
                -- Look for unit with pending memory request
                found := false;
                for offset in 0 to NUM_TEX_UNITS-1 loop
                    grant_idx := (mem_arb_ptr + offset) mod NUM_TEX_UNITS;
                    if not found and unit_mem_req_valid(grant_idx) = '1' then
                        -- Grant this unit
                        mem_req_valid <= '1';
                        mem_req_addr <= unit_mem_req_addr(grant_idx);
                        mem_req_id <= std_logic_vector(to_unsigned(grant_idx, 2));
                        active_mem_unit <= grant_idx;
                        
                        if mem_req_ready = '1' then
                            unit_mem_req_ready(grant_idx) <= '1';
                            mem_arb_ptr <= (grant_idx + 1) mod NUM_TEX_UNITS;
                            mem_req_valid <= '0';
                        else
                            mem_req_pending <= '1';
                        end if;
                        
                        found := true;
                    end if;
                end loop;
                
                if not found then
                    mem_req_valid <= '0';
                end if;
            else
                -- Waiting for ready
                mem_req_valid <= '1';
                mem_req_addr <= unit_mem_req_addr(active_mem_unit);
                mem_req_id <= std_logic_vector(to_unsigned(active_mem_unit, 2));
                
                if mem_req_ready = '1' then
                    unit_mem_req_ready(active_mem_unit) <= '1';
                    mem_arb_ptr <= (active_mem_unit + 1) mod NUM_TEX_UNITS;
                    mem_req_pending <= '0';
                    mem_req_valid <= '0';
                end if;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Memory Response Routing
    ---------------------------------------------------------------------------
    process(mem_resp_valid, mem_resp_id)
    begin
        for i in 0 to NUM_TEX_UNITS-1 loop
            if mem_resp_valid = '1' and to_integer(unsigned(mem_resp_id)) = i then
                unit_mem_resp_valid(i) <= '1';
            else
                unit_mem_resp_valid(i) <= '0';
            end if;
        end loop;
    end process;
    
    ---------------------------------------------------------------------------
    -- Writeback Arbitration (Priority to lower index, simple)
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            wb_valid <= '0';
            
        elsif rising_edge(clk) then
            wb_valid <= '0';
            
            -- Simple priority: unit 0 has priority over unit 1, etc.
            for i in 0 to NUM_TEX_UNITS-1 loop
                if unit_wb_valid(i) = '1' then
                    wb_valid <= '1';
                    wb_warp <= unit_wb_warp(i);
                    wb_mask <= unit_wb_mask(i);
                    wb_data <= unit_wb_data(i);
                    exit;
                end if;
            end loop;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Aggregate Status
    ---------------------------------------------------------------------------
    busy <= unit_busy(0) or unit_busy(1) when NUM_TEX_UNITS >= 2 else unit_busy(0);
    
    -- Sum statistics (simplified - just use unit 0 for now)
    process(clk, rst_n)
        variable sum_hits, sum_misses : unsigned(31 downto 0);
    begin
        if rst_n = '0' then
            total_cache_hits <= (others => '0');
            total_cache_misses <= (others => '0');
        elsif rising_edge(clk) then
            sum_hits := (others => '0');
            sum_misses := (others => '0');
            for i in 0 to NUM_TEX_UNITS-1 loop
                sum_hits := sum_hits + unsigned(unit_hits(i));
                sum_misses := sum_misses + unsigned(unit_misses(i));
            end loop;
            total_cache_hits <= std_logic_vector(sum_hits);
            total_cache_misses <= std_logic_vector(sum_misses);
        end if;
    end process;

end architecture rtl;
