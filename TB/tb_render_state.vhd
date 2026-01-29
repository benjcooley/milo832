-------------------------------------------------------------------------------
-- tb_render_state.vhd
-- Testbench for render state registers and triangle culling
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.render_state_pkg.all;

entity tb_render_state is
end entity tb_render_state;

architecture sim of tb_render_state is

    constant CLK_PERIOD : time := 10 ns;
    constant BASE_ADDR : std_logic_vector(31 downto 0) := x"00010000";
    
    signal clk : std_logic := '0';
    signal rst_n : std_logic := '0';
    
    -- Bus signals
    signal bus_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal bus_wr_en : std_logic := '0';
    signal bus_wr_data : std_logic_vector(31 downto 0) := (others => '0');
    signal bus_rd_en : std_logic := '0';
    signal bus_rd_data : std_logic_vector(31 downto 0);
    signal bus_rd_valid : std_logic;
    
    -- State outputs
    signal state_out : render_state_t;
    signal depth_test_en, depth_write_en : std_logic;
    signal depth_func : depth_func_t;
    signal cull_mode : cull_mode_t;
    signal front_face : winding_t;
    signal blend_en : std_logic;
    
    -- Triangle cull signals
    signal tri_in_valid, tri_in_ready : std_logic := '0';
    signal tri_out_valid, tri_out_ready : std_logic := '0';
    
    -- Vertices (fixed point 16.16)
    signal v0_x, v0_y, v0_z : std_logic_vector(31 downto 0);
    signal v1_x, v1_y, v1_z : std_logic_vector(31 downto 0);
    signal v2_x, v2_y, v2_z : std_logic_vector(31 downto 0);
    signal v0_u, v0_v, v0_color : std_logic_vector(31 downto 0);
    signal v1_u, v1_v, v1_color : std_logic_vector(31 downto 0);
    signal v2_u, v2_v, v2_color : std_logic_vector(31 downto 0);
    
    signal triangles_in, triangles_culled : std_logic_vector(31 downto 0);
    
    -- Test control
    signal test_done : boolean := false;
    
    -- Helper: convert integer to fixed point 16.16
    function to_fixed(val : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(val * 65536, 32));
    end function;
    
    -- Helper: write register
    procedure write_reg(
        signal clk : in std_logic;
        signal addr : out std_logic_vector(31 downto 0);
        signal wr_en : out std_logic;
        signal wr_data : out std_logic_vector(31 downto 0);
        offset : std_logic_vector(7 downto 0);
        data : std_logic_vector(31 downto 0)
    ) is
    begin
        wait until rising_edge(clk);
        addr <= BASE_ADDR(31 downto 8) & offset;
        wr_data <= data;
        wr_en <= '1';
        wait until rising_edge(clk);
        wr_en <= '0';
    end procedure;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done else '0';
    
    -- Instantiate render state registers
    uut_regs: entity work.render_state_regs
        generic map (
            BASE_ADDR => BASE_ADDR
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
            state_out => state_out,
            depth_test_en => depth_test_en,
            depth_write_en => depth_write_en,
            depth_func => depth_func,
            cull_mode => cull_mode,
            front_face => front_face,
            blend_en => blend_en,
            -- Connect other outputs...
            depth_clear => open,
            blend_src_rgb => open,
            blend_dst_rgb => open,
            blend_eq_rgb => open,
            blend_src_a => open,
            blend_dst_a => open,
            blend_eq_a => open,
            blend_color => open,
            color_mask => open,
            color_clear => open
        );
    
    -- Instantiate triangle cull unit
    uut_cull: entity work.triangle_cull
        port map (
            clk => clk,
            rst_n => rst_n,
            cull_mode => cull_mode,
            front_face => front_face,
            tri_in_valid => tri_in_valid,
            tri_in_ready => tri_in_ready,
            v0_x => v0_x, v0_y => v0_y, v0_z => v0_z,
            v1_x => v1_x, v1_y => v1_y, v1_z => v1_z,
            v2_x => v2_x, v2_y => v2_y, v2_z => v2_z,
            v0_u => v0_u, v0_v => v0_v, v0_color => v0_color,
            v1_u => v1_u, v1_v => v1_v, v1_color => v1_color,
            v2_u => v2_u, v2_v => v2_v, v2_color => v2_color,
            tri_out_valid => tri_out_valid,
            tri_out_ready => tri_out_ready,
            out_v0_x => open, out_v0_y => open, out_v0_z => open,
            out_v0_u => open, out_v0_v => open, out_v0_color => open,
            out_v1_x => open, out_v1_y => open, out_v1_z => open,
            out_v1_u => open, out_v1_v => open, out_v1_color => open,
            out_v2_x => open, out_v2_y => open, out_v2_z => open,
            out_v2_u => open, out_v2_v => open, out_v2_color => open,
            triangles_in => triangles_in,
            triangles_culled => triangles_culled
        );
    
    -- Always ready to accept triangles from cull unit
    tri_out_ready <= '1';
    
    -- Initialize unused signals
    v0_u <= (others => '0'); v0_v <= (others => '0'); v0_color <= x"FF0000FF";
    v1_u <= (others => '0'); v1_v <= (others => '0'); v1_color <= x"00FF00FF";
    v2_u <= (others => '0'); v2_v <= (others => '0'); v2_color <= x"0000FFFF";
    
    ---------------------------------------------------------------------------
    -- Main Test Process
    ---------------------------------------------------------------------------
    process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        report "=== Test 1: Verify default state ===";
        -- Default should be: depth enabled, back-face culling, CCW front
        assert depth_test_en = '1' report "Default depth_test_en should be 1" severity error;
        assert cull_mode = CULL_BACK report "Default cull_mode should be CULL_BACK" severity error;
        assert front_face = WINDING_CCW report "Default front_face should be CCW" severity error;
        
        if depth_test_en = '1' and cull_mode = CULL_BACK and front_face = WINDING_CCW then
            report "Test 1 PASSED: Default state correct";
            pass_count := pass_count + 1;
        else
            report "Test 1 FAILED" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 2: Write depth control register ===";
        -- Disable depth test, enable write, set func to GREATER
        write_reg(clk, bus_addr, bus_wr_en, bus_wr_data, x"00", x"00000012");
        -- bits: [0]=0 (test off), [1]=1 (write on), [4:2]=100 (GREATER)
        wait for CLK_PERIOD * 2;
        
        assert depth_test_en = '0' report "depth_test_en should be 0" severity error;
        assert depth_write_en = '1' report "depth_write_en should be 1" severity error;
        assert depth_func = DEPTH_GREATER report "depth_func should be GREATER" severity error;
        
        if depth_test_en = '0' and depth_write_en = '1' and depth_func = DEPTH_GREATER then
            report "Test 2 PASSED: Depth control updated";
            pass_count := pass_count + 1;
        else
            report "Test 2 FAILED" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 3: Write cull control - disable culling ===";
        write_reg(clk, bus_addr, bus_wr_en, bus_wr_data, x"04", x"00000000");
        -- bits: [1:0]=00 (CULL_NONE), [2]=0 (CCW)
        wait for CLK_PERIOD * 2;
        
        assert cull_mode = CULL_NONE report "cull_mode should be NONE" severity error;
        if cull_mode = CULL_NONE then
            report "Test 3 PASSED: Culling disabled";
            pass_count := pass_count + 1;
        else
            report "Test 3 FAILED" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 4: Submit CCW triangle with no culling ===";
        -- CCW triangle (positive area): (0,0) -> (10,0) -> (5,10)
        v0_x <= to_fixed(0);  v0_y <= to_fixed(0);  v0_z <= to_fixed(100);
        v1_x <= to_fixed(10); v1_y <= to_fixed(0);  v1_z <= to_fixed(100);
        v2_x <= to_fixed(5);  v2_y <= to_fixed(10); v2_z <= to_fixed(100);
        
        wait until rising_edge(clk);
        tri_in_valid <= '1';
        wait until rising_edge(clk) and tri_in_ready = '1';
        tri_in_valid <= '0';
        
        -- Wait for output
        wait until tri_out_valid = '1' for 500 ns;
        
        if tri_out_valid = '1' then
            report "Test 4 PASSED: CCW triangle passed (no cull)";
            pass_count := pass_count + 1;
        else
            report "Test 4 FAILED: Triangle should have passed" severity error;
            fail_count := fail_count + 1;
        end if;
        wait for CLK_PERIOD * 5;
        
        report "=== Test 5: Enable back-face culling, submit CCW triangle ===";
        write_reg(clk, bus_addr, bus_wr_en, bus_wr_data, x"04", x"00000002");
        -- bits: [1:0]=10 (CULL_BACK), [2]=0 (CCW = front)
        wait for CLK_PERIOD * 2;
        
        -- Submit same CCW triangle - should pass (it's front-facing)
        wait until rising_edge(clk);
        tri_in_valid <= '1';
        wait until rising_edge(clk) and tri_in_ready = '1';
        tri_in_valid <= '0';
        
        wait until tri_out_valid = '1' for 500 ns;
        
        if tri_out_valid = '1' then
            report "Test 5 PASSED: CCW (front) triangle passed with back-cull";
            pass_count := pass_count + 1;
        else
            report "Test 5 FAILED: Front triangle should pass" severity error;
            fail_count := fail_count + 1;
        end if;
        wait for CLK_PERIOD * 5;
        
        report "=== Test 6: Submit CW triangle with back-face culling ===";
        -- CW triangle (negative area): (0,0) -> (5,10) -> (10,0)
        v0_x <= to_fixed(0);  v0_y <= to_fixed(0);  v0_z <= to_fixed(100);
        v1_x <= to_fixed(5);  v1_y <= to_fixed(10); v1_z <= to_fixed(100);
        v2_x <= to_fixed(10); v2_y <= to_fixed(0);  v2_z <= to_fixed(100);
        
        wait until rising_edge(clk);
        tri_in_valid <= '1';
        wait until rising_edge(clk) and tri_in_ready = '1';
        tri_in_valid <= '0';
        
        -- Wait a bit - triangle should be culled (no output)
        wait for CLK_PERIOD * 10;
        
        -- Check culled count increased
        if unsigned(triangles_culled) > 0 then
            report "Test 6 PASSED: CW (back) triangle culled";
            pass_count := pass_count + 1;
        else
            report "Test 6 FAILED: Back triangle should be culled" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 7: Switch to front-face culling ===";
        write_reg(clk, bus_addr, bus_wr_en, bus_wr_data, x"04", x"00000001");
        -- bits: [1:0]=01 (CULL_FRONT), [2]=0 (CCW = front)
        wait for CLK_PERIOD * 2;
        
        -- Submit CCW triangle - should be culled (it's front-facing)
        v0_x <= to_fixed(0);  v0_y <= to_fixed(0);  v0_z <= to_fixed(100);
        v1_x <= to_fixed(10); v1_y <= to_fixed(0);  v1_z <= to_fixed(100);
        v2_x <= to_fixed(5);  v2_y <= to_fixed(10); v2_z <= to_fixed(100);
        
        wait until rising_edge(clk);
        tri_in_valid <= '1';
        wait until rising_edge(clk) and tri_in_ready = '1';
        tri_in_valid <= '0';
        
        wait for CLK_PERIOD * 10;
        
        if unsigned(triangles_culled) > 1 then
            report "Test 7 PASSED: Front triangle culled with front-cull mode";
            pass_count := pass_count + 1;
        else
            report "Test 7 FAILED" severity error;
            fail_count := fail_count + 1;
        end if;
        
        ---------------------------------------------------------------------------
        report "==============================================";
        report "Test Results: " & integer'image(pass_count) & " passed, " & 
               integer'image(fail_count) & " failed";
        report "Triangles in: " & integer'image(to_integer(unsigned(triangles_in)));
        report "Triangles culled: " & integer'image(to_integer(unsigned(triangles_culled)));
        report "==============================================";
        
        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        
        test_done <= true;
        wait;
    end process;

end architecture sim;
