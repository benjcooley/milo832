-------------------------------------------------------------------------------
-- gpu_core.vhd
-- Complete GPU Core integrating SM with Texture Unit Array
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.simt_pkg.all;

entity gpu_core is
    generic (
        WARP_SIZE       : integer := 32;
        NUM_WARPS       : integer := 8;
        NUM_REGS        : integer := 64;
        NUM_TEX_UNITS   : integer := 2;
        PROG_MEM_SIZE   : integer := 256
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -----------------------------------------------------------------------
        -- Control Interface
        -----------------------------------------------------------------------
        start           : in  std_logic;
        done            : out std_logic;
        warp_count      : in  std_logic_vector(4 downto 0);
        
        -- Program memory write interface
        prog_wr_en      : in  std_logic;
        prog_wr_warp    : in  std_logic_vector(4 downto 0);
        prog_wr_addr    : in  std_logic_vector(7 downto 0);
        prog_wr_data    : in  std_logic_vector(63 downto 0);
        
        -----------------------------------------------------------------------
        -- Global Memory Interface
        -----------------------------------------------------------------------
        mem_req_valid   : out std_logic;
        mem_req_ready   : in  std_logic;
        mem_req_write   : out std_logic;
        mem_req_addr    : out std_logic_vector(31 downto 0);
        mem_req_wdata   : out std_logic_vector(31 downto 0);
        mem_req_tag     : out std_logic_vector(15 downto 0);
        
        mem_resp_valid  : in  std_logic;
        mem_resp_data   : in  std_logic_vector(31 downto 0);
        mem_resp_tag    : in  std_logic_vector(15 downto 0);
        
        -----------------------------------------------------------------------
        -- Texture Memory Interface (separate from global memory)
        -----------------------------------------------------------------------
        tex_mem_req_valid   : out std_logic;
        tex_mem_req_addr    : out std_logic_vector(31 downto 0);
        tex_mem_req_id      : out std_logic_vector(1 downto 0);
        tex_mem_req_ready   : in  std_logic;
        
        tex_mem_resp_valid  : in  std_logic;
        tex_mem_resp_id     : in  std_logic_vector(1 downto 0);
        tex_mem_resp_data   : in  std_logic_vector(63 downto 0);
        
        -----------------------------------------------------------------------
        -- Texture Configuration Registers
        -----------------------------------------------------------------------
        tex_base_addr   : in  std_logic_vector(31 downto 0);
        tex_width       : in  std_logic_vector(11 downto 0);
        tex_height      : in  std_logic_vector(11 downto 0);
        tex_format      : in  std_logic_vector(3 downto 0);
        tex_wrap_mode   : in  std_logic_vector(3 downto 0);
        tex_filter      : in  std_logic;
        tex_mip_count   : in  std_logic_vector(3 downto 0);
        tex_palette_addr: in  std_logic_vector(31 downto 0);
        
        -----------------------------------------------------------------------
        -- Debug/Status
        -----------------------------------------------------------------------
        dbg_cycle_count : out std_logic_vector(31 downto 0);
        dbg_inst_count  : out std_logic_vector(31 downto 0);
        dbg_warp_state  : out std_logic_vector(7 downto 0);
        dbg_tex_busy    : out std_logic;
        dbg_tex_hits    : out std_logic_vector(31 downto 0);
        dbg_tex_misses  : out std_logic_vector(31 downto 0)
    );
end entity gpu_core;

