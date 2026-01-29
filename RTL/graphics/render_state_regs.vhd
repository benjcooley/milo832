-------------------------------------------------------------------------------
-- render_state_regs.vhd
-- Render State Register File
-- Memory-mapped registers for configuring GPU pipeline state
--
-- Address map (32-bit aligned):
--   0x00: DEPTH_CTRL   - Depth test configuration
--   0x04: CULL_CTRL    - Culling configuration  
--   0x08: BLEND_RGB    - RGB blend factors and equation
--   0x0C: BLEND_ALPHA  - Alpha blend factors and equation
--   0x10: COLOR_MASK   - Color write mask
--   0x14: BLEND_COLOR  - Blend constant color
--   0x18: DEPTH_CLEAR  - Depth buffer clear value
--   0x1C: COLOR_CLEAR  - Color buffer clear value
--   0x20: STATUS       - Read-only status
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.render_state_pkg.all;

entity render_state_regs is
    generic (
        BASE_ADDR : std_logic_vector(31 downto 0) := x"00010000"
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Bus interface (simple memory-mapped)
        bus_addr        : in  std_logic_vector(31 downto 0);
        bus_wr_en       : in  std_logic;
        bus_wr_data     : in  std_logic_vector(31 downto 0);
        bus_rd_en       : in  std_logic;
        bus_rd_data     : out std_logic_vector(31 downto 0);
        bus_rd_valid    : out std_logic;
        
        -- Output: Current render state (directly usable by pipeline)
        state_out       : out render_state_t;
        
        -- Individual outputs for direct wiring
        depth_test_en   : out std_logic;
        depth_write_en  : out std_logic;
        depth_func      : out depth_func_t;
        depth_clear     : out std_logic_vector(23 downto 0);
        
        cull_mode       : out cull_mode_t;
        front_face      : out winding_t;
        
        blend_en        : out std_logic;
        blend_src_rgb   : out blend_factor_t;
        blend_dst_rgb   : out blend_factor_t;
        blend_eq_rgb    : out blend_eq_t;
        blend_src_a     : out blend_factor_t;
        blend_dst_a     : out blend_factor_t;
        blend_eq_a      : out blend_eq_t;
        blend_color     : out std_logic_vector(31 downto 0);
        
        color_mask      : out std_logic_vector(3 downto 0);
        color_clear     : out std_logic_vector(31 downto 0)
    );
end entity render_state_regs;

architecture rtl of render_state_regs is

    -- Register addresses (offsets from BASE_ADDR)
    constant REG_DEPTH_CTRL  : std_logic_vector(7 downto 0) := x"00";
    constant REG_CULL_CTRL   : std_logic_vector(7 downto 0) := x"04";
    constant REG_BLEND_RGB   : std_logic_vector(7 downto 0) := x"08";
    constant REG_BLEND_ALPHA : std_logic_vector(7 downto 0) := x"0C";
    constant REG_COLOR_MASK  : std_logic_vector(7 downto 0) := x"10";
    constant REG_BLEND_COLOR : std_logic_vector(7 downto 0) := x"14";
    constant REG_DEPTH_CLEAR : std_logic_vector(7 downto 0) := x"18";
    constant REG_COLOR_CLEAR : std_logic_vector(7 downto 0) := x"1C";
    constant REG_STATUS      : std_logic_vector(7 downto 0) := x"20";
    
    -- Internal state registers
    signal state : render_state_t := RENDER_STATE_DEFAULT;
    
    -- Address decode
    signal addr_match : std_logic;
    signal reg_offset : std_logic_vector(7 downto 0);

