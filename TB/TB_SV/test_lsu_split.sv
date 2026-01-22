`timescale 1ns/1ps

module test_lsu_split;
    import simt_pkg::*;
    import sfu_pkg::*;

    // Parameters
    localparam WARP_SIZE = 32;
    localparam NUM_WARPS = 4; // Reduced for simpler debugging
    localparam NUM_REGS = 64;
    localparam MOCK_MEM_SIZE = 16384; 

    // Signals
    logic clk;
    logic rst_n;
    logic done;

    // DUT Instantiation
    streaming_multiprocessor #(
        .WARP_SIZE(WARP_SIZE),
        .NUM_WARPS(NUM_WARPS),
        .NUM_REGS(NUM_REGS),
        .SM_ID(0),
        .MAX_PENDING_PER_WARP(16) // Enough for splits
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .done(done)
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Test Variables
    logic [63:0] inst;
    int cycle;

    // Helper: Wait Cycles
    task wait_cycles(int n);
        repeat(n) @(posedge clk);
    endtask

    // Helper: Inject Instruction (Peek/Poke internal memory)
    // Note: We are poking the DUT's program memory directly
    task inject_instruction(int warp_id, int pc, logic [63:0] instruction);
        dut.prog_mem[warp_id][pc] = instruction;
    endtask
    
    // Helper: Build LDR Instruction: LDR R[rd], [R[rs1] + imm]
    function logic [63:0] build_ldr(int rd, int rs1, int imm);
        return {8'h10, 8'(rd), 8'(rs1), 8'h00, 4'h7, 8'h00, 20'(imm)}; 
        // Need to match instruction format:
        // [63:56] Op
        // [55:48] Rd
        // [47:40] Rs1
        // [39:32] Rs2 (unused for LDR)
        // [19:0]  Imm
    endfunction
    
    // Helper: Build MOV Instruction: MOV R[rd], imm (using simplified format or ALU op)
    // Actually we don't have a direct MOV imm instruction in standard encoding shown in pkg?
    // Let's use IADD R[rd], R31(zero), imm
    // Assuming R31 is not hardwired zero, we might need a different approach.
    // Or we use `dut.warp_reg_writes` / `dut.oc_inst.banked_reg_file` backdoor if possible?
    // Let's use backdoor initialization for simplicity of setting up addresses.

    task backdoor_set_reg(int warp_id, int lane, int reg_idx, int value);
        // We have to poke the internal memory of the operand collector or similar
        // Since `regs` was removed from SM and is now in OC.
        // Path: dut.oc_inst.gen_banks[...].rf_inst.mem[...]
        // This is complex. 
        // Alternative: Use an initialization code sequence.
        // "MOV" op is 0x07 (?) -- check pkg. Yes OP_MOV = 0x07.
        // Format: MOV Rd, Imm (where is imm?)
        // Let's assume standard I-Type: Op, Rd, Imm20.
        // Wait, standard encoding in `streaming_multiprocessor.sv` line 735:
        // id_ex[p].imm   <= {{12{if_id[p].inst[19]}}, if_id[p].inst[19:0]};
        // So yes, bottom 20 bits are immediate.
    endtask

    // Main Test Sequence
    initial begin
        // --------------------------------------------------------------------
        // INITIALIZATION
        // --------------------------------------------------------------------
        rst_n = 0;
        wait_cycles(5);
        rst_n = 1;
        wait_cycles(5); // Wait for internal init
        
        $display("============================================================");
        $display("TEST: LSU SPLITTER VERIFICATION");
        $display("============================================================");

        // --------------------------------------------------------------------
        // SCENARIO 1: COALESCED ACCESS (Single Transaction)
        // --------------------------------------------------------------------
        // Setup:
        // Warp 0. 
        // R1 = Base Address = 0x1000
        // Threads access R1 + tid*4
        // Logic: 
        // 1. Move 0x1000 into R1 (Base)
        // 2. Add TID*4 to R1
        // 3. LDR R2, [R1]
        
        $display("[%0t] SCENARIO 1: Coalesced Access (Expect 1 TX)", $time);
        
        // Step 1: Initialize R1 with 0x1000 + Lane*4
        // Since we can't easily execute a complex preamble, let's Backdoor initialize valid registers?
        // Actually, let's just use the `alloc_pop` counter to verify splitting.
        
        // We will poke the internal register file state for Warp 0, Reg 1.
        // Finding the path to the register file memory is tricky with `operand_collector`.
        // Path: dut.oc_inst.rf_data[warp][reg] ? No, it's banked.
        // Let's rely on the `lsu_mem` signals to inspect what's happening.
        
        // Let's FORCE values into the LSU pipeline input for testing the splitter logic specifically?
        // Or run a real program.
        
        // Let's run a real program.
        // We need: R1 = 0x1000 + TID*4.
        // OP_TID R2 -> R2 = TID
        // OP_SHL R3, R2, 2 -> R3 = TID*4
        // OP_MOV R4, 0x1000 -> R4 = Base
        // OP_ADD R1, R4, R3 -> R1 = Address
        // OP_LDR R5, [R1]
        
        // Program for Warp 0
        dut.prog_mem[0][0] = {8'h26, 8'd2, 8'd0, 8'd0, 4'h7, 8'd0, 20'd0}; 
        dut.prog_mem[0][1] = {8'h60, 8'd3, 8'd2, 8'd0, 4'h7, 8'd0, 20'd2}; 
        dut.prog_mem[0][2] = {8'h07, 8'd4, 8'd0, 8'd0, 4'h7, 8'd0, 20'h1000}; 
        dut.prog_mem[0][3] = {8'h01, 8'd1, 8'd4, 8'd3, 4'h7, 8'd0, 20'd0}; 
        dut.prog_mem[0][4] = {8'h10, 8'd5, 8'd1, 8'd0, 4'h7, 8'd0, 20'd0}; 
        dut.prog_mem[0][5] = {8'hFF, 8'd0, 8'd0, 8'd0, 4'h7, 8'd0, 20'd0};
        
        // Enable Warp 0
        dut.warp_state[0] = W_READY;
        dut.warp_active_mask[0] = 32'hFFFFFFFF; 
        dut.warp_pc[0] = 0;
        $display("TB DEBUG: Forced Warp 0 State to W_READY (%d). Readback: %d", W_READY, dut.warp_state[0]);
        
        // Run and Monitor
        wait_cycles(100);
        
        // Check: How many transactions?
        // We can monitor `dut.alloc_pop[0]`.
        
        // --------------------------------------------------------------------
        // SCENARIO 2: UNCOALESCED SPLIT ACCESS (Two Transactions)
        // --------------------------------------------------------------------
        $display("[%0t] SCENARIO 2: Split Access (Expect 2 TX)", $time);
        
        // Warp 1.
        // Lane 0-15: Address 0x2000 (Line A)
        // Lane 16-31: Address 0x2080 (Line B, +128 bytes)
        
        // Code:
        // TID R2
        // IF (TID < 16) R1 = 0x2000
        // ELSE R1 = 0x2080
        // LDR R5, [R1]
        
        // Simplified Logic using Predicates:
        // Set Pred P1 = (TID < 16) -> ISETP.LT P1, R2, 16
        // MOV R1, 0x2080
        // @P1 MOV R1, 0x2000
        // LDR R5, [R1]
        
        // 0: TID R2 (Reuse R2 as TID temp)
        dut.prog_mem[1][0] = {8'h26, 8'd2, 8'd0, 8'd0, 4'h7, 8'd0, 20'd0}; 
        // 1: MOV R1, 0x1000 (Base 1)
        dut.prog_mem[1][1] = {8'h07, 8'd1, 8'd0, 8'd0, 4'h7, 8'd0, 20'h1000}; 
        // 2: SHR R3, R2, 4
        dut.prog_mem[1][2] = {8'h61, 8'd3, 8'd2, 8'd0, 4'h7, 8'd0, 20'd4}; 
        // 3: SHL R3, R3, 7
        dut.prog_mem[1][3] = {8'h60, 8'd3, 8'd3, 8'd0, 4'h7, 8'd0, 20'd7}; 
        // 4: ADD R1, R1, R3
        dut.prog_mem[1][4] = {8'h01, 8'd1, 8'd1, 8'd3, 4'h7, 8'd0, 20'd0}; 
        // 5: LDR R5, [R1]
        dut.prog_mem[1][5] = {8'h10, 8'd5, 8'd1, 8'd0, 4'h7, 8'd0, 20'd0}; 
        // 6: EXIT
        dut.prog_mem[1][6] = {8'hFF, 8'd0, 8'd0, 8'd0, 4'h7, 8'd0, 20'd0};

        // Enable Warp 1
        dut.warp_state[1] = W_READY;
        dut.warp_active_mask[1] = 32'hFFFFFFFF;
        dut.warp_pc[1] = 0;
        $display("TB DEBUG: Forced Warp 1 State to W_READY (%d). Readback: %d", W_READY, dut.warp_state[1]);
        
        wait_cycles(200);
        
        $finish;
    end
    
    // ------------------------------------------------------------------------
    // MONITORING
    // ------------------------------------------------------------------------
    int tx_count_w0;
    int tx_count_w1;
    
    initial begin
        tx_count_w0 = 0;
        tx_count_w1 = 0;
    end
    
    always @(posedge clk) begin
        if (dut.mem_launch) begin
            $display("[%0t] MEM_LAUNCH: Warp=%0d Mask=%h Addr0=%h Last=%b", 
                     $time, dut.current_lsu_request.warp, dut.current_split_mask, dut.current_lsu_request.addresses[0], dut.split_is_last);
            if (dut.current_lsu_request.warp == 0) begin
                tx_count_w0++;
                $display("[%0t] MONITOR: Warp 0 Transaction! Count=%0d", $time, tx_count_w0);
            end else if (dut.current_lsu_request.warp == 1) begin
                tx_count_w1++;
                $display("[%0t] MONITOR: Warp 1 Transaction! Count=%0d", $time, tx_count_w1);
            end
        end
        
        // Debug
        if (cycle % 100 == 0) begin
             $display("DEBUG: lsu_valid=%b replay_grant=%b mask=%h", dut.lsu_mem.valid, dut.replay_grant_valid, dut.current_lsu_request.mask);
        end
    end

    always @(posedge clk) begin
        cycle++;
        if (cycle % 10 == 0) begin
            $display("[%0t] PC Monitor: Warp0 PC=%0d State=%0d | Warp1 PC=%0d State=%0d", 
                     $time, dut.warp_pc[0], dut.warp_state[0], dut.warp_pc[1], dut.warp_state[1]);
        end
    end
    
    // Final Check
    final begin
        $display("============================================================");
        $display("RESULTS");
        $display("Warp 0 (Coalesced) Transactions: %0d (Expected: 1)", tx_count_w0);
        $display("Warp 1 (Split)     Transactions: %0d (Expected: 2)", tx_count_w1);
        
        if (tx_count_w0 == 1 && tx_count_w1 == 2) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED");
        end
        $display("============================================================");
    end

endmodule
