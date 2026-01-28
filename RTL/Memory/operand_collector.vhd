-------------------------------------------------------------------------------
-- operand_collector.vhd
-- 16 Unit Shared Pool Operand Collector (Fermi Model)
--
-- Based on SIMT-GPU-Core by Aritra Manna
-- Original: https://github.com/aritramanna/SIMT-GPU-Core
-- Translated to VHDL for Milo832 GPU project
--
-- Many thanks to Aritra Manna for creating and open-sourcing the excellent
-- SIMT-GPU-Core project, which served as the foundation for this implementation.
--
-- Features:
-- 1. Dual Writeback Ports for ALU and Memory completions
-- 2. Opcode-based needed_mask: Only collects required operands
-- 3. 4-Bank Register File for parallel reads
-- 4. Round-robin arbitration for ready unit release
-- 5. Forwarding detection for zero-latency wakeup
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.simt_pkg.all;

entity operand_collector is
    generic (
        WARP_SIZE       : integer := 32;
        NUM_REGS        : integer := 64;
        NUM_WARPS       : integer := 24;
        NUM_COLLECTORS  : integer := 16
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Dispatch Interface (Two ports for Dual Schedulers)
        dispatch_valid  : in  std_logic_vector(1 downto 0);
        dispatch_inst_0 : in  id_ex_t;
        dispatch_inst_1 : in  id_ex_t;
        dispatch_ready  : out std_logic_vector(1 downto 0);
        
        -- Dual Writeback Interface
        wb_valid        : in  std_logic_vector(1 downto 0);
        wb_warp_0       : in  std_logic_vector(4 downto 0);
        wb_warp_1       : in  std_logic_vector(4 downto 0);
        wb_rd_0         : in  std_logic_vector(5 downto 0);
        wb_rd_1         : in  std_logic_vector(5 downto 0);
        wb_mask_0       : in  std_logic_vector(WARP_SIZE-1 downto 0);
        wb_mask_1       : in  std_logic_vector(WARP_SIZE-1 downto 0);
        wb_data_0       : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        wb_data_1       : in  std_logic_vector(WARP_SIZE*32-1 downto 0);
        
        -- Execution Interface (Two ports for Dual Execution)
        ex_valid        : out std_logic_vector(1 downto 0);
        ex_inst_0       : out id_ex_t;
        ex_inst_1       : out id_ex_t;
        ex_ready        : in  std_logic_vector(1 downto 0);
        
        -- Flush/Branch Interface
        flush_valid     : in  std_logic;
        flush_warp      : in  std_logic_vector(4 downto 0)
    );
end entity operand_collector;

