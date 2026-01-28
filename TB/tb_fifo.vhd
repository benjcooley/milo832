-------------------------------------------------------------------------------
-- tb_fifo.vhd
-- Unit Test: Generic FIFO Buffer
-- Tests: Push, Pop, Full, Empty, Count, Overflow/Underflow behavior
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fifo is
end entity tb_fifo;

architecture sim of tb_fifo is
    
    constant CLK_PERIOD : time := 10 ns;
    constant DEPTH      : integer := 8;
    constant WIDTH      : integer := 32;
    
    -- DUT signals
    signal clk      : std_logic := '0';
    signal rst_n    : std_logic := '0';
    signal push     : std_logic := '0';
    signal pop      : std_logic := '0';
    signal data_in  : std_logic_vector(WIDTH-1 downto 0) := (others => '0');
    signal data_out : std_logic_vector(WIDTH-1 downto 0);
    signal full     : std_logic;
    signal empty    : std_logic;
    signal count    : integer;
    
    -- Test control
    signal test_count : integer := 0;
    signal fail_count : integer := 0;
    signal done       : boolean := false;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not done;
    
    -- DUT instantiation
    u_fifo : entity work.fifo
        generic map (
            DEPTH      => DEPTH,
            DATA_WIDTH => WIDTH
        )
        port map (
            clk      => clk,
            rst_n    => rst_n,
            push     => push,
            pop      => pop,
            data_in  => data_in,
            data_out => data_out,
            full     => full,
            empty    => empty,
            count    => count
        );

    -- Test process
    process
        procedure check_flags(
            exp_empty : std_logic;
            exp_full  : std_logic;
            exp_count : integer;
            name      : string
        ) is
        begin
            test_count <= test_count + 1;
            if empty /= exp_empty or full /= exp_full or count /= exp_count then
                fail_count <= fail_count + 1;
                report "FAIL: " & name & 
                       " empty=" & std_logic'image(empty) & "(exp " & std_logic'image(exp_empty) & ")" &
                       " full=" & std_logic'image(full) & "(exp " & std_logic'image(exp_full) & ")" &
                       " count=" & integer'image(count) & "(exp " & integer'image(exp_count) & ")"
                    severity error;
            else
                report "PASS: " & name severity note;
            end if;
        end procedure;
        
        procedure check_data(
            expected : std_logic_vector(WIDTH-1 downto 0);
            name     : string
        ) is
        begin
            test_count <= test_count + 1;
            if data_out /= expected then
                fail_count <= fail_count + 1;
                report "FAIL: " & name & 
                       " got=" & integer'image(to_integer(unsigned(data_out))) &
                       " exp=" & integer'image(to_integer(unsigned(expected)))
                    severity error;
            else
                report "PASS: " & name severity note;
            end if;
        end procedure;
        
    begin
        report "=== FIFO Unit Test ===" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- Test 1: Initial state (empty)
        -------------------------------------------------
        report "--- Initial State ---" severity note;
        check_flags('1', '0', 0, "Empty after reset");
        
        -------------------------------------------------
        -- Test 2: Push single item
        -------------------------------------------------
        report "--- Push Single Item ---" severity note;
        data_in <= x"DEADBEEF";
        push <= '1';
        wait for CLK_PERIOD;
        push <= '0';
        wait for CLK_PERIOD;
        
        check_flags('0', '0', 1, "After push 1");
        check_data(x"DEADBEEF", "Peek first item");
        
        -------------------------------------------------
        -- Test 3: Fill FIFO
        -------------------------------------------------
        report "--- Fill FIFO ---" severity note;
        for i in 2 to DEPTH loop
            data_in <= std_logic_vector(to_unsigned(i * 100, WIDTH));
            push <= '1';
            wait for CLK_PERIOD;
        end loop;
        push <= '0';
        wait for CLK_PERIOD;
        
        check_flags('0', '1', DEPTH, "FIFO full");
        
        -------------------------------------------------
        -- Test 4: Push when full (should be ignored)
        -------------------------------------------------
        report "--- Push When Full ---" severity note;
        data_in <= x"FFFFFFFF";
        push <= '1';
        wait for CLK_PERIOD;
        push <= '0';
        wait for CLK_PERIOD;
        
        check_flags('0', '1', DEPTH, "Still full after overflow attempt");
        
        -------------------------------------------------
        -- Test 5: Pop all items (FIFO order)
        -------------------------------------------------
        report "--- Pop All Items ---" severity note;
        check_data(x"DEADBEEF", "First item is DEADBEEF");
        
        pop <= '1';
        wait for CLK_PERIOD;
        pop <= '0';
        wait for CLK_PERIOD;
        
        check_flags('0', '0', DEPTH-1, "After pop 1");
        check_data(std_logic_vector(to_unsigned(200, WIDTH)), "Second item is 200");
        
        -- Pop remaining
        for i in 2 to DEPTH loop
            pop <= '1';
            wait for CLK_PERIOD;
        end loop;
        pop <= '0';
        wait for CLK_PERIOD;
        
        check_flags('1', '0', 0, "FIFO empty after drain");
        
        -------------------------------------------------
        -- Test 6: Pop when empty (should be safe)
        -------------------------------------------------
        report "--- Pop When Empty ---" severity note;
        pop <= '1';
        wait for CLK_PERIOD;
        pop <= '0';
        wait for CLK_PERIOD;
        
        check_flags('1', '0', 0, "Still empty after underflow attempt");
        
        -------------------------------------------------
        -- Test 7: Simultaneous push/pop
        -------------------------------------------------
        report "--- Simultaneous Push/Pop ---" severity note;
        
        -- First push something
        data_in <= x"AAAA0001";
        push <= '1';
        wait for CLK_PERIOD;
        data_in <= x"AAAA0002";
        wait for CLK_PERIOD;
        push <= '0';
        wait for CLK_PERIOD;
        
        check_flags('0', '0', 2, "Two items in FIFO");
        
        -- Simultaneous push and pop
        data_in <= x"AAAA0003";
        push <= '1';
        pop <= '1';
        wait for CLK_PERIOD;
        push <= '0';
        pop <= '0';
        wait for CLK_PERIOD;
        
        check_flags('0', '0', 2, "Count unchanged with simultaneous push/pop");
        check_data(x"AAAA0002", "Head advanced correctly");
        
        -------------------------------------------------
        -- Summary
        -------------------------------------------------
        wait for CLK_PERIOD * 2;
        report "=== Test Summary ===" severity note;
        report "Total: " & integer'image(test_count) & 
               " Passed: " & integer'image(test_count - fail_count) &
               " Failed: " & integer'image(fail_count) severity note;
        
        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        
        done <= true;
        wait;
    end process;

end architecture sim;
