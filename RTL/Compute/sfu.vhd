-------------------------------------------------------------------------------
-- sfu.vhd
-- Special Function Unit - Transcendental Math Operations
-- Uses table lookup with linear interpolation
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

library work;
use work.simt_pkg.all;
use work.sfu_pkg.all;

entity sfu is
    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;
        
        -- Input
        valid_in    : in  std_logic;
        op          : in  sfu_op_t;
        operand     : in  std_logic_vector(31 downto 0);  -- IEEE-754 float
        
        -- Output
        valid_out   : out std_logic;
        result      : out std_logic_vector(31 downto 0)   -- IEEE-754 float
    );
end entity sfu;

architecture rtl of sfu is

    ---------------------------------------------------------------------------
    -- Lookup Tables (256 entries each, 16-bit 1.15 fixed point)
    -- Initialized with pre-computed values
    ---------------------------------------------------------------------------
    
    -- Sine table: sin(x * pi/2) for x in [0, 1]
    type table_t is array (0 to 255) of signed(15 downto 0);
    
    -- Initialize sine table
    function init_sine_table return table_t is
        variable tbl : table_t;
        variable angle : real;
        variable val : real;
    begin
        for i in 0 to 255 loop
            angle := real(i) / 256.0 * MATH_PI / 2.0;
            val := sin(angle);
            tbl(i) := to_signed(integer(val * 32767.0), 16);
        end loop;
        return tbl;
    end function;
    
    -- Initialize cosine table
    function init_cosine_table return table_t is
        variable tbl : table_t;
        variable angle : real;
        variable val : real;
    begin
        for i in 0 to 255 loop
            angle := real(i) / 256.0 * MATH_PI / 2.0;
            val := cos(angle);
            tbl(i) := to_signed(integer(val * 32767.0), 16);
        end loop;
        return tbl;
    end function;
    
    -- Initialize reciprocal table: 1/x for x in [1, 2]
    function init_rcp_table return table_t is
        variable tbl : table_t;
        variable x : real;
        variable val : real;
    begin
        for i in 0 to 255 loop
            x := 1.0 + real(i) / 256.0;
            val := 1.0 / x;
            tbl(i) := to_signed(integer(val * 32767.0), 16);
        end loop;
        return tbl;
    end function;
    
    -- Initialize reciprocal sqrt table: 1/sqrt(x) for x in [1, 2]
    function init_rsq_table return table_t is
        variable tbl : table_t;
        variable x : real;
        variable val : real;
    begin
        for i in 0 to 255 loop
            x := 1.0 + real(i) / 256.0;
            val := 1.0 / sqrt(x);
            tbl(i) := to_signed(integer(val * 32767.0), 16);
        end loop;
        return tbl;
    end function;
    
    -- Initialize sqrt table: sqrt(x) for x in [1, 2]
    function init_sqrt_table return table_t is
        variable tbl : table_t;
        variable x : real;
        variable val : real;
    begin
        for i in 0 to 255 loop
            x := 1.0 + real(i) / 256.0;
            val := sqrt(x);
            tbl(i) := to_signed(integer(val * 32767.0), 16);
        end loop;
        return tbl;
    end function;
    
    -- Initialize exp2 table: 2^x for x in [0, 1]
    function init_exp2_table return table_t is
        variable tbl : table_t;
        variable x : real;
        variable val : real;
    begin
        for i in 0 to 255 loop
            x := real(i) / 256.0;
            val := 2.0 ** x;
            -- Scale to [0.5, 1.0) range for fixed point
            tbl(i) := to_signed(integer((val - 1.0) * 32767.0), 16);
        end loop;
        return tbl;
    end function;
    
    -- Initialize log2 table: log2(x) for x in [1, 2]
    function init_log2_table return table_t is
        variable tbl : table_t;
        variable x : real;
        variable val : real;
    begin
        for i in 0 to 255 loop
            x := 1.0 + real(i) / 256.0;
            val := log2(x);
            tbl(i) := to_signed(integer(val * 32767.0), 16);
        end loop;
        return tbl;
    end function;
    
    -- Initialize tanh table: tanh(x) for x in [0, 4]
    function init_tanh_table return table_t is
        variable tbl : table_t;
        variable x : real;
        variable val : real;
    begin
        for i in 0 to 255 loop
            x := real(i) / 64.0;  -- Range [0, 4]
            val := tanh(x);
            tbl(i) := to_signed(integer(val * 32767.0), 16);
        end loop;
        return tbl;
    end function;
    
    -- Table signals
    signal sine_table   : table_t := init_sine_table;
    signal cosine_table : table_t := init_cosine_table;
    signal rcp_table    : table_t := init_rcp_table;
    signal rsq_table    : table_t := init_rsq_table;
    signal sqrt_table   : table_t := init_sqrt_table;
    signal exp2_table   : table_t := init_exp2_table;
    signal log2_table   : table_t := init_log2_table;
    signal tanh_table   : table_t := init_tanh_table;
    
    -- Pipeline registers
    signal valid_p1, valid_p2 : std_logic;
    signal op_p1, op_p2 : sfu_op_t;
    signal operand_p1 : std_logic_vector(31 downto 0);
    signal table_idx : unsigned(7 downto 0);
    signal table_val : signed(15 downto 0);
    signal sign_p1, sign_p2 : std_logic;
    signal exp_p1, exp_p2 : unsigned(7 downto 0);
    signal mantissa_p1 : unsigned(22 downto 0);
    
