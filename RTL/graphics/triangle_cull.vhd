-------------------------------------------------------------------------------
-- triangle_cull.vhd
-- Triangle Culling Unit
-- Performs backface culling before triangles reach the rasterizer
--
-- Sits between triangle input (from vertex shader/binner) and rasterizer
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.render_state_pkg.all;

entity triangle_cull is
    generic (
        FRAC_BITS : integer := 16
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Render state (from state registers)
        cull_mode       : in  cull_mode_t;
        front_face      : in  winding_t;
        
        -- Triangle input (screen space, fixed point)
        tri_in_valid    : in  std_logic;
        tri_in_ready    : out std_logic;
        
        -- Vertex 0
        v0_x            : in  std_logic_vector(31 downto 0);
        v0_y            : in  std_logic_vector(31 downto 0);
        v0_z            : in  std_logic_vector(31 downto 0);
        v0_u            : in  std_logic_vector(31 downto 0);
        v0_v            : in  std_logic_vector(31 downto 0);
        v0_color        : in  std_logic_vector(31 downto 0);
        
        -- Vertex 1
        v1_x            : in  std_logic_vector(31 downto 0);
        v1_y            : in  std_logic_vector(31 downto 0);
        v1_z            : in  std_logic_vector(31 downto 0);
        v1_u            : in  std_logic_vector(31 downto 0);
        v1_v            : in  std_logic_vector(31 downto 0);
        v1_color        : in  std_logic_vector(31 downto 0);
        
        -- Vertex 2
        v2_x            : in  std_logic_vector(31 downto 0);
        v2_y            : in  std_logic_vector(31 downto 0);
        v2_z            : in  std_logic_vector(31 downto 0);
        v2_u            : in  std_logic_vector(31 downto 0);
        v2_v            : in  std_logic_vector(31 downto 0);
        v2_color        : in  std_logic_vector(31 downto 0);
        
        -- Triangle output (passes through if not culled)
        tri_out_valid   : out std_logic;
        tri_out_ready   : in  std_logic;
        
        -- Output vertices (directly forwarded)
        out_v0_x        : out std_logic_vector(31 downto 0);
        out_v0_y        : out std_logic_vector(31 downto 0);
        out_v0_z        : out std_logic_vector(31 downto 0);
        out_v0_u        : out std_logic_vector(31 downto 0);
        out_v0_v        : out std_logic_vector(31 downto 0);
        out_v0_color    : out std_logic_vector(31 downto 0);
        
        out_v1_x        : out std_logic_vector(31 downto 0);
        out_v1_y        : out std_logic_vector(31 downto 0);
        out_v1_z        : out std_logic_vector(31 downto 0);
        out_v1_u        : out std_logic_vector(31 downto 0);
        out_v1_v        : out std_logic_vector(31 downto 0);
        out_v1_color    : out std_logic_vector(31 downto 0);
        
        out_v2_x        : out std_logic_vector(31 downto 0);
        out_v2_y        : out std_logic_vector(31 downto 0);
        out_v2_z        : out std_logic_vector(31 downto 0);
        out_v2_u        : out std_logic_vector(31 downto 0);
        out_v2_v        : out std_logic_vector(31 downto 0);
        out_v2_color    : out std_logic_vector(31 downto 0);
        
        -- Statistics
        triangles_in    : out std_logic_vector(31 downto 0);
        triangles_culled: out std_logic_vector(31 downto 0)
    );
end entity triangle_cull;

architecture rtl of triangle_cull is

    type state_t is (IDLE, COMPUTE, OUTPUT, CULLED);
    signal state : state_t := IDLE;
    
    -- Latched input
    signal lat_v0_x, lat_v0_y, lat_v0_z : std_logic_vector(31 downto 0);
    signal lat_v1_x, lat_v1_y, lat_v1_z : std_logic_vector(31 downto 0);
    signal lat_v2_x, lat_v2_y, lat_v2_z : std_logic_vector(31 downto 0);
    signal lat_v0_u, lat_v0_v, lat_v0_color : std_logic_vector(31 downto 0);
    signal lat_v1_u, lat_v1_v, lat_v1_color : std_logic_vector(31 downto 0);
    signal lat_v2_u, lat_v2_v, lat_v2_color : std_logic_vector(31 downto 0);
    
    -- Cross product result (2x signed area)
    signal cross_z : signed(63 downto 0);
    signal sign_area : std_logic;
    
    -- Counters
    signal in_count, cull_count : unsigned(31 downto 0);