architecture rtl of gpu_core is

    ---------------------------------------------------------------------------
    -- SM <-> Texture Unit Interface Signals
    ---------------------------------------------------------------------------
    signal sm_tex_req_valid   : std_logic;
    signal sm_tex_req_ready   : std_logic;
    signal sm_tex_req_warp    : std_logic_vector(4 downto 0);
    signal sm_tex_req_mask    : std_logic_vector(WARP_SIZE-1 downto 0);
    signal sm_tex_req_op      : std_logic_vector(1 downto 0);
    signal sm_tex_req_u       : std_logic_vector(WARP_SIZE*32-1 downto 0);
    signal sm_tex_req_v       : std_logic_vector(WARP_SIZE*32-1 downto 0);
    signal sm_tex_req_lod     : std_logic_vector(WARP_SIZE*8-1 downto 0);
    signal sm_tex_req_rd      : std_logic_vector(5 downto 0);
    
    signal sm_tex_resp_valid  : std_logic;
    signal sm_tex_resp_warp   : std_logic_vector(4 downto 0);
    signal sm_tex_resp_mask   : std_logic_vector(WARP_SIZE-1 downto 0);
    signal sm_tex_resp_data   : std_logic_vector(WARP_SIZE*32-1 downto 0);
    signal sm_tex_resp_rd     : std_logic_vector(5 downto 0);
    
    ---------------------------------------------------------------------------
    -- Texture Unit Internal Signals
    ---------------------------------------------------------------------------
    signal tex_wb_valid       : std_logic;
    signal tex_wb_warp        : std_logic_vector(4 downto 0);
    signal tex_wb_mask        : std_logic_vector(WARP_SIZE-1 downto 0);
    signal tex_wb_data        : std_logic_vector(WARP_SIZE*32-1 downto 0);
    signal tex_busy           : std_logic;
    signal tex_cache_hits     : std_logic_vector(31 downto 0);
    signal tex_cache_misses   : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Destination Register Tracking FIFO
    -- Tracks pending texture operations and their destination registers
    ---------------------------------------------------------------------------
    constant TEX_FIFO_DEPTH : integer := 8;
    type tex_pending_entry_t is record
        valid : std_logic;
        warp  : std_logic_vector(4 downto 0);
        rd    : std_logic_vector(5 downto 0);
    end record;
    type tex_pending_array_t is array (0 to TEX_FIFO_DEPTH-1) of tex_pending_entry_t;
    
    signal tex_pending : tex_pending_array_t;
    signal tex_fifo_wr_ptr : integer range 0 to TEX_FIFO_DEPTH-1 := 0;
    signal tex_fifo_rd_ptr : integer range 0 to TEX_FIFO_DEPTH-1 := 0;
    signal tex_fifo_count : integer range 0 to TEX_FIFO_DEPTH := 0;

