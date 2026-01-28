-------------------------------------------------------------------------------
-- fpu.vhd
-- IEEE-754 Single Precision Floating Point Unit
--
-- Uses VHDL-2008 ieee.float_pkg for IEEE-754 operations
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
use ieee.float_pkg.all;

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

    -- Pipeline registers (4 stages to match original timing)
    signal valid_p1, valid_p2, valid_p3, valid_p4 : std_logic := '0';
    signal result_p1, result_p2, result_p3 : std_logic_vector(31 downto 0) := (others => '0');

begin

    ---------------------------------------------------------------------------
    -- Main FPU Process
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable fa, fb, fc : float32;
        variable fr : float32;
        variable ia : signed(31 downto 0);
        variable ir : signed(31 downto 0);
        variable computed_result : std_logic_vector(31 downto 0);
    begin
        if rst_n = '0' then
            valid_p1 <= '0';
            valid_p2 <= '0';
            valid_p3 <= '0';
            valid_p4 <= '0';
            valid_out <= '0';
            result_p1 <= (others => '0');
            result_p2 <= (others => '0');
            result_p3 <= (others => '0');
            result <= (others => '0');
            overflow <= '0';
            underflow <= '0';
            inexact <= '0';
            invalid <= '0';
            div_zero <= '0';
            
        elsif rising_edge(clk) then
            -- Stage 1: Compute
            valid_p1 <= valid_in;
            
            if valid_in = '1' then
                -- Convert inputs to float32
                fa := to_float(a, float32'high, -float32'low);
                fb := to_float(b, float32'high, -float32'low);
                fc := to_float(c, float32'high, -float32'low);
                
                computed_result := (others => '0');
                
                case op is
                    when OP_FADD =>
                        fr := fa + fb;
                        computed_result := to_slv(fr);
                        
                    when OP_FSUB =>
                        fr := fa - fb;
                        computed_result := to_slv(fr);
                        
                    when OP_FMUL =>
                        fr := fa * fb;
                        computed_result := to_slv(fr);
                        
                    when OP_FDIV =>
                        fr := fa / fb;
                        computed_result := to_slv(fr);
                        
                    when OP_FFMA =>
                        fr := fa * fb + fc;
                        computed_result := to_slv(fr);
                        
                    when OP_FMIN =>
                        if fa < fb then
                            computed_result := a;
                        else
                            computed_result := b;
                        end if;
                        
                    when OP_FMAX =>
                        if fa > fb then
                            computed_result := a;
                        else
                            computed_result := b;
                        end if;
                        
                    when OP_FABS =>
                        fr := abs(fa);
                        computed_result := to_slv(fr);
                        
                    when OP_FNEG =>
                        fr := -fa;
                        computed_result := to_slv(fr);
                        
                    when OP_ITOF =>
                        ia := signed(a);
                        fr := to_float(ia, float32'high, -float32'low);
                        computed_result := to_slv(fr);
                        
                    when OP_FTOI =>
                        ir := to_signed(fa, 32);
                        computed_result := std_logic_vector(ir);
                        
                    when OP_FSETP =>
                        if fa < fb then
                            computed_result := x"00000001";
                        else
                            computed_result := x"00000000";
                        end if;
                        
                    when others =>
                        computed_result := (others => '0');
                end case;
                
                result_p1 <= computed_result;
            end if;
            
            -- Stage 2-4: Pipeline delay
            valid_p2 <= valid_p1;
            result_p2 <= result_p1;
            
            valid_p3 <= valid_p2;
            result_p3 <= result_p2;
            
            valid_p4 <= valid_p3;
            valid_out <= valid_p4;
            result <= result_p3;
            
            -- Exception flags (simplified)
            overflow <= '0';
            underflow <= '0';
            inexact <= '0';
            invalid <= '0';
            div_zero <= '0';
        end if;
    end process;

end architecture rtl;
