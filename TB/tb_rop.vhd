-------------------------------------------------------------------------------
-- tb_rop.vhd
-- Unit Test: Raster Operations Pipeline
-- Tests: Depth test modes, Alpha blending modes
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rop is
end entity tb_rop;

architecture sim of tb_rop is
    
    constant CLK_PERIOD : time := 10 ns;
    
    -- DUT signals
    signal clk              : std_logic := '0';
    signal rst_n            : std_logic := '0';
    
    -- Fragment input
    signal frag_valid       : std_logic := '0';
    signal frag_x, frag_y   : std_logic_vector(9 downto 0) := (others => '0');
    signal frag_z           : std_logic_vector(23 downto 0) := (others => '0');
    signal frag_r, frag_g   : std_logic_vector(7 downto 0) := (others => '0');
    signal frag_b, frag_a   : std_logic_vector(7 downto 0) := (others => '0');
    
    -- Framebuffer read (current pixel)
    signal fb_z             : std_logic_vector(23 downto 0) := (others => '0');
    signal fb_r, fb_g       : std_logic_vector(7 downto 0) := (others => '0');
    signal fb_b, fb_a       : std_logic_vector(7 downto 0) := (others => '0');
    
    -- Configuration
    signal depth_test_en    : std_logic := '1';
    signal depth_write_en   : std_logic := '1';
    signal depth_func       : std_logic_vector(2 downto 0) := "001"; -- LESS
    signal blend_en         : std_logic := '0';
    signal blend_src        : std_logic_vector(3 downto 0) := x"1"; -- SRC_ALPHA
    signal blend_dst        : std_logic_vector(3 downto 0) := x"2"; -- ONE_MINUS_SRC_ALPHA
    
    -- Output
    signal out_valid        : std_logic;
    signal out_write        : std_logic;
    signal out_x, out_y     : std_logic_vector(9 downto 0);
    signal out_z            : std_logic_vector(23 downto 0);
    signal out_r, out_g     : std_logic_vector(7 downto 0);
    signal out_b, out_a     : std_logic_vector(7 downto 0);
    
    -- Test control
    signal test_count : integer := 0;
    signal fail_count : integer := 0;
    signal sim_done   : boolean := false;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not sim_done;
    
    -- DUT instantiation
    u_rop : entity work.rop
        port map (
            clk             => clk,
            rst_n           => rst_n,
            frag_valid      => frag_valid,
            frag_x          => frag_x,
            frag_y          => frag_y,
            frag_z          => frag_z,
            frag_r          => frag_r,
            frag_g          => frag_g,
            frag_b          => frag_b,
            frag_a          => frag_a,
            fb_z            => fb_z,
            fb_r            => fb_r,
            fb_g            => fb_g,
            fb_b            => fb_b,
            fb_a            => fb_a,
            depth_test_en   => depth_test_en,
            depth_write_en  => depth_write_en,
            depth_func      => depth_func,
            blend_en        => blend_en,
            blend_src       => blend_src,
            blend_dst       => blend_dst,
            out_valid       => out_valid,
            out_write       => out_write,
            out_x           => out_x,
            out_y           => out_y,
            out_z           => out_z,
            out_r           => out_r,
            out_g           => out_g,
            out_b           => out_b,
            out_a           => out_a
        );

    -- Test process
    process
    begin
        report "=== ROP Unit Test ===" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 2;
        rst_n <= '1';
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- Test 1: Depth test PASS (fragment closer)
        -------------------------------------------------
        report "--- Test 1: Depth Test PASS ---" severity note;
        
        depth_test_en <= '1';
        depth_func <= "001";  -- LESS
        blend_en <= '0';
        
        frag_valid <= '1';
        frag_x <= std_logic_vector(to_unsigned(100, 10));
        frag_y <= std_logic_vector(to_unsigned(100, 10));
        frag_z <= x"100000";  -- Fragment Z = closer
        frag_r <= x"FF"; frag_g <= x"00"; frag_b <= x"00"; frag_a <= x"FF";
        
        fb_z <= x"800000";    -- Buffer Z = farther
        fb_r <= x"00"; fb_g <= x"FF"; fb_b <= x"00"; fb_a <= x"FF";
        
        wait for CLK_PERIOD;
        frag_valid <= '0';
        wait for CLK_PERIOD * 2;
        
        test_count <= test_count + 1;
        if out_valid = '1' and out_write = '1' then
            report "PASS: Depth test passed, write enabled" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Expected write" severity error;
        end if;
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- Test 2: Depth test FAIL (fragment farther)
        -------------------------------------------------
        report "--- Test 2: Depth Test FAIL ---" severity note;
        
        frag_valid <= '1';
        frag_z <= x"C00000";  -- Fragment Z = farther
        fb_z <= x"400000";    -- Buffer Z = closer
        
        wait for CLK_PERIOD;
        frag_valid <= '0';
        wait for CLK_PERIOD * 2;
        
        test_count <= test_count + 1;
        if out_valid = '1' and out_write = '0' then
            report "PASS: Depth test failed, write disabled" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Expected no write" severity error;
        end if;
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- Test 3: Depth test disabled
        -------------------------------------------------
        report "--- Test 3: Depth Test Disabled ---" severity note;
        
        depth_test_en <= '0';
        
        frag_valid <= '1';
        frag_z <= x"FFFFFF";  -- Very far
        fb_z <= x"000001";    -- Very close
        
        wait for CLK_PERIOD;
        frag_valid <= '0';
        wait for CLK_PERIOD * 2;
        
        test_count <= test_count + 1;
        if out_valid = '1' and out_write = '1' then
            report "PASS: Depth test disabled, always write" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Expected write with depth test disabled" severity error;
        end if;
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- Test 4: Alpha blending (50% opacity)
        -------------------------------------------------
        report "--- Test 4: Alpha Blending ---" severity note;
        
        depth_test_en <= '0';
        blend_en <= '1';
        blend_src <= x"1";  -- SRC_ALPHA
        blend_dst <= x"2";  -- ONE_MINUS_SRC_ALPHA
        
        frag_valid <= '1';
        frag_r <= x"FF"; frag_g <= x"00"; frag_b <= x"00"; frag_a <= x"80"; -- Red, 50% alpha
        fb_r <= x"00"; fb_g <= x"FF"; fb_b <= x"00"; fb_a <= x"FF";         -- Green background
        
        wait for CLK_PERIOD;
        frag_valid <= '0';
        wait for CLK_PERIOD * 2;
        
        test_count <= test_count + 1;
        -- Expect roughly 50% red + 50% green = (128, 128, 0)
        if out_valid = '1' and out_write = '1' then
            if unsigned(out_r) > 100 and unsigned(out_r) < 160 and
               unsigned(out_g) > 100 and unsigned(out_g) < 160 then
                report "PASS: Alpha blend result R=" & integer'image(to_integer(unsigned(out_r))) &
                       " G=" & integer'image(to_integer(unsigned(out_g))) severity note;
            else
                fail_count <= fail_count + 1;
                report "FAIL: Unexpected blend result" severity error;
            end if;
        else
            fail_count <= fail_count + 1;
            report "FAIL: No output from blend" severity error;
        end if;
        wait for CLK_PERIOD;
        
        -------------------------------------------------
        -- Test 5: Blend disabled (opaque write)
        -------------------------------------------------
        report "--- Test 5: Blend Disabled ---" severity note;
        
        blend_en <= '0';
        
        frag_valid <= '1';
        frag_r <= x"AA"; frag_g <= x"BB"; frag_b <= x"CC"; frag_a <= x"DD";
        
        wait for CLK_PERIOD;
        frag_valid <= '0';
        wait for CLK_PERIOD * 2;
        
        test_count <= test_count + 1;
        if out_valid = '1' and out_r = x"AA" and out_g = x"BB" and out_b = x"CC" then
            report "PASS: No blending, direct write" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Expected direct color write" severity error;
        end if;
        
        -------------------------------------------------
        -- Summary
        -------------------------------------------------
        wait for CLK_PERIOD * 5;
        report "=== Test Summary ===" severity note;
        report "Total: " & integer'image(test_count) & 
               " Passed: " & integer'image(test_count - fail_count) &
               " Failed: " & integer'image(fail_count) severity note;
        
        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
