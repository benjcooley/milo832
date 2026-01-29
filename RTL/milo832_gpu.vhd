-------------------------------------------------------------------------------
-- milo832_gpu.vhd
-- Milo832 GPU Top-Level Module
-- Integrates all GPU components: command processor, SM, rasterizer, ROP, texturing
--
-- Target FPGAs:
--   - AMD Xilinx Kria KV260 (Zynq UltraScale+ XCK26)
--   - Intel/Altera DE2-115 (Cyclone IV EP4CE115)
--
-- Milo832 GPU project - Graphics coprocessor for m65832 CPU
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.simt_pkg.all;
use work.render_state_pkg.all;

entity milo832_gpu is
    generic (
        -- Framebuffer configuration
        FB_WIDTH        : integer := 640;
        FB_HEIGHT       : integer := 480;
        TILE_SIZE       : integer := 16;
        
        -- SM configuration
        NUM_WARPS       : integer := 4;
        THREADS_PER_WARP: integer := 8;
        
        -- Texture configuration
        NUM_TEX_UNITS   : integer := 2;
        
        -- Memory configuration
        REG_FILE_SIZE   : integer := 32;
        SHARED_MEM_SIZE : integer := 4096
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -----------------------------------------------------------------------
        -- CPU/Bus Interface (memory-mapped registers)
        -----------------------------------------------------------------------
        bus_addr        : in  std_logic_vector(31 downto 0);
        bus_wr_en       : in  std_logic;
        bus_wr_data     : in  std_logic_vector(31 downto 0);
        bus_rd_en       : in  std_logic;
        bus_rd_data     : out std_logic_vector(31 downto 0);
        bus_rd_valid    : out std_logic;
        
        -- Interrupt to CPU
        irq             : out std_logic;
        
        -----------------------------------------------------------------------
        -- External Memory Interface (DDR/SDRAM)
        -----------------------------------------------------------------------
        -- Read channel
        mem_rd_addr     : out std_logic_vector(31 downto 0);
        mem_rd_en       : out std_logic;
        mem_rd_data     : in  std_logic_vector(31 downto 0);
        mem_rd_valid    : in  std_logic;
        
        -- Write channel
        mem_wr_addr     : out std_logic_vector(31 downto 0);
        mem_wr_en       : out std_logic;
        mem_wr_data     : out std_logic_vector(31 downto 0);
        mem_wr_ready    : in  std_logic;
        
        -----------------------------------------------------------------------
        -- Framebuffer Output (optional direct connection)
        -----------------------------------------------------------------------
        fb_pixel_addr   : out std_logic_vector(31 downto 0);
        fb_pixel_data   : out std_logic_vector(31 downto 0);
        fb_pixel_wr     : out std_logic;
        
        -----------------------------------------------------------------------
        -- Status
        -----------------------------------------------------------------------
        gpu_busy        : out std_logic;
        gpu_idle        : out std_logic
    );
end entity milo832_gpu;

