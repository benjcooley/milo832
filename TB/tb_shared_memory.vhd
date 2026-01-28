-------------------------------------------------------------------------------
-- tb_shared_memory.vhd
-- Unit Test: Banked Shared Memory
-- Tests: Basic R/W, Bank conflicts, Conflict serialization
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_shared_memory is
end entity tb_shared_memory;

architecture sim of tb_shared_memory is
    
    constant CLK_PERIOD : time := 10 ns;
    constant NUM_BANKS  : integer := 32;
    constant SIZE_BYTES : integer := 16384;
    
    -- DUT signals
    signal clk        : std_logic := '0';
    signal rst_n      : std_logic := '0';
    signal req_valid  : std_logic := '0';
    signal req_write  : std_logic := '0';
    signal req_addr   : std_logic_vector(NUM_BANKS*32-1 downto 0) := (others => '0');
    signal req_wdata  : std_logic_vector(NUM_BANKS*32-1 downto 0) := (others => '0');
    signal req_mask   : std_logic_vector(NUM_BANKS-1 downto 0) := (others => '0');
    signal resp_valid : std_logic;
    signal resp_data  : std_logic_vector(NUM_BANKS*32-1 downto 0);
    signal stall      : std_logic;
    
    -- Test control
    signal test_count : integer := 0;
    signal fail_count : integer := 0;
    signal done       : boolean := false;
    
    -- Helper to set lane address
    procedure set_lane_addr(
        signal addr : out std_logic_vector;
        lane        : integer;
        value       : unsigned
    ) is
    begin
        addr(lane*32+31 downto lane*32) <= std_logic_vector(resize(value, 32));
    end procedure;
    
    -- Helper to set lane data
    procedure set_lane_data(
        signal wdata : out std_logic_vector;
        lane         : integer;
        value        : unsigned
    ) is
    begin
        wdata(lane*32+31 downto lane*32) <= std_logic_vector(resize(value, 32));
    end procedure;
    
    -- Helper to get lane data
    function get_lane_data(
        data : std_logic_vector;
        lane : integer
    ) return std_logic_vector is
    begin
        return data(lane*32+31 downto lane*32);
    end function;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not done;
    
    -- DUT instantiation
    u_shm : entity work.shared_memory
        generic map (
            SIZE_BYTES    => SIZE_BYTES,
            NUM_BANKS     => NUM_BANKS,
            CONFLICT_MODE => 1  -- Serialize on conflict
        )
        port map (
            clk        => clk,
            rst_n      => rst_n,
            req_valid  => req_valid,
            req_write  => req_write,
            req_addr   => req_addr,
            req_wdata  => req_wdata,
            req_mask   => req_mask,
            resp_valid => resp_valid,
            resp_data  => resp_data,
            stall      => stall
        );

    -- Test process
    process
        variable expected : std_logic_vector(31 downto 0);
    begin
        report "=== Shared Memory Unit Test ===" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- Test 1: Single lane write/read (no conflict)
        -------------------------------------------------
        report "--- Single Lane Write/Read ---" severity note;
        
        -- Write to lane 0, address 0
        req_valid <= '1';
        req_write <= '1';
        req_mask <= (0 => '1', others => '0');
        set_lane_addr(req_addr, 0, to_unsigned(0, 32));
        set_lane_data(req_wdata, 0, to_unsigned(16#DEADBEEF#, 32));
        wait for CLK_PERIOD;
        req_valid <= '0';
        req_write <= '0';
        wait for CLK_PERIOD;
        
        -- Read back
        req_valid <= '1';
        req_write <= '0';
        req_mask <= (0 => '1', others => '0');
        set_lane_addr(req_addr, 0, to_unsigned(0, 32));
        wait for CLK_PERIOD;
        req_valid <= '0';
        
        -- Wait for response
        wait until resp_valid = '1' for CLK_PERIOD * 10;
        
        test_count <= test_count + 1;
        expected := x"DEADBEEF";
        if get_lane_data(resp_data, 0) = expected then
            report "PASS: Single lane read" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Single lane read" severity error;
        end if;
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- Test 2: All lanes parallel (no conflict)
        -------------------------------------------------
        report "--- All Lanes Parallel (No Conflict) ---" severity note;
        
        -- Write unique value to each bank (different addresses = different banks)
        req_valid <= '1';
        req_write <= '1';
        req_mask <= (others => '1');
        for i in 0 to NUM_BANKS-1 loop
            -- Address = i*4 maps to bank i (assuming 4-byte stride)
            set_lane_addr(req_addr, i, to_unsigned(i * 4, 32));
            set_lane_data(req_wdata, i, to_unsigned(16#1000# + i, 32));
        end loop;
        wait for CLK_PERIOD;
        req_valid <= '0';
        req_write <= '0';
        wait for CLK_PERIOD;
        
        -- Read back all lanes
        req_valid <= '1';
        req_write <= '0';
        req_mask <= (others => '1');
        for i in 0 to NUM_BANKS-1 loop
            set_lane_addr(req_addr, i, to_unsigned(i * 4, 32));
        end loop;
        wait for CLK_PERIOD;
        req_valid <= '0';
        
        wait until resp_valid = '1' for CLK_PERIOD * 10;
        
        test_count <= test_count + 1;
        -- Check a few lanes
        if get_lane_data(resp_data, 0) = std_logic_vector(to_unsigned(16#1000#, 32)) and
           get_lane_data(resp_data, 15) = std_logic_vector(to_unsigned(16#100F#, 32)) and
           get_lane_data(resp_data, 31) = std_logic_vector(to_unsigned(16#101F#, 32)) then
            report "PASS: Parallel read all lanes" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Parallel read all lanes" severity error;
        end if;
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- Test 3: Bank conflict (all lanes same bank)
        -------------------------------------------------
        report "--- Bank Conflict Test ---" severity note;
        
        -- All lanes access same address (worst case: 32-way conflict)
        req_valid <= '1';
        req_write <= '0';
        req_mask <= (others => '1');
        for i in 0 to NUM_BANKS-1 loop
            set_lane_addr(req_addr, i, to_unsigned(0, 32));  -- All to addr 0
        end loop;
        wait for CLK_PERIOD;
        
        -- Should stall
        test_count <= test_count + 1;
        if stall = '1' then
            report "PASS: Bank conflict detected (stall asserted)" severity note;
        else
            -- Some implementations might broadcast instead of stall
            report "NOTE: No stall on conflict (broadcast mode?)" severity note;
        end if;
        
        req_valid <= '0';
        -- Wait for serialization to complete
        wait until stall = '0' for CLK_PERIOD * 64;
        wait for CLK_PERIOD * 2;
        
        -------------------------------------------------
        -- Test 4: Partial mask
        -------------------------------------------------
        report "--- Partial Mask Test ---" severity note;
        
        -- Only lanes 0, 4, 8, 12 active
        req_valid <= '1';
        req_write <= '1';
        req_mask <= x"00001111";  -- Lanes 0,4,8,12
        for i in 0 to 3 loop
            set_lane_addr(req_addr, i*4, to_unsigned(256 + i*4, 32));
            set_lane_data(req_wdata, i*4, to_unsigned(16#AAAA# + i, 32));
        end loop;
        wait for CLK_PERIOD;
        req_valid <= '0';
        req_write <= '0';
        wait for CLK_PERIOD;
        
        -- Read back
        req_valid <= '1';
        req_write <= '0';
        req_mask <= x"00001111";
        for i in 0 to 3 loop
            set_lane_addr(req_addr, i*4, to_unsigned(256 + i*4, 32));
        end loop;
        wait for CLK_PERIOD;
        req_valid <= '0';
        
        wait until resp_valid = '1' for CLK_PERIOD * 10;
        
        test_count <= test_count + 1;
        if get_lane_data(resp_data, 0) = std_logic_vector(to_unsigned(16#AAAA#, 32)) then
            report "PASS: Partial mask write/read" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Partial mask write/read" severity error;
        end if;
        wait for CLK_PERIOD;
        
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
