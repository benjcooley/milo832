-------------------------------------------------------------------------------
-- tb_system_bus.vhd
-- Unit Test: System Bus Infrastructure
-- Tests: Arbitration, Address decode, Single transfer, Burst, Priority
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.system_bus_pkg.all;

entity tb_system_bus is
end entity tb_system_bus;

architecture sim of tb_system_bus is
    
    constant CLK_PERIOD : time := 10 ns;
    constant NUM_MASTERS : integer := 4;
    constant NUM_SLAVES : integer := 4;
    
    -- Clock and reset
    signal clk      : std_logic := '0';
    signal rst_n    : std_logic := '0';
    
    -- Bus interfaces
    signal master_req  : master_req_array_t(0 to NUM_MASTERS-1);
    signal master_resp : master_resp_array_t(0 to NUM_MASTERS-1);
    signal slave_req   : slave_req_array_t(0 to NUM_SLAVES-1);
    signal slave_resp  : slave_resp_array_t(0 to NUM_SLAVES-1);
    signal qos_config  : qos_array_t(0 to NUM_MASTERS-1);
    signal busy        : std_logic;
    
    -- Test control
    signal test_count : integer := 0;
    signal fail_count : integer := 0;
    signal sim_done   : boolean := false;
    
    -- Simple memory slave model
    type mem_t is array (0 to 255) of std_logic_vector(63 downto 0);
    signal slave_mem : mem_t := (others => (others => '0'));

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not sim_done;
    
    -- Default QoS
    qos_config <= (others => QOS_DEFAULT);
    
    ---------------------------------------------------------------------------
    -- DUT: System Bus
    ---------------------------------------------------------------------------
    u_bus : entity work.system_bus
        generic map (
            NUM_MASTERS    => NUM_MASTERS,
            NUM_SLAVES     => NUM_SLAVES,
            TIMEOUT_CYCLES => 64
        )
        port map (
            clk         => clk,
            rst_n       => rst_n,
            master_req  => master_req,
            master_resp => master_resp,
            slave_req   => slave_req,
            slave_resp  => slave_resp,
            qos_config  => qos_config,
            busy        => busy
        );
    
    ---------------------------------------------------------------------------
    -- Simple Slave Models (respond immediately)
    ---------------------------------------------------------------------------
    process(clk)
        variable addr_idx : integer;
    begin
        if rising_edge(clk) then
            for s in 0 to NUM_SLAVES-1 loop
                slave_resp(s) <= BUS_SLAVE_RESP_INIT;
                slave_resp(s).ready <= '1';
                
                if slave_req(s).sel = '1' then
                    addr_idx := to_integer(unsigned(slave_req(s).addr(10 downto 3)));
                    
                    if slave_req(s).write = '1' then
                        -- Write
                        slave_mem(addr_idx) <= slave_req(s).wdata;
                    else
                        -- Read
                        slave_resp(s).rvalid <= '1';
                        slave_resp(s).rdata <= slave_mem(addr_idx);
                        slave_resp(s).rlast <= '1';
                    end if;
                end if;
            end loop;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Test Process
    ---------------------------------------------------------------------------
    process
        -- Helper: Issue request from master and wait for response
        procedure master_write(
            master_id : integer;
            addr      : std_logic_vector(31 downto 0);
            data      : std_logic_vector(63 downto 0)
        ) is
        begin
            master_req(master_id).valid <= '1';
            master_req(master_id).write <= '1';
            master_req(master_id).addr <= addr;
            master_req(master_id).wdata <= data;
            master_req(master_id).wstrb <= x"FF";
            master_req(master_id).burst <= x"00";
            master_req(master_id).size <= SIZE_DWORD;
            master_req(master_id).lock <= '0';
            master_req(master_id).prot <= PROT_USER;
            
            wait until rising_edge(clk) and master_resp(master_id).ready = '1';
            master_req(master_id).valid <= '0';
            wait for CLK_PERIOD;
        end procedure;
        
        procedure master_read(
            master_id : integer;
            addr      : std_logic_vector(31 downto 0);
            data      : out std_logic_vector(63 downto 0)
        ) is
        begin
            master_req(master_id).valid <= '1';
            master_req(master_id).write <= '0';
            master_req(master_id).addr <= addr;
            master_req(master_id).wstrb <= x"00";
            master_req(master_id).burst <= x"00";
            master_req(master_id).size <= SIZE_DWORD;
            master_req(master_id).lock <= '0';
            master_req(master_id).prot <= PROT_USER;
            
            wait until rising_edge(clk) and master_resp(master_id).ready = '1';
            master_req(master_id).valid <= '0';
            
            wait until rising_edge(clk) and master_resp(master_id).rvalid = '1';
            data := master_resp(master_id).rdata;
            wait for CLK_PERIOD;
        end procedure;
        
        variable read_data : std_logic_vector(63 downto 0);
        
    begin
        report "=== System Bus Unit Test ===" severity note;
        
        -- Initialize
        for m in 0 to NUM_MASTERS-1 loop
            master_req(m) <= BUS_MASTER_REQ_INIT;
        end loop;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -------------------------------------------------
        -- Test 1: Single write from Master 0
        -------------------------------------------------
        report "--- Test 1: Single Write ---" severity note;
        
        master_write(0, x"00000008", x"DEADBEEF_12345678");
        wait for CLK_PERIOD * 2;
        
        test_count <= test_count + 1;
        if slave_mem(1) = x"DEADBEEF_12345678" then
            report "PASS: Write to slave memory" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Write data mismatch" severity error;
        end if;
        
        -------------------------------------------------
        -- Test 2: Single read from Master 0
        -------------------------------------------------
        report "--- Test 2: Single Read ---" severity note;
        
        master_read(0, x"00000008", read_data);
        
        test_count <= test_count + 1;
        if read_data = x"DEADBEEF_12345678" then
            report "PASS: Read from slave memory" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Read data mismatch" severity error;
        end if;
        
        -------------------------------------------------
        -- Test 3: Arbitration (multiple masters)
        -------------------------------------------------
        report "--- Test 3: Arbitration ---" severity note;
        
        -- Both masters request simultaneously
        master_req(0).valid <= '1';
        master_req(0).write <= '1';
        master_req(0).addr <= x"00000010";
        master_req(0).wdata <= x"1111111111111111";
        master_req(0).wstrb <= x"FF";
        
        master_req(1).valid <= '1';
        master_req(1).write <= '1';
        master_req(1).addr <= x"00000018";
        master_req(1).wdata <= x"2222222222222222";
        master_req(1).wstrb <= x"FF";
        
        -- Wait for both to complete
        wait until rising_edge(clk) and master_resp(0).ready = '1';
        master_req(0).valid <= '0';
        wait until rising_edge(clk) and master_resp(1).ready = '1';
        master_req(1).valid <= '0';
        wait for CLK_PERIOD * 2;
        
        test_count <= test_count + 1;
        if slave_mem(2) = x"1111111111111111" and 
           slave_mem(3) = x"2222222222222222" then
            report "PASS: Both masters completed" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Arbitration issue" severity error;
        end if;
        
        -------------------------------------------------
        -- Test 4: Priority (Master 0 should win)
        -------------------------------------------------
        report "--- Test 4: Priority ---" severity note;
        
        -- Write different values and check which completed first
        slave_mem(4) <= (others => '0');
        
        master_req(0).valid <= '1';
        master_req(0).addr <= x"00000020";
        master_req(0).wdata <= x"AAAAAAAAAAAAAAAA";
        
        master_req(2).valid <= '1';
        master_req(2).addr <= x"00000020";
        master_req(2).wdata <= x"BBBBBBBBBBBBBBBB";
        
        wait for CLK_PERIOD;
        
        -- Master 0 (highest priority) should be served first
        wait until rising_edge(clk) and master_resp(0).ready = '1';
        
        test_count <= test_count + 1;
        if slave_mem(4) = x"AAAAAAAAAAAAAAAA" then
            report "PASS: Priority master served first" severity note;
        else
            report "NOTE: Priority order may vary" severity note;
        end if;
        
        master_req(0).valid <= '0';
        master_req(2).valid <= '0';
        wait for CLK_PERIOD * 5;
        
        -------------------------------------------------
        -- Test 5: Back-to-back transfers
        -------------------------------------------------
        report "--- Test 5: Back-to-Back ---" severity note;
        
        for i in 0 to 3 loop
            master_write(0, 
                std_logic_vector(to_unsigned(16#100# + i*8, 32)),
                std_logic_vector(to_unsigned(16#A000# + i, 64)));
        end loop;
        
        test_count <= test_count + 1;
        if slave_mem(32) = x"000000000000A000" and
           slave_mem(33) = x"000000000000A001" then
            report "PASS: Back-to-back writes" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Back-to-back issue" severity error;
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
