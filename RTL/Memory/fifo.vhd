-------------------------------------------------------------------------------
-- fifo.vhd
-- Generic FIFO (First-In, First-Out) Buffer
--
-- Based on SIMT-GPU-Core by Aritra Manna
-- Original: https://github.com/aritramanna/SIMT-GPU-Core
-- Translated to VHDL for Milo832 GPU project
--
-- Many thanks to Aritra Manna for creating and open-sourcing the excellent
-- SIMT-GPU-Core project, which served as the foundation for this implementation.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fifo is
    generic (
        DEPTH       : integer := 64;
        DATA_WIDTH  : integer := 16
    );
    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;
        
        -- Push interface
        push        : in  std_logic;
        data_in     : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        
        -- Pop interface
        pop         : in  std_logic;
        data_out    : out std_logic_vector(DATA_WIDTH-1 downto 0);
        
        -- Status
        full        : out std_logic;
        empty       : out std_logic;
        count       : out integer range 0 to DEPTH
    );
end entity fifo;

architecture rtl of fifo is

    -- Memory array
    type mem_array_t is array (0 to DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem : mem_array_t := (others => (others => '0'));
    
    -- Pointers
    signal write_ptr    : integer range 0 to DEPTH-1 := 0;
    signal read_ptr     : integer range 0 to DEPTH-1 := 0;
    signal item_count   : integer range 0 to DEPTH := 0;
    
    -- Status signals
    signal full_i       : std_logic;
    signal empty_i      : std_logic;

begin

    -- Status output
    full_i  <= '1' when item_count = DEPTH else '0';
    empty_i <= '1' when item_count = 0 else '0';
    
    full    <= full_i;
    empty   <= empty_i;
    count   <= item_count;
    
    -- Read data output (combinational)
    data_out <= mem(read_ptr);
    
    -- FIFO control process
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            write_ptr   <= 0;
            read_ptr    <= 0;
            item_count  <= 0;
            
        elsif rising_edge(clk) then
            -- Simultaneous push and pop
            if push = '1' and pop = '1' and full_i = '0' and empty_i = '0' then
                -- Write new data
                mem(write_ptr) <= data_in;
                
                -- Advance both pointers
                if write_ptr = DEPTH - 1 then
                    write_ptr <= 0;
                else
                    write_ptr <= write_ptr + 1;
                end if;
                
                if read_ptr = DEPTH - 1 then
                    read_ptr <= 0;
                else
                    read_ptr <= read_ptr + 1;
                end if;
                -- Count stays the same
                
            -- Push only
            elsif push = '1' and full_i = '0' then
                mem(write_ptr) <= data_in;
                
                if write_ptr = DEPTH - 1 then
                    write_ptr <= 0;
                else
                    write_ptr <= write_ptr + 1;
                end if;
                
                item_count <= item_count + 1;
                
            -- Pop only
            elsif pop = '1' and empty_i = '0' then
                if read_ptr = DEPTH - 1 then
                    read_ptr <= 0;
                else
                    read_ptr <= read_ptr + 1;
                end if;
                
                item_count <= item_count - 1;
            end if;
        end if;
    end process;

end architecture rtl;
