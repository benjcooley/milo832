-------------------------------------------------------------------------------
-- shared_memory.vhd
-- 16KB Shared Memory with 32 Banks and Bank Conflict Detection
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

entity shared_memory is
    generic (
        SIZE_BYTES      : integer := 16384;     -- 16KB per SM
        NUM_BANKS       : integer := 32;        -- 32 Banks for Warp access
        CONFLICT_MODE   : integer := 2;         -- 0=ignore, 1=warn, 2=serialize
        BANK_ADDR_WIDTH : integer := 5          -- log2(NUM_BANKS) = 5 for 32 banks
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Request Interface (from LSU)
        req_valid       : in  std_logic;
        req_uid         : in  std_logic_vector(15 downto 0);
        req_mask        : in  std_logic_vector(NUM_BANKS-1 downto 0);
        req_we          : in  std_logic;
        req_addr        : in  std_logic_vector(NUM_BANKS*32-1 downto 0);  -- Flattened addresses
        req_wdata       : in  std_logic_vector(NUM_BANKS*32-1 downto 0);  -- Flattened write data
        
        -- Response Interface
        resp_rdata      : out std_logic_vector(NUM_BANKS*32-1 downto 0);  -- Flattened read data
        busy            : out std_logic;
        stall_cpu       : out std_logic;
        conflict_cycles : out std_logic_vector(7 downto 0)
    );
end entity shared_memory;

architecture rtl of shared_memory is

    -- Memory array (byte addressable)
    type mem_array_t is array (0 to SIZE_BYTES-1) of std_logic_vector(7 downto 0);
    signal mem : mem_array_t := (others => (others => '0'));
    
    -- State machine
    type state_t is (IDLE, REPLAY);
    signal state : state_t := IDLE;
    
    -- Conflict tracking
    signal pending_mask     : std_logic_vector(NUM_BANKS-1 downto 0);
    signal cycles_remaining : unsigned(7 downto 0);
    
    -- Request tracking
    signal last_serviced_uid : std_logic_vector(15 downto 0) := x"FFFF";
    signal current_uid       : std_logic_vector(15 downto 0);
    
    -- Latched request (for multi-cycle replay)
    signal latched_we       : std_logic;
    signal latched_addr     : std_logic_vector(NUM_BANKS*32-1 downto 0);
    signal latched_wdata    : std_logic_vector(NUM_BANKS*32-1 downto 0);
    
    -- Internal response data
    signal resp_rdata_i     : std_logic_vector(NUM_BANKS*32-1 downto 0);
    signal conflict_cycles_i : unsigned(7 downto 0);
    
    -- Helper function to extract address for lane i
    function get_lane_addr(addr_flat : std_logic_vector; lane : integer) return std_logic_vector is
    begin
        return addr_flat((lane+1)*32-1 downto lane*32);
    end function;
    
    -- Helper function to extract data for lane i
    function get_lane_data(data_flat : std_logic_vector; lane : integer) return std_logic_vector is
    begin
        return data_flat((lane+1)*32-1 downto lane*32);
    end function;
    
    -- Function to detect bank conflicts and return max conflicts per bank
    function detect_conflicts(
        mask : std_logic_vector(NUM_BANKS-1 downto 0);
        addr_flat : std_logic_vector(NUM_BANKS*32-1 downto 0)
    ) return unsigned is
        variable bank_id : integer;
        variable unique_count : integer;
        variable max_count : unsigned(7 downto 0);
        type count_array_t is array (0 to NUM_BANKS-1) of integer;
        variable counts : count_array_t := (others => 0);
        variable addr_i : std_logic_vector(31 downto 0);
    begin
        -- Count accesses per bank
        for i in 0 to NUM_BANKS-1 loop
            if mask(i) = '1' then
                addr_i := get_lane_addr(addr_flat, i);
                bank_id := to_integer(unsigned(addr_i(BANK_ADDR_WIDTH+1 downto 2)));
                if bank_id < NUM_BANKS then
                    counts(bank_id) := counts(bank_id) + 1;
                end if;
            end if;
        end loop;
        
        -- Find maximum
        max_count := to_unsigned(0, 8);
        for b in 0 to NUM_BANKS-1 loop
            if counts(b) > to_integer(max_count) then
                max_count := to_unsigned(counts(b), 8);
            end if;
        end loop;
        
        return max_count;
    end function;

