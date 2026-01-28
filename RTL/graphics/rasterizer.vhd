-------------------------------------------------------------------------------
-- rasterizer.vhd
-- Triangle Rasterizer with Edge Function Evaluation
-- Tile-based rendering for efficient memory access
--
-- New component for Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rasterizer is
    generic (
        -- Screen dimensions
        SCREEN_WIDTH    : integer := 640;
        SCREEN_HEIGHT   : integer := 480;
        
        -- Tile size (power of 2)
        TILE_SIZE       : integer := 16;
        
        -- Fixed point precision (16.16 format)
        FRAC_BITS       : integer := 16;
        
        -- Maximum triangles in queue
        TRI_QUEUE_DEPTH : integer := 32
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Triangle input interface
        tri_valid       : in  std_logic;
        tri_ready       : out std_logic;
        
        -- Vertex 0 (x, y, z, w) - screen space coordinates (fixed point 16.16)
        v0_x            : in  std_logic_vector(31 downto 0);
        v0_y            : in  std_logic_vector(31 downto 0);
        v0_z            : in  std_logic_vector(31 downto 0);
        
        -- Vertex 1
        v1_x            : in  std_logic_vector(31 downto 0);
        v1_y            : in  std_logic_vector(31 downto 0);
        v1_z            : in  std_logic_vector(31 downto 0);
        
        -- Vertex 2
        v2_x            : in  std_logic_vector(31 downto 0);
        v2_y            : in  std_logic_vector(31 downto 0);
        v2_z            : in  std_logic_vector(31 downto 0);
        
        -- Vertex attributes (interpolated to fragments)
        -- Texture coordinates (U, V) for each vertex
        v0_u            : in  std_logic_vector(31 downto 0);
        v0_v            : in  std_logic_vector(31 downto 0);
        v1_u            : in  std_logic_vector(31 downto 0);
        v1_v            : in  std_logic_vector(31 downto 0);
        v2_u            : in  std_logic_vector(31 downto 0);
        v2_v            : in  std_logic_vector(31 downto 0);
        
        -- Vertex colors (RGBA) for each vertex
        v0_color        : in  std_logic_vector(31 downto 0);
        v1_color        : in  std_logic_vector(31 downto 0);
        v2_color        : in  std_logic_vector(31 downto 0);
        
        -- Fragment output interface
        frag_valid      : out std_logic;
        frag_ready      : in  std_logic;
        frag_x          : out std_logic_vector(15 downto 0);
        frag_y          : out std_logic_vector(15 downto 0);
        frag_z          : out std_logic_vector(31 downto 0);  -- Depth for Z-buffer
        frag_u          : out std_logic_vector(31 downto 0);  -- Interpolated U
        frag_v          : out std_logic_vector(31 downto 0);  -- Interpolated V
        frag_color      : out std_logic_vector(31 downto 0);  -- Interpolated color
        
        -- Status
        busy            : out std_logic;
        triangles_in    : out std_logic_vector(15 downto 0);
        fragments_out   : out std_logic_vector(31 downto 0)
    );
end entity rasterizer;

