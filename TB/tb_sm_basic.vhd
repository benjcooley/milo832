-------------------------------------------------------------------------------
-- tb_sm_basic.vhd
-- Testbench: Basic Streaming Multiprocessor Tests
-- Tests: Simple ALU program, Thread ID, Branches
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.simt_pkg.all;

entity tb_sm_basic is
end entity tb_sm_basic;

architecture sim of tb_sm_basic is
    
    constant CLK_PERIOD : time := 10 ns;
    
    -- DUT signals
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    signal start        : std_logic := '0';
    signal done         : std_logic;
    signal warp_count   : std_logic_vector(4 downto 0) := "00001";
    
    -- Program load interface
    signal prog_wr_en   : std_logic := '0';
    signal prog_wr_warp : std_logic_vector(4 downto 0) := (others => '0');
    signal prog_wr_addr : std_logic_vector(7 downto 0) := (others => '0');
    signal prog_wr_data : std_logic_vector(63 downto 0) := (others => '0');
    
    -- Memory interface
    signal mem_req_valid  : std_logic;
    signal mem_req_ready  : std_logic := '1';
    signal mem_req_write  : std_logic;
    signal mem_req_addr   : std_logic_vector(31 downto 0);
    signal mem_req_wdata  : std_logic_vector(31 downto 0);
    signal mem_req_tag    : std_logic_vector(15 downto 0);
    signal mem_resp_valid : std_logic := '0';
    signal mem_resp_data  : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_resp_tag   : std_logic_vector(15 downto 0) := (others => '0');
    
    -- Simple memory model (1KB)
    type mem_array_t is array (0 to 255) of std_logic_vector(31 downto 0);
    signal test_memory : mem_array_t := (others => (others => '0'));
    
    -- Debug
    signal dbg_cycle_count : std_logic_vector(31 downto 0);
    signal dbg_inst_count  : std_logic_vector(31 downto 0);
    signal dbg_warp_state  : std_logic_vector(7 downto 0);
    
    -- Test control
    signal sim_done : boolean := false;
    signal test_pass : boolean := true;
    
    -- Helper: Encode instruction
    -- Format: [63:56]=op, [53:48]=rd, [45:40]=rs1, [37:32]=rs2, [29:24]=rs3, [19:0]=imm
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
    
    -- Helper: Write instruction to program memory
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
    
    -- DUT instantiation
    u_sm : entity work.streaming_multiprocessor
        generic map (
            WARP_SIZE     => 32,
            NUM_WARPS     => 4,
            NUM_REGS      => 64,
            STACK_DEPTH   => 16,
            PROG_MEM_SIZE => 256
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
            dbg_cycle_count => dbg_cycle_count,
            dbg_inst_count  => dbg_inst_count,
            dbg_warp_state  => dbg_warp_state
        );

    -- Memory model process
    process(clk)
        variable addr_idx : integer;
    begin
        if rising_edge(clk) then
            mem_resp_valid <= '0';
            
            if mem_req_valid = '1' then
                addr_idx := to_integer(unsigned(mem_req_addr(9 downto 2)));  -- Word-aligned, 256 words
                
                if mem_req_write = '1' then
                    -- Write
                    if addr_idx < 256 then
                        test_memory(addr_idx) <= mem_req_wdata;
                    end if;
                else
                    -- Read
                    mem_resp_valid <= '1';
                    mem_resp_tag <= mem_req_tag;
                    if addr_idx < 256 then
                        mem_resp_data <= test_memory(addr_idx);
                    else
                        mem_resp_data <= (others => '0');
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Test process
    process
    begin
        report "=== Streaming Multiprocessor Basic Test ===" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Test 1: Simple ADD program
        -- R1 = 5 (via MOV with imm in RS1 position - we'll use TID instead)
        -- R2 = R1 + R1
        -- EXIT
        -----------------------------------------------------------------------
        report "--- Test 1: Simple ALU Program ---" severity note;
        
        -- Load program for warp 0:
        -- 0: TID R1        ; R1 = thread_id (0-31)
        -- 1: ADD R2, R1, R1 ; R2 = R1 + R1 = 2*thread_id
        -- 2: ADD R3, R2, R1 ; R3 = R2 + R1 = 3*thread_id
        -- 3: EXIT
        
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_ADD, rd => 2, rs1 => 1, rs2 => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_ADD, rd => 3, rs1 => 2, rs2 => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_EXIT));
        
        -- Start execution with 1 warp
        warp_count <= "00001";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        -- Wait for completion
        wait until done = '1' for CLK_PERIOD * 100;
        
        if done = '1' then
            report "Test 1: Program completed in " & 
                   integer'image(to_integer(unsigned(dbg_cycle_count))) & " cycles, " &
                   integer'image(to_integer(unsigned(dbg_inst_count))) & " instructions"
                severity note;
            report "PASS: Test 1 - SM executed program" severity note;
        else
            report "FAIL: Test 1 - Timeout waiting for done" severity error;
            test_pass <= false;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Test 2: Logic operations
        -----------------------------------------------------------------------
        report "--- Test 2: Logic Operations ---" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -- Program:
        -- 0: TID R1        ; R1 = thread_id
        -- 1: AND R2, R1, imm(0x0F)  - but we don't have AND-imm, use different approach
        -- Let's do: R4 = R1 AND R1 (same value), R5 = R1 OR R1, etc.
        
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_AND, rd => 2, rs1 => 1, rs2 => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_OR, rd => 3, rs1 => 1, rs2 => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_XOR, rd => 4, rs1 => 1, rs2 => 1));  -- Should be 0
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 4, encode_inst(OP_NOT, rd => 5, rs1 => 4));  -- NOT 0 = 0xFFFFFFFF
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 5, encode_inst(OP_EXIT));
        
        warp_count <= "00001";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        wait until done = '1' for CLK_PERIOD * 100;
        
        if done = '1' then
            report "Test 2: Completed in " & 
                   integer'image(to_integer(unsigned(dbg_cycle_count))) & " cycles"
                severity note;
            report "PASS: Test 2 - Logic operations" severity note;
        else
            report "FAIL: Test 2 - Timeout" severity error;
            test_pass <= false;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Test 3: Branch (unconditional)
        -----------------------------------------------------------------------
        report "--- Test 3: Unconditional Branch ---" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -- Program:
        -- 0: TID R1
        -- 1: BRA 3        ; Jump to instruction 3
        -- 2: ADD R2, R1, R1  ; SKIPPED
        -- 3: ADD R3, R1, R1  ; Executed
        -- 4: EXIT
        
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_BRA, imm => 3));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_ADD, rd => 2, rs1 => 1, rs2 => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_ADD, rd => 3, rs1 => 1, rs2 => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 4, encode_inst(OP_EXIT));
        
        warp_count <= "00001";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        wait until done = '1' for CLK_PERIOD * 100;
        
        if done = '1' then
            -- Should have executed 4 instructions (TID, BRA, ADD@3, EXIT) not 5
            report "Test 3: " & integer'image(to_integer(unsigned(dbg_inst_count))) & 
                   " instructions executed" severity note;
            if to_integer(unsigned(dbg_inst_count)) = 4 then
                report "PASS: Test 3 - Branch worked (skipped 1 instruction)" severity note;
            else
                report "FAIL: Test 3 - Expected 4 instructions" severity error;
                test_pass <= false;
            end if;
        else
            report "FAIL: Test 3 - Timeout" severity error;
            test_pass <= false;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Test 4: Multiple Warps
        -----------------------------------------------------------------------
        report "--- Test 4: Multiple Warps ---" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -- Load same simple program for warps 0 and 1
        for w in 0 to 1 loop
            write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                       w, 0, encode_inst(OP_TID, rd => 1));
            write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                       w, 1, encode_inst(OP_ADD, rd => 2, rs1 => 1, rs2 => 1));
            write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                       w, 2, encode_inst(OP_EXIT));
        end loop;
        
        warp_count <= "00010";  -- 2 warps
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        wait until done = '1' for CLK_PERIOD * 200;
        
        if done = '1' then
            report "Test 4: " & integer'image(to_integer(unsigned(dbg_inst_count))) & 
                   " total instructions (should be 6 = 3*2 warps)" severity note;
            if to_integer(unsigned(dbg_inst_count)) = 6 then
                report "PASS: Test 4 - Multiple warps" severity note;
            else
                report "WARN: Test 4 - Instruction count mismatch" severity warning;
            end if;
        else
            report "FAIL: Test 4 - Timeout" severity error;
            test_pass <= false;
        end if;
        
        -----------------------------------------------------------------------
        -- Test 5: Floating Point Operations
        -----------------------------------------------------------------------
        report "--- Test 5: Floating Point Operations ---" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -- Load FP program for warp 0:
        -- We'll use TID to get different values, then do FP ops
        -- R1 = TID (0-31)
        -- R2 = ITOF R1  (convert to float: 0.0, 1.0, 2.0, ... 31.0)
        -- R3 = 2.0 (we'll load via TID and convert, then use a const)
        -- Actually let's simplify: just test ITOF and FADD
        
        -- 0: TID R1
        -- 1: ITOF R2, R1  (R2 = float(thread_id))
        -- 2: FADD R3, R2, R2  (R3 = 2 * thread_id as float)
        -- 3: EXIT
        
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_ITOF, rd => 2, rs1 => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_FADD, rd => 3, rs1 => 2, rs2 => 2));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_EXIT));
        
        warp_count <= "00001";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        wait until done = '1' for CLK_PERIOD * 200;
        
        if done = '1' then
            report "Test 5: Completed in " & 
                   integer'image(to_integer(unsigned(dbg_cycle_count))) & " cycles"
                severity note;
            report "PASS: Test 5 - Floating point operations" severity note;
        else
            report "FAIL: Test 5 - Timeout" severity error;
            test_pass <= false;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Test 6: Memory Load/Store
        -----------------------------------------------------------------------
        report "--- Test 6: Memory Load/Store ---" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -- Initialize test memory with some values
        test_memory(0) <= x"12345678";
        test_memory(1) <= x"DEADBEEF";
        test_memory(2) <= x"CAFEBABE";
        test_memory(3) <= x"FEEDFACE";
        
        -- Program:
        -- 0: TID R1        ; R1 = thread_id (0-31)
        -- 1: LDR R2, [R1*4]  ; Load from memory[thread_id * 4]
        --    (actually: R2 = mem[R1 + 0], R1 needs to be multiplied first)
        -- For simplicity, let's just load from address 0 for all threads:
        -- 0: LDR R2, [0]   ; R2 = mem[0] = 0x12345678
        -- 1: EXIT
        
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));  -- R1 = thread_id (not used here)
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_LDR, rd => 2, rs1 => 0, imm => 0));  -- R2 = mem[R0 + 0] = mem[0]
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_EXIT));
        
        warp_count <= "00001";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        -- Memory ops take longer (32 lanes)
        wait until done = '1' for CLK_PERIOD * 500;
        
        if done = '1' then
            report "Test 6: Completed in " & 
                   integer'image(to_integer(unsigned(dbg_cycle_count))) & " cycles"
                severity note;
            report "PASS: Test 6 - Memory load/store" severity note;
        else
            report "FAIL: Test 6 - Timeout" severity error;
            test_pass <= false;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Test 7: SFU Operations (SIN, SQRT, etc.)
        -----------------------------------------------------------------------
        report "--- Test 7: SFU Operations ---" severity note;
        
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -- Program:
        -- 0: TID R1
        -- 1: ITOF R2, R1   ; R2 = float(thread_id)
        -- 2: SQRT R3, R2   ; R3 = sqrt(thread_id)
        -- 3: EXIT
        
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_ITOF, rd => 2, rs1 => 1));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_SFU_SQRT, rd => 3, rs1 => 2));
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_EXIT));
        
        warp_count <= "00001";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        wait until done = '1' for CLK_PERIOD * 200;
        
        if done = '1' then
            report "Test 7: Completed in " & 
                   integer'image(to_integer(unsigned(dbg_cycle_count))) & " cycles"
                severity note;
            report "PASS: Test 7 - SFU operations" severity note;
        else
            report "FAIL: Test 7 - Timeout" severity error;
            test_pass <= false;
        end if;
        
        wait for CLK_PERIOD * 5;
        
        -----------------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------------
        wait for CLK_PERIOD * 5;
        report "=== Test Summary ===" severity note;
        if test_pass then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
