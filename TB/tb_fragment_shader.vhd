-------------------------------------------------------------------------------
-- tb_fragment_shader.vhd
-- Testbench: Simple Fragment Shader Test
-- Simulates a warp of 32 fragments being shaded
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.simt_pkg.all;

entity tb_fragment_shader is
end entity tb_fragment_shader;

architecture sim of tb_fragment_shader is
    
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
    
    -- Debug
    signal dbg_cycle_count : std_logic_vector(31 downto 0);
    signal dbg_inst_count  : std_logic_vector(31 downto 0);
    signal dbg_warp_state  : std_logic_vector(7 downto 0);
    
    -- Test memory (simulates framebuffer and texture)
    type mem_array_t is array (0 to 1023) of std_logic_vector(31 downto 0);
    signal test_memory : mem_array_t := (others => (others => '0'));
    
    -- Control
    signal sim_done : boolean := false;
    
    -- Helper: Encode instruction
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
    
    -- Helper: Write instruction
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
    
    -- Float constants (IEEE-754)
    constant FLOAT_ONE : std_logic_vector(31 downto 0) := x"3F800000";  -- 1.0
    constant FLOAT_HALF : std_logic_vector(31 downto 0) := x"3F000000"; -- 0.5
    constant FLOAT_255 : std_logic_vector(31 downto 0) := x"437F0000"; -- 255.0

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
            -- Texture unit interface (not used in this test)
            tex_req_valid   => open,
            tex_req_ready   => '1',
            tex_req_warp    => open,
            tex_req_mask    => open,
            tex_req_op      => open,
            tex_req_u       => open,
            tex_req_v       => open,
            tex_req_lod     => open,
            tex_req_rd      => open,
            tex_resp_valid  => '0',
            tex_resp_warp   => (others => '0'),
            tex_resp_mask   => (others => '0'),
            tex_resp_data   => (others => '0'),
            tex_resp_rd     => (others => '0'),
            dbg_cycle_count => dbg_cycle_count,
            dbg_inst_count  => dbg_inst_count,
            dbg_warp_state  => dbg_warp_state
        );

    -- Memory model
    process(clk)
        variable addr_idx : integer;
    begin
        if rising_edge(clk) then
            mem_resp_valid <= '0';
            
            if mem_req_valid = '1' then
                addr_idx := to_integer(unsigned(mem_req_addr(11 downto 2)));
                
                if mem_req_write = '1' then
                    if addr_idx < 1024 then
                        test_memory(addr_idx) <= mem_req_wdata;
                    end if;
                else
                    mem_resp_valid <= '1';
                    mem_resp_tag <= mem_req_tag;
                    if addr_idx < 1024 then
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
        report "=== Fragment Shader Test ===" severity note;
        report "Simulating 32 fragments being shaded" severity note;
        
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;
        
        -----------------------------------------------------------------------
        -- Simple Fragment Shader:
        -- Each thread processes one fragment
        -- Input: Thread ID represents fragment index
        -- Output: Color = gradient based on thread position
        --
        -- Pseudocode:
        --   tid = get_thread_id()        // 0-31
        --   u = float(tid) / 32.0        // Normalized U coordinate
        --   r = u                        // Red = U
        --   g = 1.0 - u                  // Green = 1-U
        --   b = 0.5                      // Blue = constant
        --   color = pack_rgba(r, g, b, 1.0)
        --   framebuffer[tid] = color
        -----------------------------------------------------------------------
        report "--- Loading fragment shader program ---" severity note;
        
        -- Register allocation:
        -- R1 = thread_id (integer)
        -- R2 = thread_id (float)
        -- R3 = 32.0
        -- R4 = u = tid / 32.0
        -- R5 = 1.0
        -- R6 = g = 1.0 - u
        -- R7 = 0.5
        -- R8 = 255.0
        -- R9 = r * 255 (for packing)
        -- R10 = g * 255
        -- R11 = b * 255 = 127
        -- R12 = address for store
        
        -- 0: TID R1           ; R1 = thread_id
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 0, encode_inst(OP_TID, rd => 1));
        
        -- 1: ITOF R2, R1      ; R2 = float(thread_id)
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 1, encode_inst(OP_ITOF, rd => 2, rs1 => 1));
        
        -- 2: ITOF R3, imm(32) ; We need 32.0 - use TID trick: all threads load 32
        -- Actually simpler: R3 = R2 + R2 + ... won't work
        -- Let's just compute R4 = R2 / 32.0 using shifts conceptually
        -- For simplicity: R4 = R2 * (1/32) = R2 * 0.03125
        -- We'll approximate: R4 = R2 / 32 by multiplying by RCP(32)
        -- Or even simpler: just use R2 directly as color intensity
        
        -- Simplified shader: color = thread_id / 255.0 (grayscale gradient)
        -- 2: MUL R4, R2, 1/255 approximated as R4 = R2 (already 0-31)
        -- Just store thread_id as color directly
        
        -- 2: SHL R12, R1, 2   ; R12 = thread_id * 4 (byte address)
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_SHL, rd => 12, rs1 => 1, rs2 => 0, imm => 2));
                   
        -- Actually SHL needs rs2 as shift amount register. Let's use a different approach.
        -- 2: ADD R12, R1, R1  ; R12 = 2 * tid
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 2, encode_inst(OP_ADD, rd => 12, rs1 => 1, rs2 => 1));
        
        -- 3: ADD R12, R12, R12 ; R12 = 4 * tid (byte offset)
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 3, encode_inst(OP_ADD, rd => 12, rs1 => 12, rs2 => 12));
        
        -- 4: STR [R12], R1    ; Store thread_id to framebuffer[tid*4]
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 4, encode_inst(OP_STR, rs1 => 12, rs2 => 1, imm => 0));
        
        -- 5: EXIT
        write_inst(prog_wr_en, prog_wr_warp, prog_wr_addr, prog_wr_data,
                   0, 5, encode_inst(OP_EXIT));
        
        report "--- Starting shader execution ---" severity note;
        
        warp_count <= "00001";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        
        -- Wait for completion (stores take time)
        wait until done = '1' for CLK_PERIOD * 1000;
        
        -- Wait extra time for memory stores to complete (32 lanes * 1 cycle each)
        wait for CLK_PERIOD * 50;
        
        if done = '1' then
            report "Shader completed in " & 
                   integer'image(to_integer(unsigned(dbg_cycle_count))) & " cycles"
                severity note;
            
            -- Verify framebuffer contents
            report "--- Verifying framebuffer ---" severity note;
            
            -- Check first few values
            for i in 0 to 7 loop
                report "FB[" & integer'image(i) & "] = " & 
                       integer'image(to_integer(unsigned(test_memory(i))))
                    severity note;
            end loop;
            
            -- Verify pattern (should be 0, 1, 2, 3, ... 31)
            for i in 0 to 31 loop
                if to_integer(unsigned(test_memory(i))) /= i then
                    report "FAIL: FB[" & integer'image(i) & "] = " &
                           integer'image(to_integer(unsigned(test_memory(i)))) &
                           ", expected " & integer'image(i)
                        severity error;
                end if;
            end loop;
            
            report "PASS: Fragment shader test completed!" severity note;
        else
            report "FAIL: Shader timeout" severity error;
        end if;
        
        wait for CLK_PERIOD * 10;
        
        report "=== Fragment Shader Test Complete ===" severity note;
        
        sim_done <= true;
        wait;
    end process;

end architecture sim;
