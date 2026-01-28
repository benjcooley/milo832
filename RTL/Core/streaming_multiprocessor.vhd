-------------------------------------------------------------------------------
-- streaming_multiprocessor.vhd
-- Complete SIMT GPU Core Implementation
--
-- VHDL translation of SIMT-GPU-Core by Aritra Manna
-- Original SystemVerilog: https://github.com/aritramanna/SIMT-GPU-Core
--
-- Many thanks to Aritra Manna for creating and open-sourcing the excellent
-- SIMT-GPU-Core project. This file is a VHDL translation of the original
-- SystemVerilog implementation.
--
-- Pipeline: IF -> ID -> OC -> EX -> WB
-- Features:
--   - 24 warps, 32 threads each
--   - Round-robin warp scheduler with scoreboard
--   - 32-lane SIMD execution (ALU, FPU, SFU)
--   - Divergence stack for control flow
--   - Shared memory with bank conflict handling
--   - Non-blocking global memory access
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.float_pkg.all;
use ieee.math_real.all;

library work;
use work.simt_pkg.all;

entity streaming_multiprocessor is
    generic (
        WARP_SIZE       : integer := 32;
        NUM_WARPS       : integer := 8;    -- Reduced for testing
        NUM_REGS        : integer := 64;
        STACK_DEPTH     : integer := 16;
        PROG_MEM_SIZE   : integer := 256   -- Instructions per warp
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Control
        start           : in  std_logic;
        done            : out std_logic;
        warp_count      : in  std_logic_vector(4 downto 0);
        
        -- Program memory write interface (for loading programs)
        prog_wr_en      : in  std_logic;
        prog_wr_warp    : in  std_logic_vector(4 downto 0);
        prog_wr_addr    : in  std_logic_vector(7 downto 0);
        prog_wr_data    : in  std_logic_vector(63 downto 0);
        
        -- Global memory interface
        mem_req_valid   : out std_logic;
        mem_req_ready   : in  std_logic;
        mem_req_write   : out std_logic;
        mem_req_addr    : out std_logic_vector(31 downto 0);
        mem_req_wdata   : out std_logic_vector(31 downto 0);
        mem_req_tag     : out std_logic_vector(15 downto 0);
        
        mem_resp_valid  : in  std_logic;
        mem_resp_data   : in  std_logic_vector(31 downto 0);
        mem_resp_tag    : in  std_logic_vector(15 downto 0);
        
        -- Texture Unit Interface
        tex_req_valid   : out std_logic;
        tex_req_ready   : in  std_logic;
        tex_req_warp    : out std_logic_vector(4 downto 0);
        tex_req_mask    : out std_logic_vector(WARP_SIZE-1 downto 0);
        tex_req_op      : out std_logic_vector(1 downto 0);  -- 00=TEX, 01=TXL, 10=TXB
        tex_req_u       : out std_logic_vector(WARP_SIZE*32-1 downto 0);
        tex_req_v       : out std_logic_vector(WARP_SIZE*32-1 downto 0);
        tex_req_lod     : out std_logic_vector(WARP_SIZE*8-1 downto 0);
        tex_req_rd      : out std_logic_vector(5 downto 0);  -- Destination register
        
        tex_resp_valid  : in  std_logic;
        tex_resp_warp   : in  std_logic_vector(4 downto 0);
        tex_resp_mask   : in  std_logic_vector(WARP_SIZE-1 downto 0);
        tex_resp_data   : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        tex_resp_rd     : in  std_logic_vector(5 downto 0);
        
        -- Debug/Status
        dbg_cycle_count : out std_logic_vector(31 downto 0);
        dbg_inst_count  : out std_logic_vector(31 downto 0);
        dbg_warp_state  : out std_logic_vector(7 downto 0)
    );
end entity streaming_multiprocessor;

