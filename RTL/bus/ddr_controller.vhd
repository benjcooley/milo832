-------------------------------------------------------------------------------
-- ddr_controller.vhd
-- DDR Memory Controller Bus Slave
--
-- Wraps external DDR interface for system bus.
-- Supports burst transfers and provides simple interface to DDR PHY.
--
-- Note: Actual DDR PHY is platform-specific (Xilinx MIG, Intel DDR IP).
-- This module provides the bus interface logic.
--
-- This file is shared between milo832 and m65832 projects.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.system_bus_pkg.all;

entity ddr_controller is
    generic (
        -- Memory configuration
        DDR_ADDR_WIDTH  : integer := 27;  -- 128MB addressable
        DDR_DATA_WIDTH  : integer := 64;
        BURST_LENGTH    : integer := 8;   -- DDR burst length
        
        -- Timing (in clock cycles at memory clock)
        CAS_LATENCY     : integer := 3;
        WRITE_LATENCY   : integer := 2
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Bus slave interface
        bus_req         : in  bus_slave_req_t;
        bus_resp        : out bus_slave_resp_t;
        
        -- DDR PHY interface (directly connect to external memory)
        ddr_addr        : out std_logic_vector(DDR_ADDR_WIDTH-1 downto 0);
        ddr_ba          : out std_logic_vector(2 downto 0);   -- Bank address
        ddr_cas_n       : out std_logic;
        ddr_ras_n       : out std_logic;
        ddr_we_n        : out std_logic;
        ddr_cs_n        : out std_logic;
        ddr_cke         : out std_logic;
        ddr_odt         : out std_logic;
        ddr_dm          : out std_logic_vector(DDR_DATA_WIDTH/8-1 downto 0);
        ddr_dq          : inout std_logic_vector(DDR_DATA_WIDTH-1 downto 0);
        ddr_dqs         : inOut std_logic_vector(DDR_DATA_WIDTH/8-1 downto 0);
        
        -- Status
        init_done       : out std_logic;
        busy            : out std_logic
    );
end entity ddr_controller;

