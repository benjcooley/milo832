-------------------------------------------------------------------------------
-- viewport_transform.vhd
-- Viewport Transform and Clip Unit
--
-- Transforms vertices from clip space to normalized device coordinates (NDC)
-- and then to screen space. Optionally performs frustum clipping.
--
-- Pipeline stages:
--   1. Perspective divide (x/w, y/w, z/w)
--   2. Viewport transform (NDC to screen)
--
-- Clip space: x,y,z in [-w, +w], homogeneous coordinates
-- NDC: x,y,z in [-1, +1]
-- Screen space: x in [0, width], y in [0, height], z in [0, 1] (depth)
--
-- Milo832 GPU project - Graphics coprocessor for m65832 CPU
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.fixed_pkg.all;

entity viewport_transform is
    generic (
        -- Fixed-point format for screen coordinates
        SCREEN_INT_BITS : integer := 12;    -- Integer bits (max 4096 pixels)
        SCREEN_FRAC_BITS: integer := 4      -- Fractional bits for subpixel
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -----------------------------------------------------------------------
        -- Viewport Configuration (from render state)
        -----------------------------------------------------------------------
        viewport_x      : in  std_logic_vector(15 downto 0);    -- X offset
        viewport_y      : in  std_logic_vector(15 downto 0);    -- Y offset
        viewport_width  : in  std_logic_vector(15 downto 0);    -- Width
        viewport_height : in  std_logic_vector(15 downto 0);    -- Height
        depth_near      : in  std_logic_vector(31 downto 0);    -- Near plane (float)
        depth_far       : in  std_logic_vector(31 downto 0);    -- Far plane (float)
        
        -----------------------------------------------------------------------
        -- Clip Space Vertex Input
        -----------------------------------------------------------------------
        vtx_in_valid    : in  std_logic;
        vtx_in_ready    : out std_logic;
        vtx_in_x        : in  std_logic_vector(31 downto 0);    -- Clip X
        vtx_in_y        : in  std_logic_vector(31 downto 0);    -- Clip Y
        vtx_in_z        : in  std_logic_vector(31 downto 0);    -- Clip Z
        vtx_in_w        : in  std_logic_vector(31 downto 0);    -- Clip W
        vtx_in_u        : in  std_logic_vector(31 downto 0);    -- Texture U
        vtx_in_v        : in  std_logic_vector(31 downto 0);    -- Texture V
        vtx_in_color    : in  std_logic_vector(31 downto 0);    -- Vertex color
        
        -----------------------------------------------------------------------
        -- Screen Space Vertex Output
        -----------------------------------------------------------------------
        vtx_out_valid   : out std_logic;
        vtx_out_ready   : in  std_logic;
        vtx_out_x       : out std_logic_vector(31 downto 0);    -- Screen X (fixed)
        vtx_out_y       : out std_logic_vector(31 downto 0);    -- Screen Y (fixed)
        vtx_out_z       : out std_logic_vector(31 downto 0);    -- Screen Z (depth)
        vtx_out_w       : out std_logic_vector(31 downto 0);    -- 1/W for perspective
        vtx_out_u       : out std_logic_vector(31 downto 0);    -- U/W
        vtx_out_v       : out std_logic_vector(31 downto 0);    -- V/W
        vtx_out_color   : out std_logic_vector(31 downto 0);    -- Color (passed through)
        vtx_out_clipped : out std_logic;                        -- Vertex was clipped
        
        -----------------------------------------------------------------------
        -- Status
        -----------------------------------------------------------------------
        vertices_in     : out std_logic_vector(31 downto 0);
        vertices_out    : out std_logic_vector(31 downto 0);
        vertices_clipped: out std_logic_vector(31 downto 0)
    );
end entity viewport_transform;

