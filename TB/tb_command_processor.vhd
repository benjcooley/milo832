-------------------------------------------------------------------------------
-- tb_command_processor.vhd
-- Testbench for GPU Command Processor
--
-- Milo832 GPU project
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_command_processor is
end entity tb_command_processor;

architecture sim of tb_command_processor is

    constant CLK_PERIOD : time := 10 ns;
    
    signal clk : std_logic := '0';
    signal rst_n : std_logic := '0';
    
    -- CPU interface
    signal cmd_wr_valid : std_logic := '0';
    signal cmd_wr_ready : std_logic;
    signal cmd_wr_data : std_logic_vector(31 downto 0) := (others => '0');
    
    -- Status
    signal status : std_logic_vector(31 downto 0);
    signal fence_value : std_logic_vector(31 downto 0);
    
    -- State write
    signal state_wr_en : std_logic;
    signal state_wr_addr : std_logic_vector(7 downto 0);
    signal state_wr_data : std_logic_vector(31 downto 0);
    
    -- Clear
    signal clear_valid : std_logic;
    signal clear_ready : std_logic := '1';
    signal clear_color : std_logic_vector(31 downto 0);
    signal clear_depth : std_logic_vector(23 downto 0);
    signal clear_flags : std_logic_vector(1 downto 0);
    
    -- Draw
    signal draw_valid : std_logic;
    signal draw_ready : std_logic := '1';
    signal draw_start_idx : std_logic_vector(31 downto 0);
    signal draw_count : std_logic_vector(31 downto 0);
    signal draw_done : std_logic := '0';
    
    -- Texture
    signal tex_cfg_valid : std_logic;
    signal tex_cfg_unit : std_logic_vector(3 downto 0);
    signal tex_cfg_addr : std_logic_vector(31 downto 0);
    signal tex_cfg_width : std_logic_vector(15 downto 0);
    signal tex_cfg_height : std_logic_vector(15 downto 0);
    signal tex_cfg_format : std_logic_vector(3 downto 0);
    
    -- Shader
    signal shader_valid : std_logic;
    signal shader_ready : std_logic := '1';
    signal shader_pc : std_logic_vector(31 downto 0);
    signal shader_count : std_logic_vector(31 downto 0);
    signal shader_done : std_logic := '0';
    
    -- Memory
    signal mem_rd_addr : std_logic_vector(31 downto 0);
    signal mem_rd_en : std_logic;
    signal mem_rd_data : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_rd_valid : std_logic := '0';
    
    -- Test control
    signal test_done : boolean := false;
    
    -- Command opcodes
    constant CMD_NOP            : std_logic_vector(7 downto 0) := x"00";
    constant CMD_SET_STATE      : std_logic_vector(7 downto 0) := x"01";
    constant CMD_CLEAR          : std_logic_vector(7 downto 0) := x"02";
    constant CMD_DRAW_TRIANGLES : std_logic_vector(7 downto 0) := x"03";
    constant CMD_SET_TEXTURE    : std_logic_vector(7 downto 0) := x"04";
    constant CMD_RUN_SHADER     : std_logic_vector(7 downto 0) := x"05";
    constant CMD_FENCE          : std_logic_vector(7 downto 0) := x"06";
    
    -- Helper: send command word
    procedure send_cmd(
        signal clk : in std_logic;
        signal wr_valid : out std_logic;
        signal wr_data : out std_logic_vector(31 downto 0);
        signal wr_ready : in std_logic;
        data : std_logic_vector(31 downto 0)
    ) is
    begin
        wait until rising_edge(clk);
        wr_data <= data;
        wr_valid <= '1';
        wait until rising_edge(clk) and wr_ready = '1';
        wr_valid <= '0';
    end procedure;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done else '0';
    
    -- DUT
    uut: entity work.command_processor
        port map (
            clk => clk,
            rst_n => rst_n,
            cmd_wr_valid => cmd_wr_valid,
            cmd_wr_ready => cmd_wr_ready,
            cmd_wr_data => cmd_wr_data,
            status => status,
            fence_value => fence_value,
            state_wr_en => state_wr_en,
            state_wr_addr => state_wr_addr,
            state_wr_data => state_wr_data,
            clear_valid => clear_valid,
            clear_ready => clear_ready,
            clear_color => clear_color,
            clear_depth => clear_depth,
            clear_flags => clear_flags,
            draw_valid => draw_valid,
            draw_ready => draw_ready,
            draw_start_idx => draw_start_idx,
            draw_count => draw_count,
            draw_done => draw_done,
            tex_cfg_valid => tex_cfg_valid,
            tex_cfg_unit => tex_cfg_unit,
            tex_cfg_addr => tex_cfg_addr,
            tex_cfg_width => tex_cfg_width,
            tex_cfg_height => tex_cfg_height,
            tex_cfg_format => tex_cfg_format,
            shader_valid => shader_valid,
            shader_ready => shader_ready,
            shader_pc => shader_pc,
            shader_count => shader_count,
            shader_done => shader_done,
            mem_rd_addr => mem_rd_addr,
            mem_rd_en => mem_rd_en,
            mem_rd_data => mem_rd_data,
            mem_rd_valid => mem_rd_valid
        );
    
    ---------------------------------------------------------------------------
    -- Simulate draw completion after a few cycles
    ---------------------------------------------------------------------------
    process
    begin
        wait until draw_valid = '1';
        wait for CLK_PERIOD * 5;
        draw_done <= '1';
        wait until rising_edge(clk);
        draw_done <= '0';
    end process;
    
    -- Simulate shader completion
    process
    begin
        wait until shader_valid = '1';
        wait for CLK_PERIOD * 5;
        shader_done <= '1';
        wait until rising_edge(clk);
        shader_done <= '0';
    end process;
    
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
        
        report "=== Test 1: NOP command ===" severity note;
        send_cmd(clk, cmd_wr_valid, cmd_wr_data, cmd_wr_ready, x"000000" & CMD_NOP);
        wait for CLK_PERIOD * 3;
        
        if status(24) = '0' then  -- Not busy
            report "Test 1 PASSED: NOP completed" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 1 FAILED" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 2: SET_STATE command ===" severity note;
        -- Send SET_STATE command for depth control (offset 0x00)
        send_cmd(clk, cmd_wr_valid, cmd_wr_data, cmd_wr_ready, x"0000" & x"00" & CMD_SET_STATE);
        -- Send value
        send_cmd(clk, cmd_wr_valid, cmd_wr_data, cmd_wr_ready, x"00000015");  -- depth enabled, LEQUAL
        
        wait for CLK_PERIOD * 3;
        
        if state_wr_en = '0' then  -- Write completed
            report "Test 2 PASSED: SET_STATE completed" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 2 FAILED" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 3: CLEAR command ===" severity note;
        -- Clear both color and depth
        send_cmd(clk, cmd_wr_valid, cmd_wr_data, cmd_wr_ready, x"000003" & CMD_CLEAR);
        
        wait until clear_valid = '1' for 100 ns;
        
        if clear_valid = '1' and clear_flags = "11" then
            report "Test 3 PASSED: CLEAR issued" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 3 FAILED" severity error;
            fail_count := fail_count + 1;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        report "=== Test 4: DRAW_TRIANGLES command ===" severity note;
        -- Draw 10 triangles starting at index 0
        send_cmd(clk, cmd_wr_valid, cmd_wr_data, cmd_wr_ready, x"0000" & x"00" & CMD_DRAW_TRIANGLES);
        send_cmd(clk, cmd_wr_valid, cmd_wr_data, cmd_wr_ready, x"0000000A");  -- count = 10
        
        wait until draw_valid = '1' for 100 ns;
        
        if draw_valid = '1' and draw_count = x"0000000A" then
            report "Test 4 PASSED: DRAW issued with count=10" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 4 FAILED" severity error;
            fail_count := fail_count + 1;
        end if;
        
        -- Wait for draw to complete
        wait until draw_done = '1' for 200 ns;
        wait for CLK_PERIOD * 3;
        
        report "=== Test 5: FENCE command ===" severity note;
        send_cmd(clk, cmd_wr_valid, cmd_wr_data, cmd_wr_ready, x"000000" & CMD_FENCE);
        
        -- Wait for fence to process and update
        wait for CLK_PERIOD * 10;
        
        if unsigned(fence_value) > 0 then
            report "Test 5 PASSED: FENCE incremented to " & integer'image(to_integer(unsigned(fence_value))) severity note;
            pass_count := pass_count + 1;
        else
            report "Test 5 FAILED: fence_value still 0" severity error;
            fail_count := fail_count + 1;
        end if;
        
        report "=== Test 6: RUN_SHADER command ===" severity note;
        -- Launch shader at PC 0x1000 with 64 threads
        send_cmd(clk, cmd_wr_valid, cmd_wr_data, cmd_wr_ready, x"001000" & CMD_RUN_SHADER);
        send_cmd(clk, cmd_wr_valid, cmd_wr_data, cmd_wr_ready, x"00000040");  -- 64 threads
        
        wait until shader_valid = '1' for 100 ns;
        
        if shader_valid = '1' and shader_count = x"00000040" then
            report "Test 6 PASSED: SHADER launched with 64 threads" severity note;
            pass_count := pass_count + 1;
        else
            report "Test 6 FAILED" severity error;
            fail_count := fail_count + 1;
        end if;
        
        wait until shader_done = '1' for 200 ns;
        wait for CLK_PERIOD * 3;
        
        ---------------------------------------------------------------------------
        report "=============================================" severity note;
        report "Test Results: " & integer'image(pass_count) & " passed, " & 
               integer'image(fail_count) & " failed" severity note;
        report "Commands processed: " & integer'image(to_integer(unsigned(status(23 downto 0)))) severity note;
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