architecture rtl of rasterizer is

    -- State machine
    type state_t is (
        IDLE,
        SETUP,              -- Calculate edge functions and bounding box
        TILE_SETUP,         -- Setup for current tile
        PIXEL_TEST,         -- Test pixels within tile
        OUTPUT_FRAGMENT,    -- Output valid fragment
        NEXT_TILE           -- Move to next tile
    );
    signal state : state_t := IDLE;
    
    -- Triangle data (latched from input)
    signal tri_v0_x, tri_v0_y, tri_v0_z : signed(31 downto 0);
    signal tri_v1_x, tri_v1_y, tri_v1_z : signed(31 downto 0);
    signal tri_v2_x, tri_v2_y, tri_v2_z : signed(31 downto 0);
    signal tri_v0_u, tri_v0_v : signed(31 downto 0);
    signal tri_v1_u, tri_v1_v : signed(31 downto 0);
    signal tri_v2_u, tri_v2_v : signed(31 downto 0);
    signal tri_v0_color, tri_v1_color, tri_v2_color : std_logic_vector(31 downto 0);
    
    -- Edge function coefficients: E(x,y) = A*x + B*y + C
    -- Edge 0: v0 -> v1
    signal e0_a, e0_b, e0_c : signed(47 downto 0);
    -- Edge 1: v1 -> v2
    signal e1_a, e1_b, e1_c : signed(47 downto 0);
    -- Edge 2: v2 -> v0
    signal e2_a, e2_b, e2_c : signed(47 downto 0);
    
    -- Triangle area (2x, for barycentric calculation)
    signal tri_area : signed(47 downto 0);
    signal tri_area_inv : signed(31 downto 0);  -- 1/area for interpolation
    
    -- Bounding box (in screen pixels)
    signal bbox_min_x, bbox_min_y : unsigned(15 downto 0);
    signal bbox_max_x, bbox_max_y : unsigned(15 downto 0);
    
    -- Current tile position
    signal tile_x, tile_y : unsigned(15 downto 0);
    
    -- Current pixel position within tile
    signal pixel_x, pixel_y : unsigned(15 downto 0);
    signal pixel_local_x, pixel_local_y : unsigned(3 downto 0);
    
    -- Edge function values at current pixel
    signal e0_val, e1_val, e2_val : signed(47 downto 0);
    
    -- Row start values (for efficient stepping)
    signal e0_row, e1_row, e2_row : signed(47 downto 0);
    
    -- Interpolated attributes
    signal interp_z : signed(31 downto 0);
    signal interp_u, interp_v : signed(31 downto 0);
    signal interp_color : std_logic_vector(31 downto 0);
    
    -- Statistics
    signal tri_count : unsigned(15 downto 0);
    signal frag_count : unsigned(31 downto 0);
    
    -- Helper function: Convert fixed point to integer (truncate)
    function fp_to_int(val : signed(31 downto 0)) return unsigned is
    begin
        return unsigned(val(31 downto FRAC_BITS));
    end function;
    
    -- Helper function: Clamp value to range
    function clamp(val : signed; min_val, max_val : integer) return unsigned is
        variable result : integer;
    begin
        result := to_integer(val);
        if result < min_val then
            result := min_val;
        elsif result > max_val then
            result := max_val;
        end if;
        return to_unsigned(result, 16);
    end function;
    
    -- Helper function: Check if point is inside triangle (all edges positive or all negative)
    function point_inside(e0, e1, e2 : signed(47 downto 0)) return boolean is
    begin
        -- Using top-left fill convention
        return (e0 >= 0 and e1 >= 0 and e2 >= 0) or
               (e0 <= 0 and e1 <= 0 and e2 <= 0);
    end function;

