-------------------------------------------------------------------------------
-- bus_arbiter.vhd
-- Multi-Master Bus Arbiter with Priority and Round-Robin
--
-- Features:
--   - Configurable number of masters
--   - Two-level arbitration: priority groups + round-robin within group
--   - Burst lock support
--   - QoS bandwidth/latency enforcement
--   - Fair scheduling to prevent starvation
--
-- This file is shared between milo832 and m65832 projects.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.system_bus_pkg.all;

entity bus_arbiter is
    generic (
        NUM_MASTERS     : integer := 6;
        TIMEOUT_CYCLES  : integer := 256   -- Max cycles before forced preemption
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Master requests
        master_req      : in  master_req_array_t(0 to NUM_MASTERS-1);
        master_resp     : out master_resp_array_t(0 to NUM_MASTERS-1);
        
        -- Granted master output (to interconnect)
        grant_valid     : out std_logic;
        grant_id        : out integer range 0 to NUM_MASTERS-1;
        grant_req       : out bus_master_req_t;
        grant_resp      : in  bus_master_resp_t;
        
        -- QoS configuration
        qos_config      : in  qos_array_t(0 to NUM_MASTERS-1);
        
        -- Status
        busy            : out std_logic
    );
end entity bus_arbiter;

architecture rtl of bus_arbiter is

    ---------------------------------------------------------------------------
    -- Arbiter State
    ---------------------------------------------------------------------------
    type arb_state_t is (
        ARB_IDLE,           -- No active transaction
        ARB_GRANT,          -- Grant issued, waiting for ready
        ARB_BURST,          -- In burst transaction
        ARB_LOCKED          -- Locked transaction (atomic)
    );
    
    signal state        : arb_state_t;
    signal current_master : integer range 0 to NUM_MASTERS-1;
    signal burst_count  : unsigned(7 downto 0);
    signal lock_held    : std_logic;
    
    -- Round-robin pointers per priority group
    signal rr_ptr       : integer range 0 to NUM_MASTERS-1;
    
    -- Timeout counter for starvation prevention
    signal timeout_cnt  : unsigned(15 downto 0);
    
    -- Request tracking
    signal pending      : std_logic_vector(NUM_MASTERS-1 downto 0);
    
    ---------------------------------------------------------------------------
    -- Priority Group Assignment
    ---------------------------------------------------------------------------
    type priority_array_t is array (0 to NUM_MASTERS-1) of integer range 0 to 3;
    
    -- Function to generate default priorities based on master count
    function init_priorities return priority_array_t is
        variable result : priority_array_t;
    begin
        for i in 0 to NUM_MASTERS-1 loop
            case i is
                when 0 => result(i) := 0;  -- CPU: highest
                when 1 => result(i) := 1;  -- GPU: high
                when 2 => result(i) := 1;  -- DMA: high
                when 3 => result(i) := 0;  -- Audio: realtime
                when 4 => result(i) := 0;  -- Video: realtime
                when 5 => result(i) := 3;  -- Debug: lowest
                when others => result(i) := 2;  -- Default: normal
            end case;
        end loop;
        return result;
    end function;
    
    constant MASTER_PRIORITY : priority_array_t := init_priorities;

