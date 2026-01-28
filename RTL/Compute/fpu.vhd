-------------------------------------------------------------------------------
-- fpu.vhd
-- IEEE-754 Single Precision Floating Point Unit
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

library work;
use work.simt_pkg.all;

entity fpu is
    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;
        
        -- Input
        valid_in    : in  std_logic;
        op          : in  opcode_t;
        a           : in  std_logic_vector(31 downto 0);  -- IEEE-754 operand A
        b           : in  std_logic_vector(31 downto 0);  -- IEEE-754 operand B
        c           : in  std_logic_vector(31 downto 0);  -- IEEE-754 operand C (for FMA)
        
        -- Output
        valid_out   : out std_logic;
        result      : out std_logic_vector(31 downto 0);  -- IEEE-754 result
        
        -- Exception flags
        overflow    : out std_logic;
        underflow   : out std_logic;
        inexact     : out std_logic;
        invalid     : out std_logic;
        div_zero    : out std_logic
    );
end entity fpu;

architecture rtl of fpu is

    -- IEEE-754 single precision format
    -- [31]    Sign (1 bit)
    -- [30:23] Exponent (8 bits, bias 127)
    -- [22:0]  Mantissa (23 bits, implicit leading 1)
    
    constant EXP_BIAS   : integer := 127;
    constant EXP_WIDTH  : integer := 8;
    constant MANT_WIDTH : integer := 23;
    
    -- Internal decoded format
    type float_t is record
        sign     : std_logic;
        exp      : signed(9 downto 0);  -- Extended for intermediate calculations
        mant     : unsigned(24 downto 0);  -- With implicit bit and guard bit
        is_zero  : std_logic;
        is_inf   : std_logic;
        is_nan   : std_logic;
    end record;
    
    -- Pipeline registers
    signal valid_p1, valid_p2, valid_p3, valid_p4 : std_logic;
    signal op_p1, op_p2, op_p3, op_p4 : opcode_t;
    
    -- Decoded operands
    signal a_dec, b_dec, c_dec : float_t;
    signal a_dec_p1, b_dec_p1, c_dec_p1 : float_t;
    
    -- Intermediate results
    signal add_result : std_logic_vector(31 downto 0);
    signal mul_result : std_logic_vector(31 downto 0);
    signal div_result : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Helper function: Decode IEEE-754 to internal format
    ---------------------------------------------------------------------------
    function decode_float(f : std_logic_vector(31 downto 0)) return float_t is
        variable result : float_t;
        variable exp_bits : unsigned(7 downto 0);
        variable mant_bits : unsigned(22 downto 0);
    begin
        result.sign := f(31);
        exp_bits := unsigned(f(30 downto 23));
        mant_bits := unsigned(f(22 downto 0));
        
        if exp_bits = 0 then
            if mant_bits = 0 then
                -- Zero
                result.is_zero := '1';
                result.is_inf := '0';
                result.is_nan := '0';
                result.exp := to_signed(-126, 10);
                result.mant := (others => '0');
            else
                -- Denormal
                result.is_zero := '0';
                result.is_inf := '0';
                result.is_nan := '0';
                result.exp := to_signed(-126, 10);
                result.mant := '0' & '0' & mant_bits;
            end if;
        elsif exp_bits = 255 then
            if mant_bits = 0 then
                -- Infinity
                result.is_zero := '0';
                result.is_inf := '1';
                result.is_nan := '0';
            else
                -- NaN
                result.is_zero := '0';
                result.is_inf := '0';
                result.is_nan := '1';
            end if;
            result.exp := to_signed(128, 10);
            result.mant := '0' & '1' & mant_bits;
        else
            -- Normal
            result.is_zero := '0';
            result.is_inf := '0';
            result.is_nan := '0';
            result.exp := to_signed(to_integer(exp_bits) - EXP_BIAS, 10);
            result.mant := '0' & '1' & mant_bits;  -- Implicit leading 1
        end if;
        
        return result;
    end function;
    
    ---------------------------------------------------------------------------
    -- Helper function: Encode internal format to IEEE-754
    ---------------------------------------------------------------------------
    function encode_float(sign : std_logic; exp : signed(9 downto 0); mant : unsigned(24 downto 0)) return std_logic_vector is
        variable result : std_logic_vector(31 downto 0);
        variable exp_biased : integer;
        variable final_mant : unsigned(22 downto 0);
    begin
        exp_biased := to_integer(exp) + EXP_BIAS;
        
        if exp_biased <= 0 then
            -- Denormal or zero
            result := sign & x"00" & std_logic_vector(mant(22 downto 0));
        elsif exp_biased >= 255 then
            -- Overflow to infinity
            result := sign & x"FF" & "00000000000000000000000";
        else
            -- Normal number
            final_mant := mant(22 downto 0);
            result := sign & std_logic_vector(to_unsigned(exp_biased, 8)) & std_logic_vector(final_mant);
        end if;
        
        return result;
    end function;

