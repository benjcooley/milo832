-------------------------------------------------------------------------------
-- primitive_assembly.vhd
-- Primitive Assembly Unit
--
-- Collects vertices from vertex shader/fetch and assembles primitives
-- (triangles, strips, fans) for rasterization.
--
-- Supports:
--   - Triangle list (every 3 vertices = 1 triangle)
--   - Triangle strip (first 3 = triangle, then each new vertex = new triangle)
--   - Triangle fan (first vertex = hub, then each pair forms triangle with hub)
--
-- Milo832 GPU project - Graphics coprocessor for m65832 CPU
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity primitive_assembly is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -----------------------------------------------------------------------
        -- Configuration
        -----------------------------------------------------------------------
        prim_type       : in  std_logic_vector(2 downto 0);     -- Primitive type
        prim_restart_en : in  std_logic;                        -- Restart on index
        prim_restart_idx: in  std_logic_vector(31 downto 0);    -- Restart index
        
        -----------------------------------------------------------------------
        -- Vertex Input (from vertex shader or fetch)
        -----------------------------------------------------------------------
        vtx_valid       : in  std_logic;
        vtx_ready       : out std_logic;
        vtx_index       : in  std_logic_vector(31 downto 0);
        vtx_pos_x       : in  std_logic_vector(31 downto 0);
        vtx_pos_y       : in  std_logic_vector(31 downto 0);
        vtx_pos_z       : in  std_logic_vector(31 downto 0);
        vtx_pos_w       : in  std_logic_vector(31 downto 0);    -- W component (for clip)
        vtx_uv_u        : in  std_logic_vector(31 downto 0);
        vtx_uv_v        : in  std_logic_vector(31 downto 0);
        vtx_color       : in  std_logic_vector(31 downto 0);
        
        -----------------------------------------------------------------------
        -- Triangle Output (to rasterizer)
        -----------------------------------------------------------------------
        tri_valid       : out std_logic;
        tri_ready       : in  std_logic;
        
        -- Vertex 0
        tri_v0_x        : out std_logic_vector(31 downto 0);
        tri_v0_y        : out std_logic_vector(31 downto 0);
        tri_v0_z        : out std_logic_vector(31 downto 0);
        tri_v0_w        : out std_logic_vector(31 downto 0);
        tri_v0_u        : out std_logic_vector(31 downto 0);
        tri_v0_v        : out std_logic_vector(31 downto 0);
        tri_v0_color    : out std_logic_vector(31 downto 0);
        
        -- Vertex 1
        tri_v1_x        : out std_logic_vector(31 downto 0);
        tri_v1_y        : out std_logic_vector(31 downto 0);
        tri_v1_z        : out std_logic_vector(31 downto 0);
        tri_v1_w        : out std_logic_vector(31 downto 0);
        tri_v1_u        : out std_logic_vector(31 downto 0);
        tri_v1_v        : out std_logic_vector(31 downto 0);
        tri_v1_color    : out std_logic_vector(31 downto 0);
        
        -- Vertex 2
        tri_v2_x        : out std_logic_vector(31 downto 0);
        tri_v2_y        : out std_logic_vector(31 downto 0);
        tri_v2_z        : out std_logic_vector(31 downto 0);
        tri_v2_w        : out std_logic_vector(31 downto 0);
        tri_v2_u        : out std_logic_vector(31 downto 0);
        tri_v2_v        : out std_logic_vector(31 downto 0);
        tri_v2_color    : out std_logic_vector(31 downto 0);
        
        -----------------------------------------------------------------------
        -- Control
        -----------------------------------------------------------------------
        flush           : in  std_logic;                        -- Clear state
        
        -----------------------------------------------------------------------
        -- Status
        -----------------------------------------------------------------------
        triangles_out   : out std_logic_vector(31 downto 0);
        vertices_in     : out std_logic_vector(31 downto 0)
    );
end entity primitive_assembly;

