-------------------------------------------------------------------------------
-- tb_gpu_core.vhd
-- Unit Test: GPU Core with Texture Integration
-- Tests texture sampling through the SM pipeline
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.simt_pkg.all;

entity tb_gpu_core is
end entity tb_gpu_core;

architecture sim of tb_gpu_core is

    constant CLK_PERIOD : time := 10 ns;
    constant WARP_SIZE : integer := 32;
    constant NUM_WARPS : integer := 4;
    
    -- DUT signals
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    
    -- Control
    signal start        : std_logic := '0';
    signal done         : std_logic;
    signal warp_count   : std_logic_vector(4 downto 0) := "00001";
    
    -- Program memory
    signal prog_wr_en   : std_logic := '0';
    signal prog_wr_warp : std_logic_vector(4 downto 0) := (others => '0');
    signal prog_wr_addr : std_logic_vector(7 downto 0) := (others => '0');
    signal prog_wr_data : std_logic_vector(63 downto 0) := (others => '0');
    
    -- Global memory interface
    signal mem_req_valid  : std_logic;
    signal mem_req_ready  : std_logic := '1';
    signal mem_req_write  : std_logic;
    signal mem_req_addr   : std_logic_vector(31 downto 0);
    signal mem_req_wdata  : std_logic_vector(31 downto 0);
    signal mem_req_tag    : std_logic_vector(15 downto 0);
    
    signal mem_resp_valid : std_logic := '0';
    signal mem_resp_data  : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_resp_tag   : std_logic_vector(15 downto 0) := (others => '0');
    
    -- Texture memory interface
    signal tex_mem_req_valid  : std_logic;
    signal tex_mem_req_addr   : std_logic_vector(31 downto 0);
    signal tex_mem_req_id     : std_logic_vector(1 downto 0);
    signal tex_mem_req_ready  : std_logic := '1';
    
    signal tex_mem_resp_valid : std_logic := '0';
    signal tex_mem_resp_id    : std_logic_vector(1 downto 0) := "00";
    signal tex_mem_resp_data  : std_logic_vector(63 downto 0) := (others => '0');
    
    -- Texture configuration
    signal tex_base_addr    : std_logic_vector(31 downto 0) := x"10000000";
    signal tex_width        : std_logic_vector(11 downto 0) := x"040";  -- 64 pixels
    signal tex_height       : std_logic_vector(11 downto 0) := x"040";  -- 64 pixels
    signal tex_format       : std_logic_vector(3 downto 0) := "1000";   -- RGBA8888
    signal tex_wrap_mode    : std_logic_vector(3 downto 0) := "0000";   -- REPEAT
    signal tex_filter       : std_logic := '0';                         -- Nearest
    signal tex_mip_count    : std_logic_vector(3 downto 0) := "0001";
    signal tex_palette_addr : std_logic_vector(31 downto 0) := x"00000000";
    
    -- Debug
    signal dbg_cycle_count  : std_logic_vector(31 downto 0);
    signal dbg_inst_count   : std_logic_vector(31 downto 0);
    signal dbg_warp_state   : std_logic_vector(7 downto 0);
    signal dbg_tex_busy     : std_logic;
    signal dbg_tex_hits     : std_logic_vector(31 downto 0);
    signal dbg_tex_misses   : std_logic_vector(31 downto 0);
    
    -- Test control
    signal sim_done   : boolean := false;
    signal test_count : integer := 0;
    signal fail_count : integer := 0;
    
    -- Memory response tracking
    signal pending_tex_addr : std_logic_vector(31 downto 0);
    signal pending_tex_id   : std_logic_vector(1 downto 0);
    signal tex_mem_pending  : boolean := false;
    
    ---------------------------------------------------------------------------
    -- Helper: Encode instruction
    -- Format: [63:56]=op, [53:48]=rd, [45:40]=rs1, [37:32]=rs2, [29:24]=rs3, [19:0]=imm
    ---------------------------------------------------------------------------
    function encode_inst(
        op  : std_logic_vector(7 downto 0);
        rd  : integer := 0;
        rs1 : integer := 0;
        rs2 : integer := 0;
        rs3 : integer := 0;
        imm : integer := 0
    ) return std_logic_vector is
        variable inst : std_logic_vector(63 downto 0);
    begin
        inst := (others => '0');
        inst(63 downto 56) := op;
        inst(53 downto 48) := std_logic_vector(to_unsigned(rd, 6));
        inst(45 downto 40) := std_logic_vector(to_unsigned(rs1, 6));
        inst(37 downto 32) := std_logic_vector(to_unsigned(rs2, 6));
        inst(29 downto 24) := std_logic_vector(to_unsigned(rs3, 6));
        inst(19 downto 0) := std_logic_vector(to_signed(imm, 20));
        return inst;
    end function;
    
    ---------------------------------------------------------------------------
    -- Helper: Write instruction to program memory
    ---------------------------------------------------------------------------
    procedure write_inst(
        signal wr_en   : out std_logic;
        signal wr_warp : out std_logic_vector(4 downto 0);
        signal wr_addr : out std_logic_vector(7 downto 0);
        signal wr_data : out std_logic_vector(63 downto 0);
        warp : integer;
        addr : integer;
        inst : std_logic_vector(63 downto 0)
    ) is
    begin
        wr_en <= '1';
        wr_warp <= std_logic_vector(to_unsigned(warp, 5));
        wr_addr <= std_logic_vector(to_unsigned(addr, 8));
        wr_data <= inst;
        wait for CLK_PERIOD;
        wr_en <= '0';
        wait for CLK_PERIOD;
    end procedure;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not sim_done;
    
    ---------------------------------------------------------------------------
    -- DUT Instantiation
    ---------------------------------------------------------------------------
    u_gpu : entity work.gpu_core
        generic map (
            WARP_SIZE       => WARP_SIZE,
            NUM_WARPS       => NUM_WARPS,
            NUM_REGS        => 64,
            NUM_TEX_UNITS   => 2,
            PROG_MEM_SIZE   => 256
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            
            start           => start,
            done            => done,
            warp_count      => warp_count,
            
            prog_wr_en      => prog_wr_en,
            prog_wr_warp    => prog_wr_warp,
            prog_wr_addr    => prog_wr_addr,
            prog_wr_data    => prog_wr_data,
            
            mem_req_valid   => mem_req_valid,
            mem_req_ready   => mem_req_ready,
            mem_req_write   => mem_req_write,
            mem_req_addr    => mem_req_addr,
            mem_req_wdata   => mem_req_wdata,
            mem_req_tag     => mem_req_tag,
            
            mem_resp_valid  => mem_resp_valid,
            mem_resp_data   => mem_resp_data,
            mem_resp_tag    => mem_resp_tag,
            
            tex_mem_req_valid   => tex_mem_req_valid,
            tex_mem_req_addr    => tex_mem_req_addr,
            tex_mem_req_id      => tex_mem_req_id,
            tex_mem_req_ready   => tex_mem_req_ready,
            
            tex_mem_resp_valid  => tex_mem_resp_valid,
            tex_mem_resp_id     => tex_mem_resp_id,
            tex_mem_resp_data   => tex_mem_resp_data,
            
            tex_base_addr   => tex_base_addr,
            tex_width       => tex_width,
            tex_height      => tex_height,
            tex_format      => tex_format,
            tex_wrap_mode   => tex_wrap_mode,
            tex_filter      => tex_filter,
            tex_mip_count   => tex_mip_count,
            tex_palette_addr => tex_palette_addr,
            
            dbg_cycle_count => dbg_cycle_count,
            dbg_inst_count  => dbg_inst_count,
            dbg_warp_state  => dbg_warp_state,
            dbg_tex_busy    => dbg_tex_busy,
            dbg_tex_hits    => dbg_tex_hits,
            dbg_tex_misses  => dbg_tex_misses
        );
    
    ---------------------------------------------------------------------------
    -- Texture Memory Model
    -- Responds with simple pattern based on address
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            tex_mem_resp_valid <= '0';
            
            if tex_mem_pending then
                -- Respond with pattern based on address (simulates texture data)
                tex_mem_resp_data <= x"FF00FF00" & pending_tex_addr(7 downto 0) & x"AABBCC";
                tex_mem_resp_id <= pending_tex_id;
                tex_mem_resp_valid <= '1';
                tex_mem_pending <= false;
            elsif tex_mem_req_valid = '1' and tex_mem_req_ready = '1' then
                -- Capture request
                pending_tex_addr <= tex_mem_req_addr;
                pending_tex_id <= tex_mem_req_id;
                tex_mem_pending <= true;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Test Process
    ---------------------------------------------------------------------------
    process
    begin
        report "=== GPU Core Integration Test ===" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -------------------------------------------------
        -- Test 1: Simple program execution (no texture)
        -- Program: r1 = tid, r2 = r1 + r1, r3 = r2 + r1, EXIT
        -------------------------------------------------
        report "Test 1: Simple ALU program" severity note;
        
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));           -- R1 = tid
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_ADD, rd => 2, rs1 => 1, rs2 => 1));  -- R2 = 2*tid
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_ADD, rd => 3, rs1 => 2, rs2 => 1));  -- R3 = 3*tid
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_EXIT));                   -- EXIT
        
        warp_count <= "00001";  -- 1 warp
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        
        -- Wait for completion
        for i in 0 to 500 loop
            wait until rising_edge(clk);
            if done = '1' then
                exit;
            end if;
        end loop;
        
        test_count <= test_count + 1;
        if done = '1' then
            report "PASS: Simple program completed in " & 
                   integer'image(to_integer(unsigned(dbg_cycle_count))) & " cycles" severity note;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Program did not complete" severity error;
        end if;
        
        -- Reset for next test
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -------------------------------------------------
        -- Test 2: Texture sampling program
        -- Program:
        --   R1 = tid (used as U coordinate)
        --   R2 = tid (used as V coordinate)
        --   R3 = TEX(R1, R2)  -- texture sample
        --   EXIT
        -------------------------------------------------
        report "Test 2: Texture sampling" severity note;
        
        -- Use TID as UV coordinates (each thread samples different texel)
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));           -- R1 = tid (U)
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_TID, rd => 2));           -- R2 = tid (V)
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_TEX, rd => 3, rs1 => 1, rs2 => 2));  -- R3 = TEX(R1, R2)
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_EXIT));                   -- EXIT
        
        warp_count <= "00001";  -- 1 warp
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        
        -- Wait for completion (texture ops take longer)
        for i in 0 to 5000 loop
            wait until rising_edge(clk);
            if done = '1' then
                exit;
            end if;
        end loop;
        
        test_count <= test_count + 1;
        if done = '1' then
            report "PASS: Texture program completed" severity note;
            report "  Cycles: " & integer'image(to_integer(unsigned(dbg_cycle_count)));
            report "  Tex cache hits: " & integer'image(to_integer(unsigned(dbg_tex_hits)));
            report "  Tex cache misses: " & integer'image(to_integer(unsigned(dbg_tex_misses)));
        else
            fail_count <= fail_count + 1;
            report "FAIL: Texture program did not complete" severity error;
            report "  Tex busy: " & std_logic'image(dbg_tex_busy);
        end if;
        
        -------------------------------------------------
        -- Summary
        -------------------------------------------------
        wait for CLK_PERIOD * 10;
        report "=== Test Summary ===" severity note;
        report "Total: " & integer'image(test_count) & 
               " Passed: " & integer'image(test_count - fail_count) &
               " Failed: " & integer'image(fail_count) severity note;
        
        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "FAIL: SOME TESTS FAILED" severity error;
        end if;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