begin

    ---------------------------------------------------------------------------
    -- Pipeline Stage 1: Decode operands
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            valid_p1 <= '0';
            op_p1 <= OP_NOP;
            
        elsif rising_edge(clk) then
            valid_p1 <= valid_in;
            op_p1 <= op;
            a_dec_p1 <= decode_float(a);
            b_dec_p1 <= decode_float(b);
            c_dec_p1 <= decode_float(c);
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Pipeline Stage 2-3: Execute operation
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable a_mant_ext, b_mant_ext : unsigned(47 downto 0);
        variable mul_prod : unsigned(49 downto 0);
        variable mul_exp : signed(9 downto 0);
        variable add_exp_diff : signed(9 downto 0);
        variable add_mant_a, add_mant_b : unsigned(26 downto 0);
        variable add_result_mant : unsigned(27 downto 0);
        variable result_sign : std_logic;
        variable result_exp : signed(9 downto 0);
        variable result_mant : unsigned(24 downto 0);
        variable int_abs : unsigned(31 downto 0);  -- For ITOF conversion
        variable lead_pos : integer;
    begin
        if rst_n = '0' then
            valid_p2 <= '0';
            valid_p3 <= '0';
            op_p2 <= OP_NOP;
            op_p3 <= OP_NOP;
            add_result <= (others => '0');
            mul_result <= (others => '0');
            div_result <= (others => '0');
            
        elsif rising_edge(clk) then
            valid_p2 <= valid_p1;
            valid_p3 <= valid_p2;
            op_p2 <= op_p1;
            op_p3 <= op_p2;
            
            -- Floating point operations
            case op_p1 is
                when OP_FADD | OP_FSUB =>
                    -- Addition/Subtraction
                    -- Align exponents
                    if a_dec_p1.exp >= b_dec_p1.exp then
                        add_exp_diff := a_dec_p1.exp - b_dec_p1.exp;
                        add_mant_a := resize(a_dec_p1.mant, 27);
                        add_mant_b := shift_right(resize(b_dec_p1.mant, 27), to_integer(add_exp_diff));
                        result_exp := a_dec_p1.exp;
                    else
                        add_exp_diff := b_dec_p1.exp - a_dec_p1.exp;
                        add_mant_a := shift_right(resize(a_dec_p1.mant, 27), to_integer(add_exp_diff));
                        add_mant_b := resize(b_dec_p1.mant, 27);
                        result_exp := b_dec_p1.exp;
                    end if;
                    
                    -- Add or subtract based on signs and operation
                    if (a_dec_p1.sign = b_dec_p1.sign and op_p1 = OP_FADD) or
                       (a_dec_p1.sign /= b_dec_p1.sign and op_p1 = OP_FSUB) then
                        add_result_mant := resize(add_mant_a, 28) + resize(add_mant_b, 28);
                        result_sign := a_dec_p1.sign;
                    else
                        if add_mant_a >= add_mant_b then
                            add_result_mant := resize(add_mant_a - add_mant_b, 28);
                            result_sign := a_dec_p1.sign;
                        else
                            add_result_mant := resize(add_mant_b - add_mant_a, 28);
                            if op_p1 = OP_FADD then
                                result_sign := b_dec_p1.sign;
                            else
                                result_sign := not b_dec_p1.sign;
                            end if;
                        end if;
                    end if;
                    
                    -- Normalize result
                    result_mant := add_result_mant(25 downto 1);
                    add_result <= encode_float(result_sign, result_exp, result_mant);
                    
                when OP_FMUL =>
                    -- Multiplication
                    a_mant_ext := resize(a_dec_p1.mant, 48);
                    b_mant_ext := resize(b_dec_p1.mant, 48);
                    mul_prod := resize(a_mant_ext * b_mant_ext, 50);
                    mul_exp := a_dec_p1.exp + b_dec_p1.exp;
                    result_sign := a_dec_p1.sign xor b_dec_p1.sign;
                    
                    -- Normalize
                    if mul_prod(49) = '1' then
                        result_mant := mul_prod(48 downto 24);
                        mul_exp := mul_exp + 1;
                    else
                        result_mant := mul_prod(47 downto 23);
                    end if;
                    
                    mul_result <= encode_float(result_sign, mul_exp, result_mant);
                    
                when OP_FDIV =>
                    -- Division (simplified - iterative refinement would be better)
                    result_sign := a_dec_p1.sign xor b_dec_p1.sign;
                    result_exp := a_dec_p1.exp - b_dec_p1.exp;
                    
                    -- Simple division approximation
                    if b_dec_p1.is_zero = '1' then
                        -- Division by zero -> infinity
                        div_result <= result_sign & x"7F800000";
                    elsif a_dec_p1.is_zero = '1' then
                        -- Zero / x = zero
                        div_result <= result_sign & x"00000000";
                    else
                        -- Approximate result
                        result_mant := resize(shift_left(a_dec_p1.mant, 23) / b_dec_p1.mant, 25);
                        div_result <= encode_float(result_sign, result_exp, result_mant);
                    end if;
                    
                when OP_FABS =>
                    -- Absolute value (clear sign bit)
                    add_result <= '0' & a(30 downto 0);
                    
                when OP_FNEG =>
                    -- Negate (flip sign bit)
                    add_result <= (not a(31)) & a(30 downto 0);
                    
                when OP_FMIN =>
                    -- Minimum
                    if a_dec_p1.sign = '1' and b_dec_p1.sign = '0' then
                        add_result <= a;  -- a is negative
                    elsif a_dec_p1.sign = '0' and b_dec_p1.sign = '1' then
                        add_result <= b;  -- b is negative
                    elsif a_dec_p1.exp < b_dec_p1.exp then
                        if a_dec_p1.sign = '0' then
                            add_result <= a;
                        else
                            add_result <= b;
                        end if;
                    else
                        if a_dec_p1.sign = '0' then
                            add_result <= b;
                        else
                            add_result <= a;
                        end if;
                    end if;
                    
                when OP_FMAX =>
                    -- Maximum
                    if a_dec_p1.sign = '0' and b_dec_p1.sign = '1' then
                        add_result <= a;  -- a is positive
                    elsif a_dec_p1.sign = '1' and b_dec_p1.sign = '0' then
                        add_result <= b;  -- b is positive
                    elsif a_dec_p1.exp > b_dec_p1.exp then
                        if a_dec_p1.sign = '0' then
                            add_result <= a;
                        else
                            add_result <= b;
                        end if;
                    else
                        if a_dec_p1.sign = '0' then
                            add_result <= b;
                        else
                            add_result <= a;
                        end if;
                    end if;
                    
                when OP_FTOI =>
                    -- Float to integer conversion
                    if a_dec_p1.is_zero = '1' then
                        add_result <= (others => '0');
                    elsif a_dec_p1.exp < 0 then
                        add_result <= (others => '0');  -- Less than 1
                    elsif a_dec_p1.exp > 30 then
                        -- Overflow
                        if a_dec_p1.sign = '1' then
                            add_result <= x"80000000";  -- Min int
                        else
                            add_result <= x"7FFFFFFF";  -- Max int
                        end if;
                    else
                        result_mant := shift_right(a_dec_p1.mant, 23 - to_integer(a_dec_p1.exp));
                        if a_dec_p1.sign = '1' then
                            add_result <= std_logic_vector(-signed(resize(result_mant, 32)));
                        else
                            add_result <= std_logic_vector(resize(result_mant, 32));
                        end if;
                    end if;
                    
                when OP_ITOF =>
                    -- Integer to float conversion
                    if signed(a) = 0 then
                        add_result <= (others => '0');
                    else
                        if a(31) = '1' then
                            result_sign := '1';
                            int_abs := unsigned(-signed(a));
                        else
                            result_sign := '0';
                            int_abs := unsigned(a);
                        end if;
                        
                        -- Find leading one position
                        lead_pos := 0;
                        for i in 31 downto 0 loop
                            if int_abs(i) = '1' then
                                lead_pos := i;
                                exit;
                            end if;
                        end loop;
                        result_exp := to_signed(lead_pos, 10);
                        
                        -- Normalize: shift mantissa so leading 1 is at bit 23
                        if lead_pos >= 23 then
                            result_mant := resize(shift_right(int_abs, lead_pos - 23), 25);
                        else
                            result_mant := resize(shift_left(int_abs, 23 - lead_pos), 25);
                        end if;
                        
                        add_result <= encode_float(result_sign, result_exp, result_mant);
                    end if;
                    
                when others =>
                    add_result <= (others => '0');
                    mul_result <= (others => '0');
                    div_result <= (others => '0');
            end case;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Pipeline Stage 4: Output result
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            valid_p4 <= '0';
            valid_out <= '0';
            result <= (others => '0');
            overflow <= '0';
            underflow <= '0';
            inexact <= '0';
            invalid <= '0';
            div_zero <= '0';
            
        elsif rising_edge(clk) then
            valid_p4 <= valid_p3;
            valid_out <= valid_p4;
            
            -- Select result based on operation
            case op_p3 is
                when OP_FMUL | OP_FFMA =>
                    result <= mul_result;
                when OP_FDIV =>
                    result <= div_result;
                when others =>
                    result <= add_result;
            end case;
            
            -- Exception flags (simplified)
            overflow <= '0';
            underflow <= '0';
            inexact <= '0';
            invalid <= '0';
            div_zero <= '0';
        end if;
    end process;

end architecture rtl;
