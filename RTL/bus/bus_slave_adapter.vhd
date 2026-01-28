-------------------------------------------------------------------------------
-- bus_slave_adapter.vhd
-- Simple Slave Adapter: Converts 64-bit bus to 32-bit register interface
--
-- Use this to connect simple peripherals with 32-bit register interfaces
-- to the 64-bit system bus.
--
-- This file is shared between milo832 and m65832 projects.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.system_bus_pkg.all;

entity bus_slave_adapter is
    generic (
        BASE_ADDR       : std_logic_vector(31 downto 0) := x"10000000";
        ADDR_BITS       : integer := 12   -- Address bits within peripheral (4KB)
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Bus slave interface (64-bit)
        bus_req         : in  bus_slave_req_t;
        bus_resp        : out bus_slave_resp_t;
        
        -- Register interface (32-bit)
        reg_addr        : out std_logic_vector(ADDR_BITS-1 downto 0);
        reg_write       : out std_logic;
        reg_wdata       : out std_logic_vector(31 downto 0);
        reg_wstrb       : out std_logic_vector(3 downto 0);
        reg_rdata       : in  std_logic_vector(31 downto 0);
        reg_ready       : in  std_logic := '1';  -- Optional wait state
        reg_error       : in  std_logic := '0'   -- Optional error
    );
end entity bus_slave_adapter;

architecture rtl of bus_slave_adapter is

    signal selected     : std_logic;
    signal addr_low     : std_logic;  -- 0 = lower 32 bits, 1 = upper 32 bits
    signal read_pending : std_logic;
    signal read_data    : std_logic_vector(31 downto 0);

begin

    selected <= bus_req.sel;
    addr_low <= bus_req.addr(2);  -- Bit 2 selects 32-bit half
    
    ---------------------------------------------------------------------------
    -- Address and Write Data
    ---------------------------------------------------------------------------
    reg_addr <= bus_req.addr(ADDR_BITS+1 downto 2);  -- Word-aligned
    reg_write <= bus_req.sel and bus_req.write;
    
    -- Select 32-bit portion of 64-bit write data
    process(addr_low, bus_req.wdata, bus_req.wstrb)
    begin
        if addr_low = '0' then
            reg_wdata <= bus_req.wdata(31 downto 0);
            reg_wstrb <= bus_req.wstrb(3 downto 0);
        else
            reg_wdata <= bus_req.wdata(63 downto 32);
            reg_wstrb <= bus_req.wstrb(7 downto 4);
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Read Response
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            read_pending <= '0';
            read_data <= (others => '0');
        elsif rising_edge(clk) then
            if selected = '1' and bus_req.write = '0' and reg_ready = '1' then
                read_pending <= '1';
                read_data <= reg_rdata;
            else
                read_pending <= '0';
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Bus Response
    ---------------------------------------------------------------------------
    process(selected, bus_req, reg_ready, reg_error, read_pending, read_data, addr_low)
    begin
        bus_resp <= BUS_SLAVE_RESP_INIT;
        
        if selected = '1' then
            bus_resp.ready <= reg_ready;
            bus_resp.error <= reg_error;
            
            if bus_req.write = '0' then
                -- Read response
                bus_resp.rvalid <= read_pending;
                bus_resp.rlast <= read_pending;
                
                -- Place 32-bit data in correct half of 64-bit response
                if addr_low = '0' then
                    bus_resp.rdata(31 downto 0) <= read_data;
                    bus_resp.rdata(63 downto 32) <= (others => '0');
                else
                    bus_resp.rdata(31 downto 0) <= (others => '0');
                    bus_resp.rdata(63 downto 32) <= read_data;
                end if;
            else
                -- Write response (immediate)
                bus_resp.rlast <= reg_ready;
            end if;
        end if;
    end process;

end architecture rtl;