architecture rtl of primitive_assembly is

    -- Primitive types
    constant PRIM_TRIANGLES     : std_logic_vector(2 downto 0) := "000";
    constant PRIM_TRIANGLE_STRIP: std_logic_vector(2 downto 0) := "001";
    constant PRIM_TRIANGLE_FAN  : std_logic_vector(2 downto 0) := "010";
    
    -- Vertex buffer type
    type vertex_t is record
        x, y, z, w  : std_logic_vector(31 downto 0);
        u, v        : std_logic_vector(31 downto 0);
        color       : std_logic_vector(31 downto 0);
    end record;
    
    constant VERTEX_ZERO : vertex_t := (
        x => (others => '0'), y => (others => '0'), 
        z => (others => '0'), w => (others => '0'),
        u => (others => '0'), v => (others => '0'),
        color => (others => '0')
    );
    
    -- Vertex buffer (stores up to 3 vertices)
    type vertex_array_t is array(0 to 2) of vertex_t;
    signal vtx_buf : vertex_array_t := (others => VERTEX_ZERO);
    
    -- State
    signal vtx_count        : unsigned(1 downto 0) := (others => '0');  -- 0-2
    signal strip_idx        : unsigned(31 downto 0) := (others => '0'); -- For strips
    signal fan_hub          : vertex_t := VERTEX_ZERO;  -- First vertex for fan
    signal fan_hub_valid    : std_logic := '0';
    
    -- Counters
    signal tri_count        : unsigned(31 downto 0) := (others => '0');
    signal vtx_in_count     : unsigned(31 downto 0) := (others => '0');
    
    -- Output holding register
    signal out_valid        : std_logic := '0';
    signal out_v0, out_v1, out_v2 : vertex_t := VERTEX_ZERO;
    
    -- Ready signal
    signal can_accept       : std_logic;