begin

    -- Address decode
    addr_match <= '1' when bus_addr(31 downto 8) = BASE_ADDR(31 downto 8) else '0';
    reg_offset <= bus_addr(7 downto 0);
    
    -- Output the full state record
    state_out <= state;
    
    -- Individual signal outputs
    depth_test_en   <= state.depth_test_en;
    depth_write_en  <= state.depth_write_en;
    depth_func      <= state.depth_func;
    depth_clear     <= state.depth_clear;
    cull_mode       <= state.cull_mode;
    front_face      <= state.front_face;
    blend_en        <= state.blend_en;
    blend_src_rgb   <= state.blend_src_rgb;
    blend_dst_rgb   <= state.blend_dst_rgb;
    blend_eq_rgb    <= state.blend_eq_rgb;
    blend_src_a     <= state.blend_src_a;
    blend_dst_a     <= state.blend_dst_a;
    blend_eq_a      <= state.blend_eq_a;
    blend_color     <= state.blend_color;
    color_mask      <= state.color_mask;
    color_clear     <= state.color_clear;
    
    ---------------------------------------------------------------------------
    -- Register Write Process
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            -- Reset to default state
            state <= RENDER_STATE_DEFAULT;
            
        elsif rising_edge(clk) then
            if bus_wr_en = '1' and addr_match = '1' then
                case reg_offset is
                    -- DEPTH_CTRL: [0]=test_en, [1]=write_en, [4:2]=func
                    when REG_DEPTH_CTRL =>
                        state.depth_test_en  <= bus_wr_data(0);
                        state.depth_write_en <= bus_wr_data(1);
                        state.depth_func     <= bus_wr_data(4 downto 2);
                    
                    -- CULL_CTRL: [1:0]=cull_mode, [2]=front_face
                    when REG_CULL_CTRL =>
                        state.cull_mode  <= bus_wr_data(1 downto 0);
                        state.front_face <= bus_wr_data(2);
                    
                    -- BLEND_RGB: [0]=blend_en, [4:1]=src_rgb, [8:5]=dst_rgb, [11:9]=eq_rgb
                    when REG_BLEND_RGB =>
                        state.blend_en      <= bus_wr_data(0);
                        state.blend_src_rgb <= bus_wr_data(4 downto 1);
                        state.blend_dst_rgb <= bus_wr_data(8 downto 5);
                        state.blend_eq_rgb  <= bus_wr_data(11 downto 9);
                    
                    -- BLEND_ALPHA: [3:0]=src_a, [7:4]=dst_a, [10:8]=eq_a
                    when REG_BLEND_ALPHA =>
                        state.blend_src_a <= bus_wr_data(3 downto 0);
                        state.blend_dst_a <= bus_wr_data(7 downto 4);
                        state.blend_eq_a  <= bus_wr_data(10 downto 8);
                    
                    -- COLOR_MASK: [3:0]=RGBA mask
                    when REG_COLOR_MASK =>
                        state.color_mask <= bus_wr_data(3 downto 0);
                    
                    -- BLEND_COLOR: [31:0]=RGBA constant
                    when REG_BLEND_COLOR =>
                        state.blend_color <= bus_wr_data;
                    
                    -- DEPTH_CLEAR: [23:0]=clear value
                    when REG_DEPTH_CLEAR =>
                        state.depth_clear <= bus_wr_data(23 downto 0);
                    
                    -- COLOR_CLEAR: [31:0]=RGBA clear
                    when REG_COLOR_CLEAR =>
                        state.color_clear <= bus_wr_data;
                    
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Register Read Process
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            bus_rd_data <= (others => '0');
            bus_rd_valid <= '0';
            
        elsif rising_edge(clk) then
            bus_rd_valid <= '0';
            
            if bus_rd_en = '1' and addr_match = '1' then
                bus_rd_valid <= '1';
                
                case reg_offset is
                    when REG_DEPTH_CTRL =>
                        bus_rd_data <= (others => '0');
                        bus_rd_data(0) <= state.depth_test_en;
                        bus_rd_data(1) <= state.depth_write_en;
                        bus_rd_data(4 downto 2) <= state.depth_func;
                    
                    when REG_CULL_CTRL =>
                        bus_rd_data <= (others => '0');
                        bus_rd_data(1 downto 0) <= state.cull_mode;
                        bus_rd_data(2) <= state.front_face;
                    
                    when REG_BLEND_RGB =>
                        bus_rd_data <= (others => '0');
                        bus_rd_data(0) <= state.blend_en;
                        bus_rd_data(4 downto 1) <= state.blend_src_rgb;
                        bus_rd_data(8 downto 5) <= state.blend_dst_rgb;
                        bus_rd_data(11 downto 9) <= state.blend_eq_rgb;
                    
                    when REG_BLEND_ALPHA =>
                        bus_rd_data <= (others => '0');
                        bus_rd_data(3 downto 0) <= state.blend_src_a;
                        bus_rd_data(7 downto 4) <= state.blend_dst_a;
                        bus_rd_data(10 downto 8) <= state.blend_eq_a;
                    
                    when REG_COLOR_MASK =>
                        bus_rd_data <= (others => '0');
                        bus_rd_data(3 downto 0) <= state.color_mask;
                    
                    when REG_BLEND_COLOR =>
                        bus_rd_data <= state.blend_color;
                    
                    when REG_DEPTH_CLEAR =>
                        bus_rd_data <= x"00" & state.depth_clear;
                    
                    when REG_COLOR_CLEAR =>
                        bus_rd_data <= state.color_clear;
                    
                    when REG_STATUS =>
                        -- Status register (read-only)
                        bus_rd_data <= x"4D494C4F";  -- "MILO" magic
                    
                    when others =>
                        bus_rd_data <= (others => '0');
                end case;
            end if;
        end if;
    end process;

end architecture rtl;
