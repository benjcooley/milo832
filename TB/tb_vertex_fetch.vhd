-------------------------------------------------------------------------------
-- tb_vertex_fetch.vhd
-- Testbench for Vertex Fetch and Primitive Assembly Units
--
-- Tests:
--   1. Non-indexed triangle list fetch
--   2. Indexed triangle fetch with 16-bit indices
--   3. Primitive assembly - triangle list
--   4. Primitive assembly - triangle strip
--   5. Primitive assembly - triangle fan
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vertex_fetch is
end entity tb_vertex_fetch;

architecture sim of tb_vertex_fetch is

    constant CLK_PERIOD : time := 10 ns;
    
    signal clk : std_logic := '0';
    signal rst_n : std_logic := '0';
    
    ---------------------------------------------------------------------------
    -- Vertex Fetch signals
    ---------------------------------------------------------------------------
    signal draw_valid : std_logic := '0';
    signal draw_ready : std_logic;
    signal draw_indexed : std_logic := '0';
    signal draw_prim_type : std_logic_vector(2 downto 0) := "000";
    signal draw_start : std_logic_vector(31 downto 0) := (others => '0');
    signal draw_count : std_logic_vector(31 downto 0) := (others => '0');
    signal draw_base_vert : std_logic_vector(31 downto 0) := (others => '0');
    
    signal idx_buf_addr : std_logic_vector(31 downto 0) := x"00001000";
    signal idx_buf_format : std_logic_vector(1 downto 0) := "01";  -- U16
    
    signal vtx_buf_addr : std_logic_vector(31 downto 0) := x"00002000";
    signal vtx_buf_stride : std_logic_vector(7 downto 0) := x"18";  -- 24 bytes
    signal attr_pos_offset : std_logic_vector(7 downto 0) := x"00";
    signal attr_uv_offset : std_logic_vector(7 downto 0) := x"0C";  -- 12
    signal attr_color_off : std_logic_vector(7 downto 0) := x"14";  -- 20
    signal attr_enable : std_logic_vector(2 downto 0) := "001";  -- Position only
    
    signal mem_rd_addr : std_logic_vector(31 downto 0);
    signal mem_rd_en : std_logic;
    signal mem_rd_size : std_logic_vector(1 downto 0);
    signal mem_rd_data : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_rd_valid : std_logic := '0';
    
    signal vtx_valid : std_logic;
    signal vtx_ready : std_logic := '1';
    signal vtx_index : std_logic_vector(31 downto 0);
    signal vtx_pos_x : std_logic_vector(31 downto 0);
    signal vtx_pos_y : std_logic_vector(31 downto 0);
    signal vtx_pos_z : std_logic_vector(31 downto 0);
    signal vtx_uv_u : std_logic_vector(31 downto 0);
    signal vtx_uv_v : std_logic_vector(31 downto 0);
    signal vtx_color : std_logic_vector(31 downto 0);
    
    signal fetch_busy : std_logic;
    signal vertices_fetched : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Primitive Assembly signals
    ---------------------------------------------------------------------------
    signal pa_vtx_valid : std_logic := '0';
    signal pa_vtx_ready : std_logic;
    signal pa_vtx_index : std_logic_vector(31 downto 0) := (others => '0');
    signal pa_vtx_pos_x : std_logic_vector(31 downto 0) := (others => '0');
    signal pa_vtx_pos_y : std_logic_vector(31 downto 0) := (others => '0');
    signal pa_vtx_pos_z : std_logic_vector(31 downto 0) := (others => '0');
    signal pa_vtx_pos_w : std_logic_vector(31 downto 0) := x"3F800000";  -- 1.0
    signal pa_vtx_uv_u : std_logic_vector(31 downto 0) := (others => '0');
    signal pa_vtx_uv_v : std_logic_vector(31 downto 0) := (others => '0');
    signal pa_vtx_color : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    
    signal pa_prim_type : std_logic_vector(2 downto 0) := "000";
    signal pa_prim_restart_en : std_logic := '0';
    signal pa_prim_restart_idx : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal pa_flush : std_logic := '0';
    
    signal tri_valid : std_logic;
    signal tri_ready : std_logic := '1';
    signal tri_v0_x, tri_v0_y, tri_v0_z, tri_v0_w : std_logic_vector(31 downto 0);
    signal tri_v1_x, tri_v1_y, tri_v1_z, tri_v1_w : std_logic_vector(31 downto 0);
    signal tri_v2_x, tri_v2_y, tri_v2_z, tri_v2_w : std_logic_vector(31 downto 0);
    
    signal triangles_out : std_logic_vector(31 downto 0);
    signal vertices_in : std_logic_vector(31 downto 0);
    
    -- Test control
    signal test_done : boolean := false;
    
    -- Memory model: simple array for vertex/index data
    -- Address space: 0x1000-0x1FFF = index buffer, 0x2000-0x2FFF = vertex buffer
    -- Array indexed by word address (address >> 2)
    type mem_array_t is array(0 to 4095) of std_logic_vector(31 downto 0);
    signal mem : mem_array_t := (others => (others => '0'));

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done else '0';
    
    ---------------------------------------------------------------------------
    -- DUT: Vertex Fetch
    ---------------------------------------------------------------------------
    u_vertex_fetch: entity work.vertex_fetch
        port map (
            clk => clk,
            rst_n => rst_n,
            draw_valid => draw_valid,
            draw_ready => draw_ready,
            draw_indexed => draw_indexed,
            draw_prim_type => draw_prim_type,
            draw_start => draw_start,
            draw_count => draw_count,
            draw_base_vert => draw_base_vert,
            idx_buf_addr => idx_buf_addr,
            idx_buf_format => idx_buf_format,
            vtx_buf_addr => vtx_buf_addr,
            vtx_buf_stride => vtx_buf_stride,
            attr_pos_offset => attr_pos_offset,
            attr_uv_offset => attr_uv_offset,
            attr_color_off => attr_color_off,
            attr_enable => attr_enable,
            mem_rd_addr => mem_rd_addr,
            mem_rd_en => mem_rd_en,
            mem_rd_size => mem_rd_size,
            mem_rd_data => mem_rd_data,
            mem_rd_valid => mem_rd_valid,
            vtx_valid => vtx_valid,
            vtx_ready => vtx_ready,
            vtx_index => vtx_index,
            vtx_pos_x => vtx_pos_x,
            vtx_pos_y => vtx_pos_y,
            vtx_pos_z => vtx_pos_z,
            vtx_uv_u => vtx_uv_u,
            vtx_uv_v => vtx_uv_v,
            vtx_color => vtx_color,
            fetch_busy => fetch_busy,
            vertices_fetched => vertices_fetched
        );
    
    ---------------------------------------------------------------------------
    -- DUT: Primitive Assembly
    ---------------------------------------------------------------------------
    u_prim_asm: entity work.primitive_assembly
        port map (
            clk => clk,
            rst_n => rst_n,
            prim_type => pa_prim_type,
            prim_restart_en => pa_prim_restart_en,
            prim_restart_idx => pa_prim_restart_idx,
            vtx_valid => pa_vtx_valid,
            vtx_ready => pa_vtx_ready,
            vtx_index => pa_vtx_index,
            vtx_pos_x => pa_vtx_pos_x,
            vtx_pos_y => pa_vtx_pos_y,
            vtx_pos_z => pa_vtx_pos_z,
            vtx_pos_w => pa_vtx_pos_w,
            vtx_uv_u => pa_vtx_uv_u,
            vtx_uv_v => pa_vtx_uv_v,
            vtx_color => pa_vtx_color,
            tri_valid => tri_valid,
            tri_ready => tri_ready,
            tri_v0_x => tri_v0_x,
            tri_v0_y => tri_v0_y,
            tri_v0_z => tri_v0_z,
            tri_v0_w => tri_v0_w,
            tri_v1_x => tri_v1_x,
            tri_v1_y => tri_v1_y,
            tri_v1_z => tri_v1_z,
            tri_v1_w => tri_v1_w,
            tri_v2_x => tri_v2_x,
            tri_v2_y => tri_v2_y,
            tri_v2_z => tri_v2_z,
            tri_v2_w => tri_v2_w,
            tri_v0_u => open,
            tri_v0_v => open,
            tri_v0_color => open,
            tri_v1_u => open,
            tri_v1_v => open,
            tri_v1_color => open,
            tri_v2_u => open,
            tri_v2_v => open,
            tri_v2_color => open,
            flush => pa_flush,
            triangles_out => triangles_out,
            vertices_in => vertices_in
        );
    
    ---------------------------------------------------------------------------
    -- Memory Model (simple response with 1-cycle latency)
    ---------------------------------------------------------------------------
    process(clk)
        variable addr_idx : integer;
    begin
        if rising_edge(clk) then
            mem_rd_valid <= '0';
            
            if mem_rd_en = '1' then
                -- Convert address to array index (word-aligned)
                -- Use bits 13:2 to support larger address range
                addr_idx := to_integer(unsigned(mem_rd_addr(13 downto 2)));
                if addr_idx < 4096 then
                    mem_rd_data <= mem(addr_idx);
                else
                    mem_rd_data <= x"DEADBEEF";
                end if;
                mem_rd_valid <= '1';
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Main Test Process
    ---------------------------------------------------------------------------
    process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable vtx_recv : integer;
        variable tri_recv : integer;
        
        -- Procedure to send vertex to primitive assembly
        procedure send_vertex(
            idx : integer;
            x, y, z : std_logic_vector(31 downto 0)
        ) is
        begin
            wait until rising_edge(clk);
            pa_vtx_valid <= '1';
            pa_vtx_index <= std_logic_vector(to_unsigned(idx, 32));
            pa_vtx_pos_x <= x;
            pa_vtx_pos_y <= y;
            pa_vtx_pos_z <= z;
            wait until rising_edge(clk);
            while pa_vtx_ready = '0' loop
                wait until rising_edge(clk);
            end loop;
            pa_vtx_valid <= '0';
        end procedure;
        
    begin
        -- Initialize memory with test data
        
        -- Vertex 0: pos=(1.0, 0.0, 0.0) at address 0x2000
        mem(2048) <= x"3F800000";  -- x = 1.0
        mem(2049) <= x"00000000";  -- y = 0.0
        mem(2050) <= x"00000000";  -- z = 0.0
        
        -- Vertex 1: pos=(0.0, 1.0, 0.0) at address 0x2018
        mem(2054) <= x"00000000";  -- x = 0.0
        mem(2055) <= x"3F800000";  -- y = 1.0
        mem(2056) <= x"00000000";  -- z = 0.0
        
        -- Vertex 2: pos=(0.0, 0.0, 1.0) at address 0x2030
        mem(2060) <= x"00000000";  -- x = 0.0
        mem(2061) <= x"00000000";  -- y = 0.0
        mem(2062) <= x"3F800000";  -- z = 1.0
        
        -- Index buffer at 0x1000: 16-bit indices [2, 1, 0]
        mem(1024) <= x"00010002";  -- indices 2, 1 (little-endian)
        mem(1025) <= x"00000000";  -- index 0
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        report "=== Test 1: Non-indexed vertex fetch ===" severity note;
        -----------------------------------------------------------------------
        draw_indexed <= '0';
        draw_start <= x"00000000";
        draw_count <= x"00000003";
        draw_base_vert <= x"00000000";
        attr_enable <= "001";  -- Position only
        
        wait until rising_edge(clk);
        draw_valid <= '1';
        wait until rising_edge(clk);
        draw_valid <= '0';
        
        -- Wait for completion
        vtx_recv := 0;
        for i in 0 to 100 loop
            wait until rising_edge(clk);
            if vtx_valid = '1' then
                vtx_recv := vtx_recv + 1;
            end if;
            exit when fetch_busy = '0' and vtx_valid = '0' and vtx_recv >= 3;
        end loop;
        
        if vtx_recv = 3 then
            report "Test 1 PASSED: Fetched 3 vertices" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 1 FAILED: Expected 3 vertices, got " & integer'image(vtx_recv) severity error;
            fail_count := fail_count + 1;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        report "=== Test 2: Indexed vertex fetch ===" severity note;
        -----------------------------------------------------------------------
        draw_indexed <= '1';
        draw_start <= x"00000000";
        draw_count <= x"00000003";
        idx_buf_format <= "01";  -- U16
        
        wait until rising_edge(clk);
        draw_valid <= '1';
        wait until rising_edge(clk);
        draw_valid <= '0';
        
        vtx_recv := 0;
        for i in 0 to 100 loop
            wait until rising_edge(clk);
            if vtx_valid = '1' then
                vtx_recv := vtx_recv + 1;
            end if;
            exit when fetch_busy = '0' and vtx_valid = '0' and vtx_recv >= 3;
        end loop;
        
        if vtx_recv = 3 then
            report "Test 2 PASSED: Fetched 3 indexed vertices" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 2 FAILED: Expected 3 vertices, got " & integer'image(vtx_recv) severity error;
            fail_count := fail_count + 1;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        report "=== Test 3: Triangle list assembly ===" severity note;
        -----------------------------------------------------------------------
        pa_prim_type <= "000";  -- TRIANGLES
        pa_flush <= '1';
        wait until rising_edge(clk);
        pa_flush <= '0';
        wait until rising_edge(clk);
        
        -- Send 6 vertices (2 triangles)
        send_vertex(0, x"00000000", x"00000000", x"00000000");
        send_vertex(1, x"3F800000", x"00000000", x"00000000");
        send_vertex(2, x"00000000", x"3F800000", x"00000000");
        send_vertex(3, x"3F800000", x"00000000", x"00000000");
        send_vertex(4, x"3F800000", x"3F800000", x"00000000");
        send_vertex(5, x"00000000", x"3F800000", x"00000000");
        
        wait for CLK_PERIOD * 5;
        
        tri_recv := to_integer(unsigned(triangles_out));
        if tri_recv = 2 then
            report "Test 3 PASSED: Assembled 2 triangles from list" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 3 FAILED: Expected 2 triangles, got " & integer'image(tri_recv) severity error;
            fail_count := fail_count + 1;
        end if;
        
        -----------------------------------------------------------------------
        report "=== Test 4: Triangle strip assembly ===" severity note;
        -----------------------------------------------------------------------
        pa_prim_type <= "001";  -- TRIANGLE_STRIP
        pa_flush <= '1';
        wait until rising_edge(clk);
        pa_flush <= '0';
        wait until rising_edge(clk);
        
        -- Send 5 vertices (3 triangles in strip)
        send_vertex(0, x"00000000", x"00000000", x"00000000");
        send_vertex(1, x"3F800000", x"00000000", x"00000000");
        send_vertex(2, x"00000000", x"3F800000", x"00000000");
        send_vertex(3, x"3F800000", x"3F800000", x"00000000");
        send_vertex(4, x"40000000", x"00000000", x"00000000");  -- 2.0
        
        wait for CLK_PERIOD * 5;
        
        tri_recv := to_integer(unsigned(triangles_out));
        if tri_recv = 3 then
            report "Test 4 PASSED: Assembled 3 triangles from strip" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 4 FAILED: Expected 3 triangles, got " & integer'image(tri_recv) severity error;
            fail_count := fail_count + 1;
        end if;
        
        -----------------------------------------------------------------------
        report "=== Test 5: Triangle fan assembly ===" severity note;
        -----------------------------------------------------------------------
        pa_prim_type <= "010";  -- TRIANGLE_FAN
        pa_flush <= '1';
        wait until rising_edge(clk);
        pa_flush <= '0';
        wait until rising_edge(clk);
        
        -- Send 5 vertices (3 triangles in fan)
        send_vertex(0, x"00000000", x"00000000", x"00000000");  -- Hub
        send_vertex(1, x"3F800000", x"00000000", x"00000000");
        send_vertex(2, x"00000000", x"3F800000", x"00000000");
        send_vertex(3, x"BF800000", x"00000000", x"00000000");  -- -1.0
        send_vertex(4, x"00000000", x"BF800000", x"00000000");  -- -1.0
        
        wait for CLK_PERIOD * 5;
        
        tri_recv := to_integer(unsigned(triangles_out));
        if tri_recv = 3 then
            report "Test 5 PASSED: Assembled 3 triangles from fan" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 5 FAILED: Expected 3 triangles, got " & integer'image(tri_recv) severity error;
            fail_count := fail_count + 1;
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
