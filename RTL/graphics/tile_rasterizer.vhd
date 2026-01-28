-------------------------------------------------------------------------------
-- tile_rasterizer.vhd
-- Per-Tile Triangle Rasterization
-- Generates fragments for triangles within a single tile
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tile_rasterizer is
    generic (
        TILE_SIZE       : integer := 16;
        FRAC_BITS       : integer := 16
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Tile position
        tile_x          : in  std_logic_vector(7 downto 0);   -- Tile X index
        tile_y          : in  std_logic_vector(7 downto 0);   -- Tile Y index
        
        -- Triangle input
        tri_valid       : in  std_logic;
        tri_ready       : out std_logic;
        
        -- Vertex positions (screen space, 16.16 fixed point)
        v0_x, v0_y, v0_z : in  std_logic_vector(31 downto 0);
        v1_x, v1_y, v1_z : in  std_logic_vector(31 downto 0);
        v2_x, v2_y, v2_z : in  std_logic_vector(31 downto 0);
        
        -- Vertex attributes (texture coords, 16.16 fixed point)
        v0_u, v0_v      : in  std_logic_vector(31 downto 0);
        v1_u, v1_v      : in  std_logic_vector(31 downto 0);
        v2_u, v2_v      : in  std_logic_vector(31 downto 0);
        
        -- Vertex colors (RGBA8888)
        v0_color        : in  std_logic_vector(31 downto 0);
        v1_color        : in  std_logic_vector(31 downto 0);
        v2_color        : in  std_logic_vector(31 downto 0);
        
        -- Fragment output
        frag_valid      : out std_logic;
        frag_ready      : in  std_logic;
        frag_x          : out std_logic_vector(15 downto 0);  -- Screen X
        frag_y          : out std_logic_vector(15 downto 0);  -- Screen Y
        frag_z          : out std_logic_vector(23 downto 0);  -- Depth
        frag_u          : out std_logic_vector(31 downto 0);  -- Texture U
        frag_v          : out std_logic_vector(31 downto 0);  -- Texture V
        frag_color      : out std_logic_vector(31 downto 0);  -- Interpolated color
        
        -- Status
        triangle_done   : out std_logic;
        fragments_out   : out std_logic_vector(15 downto 0)
    );
end entity tile_rasterizer;

architecture rtl of tile_rasterizer is

    type state_t is (
        IDLE,
        SETUP,
        SCAN_INIT,
        PIXEL_TEST,
        OUTPUT_FRAG,
        NEXT_PIXEL,
        DONE
    );
    signal state : state_t := IDLE;
    
    -- Latched triangle data
    signal lat_v0_x, lat_v0_y, lat_v0_z : signed(31 downto 0);
    signal lat_v1_x, lat_v1_y, lat_v1_z : signed(31 downto 0);
    signal lat_v2_x, lat_v2_y, lat_v2_z : signed(31 downto 0);
    signal lat_v0_u, lat_v0_v : signed(31 downto 0);
    signal lat_v1_u, lat_v1_v : signed(31 downto 0);
    signal lat_v2_u, lat_v2_v : signed(31 downto 0);
    signal lat_v0_color, lat_v1_color, lat_v2_color : std_logic_vector(31 downto 0);
    
    -- Tile origin in screen coordinates
    signal tile_origin_x, tile_origin_y : unsigned(15 downto 0);
    
    -- Current pixel position (within tile: 0 to TILE_SIZE-1)
    signal pixel_x, pixel_y : unsigned(4 downto 0);
    
    -- Current pixel screen coordinates (fixed point for precision)
    signal screen_x, screen_y : signed(31 downto 0);
    
    -- Edge function coefficients: E(x,y) = A*(x-v0x) + B*(y-v0y)
    -- E0: edge v0->v1, E1: edge v1->v2, E2: edge v2->v0
    signal e0_a, e0_b : signed(31 downto 0);
    signal e1_a, e1_b : signed(31 downto 0);
    signal e2_a, e2_b : signed(31 downto 0);
    
    -- Edge function values at current pixel
    signal e0_val, e1_val, e2_val : signed(63 downto 0);
    
    -- Edge function values at row start (for incremental update)
    signal e0_row, e1_row, e2_row : signed(63 downto 0);
    
    -- Triangle area (2x, for barycentric)
    signal tri_area : signed(63 downto 0);
    
    -- Interpolated attributes
    signal interp_z : signed(31 downto 0);
    signal interp_u, interp_v : signed(31 downto 0);
    signal interp_color : std_logic_vector(31 downto 0);
    
    -- Fragment counter
    signal frag_count : unsigned(15 downto 0);
    
    -- Helper: Check if inside triangle (all same sign)
    function inside_triangle(e0, e1, e2 : signed(63 downto 0)) return boolean is
    begin
        return (e0 >= 0 and e1 >= 0 and e2 >= 0) or
               (e0 <= 0 and e1 <= 0 and e2 <= 0);
    end function;