begin

    triangles_out <= std_logic_vector(tri_count);
    vertices_in <= std_logic_vector(vtx_in_count);
    
    -- Can accept new vertex when not outputting or output accepted
    can_accept <= '1' when out_valid = '0' or tri_ready = '1' else '0';
    vtx_ready <= can_accept;
    
    -- Output signals
    tri_valid <= out_valid;
    
    tri_v0_x <= out_v0.x;
    tri_v0_y <= out_v0.y;
    tri_v0_z <= out_v0.z;
    tri_v0_w <= out_v0.w;
    tri_v0_u <= out_v0.u;
    tri_v0_v <= out_v0.v;
    tri_v0_color <= out_v0.color;
    
    tri_v1_x <= out_v1.x;
    tri_v1_y <= out_v1.y;
    tri_v1_z <= out_v1.z;
    tri_v1_w <= out_v1.w;
    tri_v1_u <= out_v1.u;
    tri_v1_v <= out_v1.v;
    tri_v1_color <= out_v1.color;
    
    tri_v2_x <= out_v2.x;
    tri_v2_y <= out_v2.y;
    tri_v2_z <= out_v2.z;
    tri_v2_w <= out_v2.w;
    tri_v2_u <= out_v2.u;
    tri_v2_v <= out_v2.v;
    tri_v2_color <= out_v2.color;
    
    -- Main process
    process(clk, rst_n)
        variable new_vtx : vertex_t;
        variable is_restart : boolean;
    begin
        if rst_n = '0' then
            vtx_buf <= (others => VERTEX_ZERO);
            vtx_count <= (others => '0');
            strip_idx <= (others => '0');
            fan_hub <= VERTEX_ZERO;
            fan_hub_valid <= '0';
            tri_count <= (others => '0');
            vtx_in_count <= (others => '0');
            out_valid <= '0';
            out_v0 <= VERTEX_ZERO;
            out_v1 <= VERTEX_ZERO;
            out_v2 <= VERTEX_ZERO;
            
        elsif rising_edge(clk) then
            -- Handle output handshake
            if out_valid = '1' and tri_ready = '1' then
                out_valid <= '0';
            end if;
            
            -- Handle flush
            if flush = '1' then
                vtx_buf <= (others => VERTEX_ZERO);
                vtx_count <= (others => '0');
                strip_idx <= (others => '0');
                fan_hub_valid <= '0';
                tri_count <= (others => '0');
            
            -- Accept new vertex
            elsif vtx_valid = '1' and can_accept = '1' then
                vtx_in_count <= vtx_in_count + 1;
                
                -- Check for primitive restart
                is_restart := prim_restart_en = '1' and vtx_index = prim_restart_idx;
                
                if is_restart then
                    -- Reset state for new primitive
                    vtx_count <= (others => '0');
                    strip_idx <= (others => '0');
                    fan_hub_valid <= '0';
                else
                    -- Build vertex record
                    new_vtx.x := vtx_pos_x;
                    new_vtx.y := vtx_pos_y;
                    new_vtx.z := vtx_pos_z;
                    new_vtx.w := vtx_pos_w;
                    new_vtx.u := vtx_uv_u;
                    new_vtx.v := vtx_uv_v;
                    new_vtx.color := vtx_color;
                    
                    case prim_type is
                        --------------------------------------------------
                        -- Triangle List: every 3 vertices = 1 triangle
                        --------------------------------------------------
                        when PRIM_TRIANGLES =>
                            vtx_buf(to_integer(vtx_count)) <= new_vtx;
                            
                            if vtx_count = 2 then
                                -- Output triangle
                                out_v0 <= vtx_buf(0);
                                out_v1 <= vtx_buf(1);
                                out_v2 <= new_vtx;
                                out_valid <= '1';
                                tri_count <= tri_count + 1;
                                vtx_count <= (others => '0');
                            else
                                vtx_count <= vtx_count + 1;
                            end if;
                        
                        --------------------------------------------------
                        -- Triangle Strip: v0,v1,v2 then v1,v2,v3 etc.
                        -- Alternate winding to maintain consistent facing
                        --------------------------------------------------
                        when PRIM_TRIANGLE_STRIP =>
                            if vtx_count < 2 then
                                -- Accumulating first 2 vertices
                                vtx_buf(to_integer(vtx_count)) <= new_vtx;
                                vtx_count <= vtx_count + 1;
                            else
                                -- Have 2 vertices, new one completes triangle
                                if strip_idx(0) = '0' then
                                    -- Even: v0, v1, v2
                                    out_v0 <= vtx_buf(0);
                                    out_v1 <= vtx_buf(1);
                                    out_v2 <= new_vtx;
                                else
                                    -- Odd: v1, v0, v2 (reversed for consistent winding)
                                    out_v0 <= vtx_buf(1);
                                    out_v1 <= vtx_buf(0);
                                    out_v2 <= new_vtx;
                                end if;
                                out_valid <= '1';
                                tri_count <= tri_count + 1;
                                
                                -- Shift: v1 becomes v0, new becomes v1
                                vtx_buf(0) <= vtx_buf(1);
                                vtx_buf(1) <= new_vtx;
                                strip_idx <= strip_idx + 1;
                            end if;
                        
                        --------------------------------------------------
                        -- Triangle Fan: v0 = hub, then v0,v_n,v_{n+1}
                        --------------------------------------------------
                        when PRIM_TRIANGLE_FAN =>
                            if fan_hub_valid = '0' then
                                -- First vertex is the hub
                                fan_hub <= new_vtx;
                                fan_hub_valid <= '1';
                            elsif vtx_count = 0 then
                                -- Second vertex (first spoke)
                                vtx_buf(0) <= new_vtx;
                                vtx_count <= "01";
                            else
                                -- Third+ vertex: form triangle with hub
                                out_v0 <= fan_hub;
                                out_v1 <= vtx_buf(0);
                                out_v2 <= new_vtx;
                                out_valid <= '1';
                                tri_count <= tri_count + 1;
                                
                                -- Current becomes previous spoke
                                vtx_buf(0) <= new_vtx;
                            end if;
                        
                        when others =>
                            -- Unsupported primitive type - ignore
                            null;
                    end case;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