architecture rtl of ddr_controller is

    ---------------------------------------------------------------------------
    -- DDR Controller State
    ---------------------------------------------------------------------------
    type ddr_state_t is (
        DDR_INIT,           -- Power-up initialization
        DDR_IDLE,           -- Waiting for request
        DDR_ACTIVATE,       -- Row activate
        DDR_READ,           -- Read command
        DDR_READ_WAIT,      -- Wait for CAS latency
        DDR_READ_DATA,      -- Receive read data
        DDR_WRITE,          -- Write command
        DDR_WRITE_DATA,     -- Send write data
        DDR_PRECHARGE       -- Row precharge
    );
    
    signal state        : ddr_state_t;
    signal next_state   : ddr_state_t;
    
    -- Timing counters
    signal wait_counter : unsigned(7 downto 0);
    signal burst_counter : unsigned(7 downto 0);
    
    -- Address decode
    signal row_addr     : std_logic_vector(13 downto 0);
    signal col_addr     : std_logic_vector(9 downto 0);
    signal bank_addr    : std_logic_vector(2 downto 0);
    
    -- Data path
    signal write_data   : std_logic_vector(DDR_DATA_WIDTH-1 downto 0);
    signal read_data    : std_logic_vector(DDR_DATA_WIDTH-1 downto 0);
    signal data_valid   : std_logic;
    
    -- Initialization sequence counter
    signal init_counter : unsigned(15 downto 0);
    
    -- Open row tracking (one per bank for efficiency)
    type open_row_t is array (0 to 7) of std_logic_vector(13 downto 0);
    signal open_row     : open_row_t;
    signal row_valid    : std_logic_vector(7 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Address Decode
    ---------------------------------------------------------------------------
    -- Map bus address to DDR row/column/bank
    -- Typical mapping: [row:14][bank:3][col:10]
    row_addr  <= bus_req.addr(26 downto 13);
    bank_addr <= bus_req.addr(12 downto 10);
    col_addr  <= bus_req.addr(9 downto 0);
    
    ---------------------------------------------------------------------------
    -- DDR State Machine
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state <= DDR_INIT;
            init_counter <= (others => '0');
            wait_counter <= (others => '0');
            burst_counter <= (others => '0');
            row_valid <= (others => '0');
            init_done <= '0';
            busy <= '1';
            
            -- Default command: NOP
            ddr_cs_n <= '1';
            ddr_ras_n <= '1';
            ddr_cas_n <= '1';
            ddr_we_n <= '1';
            ddr_cke <= '0';
            ddr_odt <= '0';
            
            bus_resp <= BUS_SLAVE_RESP_INIT;
            
        elsif rising_edge(clk) then
            -- Default: NOP
            ddr_cs_n <= '0';
            ddr_ras_n <= '1';
            ddr_cas_n <= '1';
            ddr_we_n <= '1';
            
            bus_resp.ready <= '0';
            bus_resp.rvalid <= '0';
            bus_resp.rlast <= '0';
            bus_resp.error <= '0';
            
            case state is
                -----------------------------------------------------------
                -- INIT: DDR initialization sequence
                -----------------------------------------------------------
                when DDR_INIT =>
                    busy <= '1';
                    ddr_cke <= '0';
                    init_counter <= init_counter + 1;
                    
                    -- Simplified init (real DDR needs proper MRS sequence)
                    if init_counter = x"0100" then
                        ddr_cke <= '1';
                    elsif init_counter = x"0200" then
                        -- Precharge all
                        ddr_ras_n <= '0';
                        ddr_we_n <= '0';
                    elsif init_counter = x"0300" then
                        -- Load mode register
                        ddr_ras_n <= '0';
                        ddr_cas_n <= '0';
                        ddr_we_n <= '0';
                    elsif init_counter >= x"0400" then
                        init_done <= '1';
                        state <= DDR_IDLE;
                    end if;
                
                -----------------------------------------------------------
                -- IDLE: Wait for bus request
                -----------------------------------------------------------
                when DDR_IDLE =>
                    busy <= '0';
                    
                    if bus_req.sel = '1' then
                        busy <= '1';
                        
                        -- Check if row is already open
                        if row_valid(to_integer(unsigned(bank_addr))) = '1' and
                           open_row(to_integer(unsigned(bank_addr))) = row_addr then
                            -- Row hit: go directly to read/write
                            if bus_req.write = '1' then
                                state <= DDR_WRITE;
                            else
                                state <= DDR_READ;
                            end if;
                        else
                            -- Row miss: need to activate
                            state <= DDR_ACTIVATE;
                        end if;
                    end if;
                
                -----------------------------------------------------------
                -- ACTIVATE: Open row
                -----------------------------------------------------------
                when DDR_ACTIVATE =>
                    -- Issue ACTIVATE command
                    ddr_ras_n <= '0';
                    ddr_ba <= bank_addr;
                    ddr_addr(13 downto 0) <= row_addr;
                    
                    -- Track open row
                    open_row(to_integer(unsigned(bank_addr))) <= row_addr;
                    row_valid(to_integer(unsigned(bank_addr))) <= '1';
                    
                    -- Wait tRCD
                    wait_counter <= to_unsigned(3, 8);  -- Simplified timing
                    state <= DDR_READ_WAIT;
                    
                    if bus_req.write = '1' then
                        next_state <= DDR_WRITE;
                    else
                        next_state <= DDR_READ;
                    end if;
                
                -----------------------------------------------------------
                -- READ: Issue read command
                -----------------------------------------------------------
                when DDR_READ =>
                    ddr_cas_n <= '0';
                    ddr_ba <= bank_addr;
                    ddr_addr(9 downto 0) <= col_addr;
                    
                    wait_counter <= to_unsigned(CAS_LATENCY, 8);
                    burst_counter <= unsigned(bus_req.burst);
                    state <= DDR_READ_WAIT;
                    next_state <= DDR_READ_DATA;
                    
                    bus_resp.ready <= '1';
                
                -----------------------------------------------------------
                -- READ_WAIT: Wait for CAS latency or tRCD
                -----------------------------------------------------------
                when DDR_READ_WAIT =>
                    if wait_counter > 0 then
                        wait_counter <= wait_counter - 1;
                    else
                        state <= next_state;
                    end if;
                
                -----------------------------------------------------------
                -- READ_DATA: Receive data from DDR
                -----------------------------------------------------------
                when DDR_READ_DATA =>
                    bus_resp.rvalid <= '1';
                    bus_resp.rdata <= ddr_dq;  -- Would need proper DQS timing
                    
                    if burst_counter = 0 then
                        bus_resp.rlast <= '1';
                        state <= DDR_IDLE;
                    else
                        burst_counter <= burst_counter - 1;
                    end if;
                
                -----------------------------------------------------------
                -- WRITE: Issue write command
                -----------------------------------------------------------
                when DDR_WRITE =>
                    ddr_cas_n <= '0';
                    ddr_we_n <= '0';
                    ddr_ba <= bank_addr;
                    ddr_addr(9 downto 0) <= col_addr;
                    
                    burst_counter <= unsigned(bus_req.burst);
                    state <= DDR_WRITE_DATA;
                    
                    bus_resp.ready <= '1';
                
                -----------------------------------------------------------
                -- WRITE_DATA: Send data to DDR
                -----------------------------------------------------------
                when DDR_WRITE_DATA =>
                    -- Drive data (simplified - real DDR needs DQS)
                    ddr_dm <= not bus_req.wstrb;
                    
                    if burst_counter = 0 then
                        state <= DDR_IDLE;
                    else
                        burst_counter <= burst_counter - 1;
                        bus_resp.ready <= '1';
                    end if;
                
                -----------------------------------------------------------
                -- PRECHARGE: Close row (used for refresh or bank conflict)
                -----------------------------------------------------------
                when DDR_PRECHARGE =>
                    ddr_ras_n <= '0';
                    ddr_we_n <= '0';
                    -- A10 high = precharge all banks
                    ddr_addr(10) <= '1';
                    
                    row_valid <= (others => '0');
                    wait_counter <= to_unsigned(3, 8);  -- tRP
                    next_state <= DDR_IDLE;
                    state <= DDR_READ_WAIT;
                
                when others =>
                    state <= DDR_IDLE;
            end case;
        end if;
    end process;
    
    -- Bidirectional data (simplified)
    ddr_dq <= bus_req.wdata when state = DDR_WRITE_DATA else (others => 'Z');

end architecture rtl;
