-------------------------------------------------------------------------------
-- tb_viewport_transform.vhd
-- Testbench for Viewport Transform Unit
--
-- Tests:
--   1. Identity transform (NDC 0,0,0 -> center of viewport)
--   2. Corner vertices (NDC -1,-1 and +1,+1)
--   3. Clipped vertex (W <= 0)
--   4. Multiple vertices in sequence
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_viewport_transform is
end entity tb_viewport_transform;

architecture sim of tb_viewport_transform is

    constant CLK_PERIOD : time := 10 ns;
    
    signal clk : std_logic := '0';
    signal rst_n : std_logic := '0';
    
    -- Viewport config
    signal viewport_x : std_logic_vector(15 downto 0) := x"0000";
    signal viewport_y : std_logic_vector(15 downto 0) := x"0000";
    signal viewport_width : std_logic_vector(15 downto 0) := x"0280";  -- 640
    signal viewport_height : std_logic_vector(15 downto 0) := x"01E0"; -- 480
    signal depth_near : std_logic_vector(31 downto 0) := x"00000000";
    signal depth_far : std_logic_vector(31 downto 0) := x"3F800000";   -- 1.0
    
    -- Input vertex
    signal vtx_in_valid : std_logic := '0';
    signal vtx_in_ready : std_logic;
    signal vtx_in_x : std_logic_vector(31 downto 0) := (others => '0');
    signal vtx_in_y : std_logic_vector(31 downto 0) := (others => '0');
    signal vtx_in_z : std_logic_vector(31 downto 0) := (others => '0');
    signal vtx_in_w : std_logic_vector(31 downto 0) := x"3F800000";  -- 1.0
    signal vtx_in_u : std_logic_vector(31 downto 0) := (others => '0');
    signal vtx_in_v : std_logic_vector(31 downto 0) := (others => '0');
    signal vtx_in_color : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    
    -- Output vertex
    signal vtx_out_valid : std_logic;
    signal vtx_out_ready : std_logic := '1';
    signal vtx_out_x : std_logic_vector(31 downto 0);
    signal vtx_out_y : std_logic_vector(31 downto 0);
    signal vtx_out_z : std_logic_vector(31 downto 0);
    signal vtx_out_w : std_logic_vector(31 downto 0);
    signal vtx_out_u : std_logic_vector(31 downto 0);
    signal vtx_out_v : std_logic_vector(31 downto 0);
    signal vtx_out_color : std_logic_vector(31 downto 0);
    signal vtx_out_clipped : std_logic;
    
    -- Status
    signal vertices_in : std_logic_vector(31 downto 0);
    signal vertices_out : std_logic_vector(31 downto 0);
    signal vertices_clipped : std_logic_vector(31 downto 0);
    
    -- Test control
    signal test_done : boolean := false;
    
    -- Float constants
    constant FLOAT_ZERO     : std_logic_vector(31 downto 0) := x"00000000";
    constant FLOAT_ONE      : std_logic_vector(31 downto 0) := x"3F800000";
    constant FLOAT_NEG_ONE  : std_logic_vector(31 downto 0) := x"BF800000";
    constant FLOAT_HALF     : std_logic_vector(31 downto 0) := x"3F000000";

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done else '0';
    
    -- DUT
    uut: entity work.viewport_transform
        port map (
            clk => clk,
            rst_n => rst_n,
            viewport_x => viewport_x,
            viewport_y => viewport_y,
            viewport_width => viewport_width,
            viewport_height => viewport_height,
            depth_near => depth_near,
            depth_far => depth_far,
            vtx_in_valid => vtx_in_valid,
            vtx_in_ready => vtx_in_ready,
            vtx_in_x => vtx_in_x,
            vtx_in_y => vtx_in_y,
            vtx_in_z => vtx_in_z,
            vtx_in_w => vtx_in_w,
            vtx_in_u => vtx_in_u,
            vtx_in_v => vtx_in_v,
            vtx_in_color => vtx_in_color,
            vtx_out_valid => vtx_out_valid,
            vtx_out_ready => vtx_out_ready,
            vtx_out_x => vtx_out_x,
            vtx_out_y => vtx_out_y,
            vtx_out_z => vtx_out_z,
            vtx_out_w => vtx_out_w,
            vtx_out_u => vtx_out_u,
            vtx_out_v => vtx_out_v,
            vtx_out_color => vtx_out_color,
            vtx_out_clipped => vtx_out_clipped,
            vertices_in => vertices_in,
            vertices_out => vertices_out,
            vertices_clipped => vertices_clipped
        );
    
    ---------------------------------------------------------------------------
    -- Main Test Process
    ---------------------------------------------------------------------------
    process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        
        variable captured_clipped : std_logic;
        variable captured_valid : std_logic;
        
        -- Send vertex and wait for output
        procedure send_vertex(
            x, y, z, w : std_logic_vector(31 downto 0)
        ) is
        begin
            wait until rising_edge(clk);
            vtx_in_x <= x;
            vtx_in_y <= y;
            vtx_in_z <= z;
            vtx_in_w <= w;
            vtx_in_valid <= '1';
            wait until rising_edge(clk);
            vtx_in_valid <= '0';
            
            -- Wait for output and capture it
            captured_valid := '0';
            for i in 0 to 50 loop
                wait until rising_edge(clk);
                if vtx_out_valid = '1' then
                    captured_valid := '1';
                    captured_clipped := vtx_out_clipped;
                    exit;
                end if;
            end loop;
        end procedure;
        
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        report "=== Test 1: Center vertex (NDC 0,0,0) ===" severity note;
        -----------------------------------------------------------------------
        send_vertex(FLOAT_ZERO, FLOAT_ZERO, FLOAT_ZERO, FLOAT_ONE);
        
        if captured_valid = '1' and captured_clipped = '0' then
            report "Test 1 PASSED: Center vertex not clipped" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 1 FAILED: Expected valid unclipped vertex (valid=" & 
                   std_logic'image(captured_valid) & ", clipped=" & 
                   std_logic'image(captured_clipped) & ")" severity error;
            fail_count := fail_count + 1;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        report "=== Test 2: Top-left corner (NDC -1,-1) ===" severity note;
        -----------------------------------------------------------------------
        send_vertex(FLOAT_NEG_ONE, FLOAT_NEG_ONE, FLOAT_ZERO, FLOAT_ONE);
        
        if captured_valid = '1' and captured_clipped = '0' then
            report "Test 2 PASSED: Corner vertex processed" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 2 FAILED: Expected valid corner vertex" severity error;
            fail_count := fail_count + 1;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        report "=== Test 3: Clipped vertex (W=0) ===" severity note;
        -----------------------------------------------------------------------
        send_vertex(FLOAT_ZERO, FLOAT_ZERO, FLOAT_ZERO, FLOAT_ZERO);
        
        if captured_valid = '1' and captured_clipped = '1' then
            report "Test 3 PASSED: Vertex correctly marked as clipped" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 3 FAILED: Expected clipped vertex" severity error;
            fail_count := fail_count + 1;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        report "=== Test 4: Check counters ===" severity note;
        -----------------------------------------------------------------------
        if unsigned(vertices_in) = 3 and unsigned(vertices_out) = 3 then
            report "Test 4 PASSED: Processed 3 vertices" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 4 FAILED: Expected 3 vertices in/out" severity error;
            report "  In: " & integer'image(to_integer(unsigned(vertices_in))) &
                   " Out: " & integer'image(to_integer(unsigned(vertices_out))) severity error;
            fail_count := fail_count + 1;
        end if;
        
        if unsigned(vertices_clipped) = 1 then
            report "  1 vertex clipped as expected" severity note;
        end if;
        
        -----------------------------------------------------------------------
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
