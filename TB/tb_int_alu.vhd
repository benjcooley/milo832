-------------------------------------------------------------------------------
-- tb_int_alu.vhd
-- Unit Test: Integer ALU
-- Tests: ADD, SUB, MUL, AND, OR, XOR, SHL, SHR, SLT, NEG, NOT
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_int_alu is
end entity tb_int_alu;

architecture sim of tb_int_alu is
    
    -- DUT signals
    signal a, b, c    : std_logic_vector(31 downto 0);
    signal op         : std_logic_vector(7 downto 0);
    signal result     : std_logic_vector(31 downto 0);
    signal zero, negative, overflow : std_logic;
    
    -- Test control
    signal test_count : integer := 0;
    signal fail_count : integer := 0;
    
    -- Opcodes (must match simt_pkg.vhd exactly!)
    constant OP_ADD : std_logic_vector(7 downto 0) := x"01";
    constant OP_SUB : std_logic_vector(7 downto 0) := x"02";
    constant OP_MUL : std_logic_vector(7 downto 0) := x"03";
    constant OP_SLT : std_logic_vector(7 downto 0) := x"04";
    constant OP_NEG : std_logic_vector(7 downto 0) := x"06";
    constant OP_AND : std_logic_vector(7 downto 0) := x"50";
    constant OP_OR  : std_logic_vector(7 downto 0) := x"51";
    constant OP_XOR : std_logic_vector(7 downto 0) := x"52";
    constant OP_NOT : std_logic_vector(7 downto 0) := x"53";
    constant OP_SHL : std_logic_vector(7 downto 0) := x"60";
    constant OP_SHR : std_logic_vector(7 downto 0) := x"61";
    
    procedure check(
        signal tc : inout integer;
        signal fc : inout integer;
        actual    : std_logic_vector(31 downto 0);
        expected  : std_logic_vector(31 downto 0);
        name      : string
    ) is
    begin
        tc <= tc + 1;
        if actual /= expected then
            fc <= fc + 1;
            report "FAIL: " & name & 
                   " expected=" & integer'image(to_integer(signed(expected))) &
                   " got=" & integer'image(to_integer(signed(actual)))
                severity error;
        else
            report "PASS: " & name severity note;
        end if;
    end procedure;

begin

    -- DUT instantiation
    u_alu : entity work.int_alu
        port map (
            a        => a,
            b        => b,
            c        => c,
            op       => op,
            result   => result,
            zero     => zero,
            negative => negative,
            overflow => overflow
        );

    -- Test process
    process
    begin
        report "=== Integer ALU Unit Test ===" severity note;
        
        -- Initialize
        a <= (others => '0');
        b <= (others => '0');
        c <= (others => '0');
        op <= OP_ADD;
        wait for 10 ns;
        
        -------------------------------------------------
        -- ADD tests
        -------------------------------------------------
        report "--- ADD Tests ---" severity note;
        
        op <= OP_ADD;
        a <= x"00000005"; b <= x"00000003"; wait for 10 ns;
        check(test_count, fail_count, result, x"00000008", "ADD 5+3=8");
        
        a <= x"FFFFFFFF"; b <= x"00000001"; wait for 10 ns;
        check(test_count, fail_count, result, x"00000000", "ADD -1+1=0 (overflow)");
        
        a <= x"7FFFFFFF"; b <= x"00000001"; wait for 10 ns;
        check(test_count, fail_count, result, x"80000000", "ADD max_int+1");
        
        -------------------------------------------------
        -- SUB tests
        -------------------------------------------------
        report "--- SUB Tests ---" severity note;
        
        op <= OP_SUB;
        a <= x"0000000A"; b <= x"00000003"; wait for 10 ns;
        check(test_count, fail_count, result, x"00000007", "SUB 10-3=7");
        
        a <= x"00000000"; b <= x"00000001"; wait for 10 ns;
        check(test_count, fail_count, result, x"FFFFFFFF", "SUB 0-1=-1");
        
        -------------------------------------------------
        -- MUL tests
        -------------------------------------------------
        report "--- MUL Tests ---" severity note;
        
        op <= OP_MUL;
        a <= x"00000006"; b <= x"00000007"; wait for 10 ns;
        check(test_count, fail_count, result, x"0000002A", "MUL 6*7=42");
        
        a <= x"FFFFFFFF"; b <= x"00000002"; wait for 10 ns;
        check(test_count, fail_count, result, x"FFFFFFFE", "MUL -1*2=-2");
        
        -------------------------------------------------
        -- Logic tests
        -------------------------------------------------
        report "--- Logic Tests ---" severity note;
        
        op <= OP_AND;
        a <= x"FF00FF00"; b <= x"0F0F0F0F"; wait for 10 ns;
        check(test_count, fail_count, result, x"0F000F00", "AND");
        
        op <= OP_OR;
        a <= x"FF00FF00"; b <= x"0F0F0F0F"; wait for 10 ns;
        check(test_count, fail_count, result, x"FF0FFF0F", "OR");
        
        op <= OP_XOR;
        a <= x"FF00FF00"; b <= x"0F0F0F0F"; wait for 10 ns;
        check(test_count, fail_count, result, x"F00FF00F", "XOR");
        
        op <= OP_NOT;
        a <= x"FF00FF00"; wait for 10 ns;
        check(test_count, fail_count, result, x"00FF00FF", "NOT");
        
        -------------------------------------------------
        -- Shift tests
        -------------------------------------------------
        report "--- Shift Tests ---" severity note;
        
        op <= OP_SHL;
        a <= x"00000001"; b <= x"00000004"; wait for 10 ns;
        check(test_count, fail_count, result, x"00000010", "SHL 1<<4=16");
        
        op <= OP_SHR;
        a <= x"00000100"; b <= x"00000004"; wait for 10 ns;
        check(test_count, fail_count, result, x"00000010", "SHR 256>>4=16");
        
        -------------------------------------------------
        -- Compare tests
        -------------------------------------------------
        report "--- Compare Tests ---" severity note;
        
        op <= OP_SLT;
        a <= x"00000005"; b <= x"0000000A"; wait for 10 ns;
        check(test_count, fail_count, result, x"00000001", "SLT 5<10=1");
        
        a <= x"0000000A"; b <= x"00000005"; wait for 10 ns;
        check(test_count, fail_count, result, x"00000000", "SLT 10<5=0");
        
        -------------------------------------------------
        -- NEG test
        -------------------------------------------------
        report "--- NEG Tests ---" severity note;
        
        op <= OP_NEG;
        a <= x"00000005"; wait for 10 ns;
        check(test_count, fail_count, result, x"FFFFFFFB", "NEG 5=-5");
        
        a <= x"FFFFFFFF"; wait for 10 ns;
        check(test_count, fail_count, result, x"00000001", "NEG -1=1");
        
        -------------------------------------------------
        -- Summary
        -------------------------------------------------
        wait for 10 ns;
        report "=== Test Summary ===" severity note;
        report "Total: " & integer'image(test_count) & 
               " Passed: " & integer'image(test_count - fail_count) &
               " Failed: " & integer'image(fail_count) severity note;
        
        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        
        wait;
    end process;

end architecture sim;
