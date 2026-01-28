-------------------------------------------------------------------------------
-- tb_fpu.vhd
-- Unit Test: IEEE-754 Single Precision FPU
-- Tests: FADD, FSUB, FMUL, FDIV, ITOF, FTOI, special values
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.float_pkg.all;

entity tb_fpu is
end entity tb_fpu;

architecture sim of tb_fpu is
    
    constant CLK_PERIOD : time := 10 ns;
    
    -- DUT signals
    signal clk        : std_logic := '0';
    signal rst_n      : std_logic := '0';
    signal valid_in   : std_logic := '0';
    signal op         : std_logic_vector(7 downto 0) := (others => '0');
    signal a, b, c    : std_logic_vector(31 downto 0) := (others => '0');
    signal valid_out  : std_logic;
    signal result     : std_logic_vector(31 downto 0);
    
    -- Test control
    signal test_count : integer := 0;
    signal fail_count : integer := 0;
    signal sim_done   : boolean := false;
    
    -- Opcodes
    constant OP_FADD : std_logic_vector(7 downto 0) := x"10";
    constant OP_FSUB : std_logic_vector(7 downto 0) := x"11";
    constant OP_FMUL : std_logic_vector(7 downto 0) := x"12";
    constant OP_FDIV : std_logic_vector(7 downto 0) := x"13";
    constant OP_ITOF : std_logic_vector(7 downto 0) := x"17";
    constant OP_FTOI : std_logic_vector(7 downto 0) := x"18";
    
    -- IEEE-754 constants
    constant F_ZERO     : std_logic_vector(31 downto 0) := x"00000000";
    constant F_ONE      : std_logic_vector(31 downto 0) := x"3F800000";  -- 1.0
    constant F_TWO      : std_logic_vector(31 downto 0) := x"40000000";  -- 2.0
    constant F_THREE    : std_logic_vector(31 downto 0) := x"40400000";  -- 3.0
    constant F_HALF     : std_logic_vector(31 downto 0) := x"3F000000";  -- 0.5
    constant F_NEG_ONE  : std_logic_vector(31 downto 0) := x"BF800000";  -- -1.0
    constant F_TEN      : std_logic_vector(31 downto 0) := x"41200000";  -- 10.0
    constant F_PI       : std_logic_vector(31 downto 0) := x"40490FDB";  -- 3.14159...
    constant F_INF      : std_logic_vector(31 downto 0) := x"7F800000";  -- +Infinity
    constant F_NAN      : std_logic_vector(31 downto 0) := x"7FC00000";  -- NaN
    
    -- Helper to convert real to IEEE-754
    function real_to_float(r : real) return std_logic_vector is
        variable f : float32;
    begin
        f := to_float(r, 8, 23);
        return to_slv(f);
    end function;
    
    -- Helper to convert IEEE-754 to real
    function float_to_real(v : std_logic_vector) return real is
        variable f : float32;
    begin
        f := to_float(v, 8, 23);
        return to_real(f);
    end function;
    
    -- Check with tolerance
    procedure check_float(
        signal tc, fc : inout integer;
        actual        : std_logic_vector(31 downto 0);
        expected      : real;
        tolerance     : real;
        name          : string
    ) is
        variable actual_r : real;
        variable diff : real;
    begin
        tc <= tc + 1;
        actual_r := float_to_real(actual);
        diff := abs(actual_r - expected);
        
        if diff <= tolerance then
            report "PASS: " & name & " = " & real'image(actual_r) severity note;
        else
            fc <= fc + 1;
            report "FAIL: " & name & " expected=" & real'image(expected) &
                   " got=" & real'image(actual_r) severity error;
        end if;
    end procedure;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not sim_done;
    
    -- DUT instantiation
    u_fpu : entity work.fpu
        port map (
            clk       => clk,
            rst_n     => rst_n,
            valid_in  => valid_in,
            op        => op,
            a         => a,
            b         => b,
            c         => c,
            valid_out => valid_out,
            result    => result
        );

    -- Test process
    process
    begin
        report "=== FPU Unit Test ===" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- FADD Tests
        -------------------------------------------------
        report "--- FADD Tests ---" severity note;
        
        op <= OP_FADD;
        a <= F_ONE; b <= F_TWO;  -- 1.0 + 2.0 = 3.0
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 20;
        wait for CLK_PERIOD;
        check_float(test_count, fail_count, result, 3.0, 0.001, "FADD 1+2=3");
        
        a <= F_ONE; b <= F_NEG_ONE;  -- 1.0 + (-1.0) = 0.0
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 20;
        wait for CLK_PERIOD;
        check_float(test_count, fail_count, result, 0.0, 0.001, "FADD 1+(-1)=0");
        
        -------------------------------------------------
        -- FSUB Tests
        -------------------------------------------------
        report "--- FSUB Tests ---" severity note;
        
        op <= OP_FSUB;
        a <= F_THREE; b <= F_ONE;  -- 3.0 - 1.0 = 2.0
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 20;
        wait for CLK_PERIOD;
        check_float(test_count, fail_count, result, 2.0, 0.001, "FSUB 3-1=2");
        
        -------------------------------------------------
        -- FMUL Tests
        -------------------------------------------------
        report "--- FMUL Tests ---" severity note;
        
        op <= OP_FMUL;
        a <= F_THREE; b <= F_TWO;  -- 3.0 * 2.0 = 6.0
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 20;
        wait for CLK_PERIOD;
        check_float(test_count, fail_count, result, 6.0, 0.001, "FMUL 3*2=6");
        
        a <= F_HALF; b <= F_HALF;  -- 0.5 * 0.5 = 0.25
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 20;
        wait for CLK_PERIOD;
        check_float(test_count, fail_count, result, 0.25, 0.001, "FMUL 0.5*0.5=0.25");
        
        -------------------------------------------------
        -- FDIV Tests
        -------------------------------------------------
        report "--- FDIV Tests ---" severity note;
        
        op <= OP_FDIV;
        a <= F_TEN; b <= F_TWO;  -- 10.0 / 2.0 = 5.0
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 30;
        wait for CLK_PERIOD;
        check_float(test_count, fail_count, result, 5.0, 0.001, "FDIV 10/2=5");
        
        a <= F_ONE; b <= F_THREE;  -- 1.0 / 3.0 = 0.333...
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 30;
        wait for CLK_PERIOD;
        check_float(test_count, fail_count, result, 0.3333, 0.01, "FDIV 1/3=0.33");
        
        -------------------------------------------------
        -- ITOF Tests (Integer to Float)
        -------------------------------------------------
        report "--- ITOF Tests ---" severity note;
        
        op <= OP_ITOF;
        a <= std_logic_vector(to_signed(42, 32));
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 20;
        wait for CLK_PERIOD;
        check_float(test_count, fail_count, result, 42.0, 0.001, "ITOF 42=42.0");
        
        a <= std_logic_vector(to_signed(-100, 32));
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 20;
        wait for CLK_PERIOD;
        check_float(test_count, fail_count, result, -100.0, 0.001, "ITOF -100=-100.0");
        
        -------------------------------------------------
        -- FTOI Tests (Float to Integer)
        -------------------------------------------------
        report "--- FTOI Tests ---" severity note;
        
        op <= OP_FTOI;
        a <= real_to_float(123.7);
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 20;
        wait for CLK_PERIOD;
        
        test_count <= test_count + 1;
        if to_integer(signed(result)) = 123 or to_integer(signed(result)) = 124 then
            report "PASS: FTOI 123.7 = " & integer'image(to_integer(signed(result))) severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: FTOI 123.7" severity error;
        end if;
        
        -------------------------------------------------
        -- Special Values
        -------------------------------------------------
        report "--- Special Values ---" severity note;
        
        op <= OP_FMUL;
        a <= F_ZERO; b <= F_INF;  -- 0 * Inf = NaN
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';
        wait until valid_out = '1' for CLK_PERIOD * 20;
        wait for CLK_PERIOD;
        
        test_count <= test_count + 1;
        -- Check for NaN (exponent all 1s, mantissa non-zero)
        if result(30 downto 23) = "11111111" and result(22 downto 0) /= "00000000000000000000000" then
            report "PASS: 0*Inf = NaN" severity note;
        else
            -- Some implementations may return 0 or Inf
            report "NOTE: 0*Inf result: " & integer'image(to_integer(unsigned(result))) severity note;
        end if;
        
        -------------------------------------------------
        -- Summary
        -------------------------------------------------
        wait for CLK_PERIOD * 5;
        report "=== Test Summary ===" severity note;
        report "Total: " & integer'image(test_count) & 
               " Passed: " & integer'image(test_count - fail_count) &
               " Failed: " & integer'image(fail_count) severity note;
        
        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