begin

    tri_ready <= '1' when state = IDLE else '0';
    fragments_out <= std_logic_vector(frag_count);
    
    process(clk, rst_n)
        variable px_screen_x, px_screen_y : signed(31 downto 0);
        variable bary_w0, bary_w1, bary_w2 : signed(63 downto 0);
        variable interp_tmp : signed(95 downto 0);
        variable cr0, cg0, cb0, ca0 : unsigned(7 downto 0);
        variable cr1, cg1, cb1, ca1 : unsigned(7 downto 0);
        variable cr2, cg2, cb2, ca2 : unsigned(7 downto 0);
        variable wr0, wg0, wb0, wa0 : unsigned(23 downto 0);
        variable wr1, wg1, wb1, wa1 : unsigned(23 downto 0);
        variable wr2, wg2, wb2, wa2 : unsigned(23 downto 0);
        variable final_r, final_g, final_b, final_a : unsigned(7 downto 0);
        -- For barycentric normalization
        variable sum_abs : unsigned(47 downto 0);
        variable w0_abs, w1_abs, w2_abs : unsigned(31 downto 0);
        variable w0_frac, w1_frac, w2_frac : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            frag_valid <= '0';
            triangle_done <= '0';
            frag_count <= (others => '0');
            
        elsif rising_edge(clk) then
            triangle_done <= '0';
            
            case state is
                when IDLE =>
                    frag_valid <= '0';
                    
                    if tri_valid = '1' then
                        -- Latch triangle data
                        lat_v0_x <= signed(v0_x);
                        lat_v0_y <= signed(v0_y);
                        lat_v0_z <= signed(v0_z);
                        lat_v1_x <= signed(v1_x);
                        lat_v1_y <= signed(v1_y);
                        lat_v1_z <= signed(v1_z);
                        lat_v2_x <= signed(v2_x);
                        lat_v2_y <= signed(v2_y);
                        lat_v2_z <= signed(v2_z);
                        
                        lat_v0_u <= signed(v0_u);
                        lat_v0_v <= signed(v0_v);
                        lat_v1_u <= signed(v1_u);
                        lat_v1_v <= signed(v1_v);
                        lat_v2_u <= signed(v2_u);
                        lat_v2_v <= signed(v2_v);
                        
                        lat_v0_color <= v0_color;
                        lat_v1_color <= v1_color;
                        lat_v2_color <= v2_color;
                        
                        -- Calculate tile origin
                        tile_origin_x <= unsigned(tile_x) * TILE_SIZE;
                        tile_origin_y <= unsigned(tile_y) * TILE_SIZE;
                        
                        frag_count <= (others => '0');
                        state <= SETUP;
                    end if;
                
                when SETUP =>
                    -- Compute edge function coefficients
                    -- E0: v0 -> v1: A = (y1-y0), B = -(x1-x0)
                    e0_a <= lat_v1_y - lat_v0_y;
                    e0_b <= -(lat_v1_x - lat_v0_x);
                    
                    -- E1: v1 -> v2
                    e1_a <= lat_v2_y - lat_v1_y;
                    e1_b <= -(lat_v2_x - lat_v1_x);
                    
                    -- E2: v2 -> v0
                    e2_a <= lat_v0_y - lat_v2_y;
                    e2_b <= -(lat_v0_x - lat_v2_x);
                    
                    -- Triangle area (2x)
                    tri_area <= resize((lat_v1_x - lat_v0_x) * (lat_v2_y - lat_v0_y) - 
                                       (lat_v2_x - lat_v0_x) * (lat_v1_y - lat_v0_y), 64);
                    
                    state <= SCAN_INIT;
                
                when SCAN_INIT =>
                    -- synthesis translate_off
                    report "SCAN_INIT: entering";
                    -- synthesis translate_on
                    
                    -- Initialize scan at tile origin
                    pixel_x <= (others => '0');
                    pixel_y <= (others => '0');
                    
                    -- Screen coordinate of first pixel (center of pixel, +0.5)
                    -- Convert tile_origin to fixed-point: shift left by FRAC_BITS and add 0.5
                    -- synthesis translate_off
                    report "SCAN_INIT: tile_origin_x=" & integer'image(to_integer(tile_origin_x));
                    -- synthesis translate_on
                    
                    px_screen_x := shift_left(resize(signed('0' & tile_origin_x), 32), FRAC_BITS) + 
                                   to_signed(2**(FRAC_BITS-1), 32);
                    px_screen_y := shift_left(resize(signed('0' & tile_origin_y), 32), FRAC_BITS) + 
                                   to_signed(2**(FRAC_BITS-1), 32);
                    
                    -- synthesis translate_off
                    report "SCAN_INIT: px_screen=(" & integer'image(to_integer(px_screen_x)) & "," &
                                                      integer'image(to_integer(px_screen_y)) & ")";
                    -- synthesis translate_on
                    
                    screen_x <= px_screen_x;
                    screen_y <= px_screen_y;
                    
                    -- synthesis translate_off
                    report "SCAN_INIT: computing e0_row";
                    -- synthesis translate_on
                    
                    -- Compute edge functions at tile origin  
                    e0_row <= resize(e0_a * (px_screen_x - lat_v0_x) + e0_b * (px_screen_y - lat_v0_y), 64);
                    
                    -- synthesis translate_off
                    report "SCAN_INIT: e1_a=" & integer'image(to_integer(e1_a)) & 
                           " e1_b=" & integer'image(to_integer(e1_b));
                    report "SCAN_INIT: lat_v1=(" & integer'image(to_integer(lat_v1_x)) & "," &
                                                   integer'image(to_integer(lat_v1_y)) & ")";
                    -- synthesis translate_on
                    
                    e1_row <= resize(e1_a * (px_screen_x - lat_v1_x) + e1_b * (px_screen_y - lat_v1_y), 64);
                    e2_row <= resize(e2_a * (px_screen_x - lat_v2_x) + e2_b * (px_screen_y - lat_v2_y), 64);
                    
                    -- Check for degenerate triangle
                    -- synthesis translate_off
                    report "SCAN_INIT: tri_area (sign)=" & std_logic'image(tri_area(63)) &
                           " tile_origin=(" & integer'image(to_integer(tile_origin_x)) & "," &
                                              integer'image(to_integer(tile_origin_y)) & ")";
                    -- synthesis translate_on
                    
                    if tri_area = 0 then
                        -- synthesis translate_off
                        report "SCAN_INIT: Degenerate triangle, skipping";
                        -- synthesis translate_on
                        state <= DONE;
                    else
                        state <= PIXEL_TEST;
                    end if;
                
                when PIXEL_TEST =>
                    -- Compute edge values at current pixel using variables for immediate use
                    -- E0 = edge v0->v1, E1 = edge v1->v2, E2 = edge v2->v0
                    -- pixel_x offset in fixed-point: shift left by FRAC_BITS
                    px_screen_x := shift_left(resize(signed('0' & pixel_x), 32), FRAC_BITS);
                    bary_w2 := e0_row + resize(e0_a * px_screen_x, 64);
                    bary_w0 := e1_row + resize(e1_a * px_screen_x, 64);
                    bary_w1 := e2_row + resize(e2_a * px_screen_x, 64);
                    
                    -- Store in signals for debugging
                    e0_val <= bary_w2;
                    e1_val <= bary_w0;
                    e2_val <= bary_w1;
                    
                    -- Check if pixel is inside triangle
                    -- Inside if all edge values have same sign (all >= 0 or all <= 0)
                    -- synthesis translate_off
                    if (pixel_x = 0 and pixel_y = 0) or (pixel_x = 8 and pixel_y = 10) then
                        report "PIXEL_TEST(" & integer'image(to_integer(pixel_x)) & "," &
                               integer'image(to_integer(pixel_y)) & "): e0=" & 
                               integer'image(to_integer(bary_w2(47 downto 16))) &
                               " e1=" & integer'image(to_integer(bary_w0(47 downto 16))) &
                               " e2=" & integer'image(to_integer(bary_w1(47 downto 16))) &
                               " (all pos: " & boolean'image(bary_w2 >= 0 and bary_w0 >= 0 and bary_w1 >= 0) & ")";
                    end if;
                    -- synthesis translate_on
                    
                    if inside_triangle(bary_w2, bary_w0, bary_w1) then
                        -- Barycentric: w0 is opposite v0 (edge e1), etc.
                        -- synthesis translate_off
                        report "PIXEL_TEST: Inside at " & integer'image(to_integer(pixel_x)) & "," &
                               integer'image(to_integer(pixel_y));
                        -- synthesis translate_on
                        
                        -- Interpolate Z
                        interp_tmp := bary_w0 * lat_v0_z + bary_w1 * lat_v1_z + bary_w2 * lat_v2_z;
                        if tri_area /= 0 then
                            interp_z <= resize(interp_tmp / tri_area, 32);
                        end if;
                        
                        -- Interpolate texture coordinates
                        interp_tmp := bary_w0 * lat_v0_u + bary_w1 * lat_v1_u + bary_w2 * lat_v2_u;
                        if tri_area /= 0 then
                            interp_u <= resize(interp_tmp / tri_area, 32);
                        end if;
                        
                        interp_tmp := bary_w0 * lat_v0_v + bary_w1 * lat_v1_v + bary_w2 * lat_v2_v;
                        if tri_area /= 0 then
                            interp_v <= resize(interp_tmp / tri_area, 32);
                        end if;
                        
                        -- Interpolate color (per channel)
                        cr0 := unsigned(lat_v0_color(31 downto 24));
                        cg0 := unsigned(lat_v0_color(23 downto 16));
                        cb0 := unsigned(lat_v0_color(15 downto 8));
                        ca0 := unsigned(lat_v0_color(7 downto 0));
                        
                        cr1 := unsigned(lat_v1_color(31 downto 24));
                        cg1 := unsigned(lat_v1_color(23 downto 16));
                        cb1 := unsigned(lat_v1_color(15 downto 8));
                        ca1 := unsigned(lat_v1_color(7 downto 0));
                        
                        cr2 := unsigned(lat_v2_color(31 downto 24));
                        cg2 := unsigned(lat_v2_color(23 downto 16));
                        cb2 := unsigned(lat_v2_color(15 downto 8));
                        ca2 := unsigned(lat_v2_color(7 downto 0));
                        
                        -- Proper barycentric color interpolation
                        -- bary_w0, bary_w1, bary_w2 are edge function values (all positive for CCW, all negative for CW)
                        -- Normalize by sum to get weights in 0..1 range
                        
                        -- Get absolute values of barycentric coords (use bits 47:16 for magnitude)
                        if bary_w0 >= 0 then
                            w0_abs := unsigned(bary_w0(47 downto 16));
                        else
                            w0_abs := unsigned(-bary_w0(47 downto 16));
                        end if;
                        if bary_w1 >= 0 then
                            w1_abs := unsigned(bary_w1(47 downto 16));
                        else
                            w1_abs := unsigned(-bary_w1(47 downto 16));
                        end if;
                        if bary_w2 >= 0 then
                            w2_abs := unsigned(bary_w2(47 downto 16));
                        else
                            w2_abs := unsigned(-bary_w2(47 downto 16));
                        end if;
                        
                        -- Sum of weights
                        sum_abs := resize(w0_abs, 48) + resize(w1_abs, 48) + resize(w2_abs, 48);
                        
                        -- Normalize to 0.16 fixed point (multiply by 65536, divide by sum)
                        if sum_abs /= 0 then
                            w0_frac := resize(shift_left(resize(w0_abs, 48), 16) / sum_abs, 16);
                            w1_frac := resize(shift_left(resize(w1_abs, 48), 16) / sum_abs, 16);
                            w2_frac := resize(shift_left(resize(w2_abs, 48), 16) / sum_abs, 16);
                        else
                            w0_frac := x"5555"; w1_frac := x"5555"; w2_frac := x"5555";
                        end if;
                        
                        -- Interpolate colors: result = w0*c0 + w1*c1 + w2*c2
                        -- With 0.16 weights and 8-bit colors, product is 8.16, sum is 10.16
                        -- Take upper 8 bits after adding
                        wr0 := resize(w0_frac * cr0, 24);
                        wr1 := resize(w1_frac * cr1, 24);
                        wr2 := resize(w2_frac * cr2, 24);
                        final_r := resize(shift_right(wr0 + wr1 + wr2, 16), 8);
                        
                        wg0 := resize(w0_frac * cg0, 24);
                        wg1 := resize(w1_frac * cg1, 24);
                        wg2 := resize(w2_frac * cg2, 24);
                        final_g := resize(shift_right(wg0 + wg1 + wg2, 16), 8);
                        
                        wb0 := resize(w0_frac * cb0, 24);
                        wb1 := resize(w1_frac * cb1, 24);
                        wb2 := resize(w2_frac * cb2, 24);
                        final_b := resize(shift_right(wb0 + wb1 + wb2, 16), 8);
                        
                        wa0 := resize(w0_frac * ca0, 24);
                        wa1 := resize(w1_frac * ca1, 24);
                        wa2 := resize(w2_frac * ca2, 24);
                        final_a := resize(shift_right(wa0 + wa1 + wa2, 16), 8);
                        
                        interp_color <= std_logic_vector(final_r) & 
                                       std_logic_vector(final_g) & 
                                       std_logic_vector(final_b) & 
                                       std_logic_vector(final_a);
                        
                        state <= OUTPUT_FRAG;
                    else
                        state <= NEXT_PIXEL;
                    end if;
                
                when OUTPUT_FRAG =>
                    frag_valid <= '1';
                    frag_x <= std_logic_vector(resize(tile_origin_x + pixel_x, 16));
                    frag_y <= std_logic_vector(resize(tile_origin_y + pixel_y, 16));
                    frag_z <= std_logic_vector(interp_z(23 downto 0));
                    frag_u <= std_logic_vector(interp_u);
                    frag_v <= std_logic_vector(interp_v);
                    frag_color <= interp_color;
                    
                    if frag_ready = '1' then
                        -- Fragment accepted, move to next pixel
                        frag_count <= frag_count + 1;
                        state <= NEXT_PIXEL;
                        -- frag_valid will be cleared in NEXT_PIXEL or PIXEL_TEST
                    end if;
                
                when NEXT_PIXEL =>
                    frag_valid <= '0';  -- Clear fragment valid
                    -- Advance to next pixel
                    if pixel_x = TILE_SIZE - 1 then
                        pixel_x <= (others => '0');
                        
                        if pixel_y = TILE_SIZE - 1 then
                            -- Done with tile
                            state <= DONE;
                        else
                            pixel_y <= pixel_y + 1;
                            
                            -- Update row edge values (step by 1 pixel = 1.0 in fixed-point)
                            -- Widen before shifting to avoid truncation
                            e0_row <= e0_row + shift_left(resize(e0_b, 64), FRAC_BITS);
                            e1_row <= e1_row + shift_left(resize(e1_b, 64), FRAC_BITS);
                            e2_row <= e2_row + shift_left(resize(e2_b, 64), FRAC_BITS);
                            
                            state <= PIXEL_TEST;
                        end if;
                    else
                        pixel_x <= pixel_x + 1;
                        state <= PIXEL_TEST;
                    end if;
                
                when DONE =>
                    frag_valid <= '0';
                    triangle_done <= '1';
                    state <= IDLE;
                    
            end case;
        end if;
    end process;

end architecture rtl;