architecture rtl of operand_collector is

    constant REG_ADDR_WIDTH : integer := 6;  -- log2(64)
    constant BANK_COUNT : integer := 4;
    constant REGS_PER_BANK : integer := NUM_REGS / BANK_COUNT;
    
    -- Collector unit states
    type cu_state_t is (CU_IDLE, CU_ALLOCATED, CU_READY);
    
    -- Collector unit metadata
    type cu_meta_t is record
        state       : cu_state_t;
        inst        : id_ex_t;
        needed_mask : std_logic_vector(2 downto 0);  -- RS1, RS2, RS3
    end record;
    
    type cu_meta_array_t is array (0 to NUM_COLLECTORS-1) of cu_meta_t;
    signal collectors : cu_meta_array_t;
    
    -- Operand ready flags (separate for synthesis)
    type ready_flags_t is array (0 to NUM_COLLECTORS-1) of std_logic;
    signal rs1_ready, rs2_ready, rs3_ready : ready_flags_t;
    
    -- Operand data storage (as word arrays for easier access)
    type operand_data_t is array (0 to NUM_COLLECTORS-1) of word_array_t;
    signal rs1_data, rs2_data, rs3_data : operand_data_t;
    
    -- 4-Bank Register File
    type rf_bank_t is array (0 to WARP_SIZE-1, 0 to NUM_WARPS-1, 0 to REGS_PER_BANK-1) of std_logic_vector(31 downto 0);
    type rf_banks_t is array (0 to BANK_COUNT-1) of rf_bank_t;
    signal rf_bank : rf_banks_t;
    
    -- Issue ordering
    type issue_id_array_t is array (0 to NUM_WARPS-1) of unsigned(15 downto 0);
    signal warp_issue_id : issue_id_array_t;
    signal warp_release_id : issue_id_array_t;
    
    type unit_id_array_t is array (0 to NUM_COLLECTORS-1) of unsigned(15 downto 0);
    signal unit_issue_id : unit_id_array_t;
    
    -- Round-robin pointers
    type bank_ptr_t is array (0 to BANK_COUNT-1) of integer range 0 to NUM_COLLECTORS-1;
    signal bank_rr_ptr : bank_ptr_t;
    signal release_rr_ptr : integer range 0 to NUM_COLLECTORS-1;
    
    -- Forwarding detection
    signal rs1_forwarded, rs2_forwarded, rs3_forwarded : ready_flags_t;
    
    -- Selected release indices
    signal p0_idx_sel, p1_idx_sel : integer range -1 to NUM_COLLECTORS-1;
    
    -- Helper function: Get bank index from register address
    function get_bank(reg_idx : std_logic_vector(5 downto 0)) return integer is
    begin
        return to_integer(unsigned(reg_idx(1 downto 0)));
    end function;
    
    -- Helper function: Get offset within bank
    function get_bank_offset(reg_idx : std_logic_vector(5 downto 0)) return integer is
    begin
        return to_integer(unsigned(reg_idx(5 downto 2)));
    end function;
    
    -- Helper function: Convert flat vector to word array
    function to_word_array(flat : std_logic_vector) return word_array_t is
        variable result : word_array_t;
    begin
        for i in 0 to WARP_SIZE-1 loop
            result(i) := flat((i+1)*32-1 downto i*32);
        end loop;
        return result;
    end function;
    
    -- Helper function: Check if opcode needs RS1
    function needs_rs1(op : opcode_t) return boolean is
    begin
        case op is
            when OP_NOP | OP_EXIT | OP_BRA | OP_JOIN | OP_BAR | OP_SSY =>
                return false;
            when others =>
                return true;
        end case;
    end function;
    
    -- Helper function: Check if opcode needs RS2
    function needs_rs2(op : opcode_t) return boolean is
    begin
        case op is
            when OP_NOP | OP_EXIT | OP_BRA | OP_JOIN | OP_BAR | OP_SSY |
                 OP_MOV | OP_NEG | OP_NOT | OP_ITOF | OP_FTOI |
                 OP_FABS | OP_FNEG | OP_LDR | OP_LDS |
                 OP_SFU_SIN | OP_SFU_COS | OP_SFU_RCP | OP_SFU_RSQ |
                 OP_SFU_SQRT | OP_SFU_EX2 | OP_SFU_LG2 =>
                return false;
            when others =>
                return true;
        end case;
    end function;
    
    -- Helper function: Check if opcode needs RS3 (FMA operations)
    function needs_rs3(op : opcode_t) return boolean is
    begin
        case op is
            when OP_FFMA | OP_IMAD =>
                return true;
            when others =>
                return false;
        end case;
    end function;

