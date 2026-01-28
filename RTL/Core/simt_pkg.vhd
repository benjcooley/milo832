-------------------------------------------------------------------------------
-- simt_pkg.vhd
-- SIMT GPU Core Package - Types, Constants, and Functions
--
-- Based on SIMT-GPU-Core by Aritra Manna
-- Original: https://github.com/aritramanna/SIMT-GPU-Core
-- Translated to VHDL for Milo832 GPU project
--
-- Many thanks to Aritra Manna for creating and open-sourcing the excellent
-- SIMT-GPU-Core project, which served as the foundation for this implementation.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

package simt_pkg is

    ---------------------------------------------------------------------------
    -- Core Configuration Constants
    ---------------------------------------------------------------------------
    constant WARP_SIZE              : integer := 32;
    constant NUM_WARPS              : integer := 24;
    constant NUM_REGS               : integer := 64;
    constant DIVERGENCE_STACK_DEPTH : integer := 32;
    constant RETURN_STACK_DEPTH     : integer := 8;
    constant MAX_PENDING_PER_WARP   : integer := 64;
    
    -- Derived parameters
    constant WARP_ID_WIDTH          : integer := 5;  -- ceil(log2(NUM_WARPS))
    constant REG_ADDR_WIDTH         : integer := 6;  -- ceil(log2(NUM_REGS))
    constant SLOT_ID_WIDTH          : integer := 6;  -- ceil(log2(MAX_PENDING_PER_WARP))
    
    ---------------------------------------------------------------------------
    -- Instruction Set Architecture - Opcodes
    ---------------------------------------------------------------------------
    subtype opcode_t is std_logic_vector(7 downto 0);
    
    -- No Operation / Control
    constant OP_NOP     : opcode_t := x"00";
    constant OP_MOV     : opcode_t := x"07";
    constant OP_EXIT    : opcode_t := x"FF";
    
    -- Integer Arithmetic
    constant OP_ADD     : opcode_t := x"01";
    constant OP_SUB     : opcode_t := x"02";
    constant OP_MUL     : opcode_t := x"03";
    constant OP_IMAD    : opcode_t := x"05";
    constant OP_NEG     : opcode_t := x"06";
    constant OP_IDIV    : opcode_t := x"36";
    constant OP_IREM    : opcode_t := x"37";
    constant OP_IABS    : opcode_t := x"38";
    constant OP_IMIN    : opcode_t := x"39";
    constant OP_IMAX    : opcode_t := x"3A";
    
    -- Integer Comparison
    constant OP_SLT     : opcode_t := x"04";
    constant OP_SLE     : opcode_t := x"70";
    constant OP_SEQ     : opcode_t := x"71";
    
    -- Logic Operations
    constant OP_AND     : opcode_t := x"50";
    constant OP_OR      : opcode_t := x"51";
    constant OP_XOR     : opcode_t := x"52";
    constant OP_NOT     : opcode_t := x"53";
    
    -- Shift Operations
    constant OP_SHL     : opcode_t := x"60";
    constant OP_SHR     : opcode_t := x"61";
    constant OP_SHA     : opcode_t := x"62";
    
    -- Memory Operations
    constant OP_LDR     : opcode_t := x"10";
    constant OP_STR     : opcode_t := x"11";
    constant OP_LDS     : opcode_t := x"12";
    constant OP_STS     : opcode_t := x"13";
    
    -- Control Flow
    constant OP_BEQ     : opcode_t := x"20";
    constant OP_BNE     : opcode_t := x"21";
    constant OP_BRA     : opcode_t := x"22";
    constant OP_SSY     : opcode_t := x"23";
    constant OP_JOIN    : opcode_t := x"24";
    constant OP_BAR     : opcode_t := x"25";
    constant OP_TID     : opcode_t := x"26";
    constant OP_CALL    : opcode_t := x"27";
    constant OP_RET     : opcode_t := x"28";
    
    -- Floating Point Operations
    constant OP_FADD    : opcode_t := x"30";
    constant OP_FSUB    : opcode_t := x"31";
    constant OP_FMUL    : opcode_t := x"32";
    constant OP_FDIV    : opcode_t := x"33";
    constant OP_FTOI    : opcode_t := x"34";
    constant OP_FFMA    : opcode_t := x"35";
    constant OP_FMIN    : opcode_t := x"3B";
    constant OP_FMAX    : opcode_t := x"3C";
    constant OP_FABS    : opcode_t := x"3D";
    constant OP_ITOF    : opcode_t := x"3E";
    constant OP_FNEG    : opcode_t := x"54";
    
    -- Bit Manipulation
    constant OP_POPC    : opcode_t := x"68";
    constant OP_CLZ     : opcode_t := x"69";
    constant OP_BREV    : opcode_t := x"6A";
    constant OP_CNOT    : opcode_t := x"6B";
    
    -- Predicate Operations
    constant OP_ISETP   : opcode_t := x"80";
    constant OP_FSETP   : opcode_t := x"81";
    constant OP_SELP    : opcode_t := x"82";
    
    -- Special Function Unit Operations
    constant OP_SFU_SIN  : opcode_t := x"40";
    constant OP_SFU_COS  : opcode_t := x"41";
    constant OP_SFU_EX2  : opcode_t := x"42";
    constant OP_SFU_LG2  : opcode_t := x"43";
    constant OP_SFU_RCP  : opcode_t := x"44";
    constant OP_SFU_RSQ  : opcode_t := x"45";
    constant OP_SFU_SQRT : opcode_t := x"46";
    constant OP_SFU_TANH : opcode_t := x"47";
    
    -- Texture Operations (Graphics Extension)
    constant OP_TEX     : opcode_t := x"90";  -- Texture sample
    constant OP_TXL     : opcode_t := x"91";  -- Texture sample with LOD
    constant OP_TXB     : opcode_t := x"92";  -- Texture sample with bias
    
    ---------------------------------------------------------------------------
    -- Functional Unit Categories
    ---------------------------------------------------------------------------
    type unit_type_t is (UNIT_ALU, UNIT_FPU, UNIT_LSU, UNIT_CTRL);
    
    ---------------------------------------------------------------------------
    -- Warp State Machine
    ---------------------------------------------------------------------------
    type warp_state_t is (
        W_IDLE,      -- Inactive / Reset State
        W_READY,     -- Ready to Fetch
        W_RUNNING,   -- Currently in pipeline
        W_STALLED,   -- Generic Stall (Scoreboard)
        W_WAIT_MEM,  -- Memory Latency
        W_BARRIER,   -- Hit Barrier
        W_EXIT       -- Terminated
    );
    
    ---------------------------------------------------------------------------
    -- Writeback Source Type
    ---------------------------------------------------------------------------
    type wb_src_t is (WB_ALU, WB_FPU, WB_MEM, WB_SQUASH);
    
    ---------------------------------------------------------------------------
    -- Array Types for SIMD Operations
    ---------------------------------------------------------------------------
    type word_array_t is array (0 to WARP_SIZE-1) of std_logic_vector(31 downto 0);
    type reg_file_t is array (0 to NUM_REGS-1) of word_array_t;
    
    ---------------------------------------------------------------------------
    -- Pipeline Packet: IF -> ID
    ---------------------------------------------------------------------------
    type if_id_t is record
        valid       : std_logic;
        warp        : std_logic_vector(WARP_ID_WIDTH-1 downto 0);
        pc          : std_logic_vector(31 downto 0);
        inst        : std_logic_vector(63 downto 0);
        branch_tag  : std_logic_vector(1 downto 0);
    end record if_id_t;
    
    constant IF_ID_INIT : if_id_t := (
        valid       => '0',
        warp        => (others => '0'),
        pc          => (others => '0'),
        inst        => (others => '0'),
        branch_tag  => (others => '0')
    );
    
    ---------------------------------------------------------------------------
    -- Pipeline Packet: ID -> EX
    ---------------------------------------------------------------------------
    type id_ex_t is record
        valid       : std_logic;
        warp        : std_logic_vector(4 downto 0);
        pc          : std_logic_vector(31 downto 0);
        op          : opcode_t;
        rd          : std_logic_vector(7 downto 0);
        imm         : std_logic_vector(31 downto 0);
        mask        : std_logic_vector(WARP_SIZE-1 downto 0);
        rs1         : word_array_t;
        rs2         : word_array_t;
        rs3         : word_array_t;
        pred_guard  : std_logic_vector(3 downto 0);
        src_pred    : std_logic_vector(WARP_SIZE-1 downto 0);
        rs1_idx     : std_logic_vector(7 downto 0);
        rs2_idx     : std_logic_vector(7 downto 0);
        rs3_idx     : std_logic_vector(7 downto 0);
        branch_tag  : std_logic_vector(1 downto 0);
    end record id_ex_t;
    
    constant ID_EX_INIT : id_ex_t := (
        valid       => '0',
        warp        => (others => '0'),
        pc          => (others => '0'),
        op          => OP_NOP,
        rd          => (others => '0'),
        imm         => (others => '0'),
        mask        => (others => '0'),
        rs1         => (others => (others => '0')),
        rs2         => (others => (others => '0')),
        rs3         => (others => (others => '0')),
        pred_guard  => (others => '0'),
        src_pred    => (others => '0'),
        rs1_idx     => (others => '0'),
        rs2_idx     => (others => '0'),
        rs3_idx     => (others => '0'),
        branch_tag  => (others => '0')
    );
    
    ---------------------------------------------------------------------------
    -- Pipeline Packet: EX -> MEM
    ---------------------------------------------------------------------------
    type ex_mem_t is record
        valid       : std_logic;
        warp        : std_logic_vector(4 downto 0);
        op          : opcode_t;
        rd          : std_logic_vector(7 downto 0);
        mask        : std_logic_vector(WARP_SIZE-1 downto 0);
        alu         : word_array_t;
        store_data  : word_array_t;
        we          : std_logic;
        we_pred     : std_logic;
    end record ex_mem_t;
    
    constant EX_MEM_INIT : ex_mem_t := (
        valid       => '0',
        warp        => (others => '0'),
        op          => OP_NOP,
        rd          => (others => '0'),
        mask        => (others => '0'),
        alu         => (others => (others => '0')),
        store_data  => (others => (others => '0')),
        we          => '0',
        we_pred     => '0'
    );
    
    ---------------------------------------------------------------------------
    -- Pipeline Packet: MEM -> WB
    ---------------------------------------------------------------------------
    type mem_wb_t is record
        valid       : std_logic;
        src         : wb_src_t;
        we          : std_logic;
        we_pred     : std_logic;
        warp        : std_logic_vector(4 downto 0);
        rd          : std_logic_vector(7 downto 0);
        mask        : std_logic_vector(WARP_SIZE-1 downto 0);
        result      : word_array_t;
        last_split  : std_logic;
    end record mem_wb_t;
    
    constant MEM_WB_INIT : mem_wb_t := (
        valid       => '0',
        src         => WB_ALU,
        we          => '0',
        we_pred     => '0',
        warp        => (others => '0'),
        rd          => (others => '0'),
        mask        => (others => '0'),
        result      => (others => (others => '0')),
        last_split  => '0'
    );
    
    ---------------------------------------------------------------------------
    -- ALU Pipeline: EX -> WB
    ---------------------------------------------------------------------------
    type alu_wb_t is record
        valid       : std_logic;
        src         : wb_src_t;
        warp        : std_logic_vector(4 downto 0);
        op          : opcode_t;
        rd          : std_logic_vector(7 downto 0);
        mask        : std_logic_vector(WARP_SIZE-1 downto 0);
        result      : word_array_t;
        we          : std_logic;
        we_pred     : std_logic;
    end record alu_wb_t;
    
    constant ALU_WB_INIT : alu_wb_t := (
        valid       => '0',
        src         => WB_ALU,
        warp        => (others => '0'),
        op          => OP_NOP,
        rd          => (others => '0'),
        mask        => (others => '0'),
        result      => (others => (others => '0')),
        we          => '0',
        we_pred     => '0'
    );
    
    ---------------------------------------------------------------------------
    -- MSHR Entry (Miss Status Holding Register)
    ---------------------------------------------------------------------------
    type pending_load_t is record
        transaction_id  : std_logic_vector(15 downto 0);
        is_store        : std_logic;
        rd              : std_logic_vector(7 downto 0);
        mask            : std_logic_vector(WARP_SIZE-1 downto 0);
        addresses       : word_array_t;
        last_split      : std_logic;
    end record pending_load_t;
    
    ---------------------------------------------------------------------------
    -- Helper Functions
    ---------------------------------------------------------------------------
    
    -- Get functional unit type for an opcode
    function get_unit_type(op : opcode_t) return unit_type_t;
    
    -- Check if instruction is a memory operation
    function is_memory_op(op : opcode_t) return boolean;
    
    -- Check if instruction is an ALU/compute operation
    function is_alu_op(op : opcode_t) return boolean;
    
    -- Check if two instructions can dual-issue
    function can_dual_issue(inst_a, inst_b : std_logic_vector(63 downto 0)) return boolean;
    
    -- Population count (count ones)
    function popcount(v : std_logic_vector) return integer;
    
    -- Count leading zeros
    function clz(v : std_logic_vector(31 downto 0)) return integer;
    
    -- Bit reverse
    function bit_reverse(v : std_logic_vector(31 downto 0)) return std_logic_vector;