architecture rtl of viewport_transform is

    -- Pipeline states
    type state_t is (
        IDLE,
        CALC_RCP_W,
        WAIT_RCP_W,
        CALC_NDC,
        CALC_SCREEN,
        OUTPUT
    );
    signal state : state_t := IDLE;
    
    -- Latched input vertex
    signal clip_x, clip_y, clip_z, clip_w : std_logic_vector(31 downto 0);
    signal tex_u, tex_v : std_logic_vector(31 downto 0);
    signal color : std_logic_vector(31 downto 0);
    
    -- Intermediate results
    signal rcp_w : std_logic_vector(31 downto 0);       -- 1/W
    signal ndc_x, ndc_y, ndc_z : std_logic_vector(31 downto 0);
    signal screen_x, screen_y, screen_z : std_logic_vector(31 downto 0);
    signal pers_u, pers_v : std_logic_vector(31 downto 0);
    
    -- Clipping flags
    signal is_clipped : std_logic;
    
    -- Counters
    signal cnt_in, cnt_out, cnt_clipped : unsigned(31 downto 0) := (others => '0');
    
    -- Helper: check if inside clip volume
    function check_clip(x, y, z, w : std_logic_vector(31 downto 0)) return std_logic is
        variable wx, wy, wz, ww : signed(31 downto 0);
        variable neg_w : signed(31 downto 0);
    begin
        -- Simple W-clipping: reject if W <= 0 (behind camera)
        -- Full frustum clipping would check: -W <= X <= W, -W <= Y <= W, 0 <= Z <= W
        ww := signed(w);
        
        -- Check W > 0 (simplified)
        if ww(31) = '1' or ww = x"00000000" then
            return '1';  -- Clipped (W <= 0)
        end if;
        
        return '0';  -- Not clipped
    end function;
    
    -- Simple float-to-fixed conversion (for demonstration)
    -- Converts IEEE 754 float to fixed-point with specified fractional bits
    function float_to_fixed(f : std_logic_vector(31 downto 0); 
                           int_bits, frac_bits : integer) return signed is
        variable sign : std_logic;
        variable exp : integer;
        variable mant : unsigned(23 downto 0);  -- 24 bits with implied 1
        variable raw_exp : unsigned(7 downto 0);
        variable result : signed(31 downto 0);
        variable shift_amount : integer;
        constant ZERO_RESULT : signed(31 downto 0) := (others => '0');
    begin
        sign := f(31);
        raw_exp := unsigned(f(30 downto 23));
        
        -- Handle special cases
        if raw_exp = 0 then
            return ZERO_RESULT;  -- Zero or denormal
        elsif raw_exp = 255 then
            if sign = '1' then
                return signed'(x"80000000");  -- -Inf -> min
            else
                return signed'(x"7FFFFFFF");  -- +Inf -> max
            end if;
        end if;
        
        -- Build mantissa with implied leading 1
        mant := '1' & unsigned(f(22 downto 0));
        
        -- Calculate exponent (unbiased)
        exp := to_integer(raw_exp) - 127;
        
        -- Calculate total shift to position the fixed point
        -- The mantissa has binary point after bit 23 (implied 1)
        -- We want frac_bits after the binary point in our result
        -- So total shift from mantissa MSB position = exp + frac_bits - 23
        shift_amount := exp + frac_bits - 23;
        
        -- Position the mantissa
        result := ZERO_RESULT;
        if shift_amount >= 0 then
            if shift_amount < 32 then
                result := signed(resize(shift_left(mant, shift_amount), 32));
            else
                -- Overflow - saturate
                result := signed'(x"7FFFFFFF");
            end if;
        else
            -- Right shift (value < 1)
            if shift_amount > -24 then
                result := signed(resize(shift_right(mant, -shift_amount), 32));
            end if;
            -- else: value too small, result stays 0
        end if;
        
        if sign = '1' then
            result := -result;
        end if;
        
        return result;
    end function;