architecture rtl of milo832_gpu is

    ---------------------------------------------------------------------------
    -- Address Map Constants
    ---------------------------------------------------------------------------
    constant ADDR_CMD_BASE      : std_logic_vector(31 downto 0) := x"00000000";
    constant ADDR_STATE_BASE    : std_logic_vector(31 downto 0) := x"00001000";
    constant ADDR_STATUS_BASE   : std_logic_vector(31 downto 0) := x"00002000";
    constant ADDR_TEX_BASE      : std_logic_vector(31 downto 0) := x"00003000";
    
    ---------------------------------------------------------------------------
    -- Command Processor Signals
    ---------------------------------------------------------------------------
    signal cmd_wr_valid     : std_logic;
    signal cmd_wr_ready     : std_logic;
    signal cmd_wr_data      : std_logic_vector(31 downto 0);
    signal cmd_status       : std_logic_vector(31 downto 0);
    signal cmd_fence_value  : std_logic_vector(31 downto 0);
    
    -- Command outputs
    signal state_wr_en      : std_logic;
    signal state_wr_addr    : std_logic_vector(7 downto 0);
    signal state_wr_data    : std_logic_vector(31 downto 0);
    
    signal clear_valid      : std_logic;
    signal clear_ready      : std_logic := '1';
    signal clear_color      : std_logic_vector(31 downto 0);
    signal clear_depth      : std_logic_vector(23 downto 0);
    signal clear_flags      : std_logic_vector(1 downto 0);
    
    signal draw_valid       : std_logic;
    signal draw_ready       : std_logic := '1';
    signal draw_start_idx   : std_logic_vector(31 downto 0);
    signal draw_count       : std_logic_vector(31 downto 0);
    signal draw_done        : std_logic := '0';
    
    signal tex_cfg_valid    : std_logic;
    signal tex_cfg_unit     : std_logic_vector(3 downto 0);
    signal tex_cfg_addr     : std_logic_vector(31 downto 0);
    signal tex_cfg_width    : std_logic_vector(15 downto 0);
    signal tex_cfg_height   : std_logic_vector(15 downto 0);
    signal tex_cfg_format   : std_logic_vector(3 downto 0);
    
    signal shader_valid     : std_logic;
    signal shader_ready     : std_logic;
    signal shader_pc        : std_logic_vector(31 downto 0);
    signal shader_count     : std_logic_vector(31 downto 0);
    signal shader_done      : std_logic;
    
    ---------------------------------------------------------------------------
    -- Render State Signals
    ---------------------------------------------------------------------------
    signal render_state     : render_state_t;
    signal depth_test_en    : std_logic;
    signal depth_write_en   : std_logic;
    signal depth_func       : depth_func_t;
    signal cull_mode        : cull_mode_t;
    signal front_face       : winding_t;
    signal blend_en         : std_logic;
    signal blend_src_rgb    : blend_factor_t;
    signal blend_dst_rgb    : blend_factor_t;
    signal color_mask       : std_logic_vector(3 downto 0);
    
    ---------------------------------------------------------------------------
    -- Streaming Multiprocessor Signals
    ---------------------------------------------------------------------------
    signal sm_start         : std_logic;
    signal sm_done          : std_logic;
    signal sm_busy          : std_logic;
    
    -- Texture request from SM
    signal sm_tex_req_valid : std_logic;
    signal sm_tex_req_ready : std_logic;
    signal sm_tex_req_u     : std_logic_vector(31 downto 0);
    signal sm_tex_req_v     : std_logic_vector(31 downto 0);
    signal sm_tex_req_unit  : std_logic_vector(1 downto 0);
    signal sm_tex_req_warp  : std_logic_vector(1 downto 0);
    signal sm_tex_req_rd    : std_logic_vector(4 downto 0);
    
    -- Texture response to SM
    signal sm_tex_resp_valid: std_logic;
    signal sm_tex_resp_warp : std_logic_vector(1 downto 0);
    signal sm_tex_resp_rd   : std_logic_vector(4 downto 0);
    signal sm_tex_resp_data : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Triangle/Rasterizer Signals
    ---------------------------------------------------------------------------
    signal tri_valid        : std_logic := '0';
    signal tri_ready        : std_logic;
    
    -- Triangle vertices
    signal tri_v0_x, tri_v0_y, tri_v0_z : std_logic_vector(31 downto 0);
    signal tri_v1_x, tri_v1_y, tri_v1_z : std_logic_vector(31 downto 0);
    signal tri_v2_x, tri_v2_y, tri_v2_z : std_logic_vector(31 downto 0);
    signal tri_v0_u, tri_v0_v : std_logic_vector(31 downto 0);
    signal tri_v1_u, tri_v1_v : std_logic_vector(31 downto 0);
    signal tri_v2_u, tri_v2_v : std_logic_vector(31 downto 0);
    signal tri_v0_color, tri_v1_color, tri_v2_color : std_logic_vector(31 downto 0);
    
    -- Fragment output from rasterizer
    signal frag_valid       : std_logic;
    signal frag_ready       : std_logic := '1';
    signal frag_x, frag_y   : std_logic_vector(15 downto 0);
    signal frag_z           : std_logic_vector(23 downto 0);
    signal frag_u, frag_v   : std_logic_vector(31 downto 0);
    signal frag_color       : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- ROP Signals
    ---------------------------------------------------------------------------
    signal rop_frag_valid   : std_logic;
    signal rop_frag_ready   : std_logic;
    signal rop_frag_x       : std_logic_vector(15 downto 0);
    signal rop_frag_y       : std_logic_vector(15 downto 0);
    signal rop_frag_z       : std_logic_vector(31 downto 0);
    signal rop_frag_color   : std_logic_vector(31 downto 0);
    
    -- Depth buffer interface
    signal depth_rd_addr    : std_logic_vector(31 downto 0);
    signal depth_rd_data    : std_logic_vector(23 downto 0);
    signal depth_rd_valid   : std_logic := '1';
    signal depth_wr_valid   : std_logic;
    signal depth_wr_addr    : std_logic_vector(31 downto 0);
    signal depth_wr_data    : std_logic_vector(23 downto 0);
    
    -- Color buffer interface
    signal color_rd_addr    : std_logic_vector(31 downto 0);
    signal color_rd_data    : std_logic_vector(31 downto 0);
    signal color_rd_valid   : std_logic := '1';
    signal color_wr_valid   : std_logic;
    signal color_wr_addr    : std_logic_vector(31 downto 0);
    signal color_wr_data    : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Internal Status
    ---------------------------------------------------------------------------
    signal gpu_busy_int     : std_logic;
    signal irq_pending      : std_logic;
    
    ---------------------------------------------------------------------------
    -- Address Decode
    ---------------------------------------------------------------------------
    signal addr_is_cmd      : std_logic;
    signal addr_is_state    : std_logic;
    signal addr_is_status   : std_logic;
    
