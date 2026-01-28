-------------------------------------------------------------------------------
-- int_alu.vhd
-- 32-bit Integer ALU for SIMT Core
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

entity int_alu is
    port (
        -- Operands
        a           : in  std_logic_vector(31 downto 0);
        b           : in  std_logic_vector(31 downto 0);
        c           : in  std_logic_vector(31 downto 0);  -- For IMAD
        
        -- Operation
        op          : in  opcode_t;
        
        -- Result
        result      : out std_logic_vector(31 downto 0);
        
        -- Flags (optional)
        zero        : out std_logic;
        negative    : out std_logic;
        overflow    : out std_logic
    );
end entity int_alu;

architecture rtl of int_alu is

    signal a_signed     : signed(31 downto 0);
    signal b_signed     : signed(31 downto 0);
    signal a_unsigned   : unsigned(31 downto 0);
    signal b_unsigned   : unsigned(31 downto 0);
    signal result_i     : std_logic_vector(31 downto 0);
    
    -- Extended multiply result
    signal mul_result   : signed(63 downto 0);
    
begin

    a_signed   <= signed(a);
    b_signed   <= signed(b);
    a_unsigned <= unsigned(a);
    b_unsigned <= unsigned(b);
    
    mul_result <= a_signed * b_signed;
    
    -- Main ALU logic
    process(all)
        variable shift_amt : integer;
        variable pop_count : integer;
        variable lead_zeros : integer;
        variable temp_result : std_logic_vector(31 downto 0);
    begin
        result_i <= (others => '0');
        
        case op is
            -- Arithmetic Operations
            when OP_ADD =>
                result_i <= std_logic_vector(a_signed + b_signed);
                
            when OP_SUB =>
                result_i <= std_logic_vector(a_signed - b_signed);
                
            when OP_MUL =>
                result_i <= std_logic_vector(mul_result(31 downto 0));
                
            when OP_IMAD =>
                -- Integer Multiply-Add: a * b + c
                result_i <= std_logic_vector(mul_result(31 downto 0) + signed(c));
                
            when OP_IDIV =>
                -- Integer Division (signed)
                if b_signed /= 0 then
                    result_i <= std_logic_vector(a_signed / b_signed);
                else
                    result_i <= (others => '1');  -- Division by zero
                end if;
                
            when OP_IREM =>
                -- Integer Remainder (signed)
                if b_signed /= 0 then
                    result_i <= std_logic_vector(a_signed rem b_signed);
                else
                    result_i <= a;  -- Return dividend on div-by-zero
                end if;
                
            when OP_NEG =>
                result_i <= std_logic_vector(-a_signed);
                
            when OP_IABS =>
                if a_signed < 0 then
                    result_i <= std_logic_vector(-a_signed);
                else
                    result_i <= a;
                end if;
                
            when OP_IMIN =>
                if a_signed < b_signed then
                    result_i <= a;
                else
                    result_i <= b;
                end if;
                
            when OP_IMAX =>
                if a_signed > b_signed then
                    result_i <= a;
                else
                    result_i <= b;
                end if;
            
            -- Comparison Operations
            when OP_SLT =>
                if a_signed < b_signed then
                    result_i <= x"00000001";
                else
                    result_i <= x"00000000";
                end if;
                
            when OP_SLE =>
                if a_signed <= b_signed then
                    result_i <= x"00000001";
                else
                    result_i <= x"00000000";
                end if;
                
            when OP_SEQ =>
                if a = b then
                    result_i <= x"00000001";
                else
                    result_i <= x"00000000";
                end if;
            
            -- Logic Operations
            when OP_AND =>
                result_i <= a and b;
                
            when OP_OR =>
                result_i <= a or b;
                
            when OP_XOR =>
                result_i <= a xor b;
                
            when OP_NOT =>
                result_i <= not a;
            
            -- Shift Operations
            when OP_SHL =>
                shift_amt := to_integer(b_unsigned(4 downto 0));
                result_i <= std_logic_vector(shift_left(a_unsigned, shift_amt));
                
            when OP_SHR =>
                shift_amt := to_integer(b_unsigned(4 downto 0));
                result_i <= std_logic_vector(shift_right(a_unsigned, shift_amt));
                
            when OP_SHA =>
                shift_amt := to_integer(b_unsigned(4 downto 0));
                result_i <= std_logic_vector(shift_right(a_signed, shift_amt));
            
            -- Bit Manipulation
            when OP_POPC =>
                pop_count := 0;
                for i in 0 to 31 loop
                    if a(i) = '1' then
                        pop_count := pop_count + 1;
                    end if;
                end loop;
                result_i <= std_logic_vector(to_unsigned(pop_count, 32));
                
            when OP_CLZ =>
                lead_zeros := 32;
                for i in 31 downto 0 loop
                    if a(i) = '1' then
                        lead_zeros := 31 - i;
                        exit;
                    end if;
                end loop;
                result_i <= std_logic_vector(to_unsigned(lead_zeros, 32));
                
            when OP_BREV =>
                for i in 0 to 31 loop
                    result_i(i) <= a(31 - i);
                end loop;
                
            when OP_CNOT =>
                -- C-style logical NOT: (a == 0) ? 1 : 0
                if a = x"00000000" then
                    result_i <= x"00000001";
                else
                    result_i <= x"00000000";
                end if;
            
            -- Move / Misc
            when OP_MOV =>
                result_i <= a;
                
            when OP_TID =>
                -- Thread ID handled at warp level, just pass through
                result_i <= a;
                
            when others =>
                result_i <= (others => '0');
        end case;
    end process;
    
    -- Output assignments
    result   <= result_i;
    zero     <= '1' when result_i = x"00000000" else '0';
    negative <= result_i(31);
    overflow <= '0';  -- TODO: Implement proper overflow detection

end architecture rtl;