begin

    vertices_in <= std_logic_vector(cnt_in);
    vertices_out <= std_logic_vector(cnt_out);
    vertices_clipped <= std_logic_vector(cnt_clipped);
    
    vtx_in_ready <= '1' when state = IDLE else '0';
    
    -- Main process
    process(clk, rst_n)
        variable vp_x, vp_y, vp_w, vp_h : integer;
        variable half_w, half_h : integer;
        variable sx, sy : signed(31 downto 0);
    begin
        if rst_n = '0' then
            state <= IDLE;
            vtx_out_valid <= '0';
            clip_x <= (others => '0');
            clip_y <= (others => '0');
            clip_z <= (others => '0');
            clip_w <= (others => '0');
            tex_u <= (others => '0');
            tex_v <= (others => '0');
            color <= (others => '0');
            rcp_w <= (others => '0');
            ndc_x <= (others => '0');
            ndc_y <= (others => '0');
            ndc_z <= (others => '0');
            screen_x <= (others => '0');
            screen_y <= (others => '0');
            screen_z <= (others => '0');
            pers_u <= (others => '0');
            pers_v <= (others => '0');
            is_clipped <= '0';
            cnt_in <= (others => '0');
            cnt_out <= (others => '0');
            cnt_clipped <= (others => '0');
            
        elsif rising_edge(clk) then
            case state is
                when IDLE =>
                    vtx_out_valid <= '0';
                    
                    if vtx_in_valid = '1' then
                        -- Latch input
                        clip_x <= vtx_in_x;
                        clip_y <= vtx_in_y;
                        clip_z <= vtx_in_z;
                        clip_w <= vtx_in_w;
                        tex_u <= vtx_in_u;
                        tex_v <= vtx_in_v;
                        color <= vtx_in_color;
                        cnt_in <= cnt_in + 1;
                        
                        -- Check clipping
                        is_clipped <= check_clip(vtx_in_x, vtx_in_y, vtx_in_z, vtx_in_w);
                        
                        state <= CALC_NDC;
                    end if;
                
                -- Simplified: compute NDC directly (assumes W = 1 or pre-divided)
                -- Real implementation would do perspective divide
                when CALC_NDC =>
                    -- For now, pass through as if already in NDC
                    -- NDC range [-1, 1] -> need proper division
                    ndc_x <= clip_x;
                    ndc_y <= clip_y;
                    ndc_z <= clip_z;
                    rcp_w <= clip_w;  -- Pass W for perspective correction
                    pers_u <= tex_u;
                    pers_v <= tex_v;
                    state <= CALC_SCREEN;
                
                when CALC_SCREEN =>
                    -- Viewport transform: NDC -> Screen
                    -- screen_x = (ndc_x + 1) * width/2 + viewport_x
                    -- screen_y = (ndc_y + 1) * height/2 + viewport_y
                    -- screen_z = (ndc_z + 1) * (far - near)/2 + near
                    
                    vp_x := to_integer(unsigned(viewport_x));
                    vp_y := to_integer(unsigned(viewport_y));
                    vp_w := to_integer(unsigned(viewport_width));
                    vp_h := to_integer(unsigned(viewport_height));
                    half_w := vp_w / 2;
                    half_h := vp_h / 2;
                    
                    -- Convert NDC to screen (simplified integer math)
                    -- Assumes NDC is already in usable fixed-point format
                    sx := float_to_fixed(ndc_x, SCREEN_INT_BITS, SCREEN_FRAC_BITS);
                    sy := float_to_fixed(ndc_y, SCREEN_INT_BITS, SCREEN_FRAC_BITS);
                    
                    -- Scale by half viewport and offset by center
                    -- Use resize to handle multiplication width expansion
                    sx := resize(shift_right(sx * to_signed(half_w, 32), SCREEN_FRAC_BITS), 32) + 
                          to_signed((vp_x + half_w) * (2**SCREEN_FRAC_BITS), 32);
                    sy := resize(shift_right(sy * to_signed(half_h, 32), SCREEN_FRAC_BITS), 32) + 
                          to_signed((vp_y + half_h) * (2**SCREEN_FRAC_BITS), 32);
                    
                    screen_x <= std_logic_vector(sx);
                    screen_y <= std_logic_vector(sy);
                    screen_z <= ndc_z;  -- Pass through for depth
                    
                    state <= OUTPUT;
                
                when OUTPUT =>
                    vtx_out_valid <= '1';
                    vtx_out_x <= screen_x;
                    vtx_out_y <= screen_y;
                    vtx_out_z <= screen_z;
                    vtx_out_w <= rcp_w;
                    vtx_out_u <= pers_u;
                    vtx_out_v <= pers_v;
                    vtx_out_color <= color;
                    vtx_out_clipped <= is_clipped;
                    
                    if vtx_out_ready = '1' then
                        -- Don't clear valid here - let next state do it
                        cnt_out <= cnt_out + 1;
                        if is_clipped = '1' then
                            cnt_clipped <= cnt_clipped + 1;
                        end if;
                        state <= IDLE;
                    end if;
                
                when others =>
                    state <= IDLE;
            end case;
        end if;
    end process;

end architecture rtl;
