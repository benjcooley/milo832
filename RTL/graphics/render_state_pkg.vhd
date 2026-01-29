-------------------------------------------------------------------------------
-- render_state_pkg.vhd
-- Render State Package for Milo832 GPU
-- Defines configurable pipeline states: depth test, culling, blending
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package render_state_pkg is

    ---------------------------------------------------------------------------
    -- Depth Test Functions
    ---------------------------------------------------------------------------
    subtype depth_func_t is std_logic_vector(2 downto 0);
    
    constant DEPTH_NEVER    : depth_func_t := "000";
    constant DEPTH_LESS     : depth_func_t := "001";
    constant DEPTH_EQUAL    : depth_func_t := "010";
    constant DEPTH_LEQUAL   : depth_func_t := "011";
    constant DEPTH_GREATER  : depth_func_t := "100";
    constant DEPTH_NOTEQUAL : depth_func_t := "101";
    constant DEPTH_GEQUAL   : depth_func_t := "110";
    constant DEPTH_ALWAYS   : depth_func_t := "111";
    
    ---------------------------------------------------------------------------
    -- Cull Mode
    ---------------------------------------------------------------------------
    subtype cull_mode_t is std_logic_vector(1 downto 0);
    
    constant CULL_NONE      : cull_mode_t := "00";  -- No culling
    constant CULL_FRONT     : cull_mode_t := "01";  -- Cull front faces
    constant CULL_BACK      : cull_mode_t := "10";  -- Cull back faces
    constant CULL_BOTH      : cull_mode_t := "11";  -- Cull all (useful for stencil-only)
    
    ---------------------------------------------------------------------------
    -- Front Face Winding Order
    ---------------------------------------------------------------------------
    subtype winding_t is std_logic;
    
    constant WINDING_CCW    : winding_t := '0';     -- Counter-clockwise = front
    constant WINDING_CW     : winding_t := '1';     -- Clockwise = front
    
    ---------------------------------------------------------------------------
    -- Blend Factors
    ---------------------------------------------------------------------------
    subtype blend_factor_t is std_logic_vector(3 downto 0);
    
    constant BLEND_ZERO          : blend_factor_t := "0000";
    constant BLEND_ONE           : blend_factor_t := "0001";
    constant BLEND_SRC_COLOR     : blend_factor_t := "0010";
    constant BLEND_INV_SRC_COLOR : blend_factor_t := "0011";
    constant BLEND_DST_COLOR     : blend_factor_t := "0100";
    constant BLEND_INV_DST_COLOR : blend_factor_t := "0101";
    constant BLEND_SRC_ALPHA     : blend_factor_t := "0110";
    constant BLEND_INV_SRC_ALPHA : blend_factor_t := "0111";
    constant BLEND_DST_ALPHA     : blend_factor_t := "1000";
    constant BLEND_INV_DST_ALPHA : blend_factor_t := "1001";
    constant BLEND_CONST_COLOR   : blend_factor_t := "1010";
    constant BLEND_INV_CONST_COLOR : blend_factor_t := "1011";
    constant BLEND_CONST_ALPHA   : blend_factor_t := "1100";
    constant BLEND_INV_CONST_ALPHA : blend_factor_t := "1101";
    constant BLEND_SRC_ALPHA_SAT : blend_factor_t := "1110";  -- min(src_alpha, 1-dst_alpha)
    
    ---------------------------------------------------------------------------
    -- Blend Equations
    ---------------------------------------------------------------------------
    subtype blend_eq_t is std_logic_vector(2 downto 0);
    
    constant BLEND_EQ_ADD       : blend_eq_t := "000";  -- src*sf + dst*df
    constant BLEND_EQ_SUB       : blend_eq_t := "001";  -- src*sf - dst*df
    constant BLEND_EQ_REV_SUB   : blend_eq_t := "010";  -- dst*df - src*sf
    constant BLEND_EQ_MIN       : blend_eq_t := "011";  -- min(src, dst)
    constant BLEND_EQ_MAX       : blend_eq_t := "100";  -- max(src, dst)
    
    ---------------------------------------------------------------------------
    -- Render State Record - all state in one place
    ---------------------------------------------------------------------------
    type render_state_t is record
        -- Depth state
        depth_test_en   : std_logic;
        depth_write_en  : std_logic;
        depth_func      : depth_func_t;
        depth_clear     : std_logic_vector(23 downto 0);  -- Clear value
        
        -- Cull state
        cull_mode       : cull_mode_t;
        front_face      : winding_t;
        
        -- Blend state (RGB)
        blend_en        : std_logic;
        blend_src_rgb   : blend_factor_t;
        blend_dst_rgb   : blend_factor_t;
        blend_eq_rgb    : blend_eq_t;
        
        -- Blend state (Alpha - can be separate)
        blend_src_a     : blend_factor_t;
        blend_dst_a     : blend_factor_t;
        blend_eq_a      : blend_eq_t;
        
        -- Blend constant color (for CONST_COLOR/CONST_ALPHA factors)
        blend_color     : std_logic_vector(31 downto 0);
        
        -- Color write mask (per channel)
        color_mask      : std_logic_vector(3 downto 0);  -- RGBA
        
        -- Color clear value
        color_clear     : std_logic_vector(31 downto 0);
    end record;
    
    ---------------------------------------------------------------------------
    -- Default render state (typical 3D rendering settings)
    ---------------------------------------------------------------------------
    constant RENDER_STATE_DEFAULT : render_state_t := (
        -- Depth: enabled, less-than test
        depth_test_en   => '1',
        depth_write_en  => '1',
        depth_func      => DEPTH_LESS,
        depth_clear     => x"FFFFFF",  -- Far plane
        
        -- Cull: back-face culling, CCW front
        cull_mode       => CULL_BACK,
        front_face      => WINDING_CCW,
        
        -- Blend: disabled
        blend_en        => '0',
        blend_src_rgb   => BLEND_ONE,
        blend_dst_rgb   => BLEND_ZERO,
        blend_eq_rgb    => BLEND_EQ_ADD,
        blend_src_a     => BLEND_ONE,
        blend_dst_a     => BLEND_ZERO,
        blend_eq_a      => BLEND_EQ_ADD,
        blend_color     => x"00000000",
        
        -- Write all channels
        color_mask      => "1111",
        color_clear     => x"00000000"
    );
    
    ---------------------------------------------------------------------------
    -- Preset: Alpha blending (typical transparency)
    ---------------------------------------------------------------------------
    constant RENDER_STATE_ALPHA_BLEND : render_state_t := (
        depth_test_en   => '1',
        depth_write_en  => '0',   -- Usually no depth write for transparent
        depth_func      => DEPTH_LESS,
        depth_clear     => x"FFFFFF",
        cull_mode       => CULL_BACK,
        front_face      => WINDING_CCW,
        blend_en        => '1',
        blend_src_rgb   => BLEND_SRC_ALPHA,
        blend_dst_rgb   => BLEND_INV_SRC_ALPHA,
        blend_eq_rgb    => BLEND_EQ_ADD,
        blend_src_a     => BLEND_ONE,
        blend_dst_a     => BLEND_INV_SRC_ALPHA,
        blend_eq_a      => BLEND_EQ_ADD,
        blend_color     => x"00000000",
        color_mask      => "1111",
        color_clear     => x"00000000"
    );
    
    ---------------------------------------------------------------------------
    -- Preset: Additive blending (particles, glows)
    ---------------------------------------------------------------------------
    constant RENDER_STATE_ADDITIVE : render_state_t := (
        depth_test_en   => '1',
        depth_write_en  => '0',
        depth_func      => DEPTH_LESS,
        depth_clear     => x"FFFFFF",
        cull_mode       => CULL_NONE,
        front_face      => WINDING_CCW,
        blend_en        => '1',
        blend_src_rgb   => BLEND_SRC_ALPHA,
        blend_dst_rgb   => BLEND_ONE,
        blend_eq_rgb    => BLEND_EQ_ADD,
        blend_src_a     => BLEND_ZERO,
        blend_dst_a     => BLEND_ONE,
        blend_eq_a      => BLEND_EQ_ADD,
        blend_color     => x"00000000",
        color_mask      => "1111",
        color_clear     => x"00000000"
    );
    
    ---------------------------------------------------------------------------
    -- Preset: 2D/UI (no depth, no culling)
    ---------------------------------------------------------------------------
    constant RENDER_STATE_2D : render_state_t := (
        depth_test_en   => '0',
        depth_write_en  => '0',
        depth_func      => DEPTH_ALWAYS,
        depth_clear     => x"FFFFFF",
        cull_mode       => CULL_NONE,
        front_face      => WINDING_CCW,
        blend_en        => '1',
        blend_src_rgb   => BLEND_SRC_ALPHA,
        blend_dst_rgb   => BLEND_INV_SRC_ALPHA,
        blend_eq_rgb    => BLEND_EQ_ADD,
        blend_src_a     => BLEND_ONE,
        blend_dst_a     => BLEND_INV_SRC_ALPHA,
        blend_eq_a      => BLEND_EQ_ADD,
        blend_color     => x"00000000",
        color_mask      => "1111",
        color_clear     => x"00000000"
    );
    
    ---------------------------------------------------------------------------
    -- Helper function: Should this triangle be culled?
    -- sign_area: positive for CCW, negative for CW (cross product Z)
    ---------------------------------------------------------------------------
    function should_cull(
        sign_area   : std_logic;  -- '0' = positive (CCW), '1' = negative (CW)
        cull_mode   : cull_mode_t;
        front_face  : winding_t
    ) return boolean;
    
    ---------------------------------------------------------------------------
    -- Helper function: Depth comparison
    ---------------------------------------------------------------------------
    function depth_test_pass(
        frag_z  : unsigned(23 downto 0);
        buf_z   : unsigned(23 downto 0);
        func    : depth_func_t
    ) return boolean;