begin

    ---------------------------------------------------------------------------
    -- Address Decode
    ---------------------------------------------------------------------------
    addr_is_cmd   <= '1' when bus_addr(31 downto 12) = ADDR_CMD_BASE(31 downto 12) else '0';
    addr_is_state <= '1' when bus_addr(31 downto 12) = ADDR_STATE_BASE(31 downto 12) else '0';
    addr_is_status<= '1' when bus_addr(31 downto 12) = ADDR_STATUS_BASE(31 downto 12) else '0';
    
    -- Route writes to command processor
    cmd_wr_valid <= bus_wr_en and addr_is_cmd;
    cmd_wr_data <= bus_wr_data;
    
    ---------------------------------------------------------------------------
    -- Command Processor
    ---------------------------------------------------------------------------
    u_cmd_proc: entity work.command_processor
        port map (
            clk             => clk,
            rst_n           => rst_n,
            cmd_wr_valid    => cmd_wr_valid,
            cmd_wr_ready    => cmd_wr_ready,
            cmd_wr_data     => cmd_wr_data,
            status          => cmd_status,
            fence_value     => cmd_fence_value,
            state_wr_en     => state_wr_en,
            state_wr_addr   => state_wr_addr,
            state_wr_data   => state_wr_data,
            clear_valid     => clear_valid,
            clear_ready     => clear_ready,
            clear_color     => clear_color,
            clear_depth     => clear_depth,
            clear_flags     => clear_flags,
            draw_valid      => draw_valid,
            draw_ready      => draw_ready,
            draw_start_idx  => draw_start_idx,
            draw_count      => draw_count,
            draw_done       => draw_done,
            tex_cfg_valid   => tex_cfg_valid,
            tex_cfg_unit    => tex_cfg_unit,
            tex_cfg_addr    => tex_cfg_addr,
            tex_cfg_width   => tex_cfg_width,
            tex_cfg_height  => tex_cfg_height,
            tex_cfg_format  => tex_cfg_format,
            shader_valid    => shader_valid,
            shader_ready    => shader_ready,
            shader_pc       => shader_pc,
            shader_count    => shader_count,
            shader_done     => shader_done,
            mem_rd_addr     => open,
            mem_rd_en       => open,
            mem_rd_data     => (others => '0'),
            mem_rd_valid    => '0'
        );
    
    ---------------------------------------------------------------------------
    -- Render State Registers
    ---------------------------------------------------------------------------
    u_state_regs: entity work.render_state_regs
        generic map (
            BASE_ADDR => ADDR_STATE_BASE
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            bus_addr        => bus_addr,
            bus_wr_en       => bus_wr_en and addr_is_state,
            bus_wr_data     => bus_wr_data,
            bus_rd_en       => bus_rd_en and addr_is_state,
            bus_rd_data     => open,  -- Muxed below
            bus_rd_valid    => open,
            state_out       => render_state,
            depth_test_en   => depth_test_en,
            depth_write_en  => depth_write_en,
            depth_func      => depth_func,
            depth_clear     => open,
            cull_mode       => cull_mode,
            front_face      => front_face,
            blend_en        => blend_en,
            blend_src_rgb   => blend_src_rgb,
            blend_dst_rgb   => blend_dst_rgb,
            blend_eq_rgb    => open,
            blend_src_a     => open,
            blend_dst_a     => open,
            blend_eq_a      => open,
            blend_color     => open,
            color_mask      => color_mask,
            color_clear     => open
        );
    
    -- Also accept state writes from command processor
    process(clk)
    begin
        if rising_edge(clk) then
            -- State writes from command processor take effect through render_state_regs
            -- (The command processor routes through bus interface)
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Tile Rasterizer (simplified - single tile for now)
    ---------------------------------------------------------------------------
    u_rasterizer: entity work.tile_rasterizer
        generic map (
            TILE_SIZE => TILE_SIZE,
            FRAC_BITS => 16
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            tile_x          => (others => '0'),  -- Will be managed by tile renderer
            tile_y          => (others => '0'),
            tri_valid       => tri_valid,
            tri_ready       => tri_ready,
            v0_x => tri_v0_x, v0_y => tri_v0_y, v0_z => tri_v0_z,
            v1_x => tri_v1_x, v1_y => tri_v1_y, v1_z => tri_v1_z,
            v2_x => tri_v2_x, v2_y => tri_v2_y, v2_z => tri_v2_z,
            v0_u => tri_v0_u, v0_v => tri_v0_v,
            v1_u => tri_v1_u, v1_v => tri_v1_v,
            v2_u => tri_v2_u, v2_v => tri_v2_v,
            v0_color => tri_v0_color,
            v1_color => tri_v1_color,
            v2_color => tri_v2_color,
            frag_valid      => frag_valid,
            frag_ready      => frag_ready,
            frag_x          => frag_x,
            frag_y          => frag_y,
            frag_z          => frag_z,
            frag_u          => frag_u,
            frag_v          => frag_v,
            frag_color      => frag_color,
            triangle_done   => open,
            fragments_out   => open
        );
    
    ---------------------------------------------------------------------------
    -- ROP (Raster Operations Pipeline)
    ---------------------------------------------------------------------------
    -- Pass fragments from rasterizer to ROP
    rop_frag_valid <= frag_valid;
    rop_frag_x <= frag_x;
    rop_frag_y <= frag_y;
    rop_frag_z <= x"00" & frag_z;
    rop_frag_color <= frag_color;
    frag_ready <= rop_frag_ready;
    
    u_rop: entity work.rop
        generic map (
            FB_WIDTH    => FB_WIDTH,
            FB_HEIGHT   => FB_HEIGHT,
            DEPTH_BITS  => 24
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            frag_valid      => rop_frag_valid,
            frag_ready      => rop_frag_ready,
            frag_x          => rop_frag_x,
            frag_y          => rop_frag_y,
            frag_z          => rop_frag_z,
            frag_color      => rop_frag_color,
            depth_test_en   => depth_test_en,
            depth_write_en  => depth_write_en,
            depth_func      => depth_func,
            blend_en        => blend_en,
            blend_src_rgb   => blend_src_rgb,
            blend_dst_rgb   => blend_dst_rgb,
            blend_src_a     => (others => '0'),
            blend_dst_a     => (others => '0'),
            color_mask      => color_mask,
            depth_rd_addr   => depth_rd_addr,
            depth_rd_data   => depth_rd_data,
            depth_rd_valid  => depth_rd_valid,
            depth_wr_valid  => depth_wr_valid,
            depth_wr_addr   => depth_wr_addr,
            depth_wr_data   => depth_wr_data,
            color_rd_addr   => color_rd_addr,
            color_rd_data   => color_rd_data,
            color_rd_valid  => color_rd_valid,
            color_wr_valid  => color_wr_valid,
            color_wr_addr   => color_wr_addr,
            color_wr_data   => color_wr_data,
            pixels_written  => open,
            pixels_killed   => open
        );
    
    ---------------------------------------------------------------------------
    -- Framebuffer Output
    ---------------------------------------------------------------------------
    fb_pixel_addr <= color_wr_addr;
    fb_pixel_data <= color_wr_data;
    fb_pixel_wr <= color_wr_valid;
    
    ---------------------------------------------------------------------------
    -- Memory Interface Routing
    ---------------------------------------------------------------------------
    -- For now, simple passthrough - real implementation needs arbiter
    mem_rd_addr <= (others => '0');
    mem_rd_en <= '0';
    mem_wr_addr <= color_wr_addr;
    mem_wr_en <= color_wr_valid;
    mem_wr_data <= color_wr_data;
    
    ---------------------------------------------------------------------------
    -- Bus Read Mux
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            bus_rd_data <= (others => '0');
            bus_rd_valid <= '0';
        elsif rising_edge(clk) then
            bus_rd_valid <= '0';
            
            if bus_rd_en = '1' then
                bus_rd_valid <= '1';
                
                if addr_is_status = '1' then
                    case bus_addr(7 downto 0) is
                        when x"00" => bus_rd_data <= cmd_status;
                        when x"04" => bus_rd_data <= cmd_fence_value;
                        when x"08" => bus_rd_data <= x"0000000" & "000" & gpu_busy_int;
                        when x"0C" => bus_rd_data <= x"4D494C4F";  -- "MILO" magic
                        when others => bus_rd_data <= (others => '0');
                    end case;
                else
                    bus_rd_data <= (others => '0');
                end if;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Status and Interrupt
    ---------------------------------------------------------------------------
    gpu_busy_int <= cmd_status(24) or draw_valid or shader_valid;
    gpu_busy <= gpu_busy_int;
    gpu_idle <= not gpu_busy_int;
    
    -- Generate interrupt on fence completion (could be expanded)
    process(clk, rst_n)
        variable prev_fence : std_logic_vector(31 downto 0);
    begin
        if rst_n = '0' then
            irq_pending <= '0';
            prev_fence := (others => '0');
        elsif rising_edge(clk) then
            if cmd_fence_value /= prev_fence then
                irq_pending <= '1';
            end if;
            prev_fence := cmd_fence_value;
            
            -- Clear interrupt on status read
            if bus_rd_en = '1' and addr_is_status = '1' and bus_addr(7 downto 0) = x"00" then
                irq_pending <= '0';
            end if;
        end if;
    end process;
    
    irq <= irq_pending;
    
    ---------------------------------------------------------------------------
    -- Shader interface (placeholder - connects to SM)
    ---------------------------------------------------------------------------
    shader_ready <= '1';  -- Always ready for now
    shader_done <= '1';   -- Instant completion for now
    
    -- Initialize unused triangle signals
    tri_v0_x <= (others => '0'); tri_v0_y <= (others => '0'); tri_v0_z <= (others => '0');
    tri_v1_x <= (others => '0'); tri_v1_y <= (others => '0'); tri_v1_z <= (others => '0');
    tri_v2_x <= (others => '0'); tri_v2_y <= (others => '0'); tri_v2_z <= (others => '0');
    tri_v0_u <= (others => '0'); tri_v0_v <= (others => '0');
    tri_v1_u <= (others => '0'); tri_v1_v <= (others => '0');
    tri_v2_u <= (others => '0'); tri_v2_v <= (others => '0');
    tri_v0_color <= (others => '0'); tri_v1_color <= (others => '0'); tri_v2_color <= (others => '0');
    
    -- Depth buffer stub (returns max depth)
    depth_rd_data <= x"FFFFFF";
    
    -- Color buffer stub (returns black)
    color_rd_data <= x"00000000";

end architecture rtl;