begin

    ---------------------------------------------------------------------------
    -- Pending Request Detection
    ---------------------------------------------------------------------------
    process(master_req)
    begin
        for i in 0 to NUM_MASTERS-1 loop
            pending(i) <= master_req(i).valid;
        end loop;
    end process;
    
    ---------------------------------------------------------------------------
    -- Arbiter State Machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable next_master : integer range 0 to NUM_MASTERS-1;
        variable found       : boolean;
        variable check_prio  : integer;
    begin
        if rst_n = '0' then
            state <= ARB_IDLE;
            current_master <= 0;
            burst_count <= (others => '0');
            lock_held <= '0';
            rr_ptr <= 0;
            timeout_cnt <= (others => '0');
            grant_valid <= '0';
            grant_id <= 0;
            grant_req <= BUS_MASTER_REQ_INIT;
            busy <= '0';
            
            for i in 0 to NUM_MASTERS-1 loop
                master_resp(i) <= BUS_MASTER_RESP_INIT;
            end loop;
            
        elsif rising_edge(clk) then
            -- Default: clear transient signals
            for i in 0 to NUM_MASTERS-1 loop
                master_resp(i).ready <= '0';
                master_resp(i).rvalid <= '0';
                master_resp(i).rlast <= '0';
            end loop;
            
            case state is
                ---------------------------------------------------------------
                -- IDLE: Look for pending requests
                ---------------------------------------------------------------
                when ARB_IDLE =>
                    grant_valid <= '0';
                    busy <= '0';
                    
                    if pending /= (pending'range => '0') then
                        -- Two-level arbitration:
                        -- 1. Find highest priority group with pending request
                        -- 2. Round-robin within that group
                        
                        found := false;
                        
                        -- Check each priority level (0 = highest)
                        for prio in 0 to 3 loop
                            if not found then
                                -- Check masters in round-robin order starting from rr_ptr
                                for offset in 0 to NUM_MASTERS-1 loop
                                    next_master := (rr_ptr + offset) mod NUM_MASTERS;
                                    
                                    if pending(next_master) = '1' and 
                                       MASTER_PRIORITY(next_master) = prio then
                                        found := true;
                                        current_master <= next_master;
                                        exit;
                                    end if;
                                end loop;
                            end if;
                        end loop;
                        
                        if found then
                            state <= ARB_GRANT;
                            busy <= '1';
                        end if;
                    end if;
                
                ---------------------------------------------------------------
                -- GRANT: Issue grant, wait for slave ready
                ---------------------------------------------------------------
                when ARB_GRANT =>
                    grant_valid <= '1';
                    grant_id <= current_master;
                    grant_req <= master_req(current_master);
                    
                    if grant_resp.ready = '1' then
                        -- Request accepted
                        master_resp(current_master).ready <= '1';
                        
                        if master_req(current_master).lock = '1' then
                            -- Locked (atomic) transaction
                            state <= ARB_LOCKED;
                            lock_held <= '1';
                        elsif unsigned(master_req(current_master).burst) > 0 then
                            -- Burst transaction
                            state <= ARB_BURST;
                            burst_count <= unsigned(master_req(current_master).burst);
                        else
                            -- Single transfer, wait for response
                            if master_req(current_master).write = '0' then
                                -- Read: wait for data
                                state <= ARB_BURST;  -- Reuse burst state for wait
                                burst_count <= (others => '0');
                            else
                                -- Write: done
                                rr_ptr <= (current_master + 1) mod NUM_MASTERS;
                                state <= ARB_IDLE;
                            end if;
                        end if;
                    end if;
                
                ---------------------------------------------------------------
                -- BURST: Handle multi-beat transaction
                ---------------------------------------------------------------
                when ARB_BURST =>
                    grant_valid <= '1';
                    grant_id <= current_master;
                    grant_req <= master_req(current_master);
                    
                    -- Forward read response
                    if grant_resp.rvalid = '1' then
                        master_resp(current_master).rvalid <= '1';
                        master_resp(current_master).rdata <= grant_resp.rdata;
                        master_resp(current_master).error <= grant_resp.error;
                        
                        if grant_resp.rlast = '1' or burst_count = 0 then
                            master_resp(current_master).rlast <= '1';
                            rr_ptr <= (current_master + 1) mod NUM_MASTERS;
                            state <= ARB_IDLE;
                        else
                            burst_count <= burst_count - 1;
                        end if;
                    end if;
                    
                    -- Handle write bursts
                    if master_req(current_master).write = '1' and grant_resp.ready = '1' then
                        master_resp(current_master).ready <= '1';
                        
                        if burst_count = 0 then
                            rr_ptr <= (current_master + 1) mod NUM_MASTERS;
                            state <= ARB_IDLE;
                        else
                            burst_count <= burst_count - 1;
                        end if;
                    end if;
                    
                    -- Timeout protection
                    timeout_cnt <= timeout_cnt + 1;
                    if timeout_cnt >= TIMEOUT_CYCLES then
                        -- Force release (slave not responding)
                        master_resp(current_master).error <= '1';
                        state <= ARB_IDLE;
                        timeout_cnt <= (others => '0');
                    end if;
                
                ---------------------------------------------------------------
                -- LOCKED: Atomic transaction (hold bus)
                ---------------------------------------------------------------
                when ARB_LOCKED =>
                    grant_valid <= '1';
                    grant_id <= current_master;
                    grant_req <= master_req(current_master);
                    
                    -- Stay locked until master releases
                    if master_req(current_master).lock = '0' or 
                       master_req(current_master).valid = '0' then
                        lock_held <= '0';
                        rr_ptr <= (current_master + 1) mod NUM_MASTERS;
                        state <= ARB_IDLE;
                    end if;
                    
                    -- Forward responses
                    if grant_resp.ready = '1' then
                        master_resp(current_master).ready <= '1';
                    end if;
                    
                    if grant_resp.rvalid = '1' then
                        master_resp(current_master).rvalid <= '1';
                        master_resp(current_master).rdata <= grant_resp.rdata;
                        master_resp(current_master).rlast <= grant_resp.rlast;
                    end if;
                    
                when others =>
                    state <= ARB_IDLE;
            end case;
        end if;
    end process;

end architecture rtl;
