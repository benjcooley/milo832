-------------------------------------------------------------------------------
-- boot_rom.vhd
-- Boot ROM Bus Slave
--
-- Simple ROM for boot code. Can be initialized from file or constant.
-- Supports single-cycle reads, no bursts.
--
-- This file is shared between milo832 and m65832 projects.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.system_bus_pkg.all;

entity boot_rom is
    generic (
        ROM_SIZE_BYTES  : integer := 65536;  -- 64KB
        ROM_INIT_FILE   : string := ""       -- Optional hex file
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Bus slave interface
        bus_req         : in  bus_slave_req_t;
        bus_resp        : out bus_slave_resp_t
    );
end entity boot_rom;

architecture rtl of boot_rom is

    constant ROM_DEPTH : integer := ROM_SIZE_BYTES / 8;  -- 64-bit words
    constant ADDR_BITS : integer := 13;  -- log2(8192)
    
    type rom_t is array (0 to ROM_DEPTH-1) of std_logic_vector(63 downto 0);
    
    -- ROM initialization function
    impure function init_rom return rom_t is
        variable rom : rom_t := (others => (others => '0'));
        file f : text;
        variable line_v : line;
        variable word : std_logic_vector(63 downto 0);
        variable i : integer := 0;
    begin
        if ROM_INIT_FILE /= "" then
            file_open(f, ROM_INIT_FILE, read_mode);
            while not endfile(f) and i < ROM_DEPTH loop
                readline(f, line_v);
                hread(line_v, word);
                rom(i) := word;
                i := i + 1;
            end loop;
            file_close(f);
        else
            -- Default boot code: jump to RAM
            rom(0) := x"00000000_00010000";  -- Jump target
            rom(1) := x"0000000000000000";   -- NOP
        end if;
        return rom;
    end function;
    
    signal rom : rom_t := init_rom;
    
    signal read_addr : unsigned(ADDR_BITS-1 downto 0);
    signal read_valid : std_logic;

begin

    ---------------------------------------------------------------------------
    -- ROM Read Logic
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            bus_resp <= BUS_SLAVE_RESP_INIT;
            read_valid <= '0';
            read_addr <= (others => '0');
            
        elsif rising_edge(clk) then
            bus_resp.rvalid <= '0';
            bus_resp.rlast <= '0';
            bus_resp.error <= '0';
            
            if bus_req.sel = '1' then
                bus_resp.ready <= '1';
                
                if bus_req.write = '1' then
                    -- ROM is read-only, generate error
                    bus_resp.error <= '1';
                else
                    -- Read
                    read_addr <= unsigned(bus_req.addr(ADDR_BITS+2 downto 3));
                    read_valid <= '1';
                end if;
            else
                bus_resp.ready <= '1';  -- Always ready when not selected
            end if;
            
            -- Output read data on next cycle
            if read_valid = '1' then
                if to_integer(read_addr) < ROM_DEPTH then
                    bus_resp.rdata <= rom(to_integer(read_addr));
                else
                    bus_resp.rdata <= (others => '0');
                    bus_resp.error <= '1';
                end if;
                bus_resp.rvalid <= '1';
                bus_resp.rlast <= '1';
                read_valid <= '0';
            end if;
        end if;
    end process;

end architecture rtl;