begin

    ---------------------------------------------------------------------------
    -- Dispatch Ready Logic
    ---------------------------------------------------------------------------
    process(collectors)
        variable idle_count : integer;
    begin
        idle_count := 0;
        dispatch_ready <= "00";
        
        for i in 0 to NUM_COLLECTORS-1 loop
            if collectors(i).state = CU_IDLE then
                idle_count := idle_count + 1;
            end if;
        end loop;
        
        if idle_count >= 1 then
            dispatch_ready(0) <= '1';
        end if;
        if idle_count >= 2 then
            dispatch_ready(1) <= '1';
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Forwarding Detection (Combinational)
    ---------------------------------------------------------------------------
    process(collectors, wb_valid, wb_warp_0, wb_warp_1, wb_rd_0, wb_rd_1, 
            wb_mask_0, wb_mask_1, rs1_ready, rs2_ready, rs3_ready)
        variable warp_match_0, warp_match_1 : boolean;
        variable mask_valid_0, mask_valid_1 : boolean;
    begin
        for i in 0 to NUM_COLLECTORS-1 loop
            rs1_forwarded(i) <= '0';
            rs2_forwarded(i) <= '0';
            rs3_forwarded(i) <= '0';
            
            if collectors(i).state = CU_ALLOCATED then
                -- Check port 0
                warp_match_0 := (wb_warp_0 = collectors(i).inst.warp);
                mask_valid_0 := (wb_mask_0 /= (wb_mask_0'range => '0'));
                
                if wb_valid(0) = '1' and warp_match_0 and mask_valid_0 then
                    if collectors(i).inst.rs1_idx(5 downto 0) = wb_rd_0 then
                        rs1_forwarded(i) <= '1';
                    end if;
                    if collectors(i).inst.rs2_idx(5 downto 0) = wb_rd_0 then
                        rs2_forwarded(i) <= '1';
                    end if;
                    if collectors(i).inst.rs3_idx(5 downto 0) = wb_rd_0 then
                        rs3_forwarded(i) <= '1';
                    end if;
                end if;
                
                -- Check port 1
                warp_match_1 := (wb_warp_1 = collectors(i).inst.warp);
                mask_valid_1 := (wb_mask_1 /= (wb_mask_1'range => '0'));
                
                if wb_valid(1) = '1' and warp_match_1 and mask_valid_1 then
                    if collectors(i).inst.rs1_idx(5 downto 0) = wb_rd_1 then
                        rs1_forwarded(i) <= '1';
                    end if;
                    if collectors(i).inst.rs2_idx(5 downto 0) = wb_rd_1 then
                        rs2_forwarded(i) <= '1';
                    end if;
                    if collectors(i).inst.rs3_idx(5 downto 0) = wb_rd_1 then
                        rs3_forwarded(i) <= '1';
                    end if;
                end if;
            end if;
        end loop;
    end process;
    
    ---------------------------------------------------------------------------
    -- Release Port Selection (Combinational)
    ---------------------------------------------------------------------------
    process(collectors, rs1_data, rs2_data, rs3_data, unit_issue_id, 
            warp_release_id, release_rr_ptr, ex_ready)
        variable idx : integer;
        variable found_p0, found_p1 : boolean;
        variable p0_warp : integer;
        variable inst_tmp : id_ex_t;
    begin
        ex_valid <= "00";
        ex_inst_0 <= ID_EX_INIT;
        ex_inst_1 <= ID_EX_INIT;
        p0_idx_sel <= -1;
        p1_idx_sel <= -1;
        found_p0 := false;
        found_p1 := false;
        p0_warp := 0;
        
        -- Port 0 selection
        for i in 0 to NUM_COLLECTORS-1 loop
            idx := (release_rr_ptr + i) mod NUM_COLLECTORS;
            
            if not found_p0 and collectors(idx).state = CU_READY then
                if unit_issue_id(idx) = warp_release_id(to_integer(unsigned(collectors(idx).inst.warp))) then
                    inst_tmp := collectors(idx).inst;
                    inst_tmp.rs1 := rs1_data(idx);
                    inst_tmp.rs2 := rs2_data(idx);
                    inst_tmp.rs3 := rs3_data(idx);
                    
                    ex_valid(0) <= '1';
                    ex_inst_0 <= inst_tmp;
                    p0_idx_sel <= idx;
                    p0_warp := to_integer(unsigned(collectors(idx).inst.warp));
                    found_p0 := true;
                end if;
            end if;
        end loop;
        
        -- Port 1 selection (different unit type for dual issue)
        for i in 0 to NUM_COLLECTORS-1 loop
            idx := (release_rr_ptr + i) mod NUM_COLLECTORS;
            
            if not found_p1 and idx /= p0_idx_sel and collectors(idx).state = CU_READY then
                if unit_issue_id(idx) = warp_release_id(to_integer(unsigned(collectors(idx).inst.warp))) or
                   (found_p0 and to_integer(unsigned(collectors(idx).inst.warp)) = p0_warp and
                    unit_issue_id(idx) = warp_release_id(p0_warp) + 1) then
                    
                    -- Check for structural hazard (can't issue two ALU ops together)
                    if not found_p0 or 
                       (get_unit_type(collectors(idx).inst.op) /= get_unit_type(ex_inst_0.op)) then
                        
                        inst_tmp := collectors(idx).inst;
                        inst_tmp.rs1 := rs1_data(idx);
                        inst_tmp.rs2 := rs2_data(idx);
                        inst_tmp.rs3 := rs3_data(idx);
                        
                        ex_valid(1) <= '1';
                        ex_inst_1 <= inst_tmp;
                        p1_idx_sel <= idx;
                        found_p1 := true;
                    end if;
                end if;
            end if;
        end loop;
    end process;
    
    ---------------------------------------------------------------------------
    -- Register File Writeback
    ---------------------------------------------------------------------------
    process(clk)
        variable bank : integer;
        variable offset : integer;
    begin
        if rising_edge(clk) then
            -- Port 0 writeback
            if wb_valid(0) = '1' then
                bank := get_bank(wb_rd_0);
                offset := get_bank_offset(wb_rd_0);
                
                for i in 0 to WARP_SIZE-1 loop
                    if wb_mask_0(i) = '1' then
                        rf_bank(bank)(i, to_integer(unsigned(wb_warp_0)), offset) <= 
                            wb_data_0((i+1)*32-1 downto i*32);
                    end if;
                end loop;
            end if;
            
            -- Port 1 writeback
            if wb_valid(1) = '1' then
                bank := get_bank(wb_rd_1);
                offset := get_bank_offset(wb_rd_1);
                
                for i in 0 to WARP_SIZE-1 loop
                    if wb_mask_1(i) = '1' then
                        rf_bank(bank)(i, to_integer(unsigned(wb_warp_1)), offset) <= 
                            wb_data_1((i+1)*32-1 downto i*32);
                    end if;
                end loop;
            end if;
        end if;
    end process;
    
    ---------------------------------------------------------------------------
    -- Main Sequential Logic
    ---------------------------------------------------------------------------
    process(clk, rst_n)
        variable idle_idx : integer;
        variable allocated_first : integer;
        variable all_ready : boolean;
        variable bank : integer;
        variable offset : integer;
        variable warp_idx : integer;
    begin
        if rst_n = '0' then
            for i in 0 to NUM_COLLECTORS-1 loop
                collectors(i).state <= CU_IDLE;
                collectors(i).needed_mask <= "000";
                rs1_ready(i) <= '0';
                rs2_ready(i) <= '0';
                rs3_ready(i) <= '0';
                unit_issue_id(i) <= (others => '0');
            end loop;
            
            for w in 0 to NUM_WARPS-1 loop
                warp_issue_id(w) <= (others => '0');
                warp_release_id(w) <= (others => '0');
            end loop;
            
            for b in 0 to BANK_COUNT-1 loop
                bank_rr_ptr(b) <= 0;
            end loop;
            release_rr_ptr <= 0;
            
        elsif rising_edge(clk) then
            
            -----------------------------------------------------------------
            -- 1. ALLOCATION
            -----------------------------------------------------------------
            allocated_first := -1;
            
            -- Port 0 allocation
            if dispatch_valid(0) = '1' and dispatch_ready(0) = '1' then
                for i in 0 to NUM_COLLECTORS-1 loop
                    if collectors(i).state = CU_IDLE and i /= allocated_first then
                        collectors(i).state <= CU_ALLOCATED;
                        collectors(i).inst <= dispatch_inst_0;
                        
                        warp_idx := to_integer(unsigned(dispatch_inst_0.warp));
                        unit_issue_id(i) <= warp_issue_id(warp_idx);
                        warp_issue_id(warp_idx) <= warp_issue_id(warp_idx) + 1;
                        
                        rs1_ready(i) <= '0';
                        rs2_ready(i) <= '0';
                        rs3_ready(i) <= '0';
                        
                        -- Set needed mask based on opcode
                        if needs_rs1(dispatch_inst_0.op) then
                            collectors(i).needed_mask(0) <= '1';
                        else
                            collectors(i).needed_mask(0) <= '0';
                        end if;
                        
                        if needs_rs2(dispatch_inst_0.op) then
                            collectors(i).needed_mask(1) <= '1';
                        else
                            collectors(i).needed_mask(1) <= '0';
                        end if;
                        
                        if needs_rs3(dispatch_inst_0.op) then
                            collectors(i).needed_mask(2) <= '1';
                        else
                            collectors(i).needed_mask(2) <= '0';
                        end if;
                        
                        allocated_first := i;
                        exit;
                    end if;
                end loop;
            end if;
            
            -- Port 1 allocation
            if dispatch_valid(1) = '1' and dispatch_ready(1) = '1' then
                for i in 0 to NUM_COLLECTORS-1 loop
                    if collectors(i).state = CU_IDLE and i /= allocated_first then
                        collectors(i).state <= CU_ALLOCATED;
                        collectors(i).inst <= dispatch_inst_1;
                        
                        warp_idx := to_integer(unsigned(dispatch_inst_1.warp));
                        unit_issue_id(i) <= warp_issue_id(warp_idx);
                        warp_issue_id(warp_idx) <= warp_issue_id(warp_idx) + 1;
                        
                        rs1_ready(i) <= '0';
                        rs2_ready(i) <= '0';
                        rs3_ready(i) <= '0';
                        
                        if needs_rs1(dispatch_inst_1.op) then
                            collectors(i).needed_mask(0) <= '1';
                        else
                            collectors(i).needed_mask(0) <= '0';
                        end if;
                        
                        if needs_rs2(dispatch_inst_1.op) then
                            collectors(i).needed_mask(1) <= '1';
                        else
                            collectors(i).needed_mask(1) <= '0';
                        end if;
                        
                        if needs_rs3(dispatch_inst_1.op) then
                            collectors(i).needed_mask(2) <= '1';
                        else
                            collectors(i).needed_mask(2) <= '0';
                        end if;
                        
                        exit;
                    end if;
                end loop;
            end if;
            
            -----------------------------------------------------------------
            -- 2. OPERAND COLLECTION (from register file banks)
            -----------------------------------------------------------------
            for b in 0 to BANK_COUNT-1 loop
                for j in 0 to NUM_COLLECTORS-1 loop
                    idle_idx := (bank_rr_ptr(b) + j) mod NUM_COLLECTORS;
                    
                    if collectors(idle_idx).state = CU_ALLOCATED then
                        warp_idx := to_integer(unsigned(collectors(idle_idx).inst.warp));
                        
                        -- Check RS1
                        if rs1_ready(idle_idx) = '0' and rs1_forwarded(idle_idx) = '0' and
                           collectors(idle_idx).needed_mask(0) = '1' and
                           get_bank(collectors(idle_idx).inst.rs1_idx(5 downto 0)) = b then
                            
                            offset := get_bank_offset(collectors(idle_idx).inst.rs1_idx(5 downto 0));
                            for lane in 0 to WARP_SIZE-1 loop
                                rs1_data(idle_idx)(lane) <= rf_bank(b)(lane, warp_idx, offset);
                            end loop;
                            rs1_ready(idle_idx) <= '1';
                            bank_rr_ptr(b) <= (idle_idx + 1) mod NUM_COLLECTORS;
                            exit;
                        end if;
                        
                        -- Check RS2
                        if rs2_ready(idle_idx) = '0' and rs2_forwarded(idle_idx) = '0' and
                           collectors(idle_idx).needed_mask(1) = '1' and
                           get_bank(collectors(idle_idx).inst.rs2_idx(5 downto 0)) = b then
                            
                            offset := get_bank_offset(collectors(idle_idx).inst.rs2_idx(5 downto 0));
                            for lane in 0 to WARP_SIZE-1 loop
                                rs2_data(idle_idx)(lane) <= rf_bank(b)(lane, warp_idx, offset);
                            end loop;
                            rs2_ready(idle_idx) <= '1';
                            bank_rr_ptr(b) <= (idle_idx + 1) mod NUM_COLLECTORS;
                            exit;
                        end if;
                        
                        -- Check RS3
                        if rs3_ready(idle_idx) = '0' and rs3_forwarded(idle_idx) = '0' and
                           collectors(idle_idx).needed_mask(2) = '1' and
                           get_bank(collectors(idle_idx).inst.rs3_idx(5 downto 0)) = b then
                            
                            offset := get_bank_offset(collectors(idle_idx).inst.rs3_idx(5 downto 0));
                            for lane in 0 to WARP_SIZE-1 loop
                                rs3_data(idle_idx)(lane) <= rf_bank(b)(lane, warp_idx, offset);
                            end loop;
                            rs3_ready(idle_idx) <= '1';
                            bank_rr_ptr(b) <= (idle_idx + 1) mod NUM_COLLECTORS;
                            exit;
                        end if;
                    end if;
                end loop;
            end loop;
            
            -----------------------------------------------------------------
            -- 2.5 FORWARDING (from writeback bus)
            -----------------------------------------------------------------
            for i in 0 to NUM_COLLECTORS-1 loop
                if collectors(i).state = CU_ALLOCATED then
                    warp_idx := to_integer(unsigned(collectors(i).inst.warp));
                    
                    -- Check port 0
                    if wb_valid(0) = '1' and wb_warp_0 = collectors(i).inst.warp then
                        if rs1_ready(i) = '0' and collectors(i).needed_mask(0) = '1' and
                           collectors(i).inst.rs1_idx(5 downto 0) = wb_rd_0 then
                            rs1_data(i) <= to_word_array(wb_data_0);
                            rs1_ready(i) <= '1';
                        end if;
                        
                        if rs2_ready(i) = '0' and collectors(i).needed_mask(1) = '1' and
                           collectors(i).inst.rs2_idx(5 downto 0) = wb_rd_0 then
                            rs2_data(i) <= to_word_array(wb_data_0);
                            rs2_ready(i) <= '1';
                        end if;
                        
                        if rs3_ready(i) = '0' and collectors(i).needed_mask(2) = '1' and
                           collectors(i).inst.rs3_idx(5 downto 0) = wb_rd_0 then
                            rs3_data(i) <= to_word_array(wb_data_0);
                            rs3_ready(i) <= '1';
                        end if;
                    end if;
                    
                    -- Check port 1
                    if wb_valid(1) = '1' and wb_warp_1 = collectors(i).inst.warp then
                        if rs1_ready(i) = '0' and collectors(i).needed_mask(0) = '1' and
                           collectors(i).inst.rs1_idx(5 downto 0) = wb_rd_1 then
                            rs1_data(i) <= to_word_array(wb_data_1);
                            rs1_ready(i) <= '1';
                        end if;
                        
                        if rs2_ready(i) = '0' and collectors(i).needed_mask(1) = '1' and
                           collectors(i).inst.rs2_idx(5 downto 0) = wb_rd_1 then
                            rs2_data(i) <= to_word_array(wb_data_1);
                            rs2_ready(i) <= '1';
                        end if;
                        
                        if rs3_ready(i) = '0' and collectors(i).needed_mask(2) = '1' and
                           collectors(i).inst.rs3_idx(5 downto 0) = wb_rd_1 then
                            rs3_data(i) <= to_word_array(wb_data_1);
                            rs3_ready(i) <= '1';
                        end if;
                    end if;
                end if;
            end loop;
            
            -----------------------------------------------------------------
            -- 3. READY PROMOTION
            -----------------------------------------------------------------
            for i in 0 to NUM_COLLECTORS-1 loop
                if collectors(i).state = CU_ALLOCATED then
                    all_ready := true;
                    
                    if collectors(i).needed_mask(0) = '1' and rs1_ready(i) = '0' then
                        all_ready := false;
                    end if;
                    if collectors(i).needed_mask(1) = '1' and rs2_ready(i) = '0' then
                        all_ready := false;
                    end if;
                    if collectors(i).needed_mask(2) = '1' and rs3_ready(i) = '0' then
                        all_ready := false;
                    end if;
                    
                    if all_ready then
                        collectors(i).state <= CU_READY;
                    end if;
                end if;
            end loop;
            
            -----------------------------------------------------------------
            -- 3.5 FLUSH HANDLING
            -----------------------------------------------------------------
            if flush_valid = '1' then
                for i in 0 to NUM_COLLECTORS-1 loop
                    if collectors(i).state /= CU_IDLE and 
                       collectors(i).inst.warp = flush_warp then
                        collectors(i).state <= CU_READY;
                        collectors(i).inst.op <= OP_NOP;
                        collectors(i).needed_mask <= "000";
                    end if;
                end loop;
            end if;
            
            -----------------------------------------------------------------
            -- 4. RELEASE
            -----------------------------------------------------------------
            if ex_valid(0) = '1' and ex_ready(0) = '1' and p0_idx_sel /= -1 then
                collectors(p0_idx_sel).state <= CU_IDLE;
                warp_idx := to_integer(unsigned(collectors(p0_idx_sel).inst.warp));
                warp_release_id(warp_idx) <= warp_release_id(warp_idx) + 1;
            end if;
            
            if ex_valid(1) = '1' and ex_ready(1) = '1' and p1_idx_sel /= -1 then
                collectors(p1_idx_sel).state <= CU_IDLE;
                warp_idx := to_integer(unsigned(collectors(p1_idx_sel).inst.warp));
                
                -- Handle double increment if same warp as port 0
                if ex_valid(0) = '1' and ex_ready(0) = '1' and p0_idx_sel /= -1 and
                   collectors(p1_idx_sel).inst.warp = collectors(p0_idx_sel).inst.warp then
                    warp_release_id(warp_idx) <= warp_release_id(warp_idx) + 2;
                else
                    warp_release_id(warp_idx) <= warp_release_id(warp_idx) + 1;
                end if;
            end if;
            
            -- Update release round-robin pointer
            if p1_idx_sel /= -1 then
                release_rr_ptr <= (p1_idx_sel + 1) mod NUM_COLLECTORS;
            elsif p0_idx_sel /= -1 then
                release_rr_ptr <= (p0_idx_sel + 1) mod NUM_COLLECTORS;
            end if;
            
        end if;
    end process;

end architecture rtl;
