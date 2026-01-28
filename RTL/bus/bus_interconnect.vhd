-------------------------------------------------------------------------------
-- bus_interconnect.vhd
-- Shared Bus Interconnect with Address Decode
--
-- Features:
--   - Single granted master to multiple slaves
--   - Address decode and slave select
--   - Response mux
--   - Decode error generation
--
-- This file is shared between milo832 and m65832 projects.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.system_bus_pkg.all;

entity bus_interconnect is
    generic (
        NUM_SLAVES      : integer := 12
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- From arbiter (granted master)
        grant_valid     : in  std_logic;
        grant_req       : in  bus_master_req_t;
        grant_resp      : out bus_master_resp_t;
        
        -- To slaves
        slave_req       : out slave_req_array_t(0 to NUM_SLAVES-1);
        slave_resp      : in  slave_resp_array_t(0 to NUM_SLAVES-1)
    );
end entity bus_interconnect;

architecture rtl of bus_interconnect is

    signal selected_slave : integer range 0 to NUM_SLAVES-1;
    signal slave_valid    : std_logic;
    signal decode_error   : std_logic;
    
    -- Pipeline register for response timing
    signal resp_slave     : integer range 0 to NUM_SLAVES-1;
    signal resp_pending   : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Address Decode (Combinational)
    ---------------------------------------------------------------------------
    process(grant_valid, grant_req)
        variable slave_idx : integer;
    begin
        slave_valid <= '0';
        decode_error <= '0';
        selected_slave <= 0;
        
        if grant_valid = '1' and grant_req.valid = '1' then
            slave_idx := addr_to_slave(grant_req.addr);
            
            if slave_idx < NUM_SLAVES then
                selected_slave <= slave_idx;
                slave_valid <= '1';
            else
                -- Invalid address
                decode_error <= '1';
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Slave Request Generation
    ---------------------------------------------------------------------------
    process(grant_valid, grant_req, slave_valid, selected_slave)
    begin
        -- Default: deselect all slaves
        for i in 0 to NUM_SLAVES-1 loop
            slave_req(i) <= BUS_SLAVE_REQ_INIT;
        end loop;
        
        -- Select the addressed slave
        if slave_valid = '1' then
            slave_req(selected_slave).sel <= '1';
            slave_req(selected_slave).write <= grant_req.write;
            slave_req(selected_slave).addr <= grant_req.addr;
            slave_req(selected_slave).wdata <= grant_req.wdata;
            slave_req(selected_slave).wstrb <= grant_req.wstrb;
            slave_req(selected_slave).burst <= grant_req.burst;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Response Tracking
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            resp_slave <= 0;
            resp_pending <= '0';
        elsif rising_edge(clk) then
            if slave_valid = '1' then
                resp_slave <= selected_slave;
                resp_pending <= '1';
            elsif grant_resp.rlast = '1' or grant_resp.ready = '1' then
                resp_pending <= '0';
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Response Mux
    ---------------------------------------------------------------------------
    process(slave_valid, selected_slave, slave_resp, decode_error, 
            resp_pending, resp_slave, grant_req)
        variable resp_idx : integer;
    begin
        grant_resp <= BUS_MASTER_RESP_INIT;
        
        if decode_error = '1' then
            -- Address decode error
            grant_resp.ready <= '1';
            grant_resp.error <= '1';
            if grant_req.write = '0' then
                grant_resp.rvalid <= '1';
                grant_resp.rlast <= '1';
            end if;
        elsif slave_valid = '1' then
            -- Forward slave response
            resp_idx := selected_slave;
            grant_resp.ready <= slave_resp(resp_idx).ready;
            grant_resp.rvalid <= slave_resp(resp_idx).rvalid;
            grant_resp.rdata <= slave_resp(resp_idx).rdata;
            grant_resp.error <= slave_resp(resp_idx).error;
            grant_resp.rlast <= slave_resp(resp_idx).rlast;
        elsif resp_pending = '1' then
            -- Response from previously selected slave (pipelined)
            grant_resp.rvalid <= slave_resp(resp_slave).rvalid;
            grant_resp.rdata <= slave_resp(resp_slave).rdata;
            grant_resp.error <= slave_resp(resp_slave).error;
            grant_resp.rlast <= slave_resp(resp_slave).rlast;
        end if;
    end process;

end architecture rtl;
