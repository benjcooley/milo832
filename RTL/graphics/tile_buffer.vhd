-------------------------------------------------------------------------------
-- tile_buffer.vhd
-- On-Chip Tile Color and Depth Buffer
-- Dual-port access for parallel ROP operations
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tile_buffer is
    generic (
        TILE_SIZE       : integer := 16;    -- 16 for DE2-115, 32 for KV260
        COLOR_BITS      : integer := 32;    -- RGBA8888
        DEPTH_BITS      : integer := 24
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Clear interface
        clear           : in  std_logic;
        clear_color     : in  std_logic_vector(COLOR_BITS-1 downto 0);
        clear_depth     : in  std_logic_vector(DEPTH_BITS-1 downto 0);
        clear_done      : out std_logic;
        
        -- Read port (for depth test)
        rd_x            : in  std_logic_vector(4 downto 0);   -- 0-31 max
        rd_y            : in  std_logic_vector(4 downto 0);
        rd_color        : out std_logic_vector(COLOR_BITS-1 downto 0);
        rd_depth        : out std_logic_vector(DEPTH_BITS-1 downto 0);
        
        -- Write port (for ROP output)
        wr_en           : in  std_logic;
        wr_x            : in  std_logic_vector(4 downto 0);
        wr_y            : in  std_logic_vector(4 downto 0);
        wr_color        : in  std_logic_vector(COLOR_BITS-1 downto 0);
        wr_depth        : in  std_logic_vector(DEPTH_BITS-1 downto 0);
        wr_color_mask   : in  std_logic_vector(3 downto 0);   -- RGBA write mask
        wr_depth_en     : in  std_logic;
        
        -- Readback interface (for tile writeback to framebuffer)
        readback_x      : in  std_logic_vector(4 downto 0);
        readback_y      : in  std_logic_vector(4 downto 0);
        readback_color  : out std_logic_vector(COLOR_BITS-1 downto 0);
        
        -- Dirty tracking (which pixels were written)
        dirty_mask      : out std_logic_vector(TILE_SIZE*TILE_SIZE-1 downto 0)
    );
end entity tile_buffer;

architecture rtl of tile_buffer is

    constant TILE_PIXELS : integer := TILE_SIZE * TILE_SIZE;
    constant ADDR_BITS : integer := 10;  -- Up to 32x32 = 1024 pixels
    
    -- Color buffer memory
    type color_mem_t is array (0 to TILE_PIXELS-1) of std_logic_vector(COLOR_BITS-1 downto 0);
    signal color_mem : color_mem_t := (others => (others => '0'));
    
    -- Depth buffer memory
    type depth_mem_t is array (0 to TILE_PIXELS-1) of std_logic_vector(DEPTH_BITS-1 downto 0);
    signal depth_mem : depth_mem_t := (others => (others => '1'));  -- Init to max depth
    
    -- Dirty mask register
    signal dirty_reg : std_logic_vector(TILE_PIXELS-1 downto 0) := (others => '0');
    
    -- Clear state
    signal clearing : std_logic := '0';
    signal clear_addr : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
    
    -- Address calculation
    function calc_addr(x, y : std_logic_vector) return integer is
    begin
        return to_integer(unsigned(y)) * TILE_SIZE + to_integer(unsigned(x));
    end function;

begin

    dirty_mask <= dirty_reg;
    
    -- Clear state machine
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            clearing <= '0';
            clear_addr <= (others => '0');
            clear_done <= '0';
        elsif rising_edge(clk) then
            clear_done <= '0';
            
            if clear = '1' and clearing = '0' then
                clearing <= '1';
                clear_addr <= (others => '0');
                dirty_reg <= (others => '0');
            elsif clearing = '1' then
                if clear_addr = TILE_PIXELS - 1 then
                    clearing <= '0';
                    clear_done <= '1';
                else
                    clear_addr <= clear_addr + 1;
                end if;
            end if;
        end if;
    end process;
    
    -- Color buffer write process
    process(clk)
        variable addr : integer;
        variable old_color, new_color : std_logic_vector(COLOR_BITS-1 downto 0);
    begin
        if rising_edge(clk) then
            if clearing = '1' then
                -- Clear mode
                color_mem(to_integer(clear_addr)) <= clear_color;
            elsif wr_en = '1' then
                -- Normal write with color mask
                addr := calc_addr(wr_x, wr_y);
                old_color := color_mem(addr);
                new_color := old_color;
                
                if wr_color_mask(3) = '1' then
                    new_color(31 downto 24) := wr_color(31 downto 24);
                end if;
                if wr_color_mask(2) = '1' then
                    new_color(23 downto 16) := wr_color(23 downto 16);
                end if;
                if wr_color_mask(1) = '1' then
                    new_color(15 downto 8) := wr_color(15 downto 8);
                end if;
                if wr_color_mask(0) = '1' then
                    new_color(7 downto 0) := wr_color(7 downto 0);
                end if;
                
                color_mem(addr) <= new_color;
                dirty_reg(addr) <= '1';
            end if;
        end if;
    end process;
    
    -- Depth buffer write process
    process(clk)
        variable addr : integer;
    begin
        if rising_edge(clk) then
            if clearing = '1' then
                depth_mem(to_integer(clear_addr)) <= clear_depth;
            elsif wr_en = '1' and wr_depth_en = '1' then
                addr := calc_addr(wr_x, wr_y);
                depth_mem(addr) <= wr_depth;
            end if;
        end if;
    end process;
    
    -- Read port (synchronous read)
    process(clk)
        variable addr : integer;
    begin
        if rising_edge(clk) then
            addr := calc_addr(rd_x, rd_y);
            rd_color <= color_mem(addr);
            rd_depth <= depth_mem(addr);
        end if;
    end process;
    
    -- Readback port (for DMA to framebuffer)
    process(clk)
        variable addr : integer;
    begin
        if rising_edge(clk) then
            addr := calc_addr(readback_x, readback_y);
            readback_color <= color_mem(addr);
        end if;
    end process;

end architecture rtl;
