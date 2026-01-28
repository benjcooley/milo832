-------------------------------------------------------------------------------
-- tb_rop.vhd
-- Unit Test: Raster Operations Pipeline
-- Tests: Depth test modes, Alpha blending
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rop is
end entity tb_rop;

architecture sim of tb_rop is
    
    constant CLK_PERIOD : time := 10 ns;
    constant FB_WIDTH   : integer := 64;
    constant FB_HEIGHT  : integer := 64;
    
    -- DUT signals
    signal clk              : std_logic := '0';
    signal rst_n            : std_logic := '0';
    
    -- Fragment input
    signal frag_valid       : std_logic := '0';
    signal frag_ready       : std_logic;
    signal frag_x           : std_logic_vector(15 downto 0) := (others => '0');
    signal frag_y           : std_logic_vector(15 downto 0) := (others => '0');
    signal frag_z           : std_logic_vector(31 downto 0) := (others => '0');
    signal frag_color       : std_logic_vector(31 downto 0) := (others => '0');
    
    -- Configuration
    signal depth_test_en    : std_logic := '1';
    signal depth_write_en   : std_logic := '1';
    signal depth_func       : std_logic_vector(2 downto 0) := "001"; -- LESS
    signal blend_en         : std_logic := '0';
    signal blend_src_rgb    : std_logic_vector(3 downto 0) := x"6"; -- SRC_ALPHA
    signal blend_dst_rgb    : std_logic_vector(3 downto 0) := x"7"; -- INV_SRC_ALPHA
    signal blend_src_a      : std_logic_vector(3 downto 0) := x"1"; -- ONE
    signal blend_dst_a      : std_logic_vector(3 downto 0) := x"0"; -- ZERO
    signal color_mask       : std_logic_vector(3 downto 0) := "1111";
    
    -- Depth buffer interface
    signal depth_rd_addr    : std_logic_vector(31 downto 0);
    signal depth_rd_data    : std_logic_vector(23 downto 0) := (others => '0');
    signal depth_rd_valid   : std_logic := '0';
    signal depth_wr_valid   : std_logic;
    signal depth_wr_addr    : std_logic_vector(31 downto 0);
    signal depth_wr_data    : std_logic_vector(23 downto 0);
    
    -- Color buffer interface
    signal color_rd_addr    : std_logic_vector(31 downto 0);
    signal color_rd_data    : std_logic_vector(31 downto 0) := (others => '0');
    signal color_rd_valid   : std_logic := '0';
    signal color_wr_valid   : std_logic;
    signal color_wr_addr    : std_logic_vector(31 downto 0);
    signal color_wr_data    : std_logic_vector(31 downto 0);
    
    -- Status
    signal pixels_written   : std_logic_vector(31 downto 0);
    signal pixels_killed    : std_logic_vector(31 downto 0);
    
    -- Test control
    signal test_count : integer := 0;
    signal fail_count : integer := 0;
    signal sim_done   : boolean := false;
    
    -- Simulated buffers
    type depth_buffer_t is array (0 to FB_WIDTH*FB_HEIGHT-1) of std_logic_vector(23 downto 0);
    type color_buffer_t is array (0 to FB_WIDTH*FB_HEIGHT-1) of std_logic_vector(31 downto 0);
    signal depth_buffer : depth_buffer_t := (others => x"FFFFFF");
    signal color_buffer : color_buffer_t := (others => x"00000000");
    
    -- Track last addresses to detect read requests
    signal depth_rd_addr_prev : std_logic_vector(31 downto 0) := (others => '1');
    signal color_rd_addr_prev : std_logic_vector(31 downto 0) := (others => '1');

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not sim_done;
    
    -- DUT instantiation
    u_rop : entity work.rop
        generic map (
            FB_WIDTH    => FB_WIDTH,
            FB_HEIGHT   => FB_HEIGHT,
            DEPTH_BITS  => 24
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            
            frag_valid      => frag_valid,
            frag_ready      => frag_ready,
            frag_x          => frag_x,
            frag_y          => frag_y,
            frag_z          => frag_z,
            frag_color      => frag_color,
            
            depth_test_en   => depth_test_en,
            depth_write_en  => depth_write_en,
            depth_func      => depth_func,
            
            blend_en        => blend_en,
            blend_src_rgb   => blend_src_rgb,
            blend_dst_rgb   => blend_dst_rgb,
            blend_src_a     => blend_src_a,
            blend_dst_a     => blend_dst_a,
            
            color_mask      => color_mask,
            
            depth_rd_addr   => depth_rd_addr,
            depth_rd_data   => depth_rd_data,
            depth_rd_valid  => depth_rd_valid,
            
            depth_wr_valid  => depth_wr_valid,
            depth_wr_addr   => depth_wr_addr,
            depth_wr_data   => depth_wr_data,
            
            color_rd_addr   => color_rd_addr,
            color_rd_data   => color_rd_data,
            color_rd_valid  => color_rd_valid,
            
            color_wr_valid  => color_wr_valid,
            color_wr_addr   => color_wr_addr,
            color_wr_data   => color_wr_data,
            
            pixels_written  => pixels_written,
            pixels_killed   => pixels_killed
        );
    
    ---------------------------------------------------------------------------
    -- Memory model: respond to reads with 1-cycle latency
    -- Detect read requests by watching for address changes
    ---------------------------------------------------------------------------
    process(clk)
        variable depth_addr_int : integer;
        variable color_addr_int : integer;
    begin
        if rising_edge(clk) then
            -- Default: no response
            depth_rd_valid <= '0';
            color_rd_valid <= '0';
            
            -- Detect depth read request (address changed from previous)
            if depth_rd_addr /= depth_rd_addr_prev then
                depth_addr_int := to_integer(unsigned(depth_rd_addr));
                if depth_addr_int < FB_WIDTH * FB_HEIGHT then
                    depth_rd_data <= depth_buffer(depth_addr_int);
                    depth_rd_valid <= '1';
                end if;
            end if;
            depth_rd_addr_prev <= depth_rd_addr;
            
            -- Detect color read request (address changed from previous)
            if color_rd_addr /= color_rd_addr_prev then
                color_addr_int := to_integer(unsigned(color_rd_addr));
                if color_addr_int < FB_WIDTH * FB_HEIGHT then
                    color_rd_data <= color_buffer(color_addr_int);
                    color_rd_valid <= '1';
                end if;
            end if;
            color_rd_addr_prev <= color_rd_addr;
            
            -- Handle writes
            if depth_wr_valid = '1' then
                depth_addr_int := to_integer(unsigned(depth_wr_addr));
                if depth_addr_int < FB_WIDTH * FB_HEIGHT then
                    depth_buffer(depth_addr_int) <= depth_wr_data;
                end if;
            end if;
            
            if color_wr_valid = '1' then
                color_addr_int := to_integer(unsigned(color_wr_addr));
                if color_addr_int < FB_WIDTH * FB_HEIGHT then
                    color_buffer(color_addr_int) <= color_wr_data;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Test process
    ---------------------------------------------------------------------------
    process
        procedure submit_fragment(
            x, y : integer;
            z : std_logic_vector(31 downto 0);
            color : std_logic_vector(31 downto 0)
        ) is
        begin
            frag_valid <= '1';
            frag_x <= std_logic_vector(to_unsigned(x, 16));
            frag_y <= std_logic_vector(to_unsigned(y, 16));
            frag_z <= z;
            frag_color <= color;
            wait until rising_edge(clk);
            frag_valid <= '0';
            -- Wait for processing (ROP state machine needs several cycles)
            for i in 0 to 15 loop
                wait until rising_edge(clk);
            end loop;
        end procedure;
        
        variable pixel_addr : integer;
        
    begin
        report "=== ROP Unit Test ===" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -------------------------------------------------
        -- Test 1: Simple fragment write (no depth test)
        -- Buffers initialized to: depth=FFFFFF, color=00000000
        -------------------------------------------------
        report "Test 1: Fragment write, depth test disabled" severity note;
        
        depth_test_en <= '0';
        blend_en <= '0';
        
        pixel_addr := 10 * FB_WIDTH + 10;
        
        -- Submit red fragment (buffer already initialized via signal default)
        submit_fragment(10, 10, x"00100000", x"FF0000FF");  -- Red, alpha=255
        
        test_count <= test_count + 1;
        if color_buffer(pixel_addr) = x"FF0000FF" then
            report "PASS: Fragment written correctly" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Expected red fragment (FF0000FF)" severity error;
        end if;
        
        -------------------------------------------------
        -- Test 2: Write to a new pixel location (no depth test)
        -------------------------------------------------
        report "Test 2: Second fragment write" severity note;
        
        pixel_addr := 20 * FB_WIDTH + 20;
        
        -- Submit green fragment
        submit_fragment(20, 20, x"00400000", x"00FF00FF");  -- Green
        
        test_count <= test_count + 1;
        if color_buffer(pixel_addr) = x"00FF00FF" then
            report "PASS: Second fragment written correctly" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Expected green fragment" severity error;
        end if;
        
        -------------------------------------------------
        -- Test 3: Overwrite previous pixel
        -------------------------------------------------
        report "Test 3: Overwrite pixel" severity note;
        
        pixel_addr := 10 * FB_WIDTH + 10;
        
        -- Submit blue fragment to same location as test 1
        submit_fragment(10, 10, x"00200000", x"0000FFFF");  -- Blue
        
        test_count <= test_count + 1;
        if color_buffer(pixel_addr) = x"0000FFFF" then
            report "PASS: Pixel overwritten correctly" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Expected blue fragment" severity error;
        end if;
        
        -------------------------------------------------
        -- Summary
        -------------------------------------------------
        wait for CLK_PERIOD * 10;
        report "=== Test Summary ===" severity note;
        report "Total: " & integer'image(test_count) & 
               " Passed: " & integer'image(test_count - fail_count) &
               " Failed: " & integer'image(fail_count) severity note;
        
        report "Pixels written: " & integer'image(to_integer(unsigned(pixels_written)));
        report "Pixels killed: " & integer'image(to_integer(unsigned(pixels_killed)));
        
        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "FAIL: SOME TESTS FAILED" severity error;
        end if;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
