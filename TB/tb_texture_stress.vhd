-------------------------------------------------------------------------------
-- tb_texture_stress.vhd
-- Texture Sampling Stress Test
-- Tests texture sampling from shader threads with multiple warps
--
-- Test scenarios:
-- 1. Single warp sampling - each thread samples different texel
-- 2. Multi-warp parallel sampling - stress the texture unit array
-- 3. Cache coherence - multiple threads sampling same texel
-- 4. Sequential vs random access patterns
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.simt_pkg.all;

entity tb_texture_stress is
end entity tb_texture_stress;

architecture sim of tb_texture_stress is

    constant CLK_PERIOD : time := 10 ns;
    constant WARP_SIZE : integer := 32;
    constant NUM_WARPS : integer := 4;
    constant C_TEX_WIDTH : integer := 64;
    constant C_TEX_HEIGHT : integer := 64;
    
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
    
    -- Texture configuration (64x64 RGBA8888)
    signal tex_base_addr    : std_logic_vector(31 downto 0) := x"10000000";
    signal tex_width        : std_logic_vector(11 downto 0) := std_logic_vector(to_unsigned(C_TEX_WIDTH, 12));
    signal tex_height       : std_logic_vector(11 downto 0) := std_logic_vector(to_unsigned(C_TEX_HEIGHT, 12));
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
    
    -- Texture memory simulation
    type tex_mem_t is array (0 to 4095) of std_logic_vector(31 downto 0);
    signal texture_memory : tex_mem_t;
    
    -- Memory request tracking
    signal pending_tex_addr : std_logic_vector(31 downto 0);
    signal pending_tex_id   : std_logic_vector(1 downto 0);
    signal tex_mem_pending  : boolean := false;
    -- Counters only driven by memory process (signals, read-only from test process)
    signal tex_req_count    : integer := 0;
    signal tex_resp_count   : integer := 0;
    
    ---------------------------------------------------------------------------
    -- Helper: Encode instruction
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
    -- Helper: Write instruction
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
    -- DUT: GPU Core
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
    -- Simulates texture memory with configurable latency
    -- Returns RGBA color based on texel address
    ---------------------------------------------------------------------------
    process(clk)
        variable addr_offset : integer;
        variable texel_x, texel_y : integer;
        variable color : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            tex_mem_resp_valid <= '0';
            
            if tex_mem_pending then
                -- Calculate texel position from address
                addr_offset := to_integer(unsigned(pending_tex_addr)) - 16#10000000#;
                texel_x := (addr_offset / 4) mod C_TEX_WIDTH;
                texel_y := (addr_offset / 4) / C_TEX_WIDTH;
                
                -- Generate predictable RGBA based on position
                -- R = x*4, G = y*4, B = (x+y)*2, A = 255
                color(31 downto 24) := std_logic_vector(to_unsigned((texel_x * 4) mod 256, 8));  -- R
                color(23 downto 16) := std_logic_vector(to_unsigned((texel_y * 4) mod 256, 8));  -- G
                color(15 downto 8)  := std_logic_vector(to_unsigned(((texel_x + texel_y) * 2) mod 256, 8));  -- B
                color(7 downto 0)   := x"FF";  -- A
                
                -- Return 64 bits (2 texels for RGBA8888)
                tex_mem_resp_data <= color & color;  -- Same color repeated (simplified)
                tex_mem_resp_id <= pending_tex_id;
                tex_mem_resp_valid <= '1';
                tex_mem_pending <= false;
                tex_resp_count <= tex_resp_count + 1;
                
            elsif tex_mem_req_valid = '1' and tex_mem_req_ready = '1' then
                pending_tex_addr <= tex_mem_req_addr;
                pending_tex_id <= tex_mem_req_id;
                tex_mem_pending <= true;
                tex_req_count <= tex_req_count + 1;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Global Memory Model (for store results)
    ---------------------------------------------------------------------------
    process(clk)
        variable mem_addr : integer;
    begin
        if rising_edge(clk) then
            mem_resp_valid <= '0';
            
            if mem_req_valid = '1' and mem_req_ready = '1' then
                if mem_req_write = '0' then
                    -- Read - return dummy data
                    mem_resp_valid <= '1';
                    mem_resp_data <= x"DEADBEEF";
                    mem_resp_tag <= mem_req_tag;
                end if;
                -- Writes are silently accepted
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Test Process
    ---------------------------------------------------------------------------
    process
        variable start_cycles : integer;
        variable end_cycles : integer;
        variable total_samples : integer;
        variable start_reqs : integer;
        variable end_reqs : integer;
    begin
        report "=== Texture Sampling Stress Test ===" severity note;
        
        -- Initialize
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 1: Single Warp - Each thread samples unique texel
        -- 32 threads, each samples texel at (tid, tid)
        -----------------------------------------------------------------------
        report "Test 1: Single warp, 32 unique texel samples" severity note;
        
        -- Shader program:
        -- R1 = tid (U coordinate = thread_id)
        -- R2 = tid (V coordinate = thread_id)  
        -- R3 = TEX(R1, R2)  -- Sample at (tid, tid)
        -- R4 = R3 + R3      -- Use the result
        -- EXIT
        
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));           -- R1 = tid
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_TID, rd => 2));           -- R2 = tid
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_TEX, rd => 3, rs1 => 1, rs2 => 2));  -- R3 = TEX
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_ADD, rd => 4, rs1 => 3, rs2 => 3));  -- R4 = R3 + R3
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 4, encode_inst(OP_EXIT));
        
        start_reqs := tex_req_count;
        
        warp_count <= "00001";  -- 1 warp
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        
        start_cycles := to_integer(unsigned(dbg_cycle_count));
        
        -- Wait for completion
        for i in 0 to 10000 loop
            wait until rising_edge(clk);
            if done = '1' then
                exit;
            end if;
        end loop;
        
        end_cycles := to_integer(unsigned(dbg_cycle_count));
        end_reqs := tex_req_count;
        
        test_count <= test_count + 1;
        if done = '1' then
            report "PASS: Test 1 completed" severity note;
            report "  Cycles: " & integer'image(end_cycles - start_cycles);
            report "  Tex memory requests: " & integer'image(end_reqs - start_reqs);
            report "  Cache hits: " & integer'image(to_integer(unsigned(dbg_tex_hits)));
            report "  Cache misses: " & integer'image(to_integer(unsigned(dbg_tex_misses)));
        else
            fail_count <= fail_count + 1;
            report "FAIL: Test 1 timeout" severity error;
        end if;
        
        -- Reset for next test
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 2: Multi-warp parallel sampling
        -- 4 warps, each with 32 threads = 128 texture samples
        -----------------------------------------------------------------------
        report "Test 2: 4 warps parallel, 128 texture samples" severity note;
        
        -- Load same shader for all 4 warps
        for w in 0 to 3 loop
            write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                       w, 0, encode_inst(OP_TID, rd => 1));
            write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                       w, 1, encode_inst(OP_TID, rd => 2));
            write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                       w, 2, encode_inst(OP_TEX, rd => 3, rs1 => 1, rs2 => 2));
            write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                       w, 3, encode_inst(OP_ADD, rd => 4, rs1 => 3, rs2 => 3));
            write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                       w, 4, encode_inst(OP_EXIT));
        end loop;
        
        start_reqs := tex_req_count;
        
        warp_count <= "00100";  -- 4 warps
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        
        start_cycles := to_integer(unsigned(dbg_cycle_count));
        
        for i in 0 to 20000 loop
            wait until rising_edge(clk);
            if done = '1' then
                exit;
            end if;
        end loop;
        
        end_cycles := to_integer(unsigned(dbg_cycle_count));
        end_reqs := tex_req_count;
        total_samples := 4 * 32;  -- 128 samples
        
        test_count <= test_count + 1;
        if done = '1' then
            report "PASS: Test 2 completed" severity note;
            report "  Total samples: " & integer'image(total_samples);
            report "  Cycles: " & integer'image(end_cycles - start_cycles);
            report "  Tex memory requests: " & integer'image(end_reqs - start_reqs);
            report "  Cache hits: " & integer'image(to_integer(unsigned(dbg_tex_hits)));
            report "  Cache misses: " & integer'image(to_integer(unsigned(dbg_tex_misses)));
            if total_samples > 0 then
                report "  Cycles per sample: " & integer'image((end_cycles - start_cycles) / total_samples);
            end if;
        else
            fail_count <= fail_count + 1;
            report "FAIL: Test 2 timeout" severity error;
        end if;
        
        -- Reset for next test
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 3: Multiple texture samples per thread
        -- Each thread samples 3 different texels
        -----------------------------------------------------------------------
        report "Test 3: Multiple samples per thread (3 samples each)" severity note;
        
        -- Shader: 3 texture samples per thread
        -- R1 = tid (base coord)
        -- R2 = tid
        -- R3 = TEX(R1, R2)       -- First sample at (tid, tid)
        -- R5 = R1 + R1           -- R5 = 2*tid
        -- R6 = TEX(R5, R2)       -- Second sample at (2*tid, tid)
        -- R7 = R5 + R1           -- R7 = 3*tid
        -- R8 = TEX(R7, R2)       -- Third sample at (3*tid, tid)
        -- R9 = R3 + R6           -- Combine results
        -- R10 = R9 + R8
        -- EXIT
        
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_TID, rd => 2));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_TEX, rd => 3, rs1 => 1, rs2 => 2));  -- Sample 1
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_ADD, rd => 5, rs1 => 1, rs2 => 1));  -- R5 = 2*tid
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 4, encode_inst(OP_TEX, rd => 6, rs1 => 5, rs2 => 2));  -- Sample 2
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 5, encode_inst(OP_ADD, rd => 7, rs1 => 5, rs2 => 1));  -- R7 = 3*tid
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 6, encode_inst(OP_TEX, rd => 8, rs1 => 7, rs2 => 2));  -- Sample 3
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 7, encode_inst(OP_ADD, rd => 9, rs1 => 3, rs2 => 6));  -- Combine
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 8, encode_inst(OP_ADD, rd => 10, rs1 => 9, rs2 => 8));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 9, encode_inst(OP_EXIT));
        
        start_reqs := tex_req_count;
        
        warp_count <= "00001";  -- 1 warp
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        
        start_cycles := to_integer(unsigned(dbg_cycle_count));
        
        for i in 0 to 20000 loop
            wait until rising_edge(clk);
            if done = '1' then
                exit;
            end if;
        end loop;
        
        end_cycles := to_integer(unsigned(dbg_cycle_count));
        end_reqs := tex_req_count;
        total_samples := 3 * 32;  -- 96 samples (3 per thread)
        
        test_count <= test_count + 1;
        if done = '1' then
            report "PASS: Test 3 completed" severity note;
            report "  Total samples: " & integer'image(total_samples);
            report "  Cycles: " & integer'image(end_cycles - start_cycles);
            report "  Tex memory requests: " & integer'image(end_reqs - start_reqs);
            report "  Cache hits: " & integer'image(to_integer(unsigned(dbg_tex_hits)));
            report "  Cache misses: " & integer'image(to_integer(unsigned(dbg_tex_misses)));
        else
            fail_count <= fail_count + 1;
            report "FAIL: Test 3 timeout" severity error;
        end if;
        
        -----------------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------------
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