begin

    ---------------------------------------------------------------------------
    -- Streaming Multiprocessor Instance
    ---------------------------------------------------------------------------
    u_sm : entity work.streaming_multiprocessor
        generic map (
            WARP_SIZE       => WARP_SIZE,
            NUM_WARPS       => NUM_WARPS,
            NUM_REGS        => NUM_REGS,
            STACK_DEPTH     => 16,
            PROG_MEM_SIZE   => PROG_MEM_SIZE
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            
            start           => start,
            done            => done,
            warp_count      => warp_count,
            
            prog_wr_en      => prog_wr_en,
            prog_wr_warp    => prog_wr_warp,
            prog_wr_addr    => prog_wr_addr,
            prog_wr_data    => prog_wr_data,
            
            mem_req_valid   => mem_req_valid,
            mem_req_ready   => mem_req_ready,
            mem_req_write   => mem_req_write,
            mem_req_addr    => mem_req_addr,
            mem_req_wdata   => mem_req_wdata,
            mem_req_tag     => mem_req_tag,
            
            mem_resp_valid  => mem_resp_valid,
            mem_resp_data   => mem_resp_data,
            mem_resp_tag    => mem_resp_tag,
            
            -- Texture interface
            tex_req_valid   => sm_tex_req_valid,
            tex_req_ready   => sm_tex_req_ready,
            tex_req_warp    => sm_tex_req_warp,
            tex_req_mask    => sm_tex_req_mask,
            tex_req_op      => sm_tex_req_op,
            tex_req_u       => sm_tex_req_u,
            tex_req_v       => sm_tex_req_v,
            tex_req_lod     => sm_tex_req_lod,
            tex_req_rd      => sm_tex_req_rd,
            
            tex_resp_valid  => sm_tex_resp_valid,
            tex_resp_warp   => sm_tex_resp_warp,
            tex_resp_mask   => sm_tex_resp_mask,
            tex_resp_data   => sm_tex_resp_data,
            tex_resp_rd     => sm_tex_resp_rd,
            
            dbg_cycle_count => dbg_cycle_count,
            dbg_inst_count  => dbg_inst_count,
            dbg_warp_state  => dbg_warp_state
        );
    
    ---------------------------------------------------------------------------
    -- Texture Unit Array Instance
    ---------------------------------------------------------------------------
    u_tex_array : entity work.texture_unit_array
        generic map (
            NUM_TEX_UNITS   => NUM_TEX_UNITS,
            WARP_SIZE       => WARP_SIZE,
            BLOCK_CACHE_SIZE => 16,
            MAX_TEX_DIM     => 2048
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            
            -- From SM
            req_valid       => sm_tex_req_valid,
            req_ready       => sm_tex_req_ready,
            req_warp        => sm_tex_req_warp,
            req_mask        => sm_tex_req_mask,
            req_op          => sm_tex_req_op,
            req_u           => sm_tex_req_u,
            req_v           => sm_tex_req_v,
            req_lod         => sm_tex_req_lod,
            
            -- Texture descriptor
            tex_base_addr   => tex_base_addr,
            tex_width       => tex_width,
            tex_height      => tex_height,
            tex_format      => tex_format,
            tex_wrap_mode   => tex_wrap_mode,
            tex_filter      => tex_filter,
            tex_mip_count   => tex_mip_count,
            tex_palette_addr => tex_palette_addr,
            
            -- Writeback
            wb_valid        => tex_wb_valid,
            wb_warp         => tex_wb_warp,
            wb_mask         => tex_wb_mask,
            wb_data         => tex_wb_data,
            
            -- Memory interface
            mem_req_valid   => tex_mem_req_valid,
            mem_req_addr    => tex_mem_req_addr,
            mem_req_id      => tex_mem_req_id,
            mem_req_ready   => tex_mem_req_ready,
            
            mem_resp_valid  => tex_mem_resp_valid,
            mem_resp_id     => tex_mem_resp_id,
            mem_resp_data   => tex_mem_resp_data,
            
            -- Status
            busy            => tex_busy,
            total_cache_hits  => tex_cache_hits,
            total_cache_misses => tex_cache_misses
        );
    
    ---------------------------------------------------------------------------
    -- Destination Register Tracking
    -- Push rd when request is accepted, pop when response arrives
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            tex_fifo_wr_ptr <= 0;
            tex_fifo_rd_ptr <= 0;
            tex_fifo_count <= 0;
            for i in 0 to TEX_FIFO_DEPTH-1 loop
                tex_pending(i).valid <= '0';
            end loop;
            
        elsif rising_edge(clk) then
            -- Push on accepted request
            if sm_tex_req_valid = '1' and sm_tex_req_ready = '1' then
                tex_pending(tex_fifo_wr_ptr).valid <= '1';
                tex_pending(tex_fifo_wr_ptr).warp <= sm_tex_req_warp;
                tex_pending(tex_fifo_wr_ptr).rd <= sm_tex_req_rd;
                tex_fifo_wr_ptr <= (tex_fifo_wr_ptr + 1) mod TEX_FIFO_DEPTH;
                tex_fifo_count <= tex_fifo_count + 1;
            end if;
            
            -- Pop on response
            if tex_wb_valid = '1' then
                tex_pending(tex_fifo_rd_ptr).valid <= '0';
                tex_fifo_rd_ptr <= (tex_fifo_rd_ptr + 1) mod TEX_FIFO_DEPTH;
                if not (sm_tex_req_valid = '1' and sm_tex_req_ready = '1') then
                    tex_fifo_count <= tex_fifo_count - 1;
                end if;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Route Texture Response to SM
    ---------------------------------------------------------------------------
    sm_tex_resp_valid <= tex_wb_valid;
    sm_tex_resp_warp <= tex_wb_warp;
    sm_tex_resp_mask <= tex_wb_mask;
    sm_tex_resp_data <= tex_wb_data;
    sm_tex_resp_rd <= tex_pending(tex_fifo_rd_ptr).rd when tex_pending(tex_fifo_rd_ptr).valid = '1' 
                      else (others => '0');
    
    ---------------------------------------------------------------------------
    -- Debug Outputs
    ---------------------------------------------------------------------------
    dbg_tex_busy <= tex_busy;
    dbg_tex_hits <= tex_cache_hits;
    dbg_tex_misses <= tex_cache_misses;

end architecture rtl;