begin

    -- Output assignments
    resp_rdata <= resp_rdata_i;
    busy <= '1' when state = REPLAY else '0';
    conflict_cycles <= std_logic_vector(conflict_cycles_i);
    
    -- Stall logic
    stall_cpu <= '1' when state = REPLAY else '0';
    
    -- Main state machine
    process(clk, rst_n)
        variable max_conflicts : unsigned(7 downto 0);
        variable bank_id : integer;
        variable byte_addr : integer;
        variable addr_i : std_logic_vector(31 downto 0);
        variable data_i : std_logic_vector(31 downto 0);
        variable bank_used : std_logic_vector(NUM_BANKS-1 downto 0);
        variable serviced : std_logic_vector(NUM_BANKS-1 downto 0);
        variable active_mask : std_logic_vector(NUM_BANKS-1 downto 0);
        variable active_addr : std_logic_vector(NUM_BANKS*32-1 downto 0);
        variable active_wdata : std_logic_vector(NUM_BANKS*32-1 downto 0);
        variable we : std_logic;
    begin
        if rst_n = '0' then
            state <= IDLE;
            pending_mask <= (others => '0');
            cycles_remaining <= (others => '0');
            conflict_cycles_i <= (others => '0');
            latched_we <= '0';
            latched_addr <= (others => '0');
            latched_wdata <= (others => '0');
            last_serviced_uid <= x"FFFF";
            current_uid <= (others => '0');
            resp_rdata_i <= (others => '0');
            
        elsif rising_edge(clk) then
            case state is
                when IDLE =>
                    if req_valid = '1' and (CONFLICT_MODE = 0 or req_uid /= last_serviced_uid) then
                        max_conflicts := detect_conflicts(req_mask, req_addr);
                        current_uid <= req_uid;
                        
                        -- Service threads (one per bank per cycle if conflicts)
                        bank_used := (others => '0');
                        serviced := (others => '0');
                        
                        for i in 0 to NUM_BANKS-1 loop
                            if req_mask(i) = '1' then
                                addr_i := get_lane_addr(req_addr, i);
                                bank_id := to_integer(unsigned(addr_i(BANK_ADDR_WIDTH+1 downto 2))) mod NUM_BANKS;
                                
                                -- Service if bank is free or ignoring conflicts
                                if CONFLICT_MODE = 0 or bank_used(bank_id) = '0' then
                                    byte_addr := to_integer(unsigned(addr_i)) mod SIZE_BYTES;
                                    
                                    if req_we = '1' then
                                        -- Write operation
                                        data_i := get_lane_data(req_wdata, i);
                                        mem(byte_addr)   <= data_i(7 downto 0);
                                        mem(byte_addr+1) <= data_i(15 downto 8);
                                        mem(byte_addr+2) <= data_i(23 downto 16);
                                        mem(byte_addr+3) <= data_i(31 downto 24);
                                    else
                                        -- Read operation
                                        resp_rdata_i((i+1)*32-1 downto i*32) <= 
                                            mem(byte_addr+3) & mem(byte_addr+2) & 
                                            mem(byte_addr+1) & mem(byte_addr);
                                    end if;
                                    
                                    serviced(i) := '1';
                                    bank_used(bank_id) := '1';
                                end if;
                            end if;
                        end loop;
                        
                        -- Check if we need replay cycles
                        if CONFLICT_MODE = 2 and max_conflicts > 1 then
                            latched_we <= req_we;
                            latched_addr <= req_addr;
                            latched_wdata <= req_wdata;
                            pending_mask <= req_mask and (not serviced);
                            cycles_remaining <= max_conflicts - 1;
                            conflict_cycles_i <= max_conflicts;
                            state <= REPLAY;
                        else
                            conflict_cycles_i <= to_unsigned(1, 8);
                            last_serviced_uid <= req_uid;
                        end if;
                    end if;
                    
                when REPLAY =>
                    -- Service remaining threads
                    bank_used := (others => '0');
                    serviced := (others => '0');
                    
                    for i in 0 to NUM_BANKS-1 loop
                        if pending_mask(i) = '1' then
                            addr_i := get_lane_addr(latched_addr, i);
                            bank_id := to_integer(unsigned(addr_i(BANK_ADDR_WIDTH+1 downto 2))) mod NUM_BANKS;
                            
                            if bank_used(bank_id) = '0' then
                                byte_addr := to_integer(unsigned(addr_i)) mod SIZE_BYTES;
                                
                                if latched_we = '1' then
                                    data_i := get_lane_data(latched_wdata, i);
                                    mem(byte_addr)   <= data_i(7 downto 0);
                                    mem(byte_addr+1) <= data_i(15 downto 8);
                                    mem(byte_addr+2) <= data_i(23 downto 16);
                                    mem(byte_addr+3) <= data_i(31 downto 24);
                                else
                                    resp_rdata_i((i+1)*32-1 downto i*32) <= 
                                        mem(byte_addr+3) & mem(byte_addr+2) & 
                                        mem(byte_addr+1) & mem(byte_addr);
                                end if;
                                
                                serviced(i) := '1';
                                bank_used(bank_id) := '1';
                            end if;
                        end if;
                    end loop;
                    
                    pending_mask <= pending_mask and (not serviced);
                    cycles_remaining <= cycles_remaining - 1;
                    
                    if cycles_remaining = 1 or (pending_mask and (not serviced)) = (pending_mask'range => '0') then
                        state <= IDLE;
                        last_serviced_uid <= current_uid;
                    end if;
            end case;
        end if;
    end process;

end architecture rtl;
