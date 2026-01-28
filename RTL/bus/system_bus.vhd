-------------------------------------------------------------------------------
-- system_bus.vhd
-- Top-Level System Bus (Arbiter + Interconnect)
--
-- Provides a complete multi-master, multi-slave bus infrastructure.
-- Instantiates arbiter and interconnect as sub-components.
--
-- This file is shared between milo832 and m65832 projects.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.system_bus_pkg.all;

entity system_bus is
    generic (
        NUM_MASTERS     : integer := 6;
        NUM_SLAVES      : integer := 12;
        TIMEOUT_CYCLES  : integer := 256
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Master interfaces
        master_req      : in  master_req_array_t(0 to NUM_MASTERS-1);
        master_resp     : out master_resp_array_t(0 to NUM_MASTERS-1);
        
        -- Slave interfaces
        slave_req       : out slave_req_array_t(0 to NUM_SLAVES-1);
        slave_resp      : in  slave_resp_array_t(0 to NUM_SLAVES-1);
        
        -- QoS (optional)
        qos_config      : in  qos_array_t(0 to NUM_MASTERS-1) := (others => QOS_DEFAULT);
        
        -- Status
        busy            : out std_logic
    );
end entity system_bus;

architecture rtl of system_bus is

    -- Internal signals between arbiter and interconnect
    signal grant_valid : std_logic;
    signal grant_id    : integer range 0 to NUM_MASTERS-1;
    signal grant_req   : bus_master_req_t;
    signal grant_resp  : bus_master_resp_t;

begin

    ---------------------------------------------------------------------------
    -- Arbiter Instance
    ---------------------------------------------------------------------------
    u_arbiter : entity work.bus_arbiter
        generic map (
            NUM_MASTERS    => NUM_MASTERS,
            TIMEOUT_CYCLES => TIMEOUT_CYCLES
        )
        port map (
            clk         => clk,
            rst_n       => rst_n,
            master_req  => master_req,
            master_resp => master_resp,
            grant_valid => grant_valid,
            grant_id    => grant_id,
            grant_req   => grant_req,
            grant_resp  => grant_resp,
            qos_config  => qos_config,
            busy        => busy
        );
    
    ---------------------------------------------------------------------------
    -- Interconnect Instance
    ---------------------------------------------------------------------------
    u_interconnect : entity work.bus_interconnect
        generic map (
            NUM_SLAVES => NUM_SLAVES
        )
        port map (
            clk         => clk,
            rst_n       => rst_n,
            grant_valid => grant_valid,
            grant_req   => grant_req,
            grant_resp  => grant_resp,
            slave_req   => slave_req,
            slave_resp  => slave_resp
        );

end architecture rtl;