begin

    tri_in_ready <= '1' when state = IDLE else '0';
    
    triangles_in <= std_logic_vector(in_count);
    triangles_culled <= std_logic_vector(cull_count);
    
    -- Output vertex data (directly from latches)
    out_v0_x <= lat_v0_x; out_v0_y <= lat_v0_y; out_v0_z <= lat_v0_z;
    out_v0_u <= lat_v0_u; out_v0_v <= lat_v0_v; out_v0_color <= lat_v0_color;
    out_v1_x <= lat_v1_x; out_v1_y <= lat_v1_y; out_v1_z <= lat_v1_z;
    out_v1_u <= lat_v1_u; out_v1_v <= lat_v1_v; out_v1_color <= lat_v1_color;
    out_v2_x <= lat_v2_x; out_v2_y <= lat_v2_y; out_v2_z <= lat_v2_z;
    out_v2_u <= lat_v2_u; out_v2_v <= lat_v2_v; out_v2_color <= lat_v2_color;
    
    process(clk, rst_n)
        variable dx1, dy1, dx2, dy2 : signed(31 downto 0);
        variable cross : signed(63 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            tri_out_valid <= '0';
            in_count <= (others => '0');
            cull_count <= (others => '0');
            cross_z <= (others => '0');
            sign_area <= '0';
            
        elsif rising_edge(clk) then
            case state is
                when IDLE =>
                    tri_out_valid <= '0';
                    
                    if tri_in_valid = '1' then
                        -- Latch all vertex data
                        lat_v0_x <= v0_x; lat_v0_y <= v0_y; lat_v0_z <= v0_z;
                        lat_v0_u <= v0_u; lat_v0_v <= v0_v; lat_v0_color <= v0_color;
                        lat_v1_x <= v1_x; lat_v1_y <= v1_y; lat_v1_z <= v1_z;
                        lat_v1_u <= v1_u; lat_v1_v <= v1_v; lat_v1_color <= v1_color;
                        lat_v2_x <= v2_x; lat_v2_y <= v2_y; lat_v2_z <= v2_z;
                        lat_v2_u <= v2_u; lat_v2_v <= v2_v; lat_v2_color <= v2_color;
                        
                        in_count <= in_count + 1;
                        state <= COMPUTE;
                    end if;
                
                when COMPUTE =>
                    -- Compute 2D cross product (signed area) in screen space
                    -- cross_z = (v1 - v0) x (v2 - v0)
                    --         = (v1.x - v0.x) * (v2.y - v0.y) - (v1.y - v0.y) * (v2.x - v0.x)
                    
                    dx1 := signed(lat_v1_x) - signed(lat_v0_x);
                    dy1 := signed(lat_v1_y) - signed(lat_v0_y);
                    dx2 := signed(lat_v2_x) - signed(lat_v0_x);
                    dy2 := signed(lat_v2_y) - signed(lat_v0_y);
                    
                    cross := dx1 * dy2 - dy1 * dx2;
                    cross_z <= cross;
                    
                    -- synthesis translate_off
                    report "triangle_cull COMPUTE: cross=" & integer'image(to_integer(cross(47 downto 16))) &
                           " sign=" & std_logic'image(cross(63)) &
                           " cull_mode=" & integer'image(to_integer(unsigned(cull_mode))) &
                           " front_face=" & std_logic'image(front_face);
                    -- synthesis translate_on
                    
                    -- Sign: '0' = positive (CCW), '1' = negative (CW)
                    if cross < 0 then
                        sign_area <= '1';
                    else
                        sign_area <= '0';
                    end if;
                    
                    -- Check if should cull (using computed sign)
                    if should_cull(cross(63), cull_mode, front_face) then
                        -- synthesis translate_off
                        report "triangle_cull: CULLING triangle";
                        -- synthesis translate_on
                        state <= CULLED;
                    else
                        -- synthesis translate_off
                        report "triangle_cull: PASSING triangle to OUTPUT";
                        -- synthesis translate_on
                        state <= OUTPUT;
                    end if;
                
                when OUTPUT =>
                    tri_out_valid <= '1';
                    
                    if tri_out_ready = '1' then
                        -- Handshake complete, go back to idle
                        -- tri_out_valid will be cleared when we reach IDLE
                        state <= IDLE;
                    end if;
                
                when CULLED =>
                    -- Triangle was culled, go back to idle
                    cull_count <= cull_count + 1;
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