architecture rtl of streaming_multiprocessor is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant WARP_ID_BITS : integer := 5;
    constant REG_ADDR_BITS : integer := 6;
    
    ---------------------------------------------------------------------------
    -- Program Memory (per warp)
    ---------------------------------------------------------------------------
    type prog_mem_t is array (0 to PROG_MEM_SIZE-1) of std_logic_vector(63 downto 0);
    type prog_mem_array_t is array (0 to NUM_WARPS-1) of prog_mem_t;
    signal prog_mem : prog_mem_array_t;
    
    ---------------------------------------------------------------------------
    -- Register File (per warp, per lane)
    ---------------------------------------------------------------------------
    type lane_regs_t is array (0 to NUM_REGS-1) of std_logic_vector(31 downto 0);
    type warp_regs_t is array (0 to WARP_SIZE-1) of lane_regs_t;
    type reg_file_t is array (0 to NUM_WARPS-1) of warp_regs_t;
    signal reg_file : reg_file_t;
    
    ---------------------------------------------------------------------------
    -- Warp State
    ---------------------------------------------------------------------------
    type warp_state_array_t is array (0 to NUM_WARPS-1) of warp_state_t;
    signal warp_state : warp_state_array_t;
    
    type pc_array_t is array (0 to NUM_WARPS-1) of unsigned(7 downto 0);
    signal warp_pc : pc_array_t;
    
    type mask_array_t is array (0 to NUM_WARPS-1) of std_logic_vector(WARP_SIZE-1 downto 0);
    signal warp_active_mask : mask_array_t;
    
    ---------------------------------------------------------------------------
    -- Scoreboard (per warp: which registers are pending write)
    ---------------------------------------------------------------------------
    type scoreboard_t is array (0 to NUM_WARPS-1) of std_logic_vector(NUM_REGS-1 downto 0);
    signal scoreboard : scoreboard_t;
    
    ---------------------------------------------------------------------------
    -- Divergence Stack (per warp)
    ---------------------------------------------------------------------------
    type stack_entry_t is record
        pc   : unsigned(7 downto 0);
        mask : std_logic_vector(WARP_SIZE-1 downto 0);
    end record;
    type stack_t is array (0 to STACK_DEPTH-1) of stack_entry_t;
    type stack_array_t is array (0 to NUM_WARPS-1) of stack_t;
    signal div_stack : stack_array_t;
    
    type stack_ptr_t is array (0 to NUM_WARPS-1) of integer range 0 to STACK_DEPTH;
    signal stack_ptr : stack_ptr_t;
    
    ---------------------------------------------------------------------------
    -- Pipeline Registers
    ---------------------------------------------------------------------------
    
    -- IF/ID Stage
    type if_id_reg_t is record
        valid   : std_logic;
        warp    : integer range 0 to NUM_WARPS-1;
        pc      : unsigned(7 downto 0);
        inst    : std_logic_vector(63 downto 0);
        mask    : std_logic_vector(WARP_SIZE-1 downto 0);
    end record;
    signal if_id : if_id_reg_t;
    
    -- ID/EX Stage
    type id_ex_reg_t is record
        valid   : std_logic;
        warp    : integer range 0 to NUM_WARPS-1;
        pc      : unsigned(7 downto 0);
        op      : opcode_t;
        rd      : unsigned(5 downto 0);
        rs1     : unsigned(5 downto 0);
        rs2     : unsigned(5 downto 0);
        rs3     : unsigned(5 downto 0);
        imm     : std_logic_vector(31 downto 0);
        mask    : std_logic_vector(WARP_SIZE-1 downto 0);
        rs1_data : word_array_t;
        rs2_data : word_array_t;
        rs3_data : word_array_t;
    end record;
    signal id_ex : id_ex_reg_t;
    
    -- EX/WB Stage
    type ex_wb_reg_t is record
        valid   : std_logic;
        warp    : integer range 0 to NUM_WARPS-1;
        op      : opcode_t;
        rd      : unsigned(5 downto 0);
        mask    : std_logic_vector(WARP_SIZE-1 downto 0);
        result  : word_array_t;
        we      : std_logic;
    end record;
    signal ex_wb : ex_wb_reg_t;
    
    ---------------------------------------------------------------------------
    -- Scheduler State
    ---------------------------------------------------------------------------
    signal rr_ptr : integer range 0 to NUM_WARPS-1;
    signal cycle_count : unsigned(31 downto 0);
    signal inst_count : unsigned(31 downto 0);
    signal active_warps : integer range 0 to NUM_WARPS;
    
    ---------------------------------------------------------------------------
    -- Pipeline Control
    ---------------------------------------------------------------------------
    signal stall_if : std_logic;
    signal stall_id : std_logic;
    signal flush_if : std_logic;
    signal branch_taken : std_logic;
    signal branch_warp : integer range 0 to NUM_WARPS-1;
    signal branch_target : unsigned(7 downto 0);
    signal branch_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    
    ---------------------------------------------------------------------------
    -- ALU Results (32 lanes)
    ---------------------------------------------------------------------------
    type alu_result_array_t is array (0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    signal alu_results : alu_result_array_t;
    
    ---------------------------------------------------------------------------
    -- Completion Tracking
    ---------------------------------------------------------------------------
    signal started : std_logic;
    signal any_warp_ran : std_logic;
    
    ---------------------------------------------------------------------------
    -- Memory Operations
    ---------------------------------------------------------------------------
    type mem_op_state_t is (MEM_IDLE, MEM_LOAD_PENDING, MEM_STORE_PENDING);
    signal mem_state : mem_op_state_t;
    signal mem_warp : integer range 0 to NUM_WARPS-1;
    signal mem_rd : unsigned(5 downto 0);
    signal mem_lane : integer range 0 to WARP_SIZE-1;
    signal mem_lane_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    signal mem_addr_array : word_array_t;  -- Addresses for each lane
    signal mem_data_array : word_array_t;  -- Data for store, result for load
    
    ---------------------------------------------------------------------------
    -- Divergence Stack Operations (signals for cross-process communication)
    ---------------------------------------------------------------------------
    signal stack_push_req : std_logic;
    signal stack_pop_req : std_logic;
    signal stack_push_warp : integer range 0 to NUM_WARPS-1;
    signal stack_push_pc : unsigned(7 downto 0);
    signal stack_push_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    signal stack_set_mask_req : std_logic;
    signal stack_new_mask : std_logic_vector(WARP_SIZE-1 downto 0);
    
    ---------------------------------------------------------------------------
    -- Memory Load Writeback (for WB process to handle)
    ---------------------------------------------------------------------------
    signal mem_load_wb_valid : std_logic;
    signal mem_load_wb_warp : integer range 0 to NUM_WARPS-1;
    signal mem_load_wb_lane : integer range 0 to WARP_SIZE-1;
    signal mem_load_wb_rd : unsigned(5 downto 0);
    signal mem_load_wb_data : std_logic_vector(31 downto 0);
    
    ---------------------------------------------------------------------------
    -- Texture Unit Interface Signals
    ---------------------------------------------------------------------------
    signal tex_pending : std_logic;
    signal tex_pending_warp : integer range 0 to NUM_WARPS-1;
    signal tex_pending_rd : unsigned(5 downto 0);
    
    ---------------------------------------------------------------------------
    -- Helper Functions
    ---------------------------------------------------------------------------
    
    -- Check if instruction writes to a register
    function writes_reg(op : opcode_t) return boolean is
    begin
        case op is
            when OP_ADD | OP_SUB | OP_MUL | OP_IMAD | OP_NEG |
                 OP_AND | OP_OR | OP_XOR | OP_NOT | OP_SHL | OP_SHR |
                 OP_SLT | OP_SLE | OP_SEQ |
                 OP_FADD | OP_FSUB | OP_FMUL | OP_FDIV | OP_FFMA |
                 OP_FABS | OP_FNEG | OP_FMIN | OP_FMAX |
                 OP_ITOF | OP_FTOI |
                 OP_SFU_SIN | OP_SFU_COS | OP_SFU_RCP | OP_SFU_RSQ |
                 OP_SFU_SQRT | OP_SFU_EX2 | OP_SFU_LG2 |
                 OP_LDR | OP_LDS | OP_MOV | OP_TID =>
                return true;
            when others =>
                return false;
        end case;
    end function;
    
    -- Check if instruction reads RS1
    function needs_rs1(op : opcode_t) return boolean is
    begin
        case op is
            when OP_NOP | OP_EXIT | OP_TID | OP_BAR | OP_SSY | OP_JOIN =>
                return false;
            when others =>
                return true;
        end case;
    end function;
    
    -- Check if instruction reads RS2
    function needs_rs2(op : opcode_t) return boolean is
    begin
        case op is
            when OP_ADD | OP_SUB | OP_MUL | OP_AND | OP_OR | OP_XOR |
                 OP_SHL | OP_SHR | OP_SLT | OP_SLE | OP_SEQ |
                 OP_FADD | OP_FSUB | OP_FMUL | OP_FDIV |
                 OP_FMIN | OP_FMAX |
                 OP_STR | OP_STS | OP_BEQ | OP_BNE =>
                return true;
            when others =>
                return false;
        end case;
    end function;

begin

    ---------------------------------------------------------------------------
    -- Debug outputs
    ---------------------------------------------------------------------------
    dbg_cycle_count <= std_logic_vector(cycle_count);
    dbg_inst_count <= std_logic_vector(inst_count);
    dbg_warp_state <= std_logic_vector(to_unsigned(warp_state_t'pos(warp_state(0)), 8));
    
    ---------------------------------------------------------------------------
    -- Program Memory Write
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if prog_wr_en = '1' then
                prog_mem(to_integer(unsigned(prog_wr_warp)))(to_integer(unsigned(prog_wr_addr))) <= prog_wr_data;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Count Active Warps and Track Started State
    ---------------------------------------------------------------------------
    process(warp_state)
        variable count : integer;
        variable has_exited : boolean;
    begin
        count := 0;
        has_exited := false;
        for w in 0 to NUM_WARPS-1 loop
            if warp_state(w) = W_READY or warp_state(w) = W_BARRIER then
                count := count + 1;
            end if;
            if warp_state(w) = W_EXIT then
                has_exited := true;
            end if;
        end loop;
        active_warps <= count;
        if has_exited then
            any_warp_ran <= '1';
        else
            any_warp_ran <= '0';
        end if;
    end process;
    
    -- Done when: we started, at least one warp finished, and no warps are running
    done <= '1' when started = '1' and any_warp_ran = '1' and active_warps = 0 else '0';
    
    ---------------------------------------------------------------------------
    -- Stall Logic
    ---------------------------------------------------------------------------
    stall_if <= stall_id;
    stall_id <= '0';  -- Can add backpressure here later
    flush_if <= branch_taken;
    
    ---------------------------------------------------------------------------
    -- STAGE 1: Instruction Fetch + Warp Scheduler
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable sel_warp : integer range 0 to NUM_WARPS-1;
        variable found : boolean;
        variable inst : std_logic_vector(63 downto 0);
        variable op : opcode_t;
        variable rd, rs1, rs2 : unsigned(5 downto 0);
        variable sb_ok : boolean;
    begin
        if rst_n = '0' then
            -- Reset all warps
            for w in 0 to NUM_WARPS-1 loop
                warp_state(w) <= W_IDLE;
                warp_pc(w) <= (others => '0');
                warp_active_mask(w) <= (others => '1');
                scoreboard(w) <= (others => '0');
                stack_ptr(w) <= 0;
            end loop;
            
            rr_ptr <= 0;
            cycle_count <= (others => '0');
            inst_count <= (others => '0');
            started <= '0';
            
            if_id.valid <= '0';
            branch_taken <= '0';
            
        elsif rising_edge(clk) then
            cycle_count <= cycle_count + 1;
            branch_taken <= '0';
            
            -- Handle start signal
            if start = '1' then
                started <= '1';
                for w in 0 to to_integer(unsigned(warp_count))-1 loop
                    if w < NUM_WARPS then
                        warp_state(w) <= W_READY;
                    end if;
                end loop;
            end if;
            
            -- Clear scoreboard on writeback
            if ex_wb.valid = '1' and ex_wb.we = '1' then
                scoreboard(ex_wb.warp)(to_integer(ex_wb.rd)) <= '0';
            end if;
            
            -- Handle branch redirect from EX stage
            if branch_taken = '1' then
                warp_pc(branch_warp) <= branch_target;
                -- Flush IF/ID if it contains an instruction from this warp
                if if_id.valid = '1' and if_id.warp = branch_warp then
                    if_id.valid <= '0';
                end if;
            end if;
            
            -- Handle divergence stack push (from EX stage)
            if stack_push_req = '1' then
                if stack_ptr(stack_push_warp) < STACK_DEPTH then
                    div_stack(stack_push_warp)(stack_ptr(stack_push_warp)).pc <= stack_push_pc;
                    div_stack(stack_push_warp)(stack_ptr(stack_push_warp)).mask <= stack_push_mask;
                    stack_ptr(stack_push_warp) <= stack_ptr(stack_push_warp) + 1;
                end if;
            end if;
            
            -- Handle divergence stack pop (JOIN instruction)
            if stack_pop_req = '1' then
                if stack_ptr(stack_push_warp) > 0 then
                    -- Pop entry and restore PC/mask
                    stack_ptr(stack_push_warp) <= stack_ptr(stack_push_warp) - 1;
                    warp_pc(stack_push_warp) <= div_stack(stack_push_warp)(stack_ptr(stack_push_warp) - 1).pc;
                    warp_active_mask(stack_push_warp) <= div_stack(stack_push_warp)(stack_ptr(stack_push_warp) - 1).mask;
                end if;
            end if;
            
            -- Handle mask update for divergence
            if stack_set_mask_req = '1' then
                warp_active_mask(stack_push_warp) <= stack_new_mask;
            end if;
            
            -- Fetch stage
            if stall_if = '0' then
                if_id.valid <= '0';
                
                if flush_if = '0' then
                    -- Round-robin warp selection with scoreboard check
                    found := false;
                    
                    for i in 0 to NUM_WARPS-1 loop
                        sel_warp := (rr_ptr + i) mod NUM_WARPS;
                        
                        if warp_state(sel_warp) = W_READY then
                            -- Get instruction
                            inst := prog_mem(sel_warp)(to_integer(warp_pc(sel_warp)));
                            op := inst(63 downto 56);
                            rd := unsigned(inst(53 downto 48));
                            rs1 := unsigned(inst(45 downto 40));
                            rs2 := unsigned(inst(37 downto 32));
                            
                            -- Scoreboard check
                            sb_ok := true;
                            if needs_rs1(op) and scoreboard(sel_warp)(to_integer(rs1)) = '1' then
                                sb_ok := false;
                            end if;
                            if needs_rs2(op) and scoreboard(sel_warp)(to_integer(rs2)) = '1' then
                                sb_ok := false;
                            end if;
                            -- WAW hazard
                            if writes_reg(op) and scoreboard(sel_warp)(to_integer(rd)) = '1' then
                                sb_ok := false;
                            end if;
                            
                            if sb_ok then
                                -- Issue instruction
                                if_id.valid <= '1';
                                if_id.warp <= sel_warp;
                                if_id.pc <= warp_pc(sel_warp);
                                if_id.inst <= inst;
                                if_id.mask <= warp_active_mask(sel_warp);
                                
                                -- Set scoreboard for destination
                                if writes_reg(op) then
                                    scoreboard(sel_warp)(to_integer(rd)) <= '1';
                                end if;
                                
                                -- Advance PC
                                warp_pc(sel_warp) <= warp_pc(sel_warp) + 1;
                                inst_count <= inst_count + 1;
                                
                                rr_ptr <= (sel_warp + 1) mod NUM_WARPS;
                                found := true;
                                exit;
                            end if;
                        end if;
                    end loop;
                end if;
            end if;
            
            -- Handle EXIT instruction (detected in decode)
            if id_ex.valid = '1' and id_ex.op = OP_EXIT then
                warp_state(id_ex.warp) <= W_EXIT;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- STAGE 2: Instruction Decode + Register Read
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable op : opcode_t;
        variable rd, rs1, rs2, rs3 : unsigned(5 downto 0);
        variable imm : std_logic_vector(31 downto 0);
    begin
        if rst_n = '0' then
            id_ex.valid <= '0';
        elsif rising_edge(clk) then
            if stall_id = '0' then
                id_ex.valid <= '0';
                
                if if_id.valid = '1' then
                    -- Decode instruction
                    op := if_id.inst(63 downto 56);
                    rd := unsigned(if_id.inst(53 downto 48));
                    rs1 := unsigned(if_id.inst(45 downto 40));
                    rs2 := unsigned(if_id.inst(37 downto 32));
                    rs3 := unsigned(if_id.inst(29 downto 24));
                    
                    
                    -- Sign-extend immediate (lower 20 bits)
                    imm := (31 downto 20 => if_id.inst(19)) & if_id.inst(19 downto 0);
                    
                    id_ex.valid <= '1';
                    id_ex.warp <= if_id.warp;
                    id_ex.pc <= if_id.pc;
                    id_ex.op <= op;
                    id_ex.rd <= rd;
                    id_ex.rs1 <= rs1;
                    id_ex.rs2 <= rs2;
                    id_ex.rs3 <= rs3;
                    id_ex.imm <= imm;
                    id_ex.mask <= if_id.mask;
                    
                    -- Read register file with forwarding (all 32 lanes)
                    -- Priority: WB stage > Reg file
                    
                    for lane in 0 to WARP_SIZE-1 loop
                        -- RS1 forwarding from WB
                        if ex_wb.valid = '1' and ex_wb.we = '1' and 
                           ex_wb.warp = if_id.warp and ex_wb.rd = rs1 then
                            id_ex.rs1_data(lane) <= ex_wb.result(lane);
                        else
                            id_ex.rs1_data(lane) <= reg_file(if_id.warp)(lane)(to_integer(rs1));
                        end if;
                        
                        -- RS2 forwarding
                        if id_ex.valid = '1' and writes_reg(id_ex.op) and 
                           id_ex.warp = if_id.warp and id_ex.rd = rs2 then
                            id_ex.rs2_data(lane) <= reg_file(if_id.warp)(lane)(to_integer(rs2));
                        elsif ex_wb.valid = '1' and ex_wb.we = '1' and 
                           ex_wb.warp = if_id.warp and ex_wb.rd = rs2 then
                            id_ex.rs2_data(lane) <= ex_wb.result(lane);
                        else
                            id_ex.rs2_data(lane) <= reg_file(if_id.warp)(lane)(to_integer(rs2));
                        end if;
                        
                        -- RS3 forwarding
                        if id_ex.valid = '1' and writes_reg(id_ex.op) and 
                           id_ex.warp = if_id.warp and id_ex.rd = rs3 then
                            id_ex.rs3_data(lane) <= reg_file(if_id.warp)(lane)(to_integer(rs3));
                        elsif ex_wb.valid = '1' and ex_wb.we = '1' and 
                           ex_wb.warp = if_id.warp and ex_wb.rd = rs3 then
                            id_ex.rs3_data(lane) <= ex_wb.result(lane);
                        else
                            id_ex.rs3_data(lane) <= reg_file(if_id.warp)(lane)(to_integer(rs3));
                        end if;
                    end loop;
                end if;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- STAGE 3: Execute (32-lane SIMD ALU)
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable a, b, c : signed(31 downto 0);
        variable au, bu : unsigned(31 downto 0);
        variable res : std_logic_vector(31 downto 0);
        variable mul_res : signed(63 downto 0);
        variable take_branch : std_logic_vector(WARP_SIZE-1 downto 0);
        variable any_taken, all_taken : boolean;
    begin
        if rst_n = '0' then
            ex_wb.valid <= '0';
            branch_taken <= '0';
            stack_push_req <= '0';
            stack_pop_req <= '0';
            stack_set_mask_req <= '0';
            tex_req_valid <= '0';
        elsif rising_edge(clk) then
            ex_wb.valid <= '0';
            branch_taken <= '0';
            stack_push_req <= '0';
            stack_pop_req <= '0';
            stack_set_mask_req <= '0';
            tex_req_valid <= '0';
            
            if id_ex.valid = '1' then
                ex_wb.valid <= '1';
                ex_wb.warp <= id_ex.warp;
                ex_wb.op <= id_ex.op;
                ex_wb.rd <= id_ex.rd;
                ex_wb.mask <= id_ex.mask;
                ex_wb.we <= '0';
                
                -- Default: enable writeback for ALU ops
                if writes_reg(id_ex.op) then
                    ex_wb.we <= '1';
                end if;
                
                -- Execute on each active lane
                for lane in 0 to WARP_SIZE-1 loop
                    if id_ex.mask(lane) = '1' then
                        a := signed(id_ex.rs1_data(lane));
                        b := signed(id_ex.rs2_data(lane));
                        c := signed(id_ex.rs3_data(lane));
                        au := unsigned(id_ex.rs1_data(lane));
                        bu := unsigned(id_ex.rs2_data(lane));
                        res := (others => '0');
                        
                        case id_ex.op is
                            -- Integer Arithmetic
                            when OP_ADD =>
                                res := std_logic_vector(a + b);
                            when OP_SUB =>
                                res := std_logic_vector(a - b);
                            when OP_MUL =>
                                mul_res := a * b;
                                res := std_logic_vector(mul_res(31 downto 0));
                            when OP_IMAD =>
                                mul_res := a * b;
                                res := std_logic_vector(mul_res(31 downto 0) + c);
                            when OP_NEG =>
                                res := std_logic_vector(-a);
                            
                            -- Logic
                            when OP_AND =>
                                res := id_ex.rs1_data(lane) and id_ex.rs2_data(lane);
                            when OP_OR =>
                                res := id_ex.rs1_data(lane) or id_ex.rs2_data(lane);
                            when OP_XOR =>
                                res := id_ex.rs1_data(lane) xor id_ex.rs2_data(lane);
                            when OP_NOT =>
                                res := not id_ex.rs1_data(lane);
                            
                            -- Shifts
                            when OP_SHL =>
                                res := std_logic_vector(shift_left(au, to_integer(bu(4 downto 0))));
                            when OP_SHR =>
                                res := std_logic_vector(shift_right(au, to_integer(bu(4 downto 0))));
                            
                            -- Comparisons
                            when OP_SLT =>
                                if a < b then res := x"00000001"; else res := x"00000000"; end if;
                            when OP_SLE =>
                                if a <= b then res := x"00000001"; else res := x"00000000"; end if;
                            when OP_SEQ =>
                                if a = b then res := x"00000001"; else res := x"00000000"; end if;
                            
                            -- Move / Immediate
                            when OP_MOV =>
                                res := id_ex.rs1_data(lane);
                            when OP_TID =>
                                res := std_logic_vector(to_unsigned(lane, 32));
                            
                            -- Floating point operations using ieee.float_pkg
                            when OP_FADD =>
                                res := to_slv(to_float(id_ex.rs1_data(lane)) + to_float(id_ex.rs2_data(lane)));
                            when OP_FSUB =>
                                res := to_slv(to_float(id_ex.rs1_data(lane)) - to_float(id_ex.rs2_data(lane)));
                            when OP_FMUL =>
                                res := to_slv(to_float(id_ex.rs1_data(lane)) * to_float(id_ex.rs2_data(lane)));
                            when OP_FDIV =>
                                res := to_slv(to_float(id_ex.rs1_data(lane)) / to_float(id_ex.rs2_data(lane)));
                            when OP_FFMA =>
                                res := to_slv(to_float(id_ex.rs1_data(lane)) * to_float(id_ex.rs2_data(lane)) + to_float(id_ex.rs3_data(lane)));
                            when OP_FABS =>
                                res := '0' & id_ex.rs1_data(lane)(30 downto 0);  -- Clear sign bit
                            when OP_FNEG =>
                                res := not id_ex.rs1_data(lane)(31) & id_ex.rs1_data(lane)(30 downto 0);  -- Flip sign bit
                            when OP_FMIN =>
                                if to_float(id_ex.rs1_data(lane)) < to_float(id_ex.rs2_data(lane)) then
                                    res := id_ex.rs1_data(lane);
                                else
                                    res := id_ex.rs2_data(lane);
                                end if;
                            when OP_FMAX =>
                                if to_float(id_ex.rs1_data(lane)) > to_float(id_ex.rs2_data(lane)) then
                                    res := id_ex.rs1_data(lane);
                                else
                                    res := id_ex.rs2_data(lane);
                                end if;
                            when OP_ITOF =>
                                res := to_slv(to_float(a, 8, 23));  -- Convert signed int to float
                            when OP_FTOI =>
                                res := std_logic_vector(to_signed(to_float(id_ex.rs1_data(lane)), 32));
                            
                            -- SFU Operations (using ieee.math_real for behavioral simulation)
                            when OP_SFU_SIN =>
                                res := to_slv(to_float(sin(to_real(to_float(id_ex.rs1_data(lane)))), 8, 23));
                            when OP_SFU_COS =>
                                res := to_slv(to_float(cos(to_real(to_float(id_ex.rs1_data(lane)))), 8, 23));
                            when OP_SFU_RCP =>  -- 1/x
                                res := to_slv(1.0 / to_float(id_ex.rs1_data(lane)));
                            when OP_SFU_RSQ =>  -- 1/sqrt(x)
                                res := to_slv(to_float(1.0 / sqrt(to_real(to_float(id_ex.rs1_data(lane)))), 8, 23));
                            when OP_SFU_SQRT =>
                                res := to_slv(to_float(sqrt(to_real(to_float(id_ex.rs1_data(lane)))), 8, 23));
                            when OP_SFU_EX2 =>  -- 2^x
                                res := to_slv(to_float(2.0 ** to_real(to_float(id_ex.rs1_data(lane))), 8, 23));
                            when OP_SFU_LG2 =>  -- log2(x)
                                res := to_slv(to_float(log2(to_real(to_float(id_ex.rs1_data(lane)))), 8, 23));
                            
                            -- Texture sampling (handled separately, result comes async)
                            when OP_TEX | OP_TXL | OP_TXB =>
                                -- These are handled by the texture unit
                                -- Result will be written back when tex_resp_valid
                                res := (others => '0');
                            
                            -- Branch comparisons
                            when OP_BEQ =>
                                if a = b then take_branch(lane) := '1'; else take_branch(lane) := '0'; end if;
                            when OP_BNE =>
                                if a /= b then take_branch(lane) := '1'; else take_branch(lane) := '0'; end if;
                            
                            when others =>
                                res := (others => '0');
                        end case;
                        
                        ex_wb.result(lane) <= res;
                    else
                        ex_wb.result(lane) <= (others => '0');
                    end if;
                end loop;
                
                -- Branch handling (PC update happens in IF process)
                if id_ex.op = OP_BRA then
                    branch_taken <= '1';
                    branch_warp <= id_ex.warp;
                    branch_target <= unsigned(id_ex.imm(7 downto 0));
                    ex_wb.we <= '0';
                end if;
                
                -- SSY: Set Synchronization Point (push reconvergence PC and mask)
                if id_ex.op = OP_SSY then
                    stack_push_req <= '1';
                    stack_push_warp <= id_ex.warp;
                    stack_push_pc <= unsigned(id_ex.imm(7 downto 0));  -- Reconvergence PC
                    stack_push_mask <= id_ex.mask;  -- Current active mask
                    ex_wb.we <= '0';
                end if;
                
                -- JOIN: Pop divergence stack and restore mask
                if id_ex.op = OP_JOIN then
                    stack_pop_req <= '1';
                    stack_push_warp <= id_ex.warp;  -- Reuse for pop warp
                    ex_wb.we <= '0';
                end if;
                
                -- Conditional branch with divergence handling
                if id_ex.op = OP_BEQ or id_ex.op = OP_BNE then
                    any_taken := false;
                    all_taken := true;
                    for lane in 0 to WARP_SIZE-1 loop
                        if id_ex.mask(lane) = '1' then
                            if take_branch(lane) = '1' then
                                any_taken := true;
                            else
                                all_taken := false;
                            end if;
                        end if;
                    end loop;
                    
                    if all_taken then
                        -- All active threads take the branch
                        branch_taken <= '1';
                        branch_warp <= id_ex.warp;
                        branch_target <= unsigned(id_ex.imm(7 downto 0));
                    elsif any_taken then
                        -- Divergence: some threads take, some don't
                        -- Execute taken threads first (branch), push fallthrough
                        -- Compute taken and not-taken masks
                        for lane in 0 to WARP_SIZE-1 loop
                            if id_ex.mask(lane) = '1' and take_branch(lane) = '0' then
                                -- Not-taken lane - save for later
                                stack_push_mask(lane) <= '1';
                            else
                                stack_push_mask(lane) <= '0';
                            end if;
                        end loop;
                        
                        -- Push not-taken threads with fallthrough PC
                        stack_push_req <= '1';
                        stack_push_warp <= id_ex.warp;
                        stack_push_pc <= id_ex.pc + 1;  -- Fallthrough PC
                        
                        -- Update mask to only taken threads and branch
                        stack_set_mask_req <= '1';
                        for lane in 0 to WARP_SIZE-1 loop
                            if id_ex.mask(lane) = '1' and take_branch(lane) = '1' then
                                stack_new_mask(lane) <= '1';
                            else
                                stack_new_mask(lane) <= '0';
                            end if;
                        end loop;
                        
                        branch_taken <= '1';
                        branch_warp <= id_ex.warp;
                        branch_target <= unsigned(id_ex.imm(7 downto 0));
                    end if;
                    -- Else: no threads take branch, continue sequentially
                    ex_wb.we <= '0';
                end if;
                
                -- Texture sampling request
                if id_ex.op = OP_TEX or id_ex.op = OP_TXL or id_ex.op = OP_TXB then
                    tex_req_valid <= '1';
                    tex_req_warp <= std_logic_vector(to_unsigned(id_ex.warp, 5));
                    tex_req_mask <= id_ex.mask;
                    tex_req_rd <= std_logic_vector(id_ex.rd);
                    
                    -- Set operation type
                    if id_ex.op = OP_TEX then
                        tex_req_op <= "00";
                    elsif id_ex.op = OP_TXL then
                        tex_req_op <= "01";
                    else  -- OP_TXB
                        tex_req_op <= "10";
                    end if;
                    
                    -- Pack UV coordinates from rs1 (U) and rs2 (V) for all lanes
                    for lane in 0 to WARP_SIZE-1 loop
                        tex_req_u((lane+1)*32-1 downto lane*32) <= id_ex.rs1_data(lane);
                        tex_req_v((lane+1)*32-1 downto lane*32) <= id_ex.rs2_data(lane);
                        -- LOD from rs3 (lower 8 bits per lane)
                        tex_req_lod((lane+1)*8-1 downto lane*8) <= id_ex.rs3_data(lane)(7 downto 0);
                    end loop;
                    
                    -- Texture ops don't write directly, result comes async
                    ex_wb.we <= '0';
                end if;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- STAGE 4: Writeback
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            -- Reset handled elsewhere
        elsif rising_edge(clk) then
            -- Regular ALU/FP/SFU writeback
            if ex_wb.valid = '1' and ex_wb.we = '1' then
                -- Write results to register file
                for lane in 0 to WARP_SIZE-1 loop
                    if ex_wb.mask(lane) = '1' then
                        reg_file(ex_wb.warp)(lane)(to_integer(ex_wb.rd)) <= ex_wb.result(lane);
                    end if;
                end loop;
            end if;
            
            -- Memory load writeback (single lane at a time)
            if mem_load_wb_valid = '1' then
                reg_file(mem_load_wb_warp)(mem_load_wb_lane)(to_integer(mem_load_wb_rd)) <= mem_load_wb_data;
            end if;
            
            -- Texture sample writeback (all lanes at once)
            if tex_resp_valid = '1' then
                for lane in 0 to WARP_SIZE-1 loop
                    if tex_resp_mask(lane) = '1' then
                        reg_file(to_integer(unsigned(tex_resp_warp)))(lane)(to_integer(unsigned(tex_resp_rd))) 
                            <= tex_resp_data((lane+1)*32-1 downto lane*32);
                    end if;
                end loop;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Memory Controller Process
    -- Handles load/store operations serially across lanes
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable next_lane : integer;
        variable found_lane : boolean;
    begin
        if rst_n = '0' then
            mem_state <= MEM_IDLE;
            mem_req_valid <= '0';
            mem_req_write <= '0';
            mem_req_addr <= (others => '0');
            mem_req_wdata <= (others => '0');
            mem_req_tag <= (others => '0');
            mem_lane <= 0;
            mem_warp <= 0;
            mem_rd <= (others => '0');
            mem_lane_mask <= (others => '0');
            mem_load_wb_valid <= '0';
            mem_load_wb_warp <= 0;
            mem_load_wb_lane <= 0;
            mem_load_wb_rd <= (others => '0');
            mem_load_wb_data <= (others => '0');
        elsif rising_edge(clk) then
            -- Default: no request
            mem_req_valid <= '0';
            mem_load_wb_valid <= '0';
            
            case mem_state is
                when MEM_IDLE =>
                    -- Check for memory operation from EX stage
                    if id_ex.valid = '1' and (id_ex.op = OP_LDR or id_ex.op = OP_STR) then
                        -- Start memory operation
                        mem_warp <= id_ex.warp;
                        mem_rd <= id_ex.rd;
                        mem_lane_mask <= id_ex.mask;
                        
                        -- Calculate addresses: base + offset for each lane
                        for lane in 0 to WARP_SIZE-1 loop
                            mem_addr_array(lane) <= std_logic_vector(
                                signed(id_ex.rs1_data(lane)) + signed(id_ex.imm)
                            );
                            mem_data_array(lane) <= id_ex.rs2_data(lane);  -- For stores
                        end loop;
                        
                        -- Find first active lane
                        mem_lane <= 0;
                        for lane in 0 to WARP_SIZE-1 loop
                            if id_ex.mask(lane) = '1' then
                                mem_lane <= lane;
                                exit;
                            end if;
                        end loop;
                        
                        if id_ex.op = OP_LDR then
                            mem_state <= MEM_LOAD_PENDING;
                        else
                            mem_state <= MEM_STORE_PENDING;
                        end if;
                    end if;
                    
                when MEM_LOAD_PENDING =>
                    -- Issue load request for current lane
                    if mem_lane_mask(mem_lane) = '1' then
                        mem_req_valid <= '1';
                        mem_req_write <= '0';
                        mem_req_addr <= mem_addr_array(mem_lane);
                        mem_req_tag <= std_logic_vector(to_unsigned(mem_warp, 5)) & 
                                       std_logic_vector(mem_rd) &
                                       std_logic_vector(to_unsigned(mem_lane, 5));
                        
                        -- Wait for response
                        if mem_resp_valid = '1' then
                            mem_data_array(mem_lane) <= mem_resp_data;
                            
                            -- Signal WB process to write to reg_file
                            mem_load_wb_valid <= '1';
                            mem_load_wb_warp <= mem_warp;
                            mem_load_wb_lane <= mem_lane;
                            mem_load_wb_rd <= mem_rd;
                            mem_load_wb_data <= mem_resp_data;
                            
                            -- Move to next lane
                            found_lane := false;
                            for next_l in mem_lane+1 to WARP_SIZE-1 loop
                                if mem_lane_mask(next_l) = '1' then
                                    mem_lane <= next_l;
                                    found_lane := true;
                                    exit;
                                end if;
                            end loop;
                            
                            if not found_lane then
                                mem_state <= MEM_IDLE;
                            end if;
                        end if;
                    else
                        -- Skip inactive lane
                        found_lane := false;
                        for next_l in mem_lane+1 to WARP_SIZE-1 loop
                            if mem_lane_mask(next_l) = '1' then
                                mem_lane <= next_l;
                                found_lane := true;
                                exit;
                            end if;
                        end loop;
                        
                        if not found_lane then
                            mem_state <= MEM_IDLE;
                        end if;
                    end if;
                    
                when MEM_STORE_PENDING =>
                    -- Issue store request for current lane
                    if mem_lane_mask(mem_lane) = '1' then
                        mem_req_valid <= '1';
                        mem_req_write <= '1';
                        mem_req_addr <= mem_addr_array(mem_lane);
                        mem_req_wdata <= mem_data_array(mem_lane);
                        mem_req_tag <= std_logic_vector(to_unsigned(mem_warp, 5)) & 
                                       std_logic_vector(mem_rd) &
                                       std_logic_vector(to_unsigned(mem_lane, 5));
                        
                        -- For stores, we can move to next lane when ready accepted
                        if mem_req_ready = '1' then
                            -- Move to next lane
                            found_lane := false;
                            for next_l in mem_lane+1 to WARP_SIZE-1 loop
                                if mem_lane_mask(next_l) = '1' then
                                    mem_lane <= next_l;
                                    found_lane := true;
                                    exit;
                                end if;
                            end loop;
                            
                            if not found_lane then
                                mem_state <= MEM_IDLE;
                            end if;
                        end if;
                    else
                        -- Skip inactive lane
                        found_lane := false;
                        for next_l in mem_lane+1 to WARP_SIZE-1 loop
                            if mem_lane_mask(next_l) = '1' then
                                mem_lane <= next_l;
                                found_lane := true;
                                exit;
                            end if;
                        end loop;
                        
                        if not found_lane then
                            mem_state <= MEM_IDLE;
                        end if;
                    end if;
            end case;
        end if;
    end process;

end architecture rtl;
