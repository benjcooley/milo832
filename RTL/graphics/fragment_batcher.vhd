-------------------------------------------------------------------------------
-- fragment_batcher.vhd
-- Fragment Collection and Warp Dispatch
-- Batches fragments into groups of 32 for SIMT execution
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.simt_pkg.all;

entity fragment_batcher is
    generic (
        WARP_SIZE       : integer := 32
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Fragment input (from rasterizer)
        frag_valid      : in  std_logic;
        frag_ready      : out std_logic;
        frag_x          : in  std_logic_vector(15 downto 0);
        frag_y          : in  std_logic_vector(15 downto 0);
        frag_z          : in  std_logic_vector(23 downto 0);
        frag_u          : in  std_logic_vector(31 downto 0);
        frag_v          : in  std_logic_vector(31 downto 0);
        frag_r          : in  std_logic_vector(7 downto 0);
        frag_g          : in  std_logic_vector(7 downto 0);
        frag_b          : in  std_logic_vector(7 downto 0);
        frag_a          : in  std_logic_vector(7 downto 0);
        
        -- End of primitive signal (flush partial warp)
        end_primitive   : in  std_logic;
        
        -- Warp output (to SIMT shader dispatch)
        warp_valid      : out std_logic;
        warp_ready      : in  std_logic;
        warp_mask       : out std_logic_vector(WARP_SIZE-1 downto 0);
        warp_count      : out std_logic_vector(5 downto 0);  -- Number of valid fragments
        
        -- Per-thread fragment data
        warp_x          : out std_logic_vector(WARP_SIZE*16-1 downto 0);
        warp_y          : out std_logic_vector(WARP_SIZE*16-1 downto 0);
        warp_z          : out std_logic_vector(WARP_SIZE*24-1 downto 0);
        warp_u          : out std_logic_vector(WARP_SIZE*32-1 downto 0);
        warp_v          : out std_logic_vector(WARP_SIZE*32-1 downto 0);
        warp_color      : out std_logic_vector(WARP_SIZE*32-1 downto 0);
        
        -- Status
        fragments_in    : out std_logic_vector(31 downto 0);
        warps_out       : out std_logic_vector(31 downto 0)
    );
end entity fragment_batcher;

architecture rtl of fragment_batcher is

    -- Fragment storage arrays
    type coord_array_t is array (0 to WARP_SIZE-1) of std_logic_vector(15 downto 0);
    type depth_array_t is array (0 to WARP_SIZE-1) of std_logic_vector(23 downto 0);
    type uv_array_t is array (0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    type color_array_t is array (0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    
    signal store_x, store_y : coord_array_t;
    signal store_z : depth_array_t;
    signal store_u, store_v : uv_array_t;
    signal store_color : color_array_t;
    signal store_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    
    -- Current write position
    signal write_ptr : unsigned(5 downto 0);  -- 0-31
    
    -- State
    type state_t is (COLLECTING, DISPATCHING);
    signal state : state_t := COLLECTING;
    
    -- Statistics
    signal frag_counter : unsigned(31 downto 0);
    signal warp_counter : unsigned(31 downto 0);

begin

    fragments_in <= std_logic_vector(frag_counter);
    warps_out <= std_logic_vector(warp_counter);
    
    -- Ready to accept fragments when collecting and not full
    frag_ready <= '1' when state = COLLECTING and write_ptr < WARP_SIZE else '0';
    
    process(clk, rst_n)
        variable color_packed : std_logic_vector(31 downto 0);
    begin
        if rst_n = '0' then
            state <= COLLECTING;
            write_ptr <= (others => '0');
            store_mask <= (others => '0');
            warp_valid <= '0';
            frag_counter <= (others => '0');
            warp_counter <= (others => '0');
            
        elsif rising_edge(clk) then
            case state is
                when COLLECTING =>
                    warp_valid <= '0';
                    
                    -- Accept incoming fragment
                    if frag_valid = '1' and write_ptr < WARP_SIZE then
                        store_x(to_integer(write_ptr)) <= frag_x;
                        store_y(to_integer(write_ptr)) <= frag_y;
                        store_z(to_integer(write_ptr)) <= frag_z;
                        store_u(to_integer(write_ptr)) <= frag_u;
                        store_v(to_integer(write_ptr)) <= frag_v;
                        
                        color_packed := frag_r & frag_g & frag_b & frag_a;
                        store_color(to_integer(write_ptr)) <= color_packed;
                        
                        store_mask(to_integer(write_ptr)) <= '1';
                        write_ptr <= write_ptr + 1;
                        frag_counter <= frag_counter + 1;
                    end if;
                    
                    -- Check if warp is full or primitive ended
                    if write_ptr = WARP_SIZE or (end_primitive = '1' and write_ptr > 0) then
                        state <= DISPATCHING;
                    end if;
                
                when DISPATCHING =>
                    -- Output the collected warp
                    warp_valid <= '1';
                    warp_mask <= store_mask;
                    warp_count <= std_logic_vector(write_ptr);
                    
                    -- Pack arrays into wide vectors
                    for i in 0 to WARP_SIZE-1 loop
                        warp_x((i+1)*16-1 downto i*16) <= store_x(i);
                        warp_y((i+1)*16-1 downto i*16) <= store_y(i);
                        warp_z((i+1)*24-1 downto i*24) <= store_z(i);
                        warp_u((i+1)*32-1 downto i*32) <= store_u(i);
                        warp_v((i+1)*32-1 downto i*32) <= store_v(i);
                        warp_color((i+1)*32-1 downto i*32) <= store_color(i);
                    end loop;
                    
                    if warp_ready = '1' then
                        warp_valid <= '0';
                        warp_counter <= warp_counter + 1;
                        
                        -- Reset for next batch
                        write_ptr <= (others => '0');
                        store_mask <= (others => '0');
                        state <= COLLECTING;
                    end if;
                    
            end case;
        end if;
    end process;

end architecture rtl;