end package render_state_pkg;

package body render_state_pkg is

    ---------------------------------------------------------------------------
    -- should_cull implementation
    ---------------------------------------------------------------------------
    function should_cull(
        sign_area   : std_logic;
        cull_mode   : cull_mode_t;
        front_face  : winding_t
    ) return boolean is
        variable is_front : boolean;
    begin
        -- Determine if this is a front face
        -- sign_area='0' means positive area (CCW in screen space)
        -- sign_area='1' means negative area (CW in screen space)
        if front_face = WINDING_CCW then
            is_front := (sign_area = '0');  -- CCW = front
        else
            is_front := (sign_area = '1');  -- CW = front
        end if;
        
        -- Apply cull mode
        case cull_mode is
            when CULL_NONE  => return false;
            when CULL_FRONT => return is_front;
            when CULL_BACK  => return not is_front;
            when CULL_BOTH  => return true;
            when others     => return false;
        end case;
    end function;
    
    ---------------------------------------------------------------------------
    -- depth_test_pass implementation
    ---------------------------------------------------------------------------
    function depth_test_pass(
        frag_z  : unsigned(23 downto 0);
        buf_z   : unsigned(23 downto 0);
        func    : depth_func_t
    ) return boolean is
    begin
        case func is
            when DEPTH_NEVER    => return false;
            when DEPTH_LESS     => return frag_z < buf_z;
            when DEPTH_EQUAL    => return frag_z = buf_z;
            when DEPTH_LEQUAL   => return frag_z <= buf_z;
            when DEPTH_GREATER  => return frag_z > buf_z;
            when DEPTH_NOTEQUAL => return frag_z /= buf_z;
            when DEPTH_GEQUAL   => return frag_z >= buf_z;
            when DEPTH_ALWAYS   => return true;
            when others         => return true;
        end case;
    end function;

end package body render_state_pkg;