begin

    -- Output assignments
    tri_ready <= '1' when state = IDLE else '0';
    busy <= '0' when state = IDLE else '1';
    triangles_in <= std_logic_vector(tri_count);
    fragments_out <= std_logic_vector(frag_count);
    
    ---------------------------------------------------------------------------
    -- Main Rasterization State Machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable e0_step_x, e1_step_x, e2_step_x : signed(47 downto 0);
        variable e0_step_y, e1_step_y, e2_step_y : signed(47 downto 0);
        variable pixel_inside : boolean;
        variable bary_w0, bary_w1, bary_w2 : signed(47 downto 0);
        variable interp_tmp : signed(63 downto 0);
        variable color_r, color_g, color_b, color_a : unsigned(7 downto 0);
        variable w0_r, w0_g, w0_b, w0_a : unsigned(15 downto 0);
        variable w1_r, w1_g, w1_b, w1_a : unsigned(15 downto 0);
        variable w2_r, w2_g, w2_b, w2_a : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            frag_valid <= '0';
            tri_count <= (others => '0');
            frag_count <= (others => '0');
            
            frag_x <= (others => '0');
            frag_y <= (others => '0');
            frag_z <= (others => '0');
            frag_u <= (others => '0');
            frag_v <= (others => '0');
            frag_color <= (others => '0');
            
        elsif rising_edge(clk) then
            case state is
                ---------------------------------------------------------------
                when IDLE =>
                    frag_valid <= '0';
                    
                    if tri_valid = '1' then
                        -- Latch triangle data
                        tri_v0_x <= signed(v0_x);
                        tri_v0_y <= signed(v0_y);
                        tri_v0_z <= signed(v0_z);
                        tri_v1_x <= signed(v1_x);
                        tri_v1_y <= signed(v1_y);
                        tri_v1_z <= signed(v1_z);
                        tri_v2_x <= signed(v2_x);
                        tri_v2_y <= signed(v2_y);
                        tri_v2_z <= signed(v2_z);
                        
                        tri_v0_u <= signed(v0_u);
                        tri_v0_v <= signed(v0_v);
                        tri_v1_u <= signed(v1_u);
                        tri_v1_v <= signed(v1_v);
                        tri_v2_u <= signed(v2_u);
                        tri_v2_v <= signed(v2_v);
                        
                        tri_v0_color <= v0_color;
                        tri_v1_color <= v1_color;
                        tri_v2_color <= v2_color;
                        
                        tri_count <= tri_count + 1;
                        state <= SETUP;
                    end if;
                
                ---------------------------------------------------------------
                when SETUP =>
                    -- Calculate edge function coefficients
                    -- E0(x,y) = (v1_y - v0_y) * x - (v1_x - v0_x) * y + (v1_x * v0_y - v0_x * v1_y)
                    e0_a <= resize(tri_v1_y - tri_v0_y, 48);
                    e0_b <= resize(-(tri_v1_x - tri_v0_x), 48);
                    e0_c <= resize((tri_v1_x * tri_v0_y - tri_v0_x * tri_v1_y) / (2**FRAC_BITS), 48);
                    
                    e1_a <= resize(tri_v2_y - tri_v1_y, 48);
                    e1_b <= resize(-(tri_v2_x - tri_v1_x), 48);
                    e1_c <= resize((tri_v2_x * tri_v1_y - tri_v1_x * tri_v2_y) / (2**FRAC_BITS), 48);
                    
                    e2_a <= resize(tri_v0_y - tri_v2_y, 48);
                    e2_b <= resize(-(tri_v0_x - tri_v2_x), 48);
                    e2_c <= resize((tri_v0_x * tri_v2_y - tri_v2_x * tri_v0_y) / (2**FRAC_BITS), 48);
                    
                    -- Calculate triangle area (2x)
                    tri_area <= resize((tri_v1_x - tri_v0_x) * (tri_v2_y - tri_v0_y) - 
                                       (tri_v2_x - tri_v0_x) * (tri_v1_y - tri_v0_y), 48) / (2**FRAC_BITS);
                    
                    -- Calculate bounding box
                    bbox_min_x <= clamp(shift_right(tri_v0_x, FRAC_BITS), 0, SCREEN_WIDTH-1);
                    bbox_max_x <= clamp(shift_right(tri_v0_x, FRAC_BITS), 0, SCREEN_WIDTH-1);
                    bbox_min_y <= clamp(shift_right(tri_v0_y, FRAC_BITS), 0, SCREEN_HEIGHT-1);
                    bbox_max_y <= clamp(shift_right(tri_v0_y, FRAC_BITS), 0, SCREEN_HEIGHT-1);
                    
                    -- Expand bounding box for other vertices
                    if fp_to_int(tri_v1_x) < bbox_min_x then
                        bbox_min_x <= clamp(shift_right(tri_v1_x, FRAC_BITS), 0, SCREEN_WIDTH-1);
                    end if;
                    if fp_to_int(tri_v1_x) > bbox_max_x then
                        bbox_max_x <= clamp(shift_right(tri_v1_x, FRAC_BITS), 0, SCREEN_WIDTH-1);
                    end if;
                    if fp_to_int(tri_v2_x) < bbox_min_x then
                        bbox_min_x <= clamp(shift_right(tri_v2_x, FRAC_BITS), 0, SCREEN_WIDTH-1);
                    end if;
                    if fp_to_int(tri_v2_x) > bbox_max_x then
                        bbox_max_x <= clamp(shift_right(tri_v2_x, FRAC_BITS), 0, SCREEN_WIDTH-1);
                    end if;
                    
                    if fp_to_int(tri_v1_y) < bbox_min_y then
                        bbox_min_y <= clamp(shift_right(tri_v1_y, FRAC_BITS), 0, SCREEN_HEIGHT-1);
                    end if;
                    if fp_to_int(tri_v1_y) > bbox_max_y then
                        bbox_max_y <= clamp(shift_right(tri_v1_y, FRAC_BITS), 0, SCREEN_HEIGHT-1);
                    end if;
                    if fp_to_int(tri_v2_y) < bbox_min_y then
                        bbox_min_y <= clamp(shift_right(tri_v2_y, FRAC_BITS), 0, SCREEN_HEIGHT-1);
                    end if;
                    if fp_to_int(tri_v2_y) > bbox_max_y then
                        bbox_max_y <= clamp(shift_right(tri_v2_y, FRAC_BITS), 0, SCREEN_HEIGHT-1);
                    end if;
                    
                    -- Align bounding box to tile boundaries
                    tile_x <= bbox_min_x(15 downto 4) & "0000";
                    tile_y <= bbox_min_y(15 downto 4) & "0000";
                    
                    -- Check for degenerate triangle (zero area)
                    if tri_area = 0 then
                        state <= IDLE;
                    else
                        state <= TILE_SETUP;
                    end if;
                
                ---------------------------------------------------------------
                when TILE_SETUP =>
                    -- Calculate edge functions at tile origin
                    pixel_x <= tile_x;
                    pixel_y <= tile_y;
                    pixel_local_x <= (others => '0');
                    pixel_local_y <= (others => '0');
                    
                    -- Edge function at tile origin
                    e0_row <= e0_a * signed(resize(tile_x, 32)) + 
                              e0_b * signed(resize(tile_y, 32)) + e0_c;
                    e1_row <= e1_a * signed(resize(tile_x, 32)) + 
                              e1_b * signed(resize(tile_y, 32)) + e1_c;
                    e2_row <= e2_a * signed(resize(tile_x, 32)) + 
                              e2_b * signed(resize(tile_y, 32)) + e2_c;
                    
                    state <= PIXEL_TEST;
                
                ---------------------------------------------------------------
                when PIXEL_TEST =>
                    -- Calculate edge function values at current pixel
                    e0_val <= e0_row + e0_a * signed(resize(pixel_local_x, 48));
                    e1_val <= e1_row + e1_a * signed(resize(pixel_local_x, 48));
                    e2_val <= e2_row + e2_a * signed(resize(pixel_local_x, 48));
                    
                    -- Test if pixel is inside triangle
                    pixel_inside := point_inside(e0_val, e1_val, e2_val);
                    
                    if pixel_inside and pixel_x < SCREEN_WIDTH and pixel_y < SCREEN_HEIGHT and
                       pixel_x >= bbox_min_x and pixel_x <= bbox_max_x and
                       pixel_y >= bbox_min_y and pixel_y <= bbox_max_y then
                        -- Calculate barycentric coordinates
                        bary_w0 := e1_val;
                        bary_w1 := e2_val;
                        bary_w2 := e0_val;
                        
                        -- Interpolate Z (depth)
                        interp_tmp := (bary_w0 * tri_v0_z + bary_w1 * tri_v1_z + bary_w2 * tri_v2_z);
                        if tri_area /= 0 then
                            interp_z <= resize(interp_tmp / tri_area, 32);
                        end if;
                        
                        -- Interpolate texture coordinates
                        interp_tmp := (bary_w0 * tri_v0_u + bary_w1 * tri_v1_u + bary_w2 * tri_v2_u);
                        if tri_area /= 0 then
                            interp_u <= resize(interp_tmp / tri_area, 32);
                        end if;
                        
                        interp_tmp := (bary_w0 * tri_v0_v + bary_w1 * tri_v1_v + bary_w2 * tri_v2_v);
                        if tri_area /= 0 then
                            interp_v <= resize(interp_tmp / tri_area, 32);
                        end if;
                        
                        -- Interpolate color (per component)
                        w0_r := resize(unsigned(bary_w0(31 downto 16)) * unsigned(tri_v0_color(31 downto 24)), 16);
                        w1_r := resize(unsigned(bary_w1(31 downto 16)) * unsigned(tri_v1_color(31 downto 24)), 16);
                        w2_r := resize(unsigned(bary_w2(31 downto 16)) * unsigned(tri_v2_color(31 downto 24)), 16);
                        color_r := (w0_r + w1_r + w2_r)(15 downto 8);
                        
                        w0_g := resize(unsigned(bary_w0(31 downto 16)) * unsigned(tri_v0_color(23 downto 16)), 16);
                        w1_g := resize(unsigned(bary_w1(31 downto 16)) * unsigned(tri_v1_color(23 downto 16)), 16);
                        w2_g := resize(unsigned(bary_w2(31 downto 16)) * unsigned(tri_v2_color(23 downto 16)), 16);
                        color_g := (w0_g + w1_g + w2_g)(15 downto 8);
                        
                        w0_b := resize(unsigned(bary_w0(31 downto 16)) * unsigned(tri_v0_color(15 downto 8)), 16);
                        w1_b := resize(unsigned(bary_w1(31 downto 16)) * unsigned(tri_v1_color(15 downto 8)), 16);
                        w2_b := resize(unsigned(bary_w2(31 downto 16)) * unsigned(tri_v2_color(15 downto 8)), 16);
                        color_b := (w0_b + w1_b + w2_b)(15 downto 8);
                        
                        w0_a := resize(unsigned(bary_w0(31 downto 16)) * unsigned(tri_v0_color(7 downto 0)), 16);
                        w1_a := resize(unsigned(bary_w1(31 downto 16)) * unsigned(tri_v1_color(7 downto 0)), 16);
                        w2_a := resize(unsigned(bary_w2(31 downto 16)) * unsigned(tri_v2_color(7 downto 0)), 16);
                        color_a := (w0_a + w1_a + w2_a)(15 downto 8);
                        
                        interp_color <= std_logic_vector(color_r) & std_logic_vector(color_g) & 
                                       std_logic_vector(color_b) & std_logic_vector(color_a);
                        
                        state <= OUTPUT_FRAGMENT;
                    else
                        -- Move to next pixel
                        if pixel_local_x = TILE_SIZE - 1 then
                            pixel_local_x <= (others => '0');
                            pixel_x <= tile_x;
                            
                            if pixel_local_y = TILE_SIZE - 1 then
                                -- End of tile
                                state <= NEXT_TILE;
                            else
                                pixel_local_y <= pixel_local_y + 1;
                                pixel_y <= pixel_y + 1;
                                
                                -- Update row values
                                e0_row <= e0_row + e0_b;
                                e1_row <= e1_row + e1_b;
                                e2_row <= e2_row + e2_b;
                            end if;
                        else
                            pixel_local_x <= pixel_local_x + 1;
                            pixel_x <= pixel_x + 1;
                        end if;
                    end if;
                
                ---------------------------------------------------------------
                when OUTPUT_FRAGMENT =>
                    frag_valid <= '1';
                    frag_x <= std_logic_vector(pixel_x);
                    frag_y <= std_logic_vector(pixel_y);
                    frag_z <= std_logic_vector(interp_z);
                    frag_u <= std_logic_vector(interp_u);
                    frag_v <= std_logic_vector(interp_v);
                    frag_color <= interp_color;
                    
                    if frag_ready = '1' then
                        frag_valid <= '0';
                        frag_count <= frag_count + 1;
                        
                        -- Move to next pixel
                        if pixel_local_x = TILE_SIZE - 1 then
                            pixel_local_x <= (others => '0');
                            pixel_x <= tile_x;
                            
                            if pixel_local_y = TILE_SIZE - 1 then
                                state <= NEXT_TILE;
                            else
                                pixel_local_y <= pixel_local_y + 1;
                                pixel_y <= pixel_y + 1;
                                e0_row <= e0_row + e0_b;
                                e1_row <= e1_row + e1_b;
                                e2_row <= e2_row + e2_b;
                                state <= PIXEL_TEST;
                            end if;
                        else
                            pixel_local_x <= pixel_local_x + 1;
                            pixel_x <= pixel_x + 1;
                            state <= PIXEL_TEST;
                        end if;
                    end if;
                
                ---------------------------------------------------------------
                when NEXT_TILE =>
                    frag_valid <= '0';
                    
                    -- Move to next tile
                    if tile_x + TILE_SIZE <= bbox_max_x then
                        tile_x <= tile_x + TILE_SIZE;
                        state <= TILE_SETUP;
                    elsif tile_y + TILE_SIZE <= bbox_max_y then
                        tile_x <= bbox_min_x(15 downto 4) & "0000";
                        tile_y <= tile_y + TILE_SIZE;
                        state <= TILE_SETUP;
                    else
                        -- Done with triangle
                        state <= IDLE;
                    end if;
            end case;
        end if;
    end process;

end architecture rtl;