end package simt_pkg;

package body simt_pkg is

    ---------------------------------------------------------------------------
    -- get_unit_type: Classify opcode to functional unit
    ---------------------------------------------------------------------------
    function get_unit_type(op : opcode_t) return unit_type_t is
    begin
        case op is
            when OP_LDR | OP_STR | OP_LDS | OP_STS =>
                return UNIT_LSU;
                
            when OP_FADD | OP_FSUB | OP_FMUL | OP_FDIV | OP_FFMA | OP_FTOI |
                 OP_SFU_SIN | OP_SFU_COS | OP_SFU_EX2 | OP_SFU_LG2 |
                 OP_SFU_RCP | OP_SFU_RSQ | OP_SFU_SQRT | OP_SFU_TANH =>
                return UNIT_FPU;
                
            when OP_BRA | OP_BEQ | OP_BNE | OP_SSY | OP_JOIN | 
                 OP_BAR | OP_EXIT | OP_CALL | OP_RET =>
                return UNIT_CTRL;
                
            when others =>
                return UNIT_ALU;
        end case;
    end function get_unit_type;
    
    ---------------------------------------------------------------------------
    -- is_memory_op: Check if opcode is a memory operation
    ---------------------------------------------------------------------------
    function is_memory_op(op : opcode_t) return boolean is
    begin
        return (op = OP_LDR or op = OP_STR or op = OP_LDS or op = OP_STS);
    end function is_memory_op;
    
    ---------------------------------------------------------------------------
    -- is_alu_op: Check if opcode is an ALU/compute operation
    ---------------------------------------------------------------------------
    function is_alu_op(op : opcode_t) return boolean is
    begin
        return (not is_memory_op(op)) and (op /= OP_NOP) and (op /= OP_EXIT);
    end function is_alu_op;
    
    ---------------------------------------------------------------------------
    -- can_dual_issue: Check if two instructions can issue together
    ---------------------------------------------------------------------------
    function can_dual_issue(inst_a, inst_b : std_logic_vector(63 downto 0)) return boolean is
        variable op_a, op_b : opcode_t;
        variable rd_a, rs1_b, rs2_b, rs3_b : std_logic_vector(7 downto 0);
        variable raw_hazard, structural_hazard, control_hazard : boolean;
        variable unit_a, unit_b : unit_type_t;
    begin
        op_a := inst_a(63 downto 56);
        op_b := inst_b(63 downto 56);
        
        rd_a  := inst_a(55 downto 48);
        rs1_b := inst_b(47 downto 40);
        rs2_b := inst_b(39 downto 32);
        rs3_b := inst_b(27 downto 20);
        
        -- Check RAW hazard (inst_b reads what inst_a writes)
        raw_hazard := false;
        if op_a /= OP_NOP and op_a /= OP_EXIT and op_a /= OP_STR and op_a /= OP_STS then
            if rd_a = rs1_b or rd_a = rs2_b or rd_a = rs3_b then
                raw_hazard := true;
            end if;
        end if;
        
        -- Check WAW hazard
        if op_a /= OP_NOP and op_b /= OP_NOP then
            if rd_a = inst_b(55 downto 48) then
                raw_hazard := true;
            end if;
        end if;
        
        -- Check structural hazard
        unit_a := get_unit_type(op_a);
        unit_b := get_unit_type(op_b);
        
        structural_hazard := false;
        if is_memory_op(op_a) and is_memory_op(op_b) then
            structural_hazard := true;
        end if;
        
        if unit_a = unit_b then
            structural_hazard := true;
        end if;
        
        -- ALU and CTRL share resources
        if (unit_a = UNIT_ALU and unit_b = UNIT_CTRL) or
           (unit_a = UNIT_CTRL and unit_b = UNIT_ALU) then
            structural_hazard := true;
        end if;
        
        -- Check control flow hazard
        control_hazard := false;
        if op_a = OP_BRA or op_a = OP_BEQ or op_a = OP_BNE or 
           op_a = OP_JOIN or op_a = OP_EXIT or op_a = OP_BAR or 
           op_a = OP_SSY or op_a = OP_CALL or op_a = OP_RET then
            control_hazard := true;
        end if;
        
        return (not raw_hazard) and (not structural_hazard) and (not control_hazard);
    end function can_dual_issue;
    
    ---------------------------------------------------------------------------
    -- popcount: Count number of '1' bits
    ---------------------------------------------------------------------------
    function popcount(v : std_logic_vector) return integer is
        variable count : integer := 0;
    begin
        for i in v'range loop
            if v(i) = '1' then
                count := count + 1;
            end if;
        end loop;
        return count;
    end function popcount;
    
    ---------------------------------------------------------------------------
    -- clz: Count leading zeros
    ---------------------------------------------------------------------------
    function clz(v : std_logic_vector(31 downto 0)) return integer is
        variable count : integer := 0;
    begin
        for i in 31 downto 0 loop
            if v(i) = '1' then
                return count;
            end if;
            count := count + 1;
        end loop;
        return 32;
    end function clz;
    
    ---------------------------------------------------------------------------
    -- bit_reverse: Reverse bit order
    ---------------------------------------------------------------------------
    function bit_reverse(v : std_logic_vector(31 downto 0)) return std_logic_vector is
        variable result : std_logic_vector(31 downto 0);
    begin
        for i in 0 to 31 loop
            result(i) := v(31 - i);
        end loop;
        return result;
    end function bit_reverse;

end package body simt_pkg;