begin

    ---------------------------------------------------------------------------
    -- Pipeline Stage 1: Decode input and compute table index
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable sign_v : std_logic;
        variable exp_v : unsigned(7 downto 0);
        variable mant_v : unsigned(22 downto 0);
        variable idx : unsigned(7 downto 0);
    begin
        if rst_n = '0' then
            valid_p1 <= '0';
            op_p1 <= SFU_SIN;
            operand_p1 <= (others => '0');
            sign_p1 <= '0';
            exp_p1 <= (others => '0');
            mantissa_p1 <= (others => '0');
            table_idx <= (others => '0');
            
        elsif rising_edge(clk) then
            valid_p1 <= valid_in;
            op_p1 <= op;
            operand_p1 <= operand;
            
            -- Decode IEEE-754
            sign_v := operand(31);
            exp_v := unsigned(operand(30 downto 23));
            mant_v := unsigned(operand(22 downto 0));
            
            sign_p1 <= sign_v;
            exp_p1 <= exp_v;
            mantissa_p1 <= mant_v;
            
            -- Compute table index based on operation
            case op is
                when SFU_SIN | SFU_COS =>
                    -- Use mantissa bits for angle lookup
                    -- (Simplified - full impl needs range reduction)
                    idx := mant_v(22 downto 15);
                    
                when SFU_RCP | SFU_RSQ | SFU_SQRT | SFU_LG2 =>
                    -- Use mantissa bits directly (input in [1,2) range)
                    idx := mant_v(22 downto 15);
                    
                when SFU_EX2 =>
                    -- Use mantissa for fractional part
                    idx := mant_v(22 downto 15);
                    
                when SFU_TANH =>
                    -- Scale input range
                    idx := mant_v(22 downto 15);
                    
                when others =>
                    idx := (others => '0');
            end case;
            
            table_idx <= idx;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Pipeline Stage 2: Table lookup
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            valid_p2 <= '0';
            op_p2 <= SFU_SIN;
            table_val <= (others => '0');
            sign_p2 <= '0';
            exp_p2 <= (others => '0');
            
        elsif rising_edge(clk) then
            valid_p2 <= valid_p1;
            op_p2 <= op_p1;
            sign_p2 <= sign_p1;
            exp_p2 <= exp_p1;
            
            -- Table lookup
            case op_p1 is
                when SFU_SIN =>
                    table_val <= sine_table(to_integer(table_idx));
                when SFU_COS =>
                    table_val <= cosine_table(to_integer(table_idx));
                when SFU_RCP =>
                    table_val <= rcp_table(to_integer(table_idx));
                when SFU_RSQ =>
                    table_val <= rsq_table(to_integer(table_idx));
                when SFU_SQRT =>
                    table_val <= sqrt_table(to_integer(table_idx));
                when SFU_EX2 =>
                    table_val <= exp2_table(to_integer(table_idx));
                when SFU_LG2 =>
                    table_val <= log2_table(to_integer(table_idx));
                when SFU_TANH =>
                    table_val <= tanh_table(to_integer(table_idx));
                when others =>
                    table_val <= (others => '0');
            end case;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Pipeline Stage 3: Convert result to IEEE-754
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable result_sign : std_logic;
        variable result_exp : unsigned(7 downto 0);
        variable result_mant : unsigned(22 downto 0);
        variable abs_table : unsigned(14 downto 0);
        variable shift : integer;
    begin
        if rst_n = '0' then
            valid_out <= '0';
            result <= (others => '0');
            
        elsif rising_edge(clk) then
            valid_out <= valid_p2;
            
            if valid_p2 = '1' then
                -- Convert fixed point table value to IEEE-754
                result_sign := '0';
                
                -- Handle sign
                case op_p2 is
                    when SFU_SIN | SFU_TANH =>
                        -- Preserve input sign
                        result_sign := sign_p2;
                    when SFU_COS =>
                        -- Cosine is even function
                        result_sign := '0';
                    when SFU_RCP =>
                        -- Sign follows input
                        result_sign := sign_p2;
                    when others =>
                        result_sign := '0';
                end case;
                
                -- Convert magnitude
                if table_val(15) = '1' then
                    abs_table := unsigned(-table_val(14 downto 0));
                    result_sign := not result_sign;
                else
                    abs_table := unsigned(table_val(14 downto 0));
                end if;
                
                if abs_table = 0 then
                    result <= (others => '0');
                else
                    -- Find leading one and normalize
                    shift := 0;
                    for i in 14 downto 0 loop
                        if abs_table(i) = '1' then
                            shift := 14 - i;
                            exit;
                        end if;
                    end loop;
                    
                    -- Exponent adjustment based on operation
                    case op_p2 is
                        when SFU_RCP =>
                            -- 1/x: exp_out = 253 - exp_in + adjustment
                            result_exp := 126 - resize(shift_right(exp_p2, 0), 8);
                        when SFU_RSQ =>
                            -- 1/sqrt(x): exp_out = 190 - exp_in/2
                            result_exp := 126 - shift_right(exp_p2, 1);
                        when SFU_SQRT =>
                            -- sqrt(x): exp_out = (exp_in + 127) / 2
                            result_exp := shift_right(exp_p2 + 127, 1);
                        when others =>
                            -- Default: assume result in [-1, 1] range
                            result_exp := to_unsigned(126 - shift, 8);
                    end case;
                    
                    -- Mantissa from table value
                    result_mant := resize(shift_left(abs_table, shift + 8), 23);
                    
                    result <= result_sign & std_logic_vector(result_exp) & std_logic_vector(result_mant);
                end if;
            else
                result <= (others => '0');
            end if;
        end if;
    end process;

end architecture rtl;
