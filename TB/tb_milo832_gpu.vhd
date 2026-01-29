-------------------------------------------------------------------------------
-- tb_milo832_gpu.vhd
-- Testbench for Milo832 GPU Top-Level
--
-- Verifies basic GPU integration: command processor, state management, status
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_milo832_gpu is
end entity tb_milo832_gpu;

architecture sim of tb_milo832_gpu is

    constant CLK_PERIOD : time := 10 ns;
    
    signal clk : std_logic := '0';
    signal rst_n : std_logic := '0';
    
    -- Bus interface
    signal bus_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal bus_wr_en : std_logic := '0';
    signal bus_wr_data : std_logic_vector(31 downto 0) := (others => '0');
    signal bus_rd_en : std_logic := '0';
    signal bus_rd_data : std_logic_vector(31 downto 0);
    signal bus_rd_valid : std_logic;
    
    signal irq : std_logic;
    
    -- Memory interface
    signal mem_rd_addr : std_logic_vector(31 downto 0);
    signal mem_rd_en : std_logic;
    signal mem_rd_data : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_rd_valid : std_logic := '0';
    
    signal mem_wr_addr : std_logic_vector(31 downto 0);
    signal mem_wr_en : std_logic;
    signal mem_wr_data : std_logic_vector(31 downto 0);
    signal mem_wr_ready : std_logic := '1';
    
    -- Framebuffer output
    signal fb_pixel_addr : std_logic_vector(31 downto 0);
    signal fb_pixel_data : std_logic_vector(31 downto 0);
    signal fb_pixel_wr : std_logic;
    
    -- Status
    signal gpu_busy : std_logic;
    signal gpu_idle : std_logic;
    
    -- Test control
    signal test_done : boolean := false;
    
    -- Address constants
    constant ADDR_CMD      : std_logic_vector(31 downto 0) := x"00000000";
    constant ADDR_STATUS   : std_logic_vector(31 downto 0) := x"00002000";
    constant ADDR_FENCE    : std_logic_vector(31 downto 0) := x"00002004";
    constant ADDR_BUSY     : std_logic_vector(31 downto 0) := x"00002008";
    constant ADDR_MAGIC    : std_logic_vector(31 downto 0) := x"0000200C";
    
    -- Command opcodes
    constant CMD_NOP       : std_logic_vector(7 downto 0) := x"00";
    constant CMD_FENCE     : std_logic_vector(7 downto 0) := x"06";
    
    -- Helper procedures
    procedure write_bus(
        signal clk : in std_logic;
        signal addr : out std_logic_vector(31 downto 0);
        signal wr_en : out std_logic;
        signal wr_data : out std_logic_vector(31 downto 0);
        address : std_logic_vector(31 downto 0);
        data : std_logic_vector(31 downto 0)
    ) is
    begin
        wait until rising_edge(clk);
        addr <= address;
        wr_data <= data;
        wr_en <= '1';
        wait until rising_edge(clk);
        wr_en <= '0';
    end procedure;
    
    procedure read_bus(
        signal clk : in std_logic;
        signal addr : out std_logic_vector(31 downto 0);
        signal rd_en : out std_logic;
        signal rd_data : in std_logic_vector(31 downto 0);
        signal rd_valid : in std_logic;
        address : std_logic_vector(31 downto 0);
        variable result : out std_logic_vector(31 downto 0)
    ) is
    begin
        wait until rising_edge(clk);
        addr <= address;
        rd_en <= '1';
        wait until rising_edge(clk);
        rd_en <= '0';
        wait until rd_valid = '1' for 100 ns;
        result := rd_data;
    end procedure;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done else '0';
    
    -- DUT
    uut: entity work.milo832_gpu
        generic map (
            FB_WIDTH => 64,
            FB_HEIGHT => 64,
            TILE_SIZE => 16
        )
        port map (
            clk => clk,
            rst_n => rst_n,
            bus_addr => bus_addr,
            bus_wr_en => bus_wr_en,
            bus_wr_data => bus_wr_data,
            bus_rd_en => bus_rd_en,
            bus_rd_data => bus_rd_data,
            bus_rd_valid => bus_rd_valid,
            irq => irq,
            mem_rd_addr => mem_rd_addr,
            mem_rd_en => mem_rd_en,
            mem_rd_data => mem_rd_data,
            mem_rd_valid => mem_rd_valid,
            mem_wr_addr => mem_wr_addr,
            mem_wr_en => mem_wr_en,
            mem_wr_data => mem_wr_data,
            mem_wr_ready => mem_wr_ready,
            fb_pixel_addr => fb_pixel_addr,
            fb_pixel_data => fb_pixel_data,
            fb_pixel_wr => fb_pixel_wr,
            gpu_busy => gpu_busy,
            gpu_idle => gpu_idle
        );
    
    ---------------------------------------------------------------------------
    -- Main Test Process
    ---------------------------------------------------------------------------
    process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable rd_result : std_logic_vector(31 downto 0);
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;
        
        report "=== Test 1: Read magic number ===" severity note;
        read_bus(clk, bus_addr, bus_rd_en, bus_rd_data, bus_rd_valid, ADDR_MAGIC, rd_result);
        
        if rd_result = x"4D494C4F" then  -- "MILO"
            report "Test 1 PASSED: Magic = MILO" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 1 FAILED: Bad magic" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 2: Check initial idle state ===" severity note;
        
        if gpu_idle = '1' and gpu_busy = '0' then
            report "Test 2 PASSED: GPU is idle" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 2 FAILED: GPU should be idle" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 3: Send NOP command ===" severity note;
        write_bus(clk, bus_addr, bus_wr_en, bus_wr_data, ADDR_CMD, x"000000" & CMD_NOP);
        wait for CLK_PERIOD * 10;
        
        read_bus(clk, bus_addr, bus_rd_en, bus_rd_data, bus_rd_valid, ADDR_STATUS, rd_result);
        
        -- Check that command was processed (count > 0)
        if unsigned(rd_result(23 downto 0)) > 0 then
            report "Test 3 PASSED: NOP processed, count=" & integer'image(to_integer(unsigned(rd_result(23 downto 0)))) severity note;
            pass_count := pass_count + 1;
        else
            report "Test 3 FAILED: NOP not processed" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 4: Send FENCE command ===" severity note;
        read_bus(clk, bus_addr, bus_rd_en, bus_rd_data, bus_rd_valid, ADDR_FENCE, rd_result);
        report "Fence before: " & integer'image(to_integer(unsigned(rd_result))) severity note;
        
        write_bus(clk, bus_addr, bus_wr_en, bus_wr_data, ADDR_CMD, x"000000" & CMD_FENCE);
        wait for CLK_PERIOD * 10;
        
        read_bus(clk, bus_addr, bus_rd_en, bus_rd_data, bus_rd_valid, ADDR_FENCE, rd_result);
        
        if unsigned(rd_result) > 0 then
            report "Test 4 PASSED: FENCE value=" & integer'image(to_integer(unsigned(rd_result))) severity note;
            pass_count := pass_count + 1;
        else
            report "Test 4 FAILED: FENCE not incremented" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 5: Check interrupt on fence ===" severity note;
        
        -- IRQ should have been set
        if irq = '1' then
            report "Test 5 PASSED: IRQ asserted on fence" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 5 FAILED: IRQ not asserted" severity error;
            fail_count := fail_count + 1;
        end if;
        
        -- Clear IRQ by reading status
        read_bus(clk, bus_addr, bus_rd_en, bus_rd_data, bus_rd_valid, ADDR_STATUS, rd_result);
        wait for CLK_PERIOD * 2;
        
        ---------------------------------------------------------------------------
        report "=============================================" severity note;
        report "Test Results: " & integer'image(pass_count) & " passed, " & 
               integer'image(fail_count) & " failed" severity note;
        report "=============================================" severity note;
        
        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        
        test_done <= true;
        wait;
    end process;

end architecture sim;
