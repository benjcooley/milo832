-------------------------------------------------------------------------------
-- sfu_pkg.vhd
-- Special Function Unit Package - Types and Constants
--
-- VHDL translation of SIMT-GPU-Core by Aritra Manna
-- Original SystemVerilog: https://github.com/aritramanna/SIMT-GPU-Core
--
-- Many thanks to Aritra Manna for creating and open-sourcing the excellent
-- SIMT-GPU-Core project. This file is a VHDL translation of the original
-- SystemVerilog implementation.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

package sfu_pkg is

    ---------------------------------------------------------------------------
    -- Fixed Point Format: 1.15 (1 sign bit, 15 fractional bits)
    -- Range: -1.0 to +0.999969... (approximately +1.0)
    ---------------------------------------------------------------------------
    constant FIXED_POINT_BITS   : integer := 16;
    constant FIXED_FRAC_BITS    : integer := 15;
    
    -- Table size for lookup tables
    constant TABLE_SIZE         : integer := 256;
    constant TABLE_ADDR_BITS    : integer := 8;
    
    ---------------------------------------------------------------------------
    -- Lookup Table Types
    ---------------------------------------------------------------------------
    type sfu_table_t is array (0 to TABLE_SIZE-1) of std_logic_vector(15 downto 0);
    
    ---------------------------------------------------------------------------
    -- Conversion Functions
    ---------------------------------------------------------------------------
    
    -- Convert real to 1.15 fixed point
    function real_to_fixed(val : real) return std_logic_vector;
    
    -- Convert 1.15 fixed point to real
    function fixed_to_real(val : std_logic_vector(15 downto 0)) return real;
    
    -- Convert IEEE-754 float to fixed point for SFU input
    function float_to_fixed_input(val : std_logic_vector(31 downto 0)) return std_logic_vector;
    
    -- Convert fixed point result to IEEE-754 float
    function fixed_to_float_output(val : std_logic_vector(15 downto 0)) return std_logic_vector;
    
    ---------------------------------------------------------------------------
    -- SFU Operation Select
    ---------------------------------------------------------------------------
    type sfu_op_t is (
        SFU_SIN,    -- Sine
        SFU_COS,    -- Cosine
        SFU_EX2,    -- 2^x
        SFU_LG2,    -- log2(x)
        SFU_RCP,    -- 1/x
        SFU_RSQ,    -- 1/sqrt(x)
        SFU_SQRT,   -- sqrt(x)
        SFU_TANH    -- tanh(x)
    );

end package sfu_pkg;

package body sfu_pkg is

    ---------------------------------------------------------------------------
    -- real_to_fixed: Convert real number to 1.15 fixed point
    ---------------------------------------------------------------------------
    function real_to_fixed(val : real) return std_logic_vector is
        variable clamped : real;
        variable scaled : integer;
    begin
        -- Clamp to valid range [-1.0, +1.0)
        if val >= 1.0 then
            clamped := 0.999969482421875;  -- Max positive value
        elsif val < -1.0 then
            clamped := -1.0;
        else
            clamped := val;
        end if;
        
        -- Scale by 2^15 and convert to integer
        scaled := integer(clamped * 32768.0);
        
        return std_logic_vector(to_signed(scaled, 16));
    end function;
    
    ---------------------------------------------------------------------------
    -- fixed_to_real: Convert 1.15 fixed point to real
    ---------------------------------------------------------------------------
    function fixed_to_real(val : std_logic_vector(15 downto 0)) return real is
    begin
        return real(to_integer(signed(val))) / 32768.0;
    end function;
    
    ---------------------------------------------------------------------------
    -- float_to_fixed_input: Extract mantissa for SFU table lookup
    -- For SIN/COS: input is in radians, need to extract fractional part
    -- For other ops: extract mantissa bits
    ---------------------------------------------------------------------------
    function float_to_fixed_input(val : std_logic_vector(31 downto 0)) return std_logic_vector is
        variable sign     : std_logic;
        variable exponent : unsigned(7 downto 0);
        variable mantissa : unsigned(22 downto 0);
        variable result   : std_logic_vector(15 downto 0);
    begin
        sign     := val(31);
        exponent := unsigned(val(30 downto 23));
        mantissa := unsigned(val(22 downto 0));
        
        -- Simple extraction: take top 15 bits of mantissa with implicit 1
        -- This is a simplified version - full implementation needs proper
        -- range reduction for transcendental functions
        if exponent = 0 then
            -- Denormal or zero
            result := (others => '0');
        else
            -- Normalized: extract bits with sign
            result := sign & std_logic_vector(mantissa(22 downto 8));
        end if;
        
        return result;
    end function;
    
    ---------------------------------------------------------------------------
    -- fixed_to_float_output: Convert 1.15 fixed point result to IEEE-754
    ---------------------------------------------------------------------------
    function fixed_to_float_output(val : std_logic_vector(15 downto 0)) return std_logic_vector is
        variable sign     : std_logic;
        variable abs_val  : unsigned(14 downto 0);
        variable exponent : unsigned(7 downto 0);
        variable mantissa : unsigned(22 downto 0);
        variable result   : std_logic_vector(31 downto 0);
        variable shift    : integer;
    begin
        sign := val(15);
        
        if signed(val) < 0 then
            abs_val := unsigned(-signed('0' & val(14 downto 0)));
        else
            abs_val := unsigned(val(14 downto 0));
        end if;
        
        -- Find leading one position
        shift := 0;
        for i in 14 downto 0 loop
            if abs_val(i) = '1' then
                shift := 14 - i;
                exit;
            end if;
        end loop;
        
        if abs_val = 0 then
            -- Zero
            result := (others => '0');
        else
            -- Exponent: bias 127, -1 for fixed point position
            exponent := to_unsigned(127 - 1 - shift, 8);
            
            -- Shift mantissa to normalize
            mantissa := resize(shift_left(abs_val, shift + 9), 23);
            
            result := sign & std_logic_vector(exponent) & std_logic_vector(mantissa);
        end if;
        
        return result;
    end function;

end package body sfu_pkg;
