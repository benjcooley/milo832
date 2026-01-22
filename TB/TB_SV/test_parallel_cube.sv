`timescale 1ns/1ps

import simt_pkg::*;

module test_parallel_cube;
    // DUT signals
    logic clk;
    logic rst_n;
    
    // Instantiate DUT
    streaming_multiprocessor dut (
        .clk(clk),
        .rst_n(rst_n)
    );
    
    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk; // 100MHz
    
    // Simulation control
    integer cycle;
    integer max_cycles = 100000;
    integer pc;
    integer loop_start_pc;
    
    // Framebuffer parameters
    parameter FB_WIDTH = 64;
    parameter FB_HEIGHT = 64;
    parameter FB_BASE = 32'h2000; 
    parameter FB_SIZE = (FB_WIDTH * FB_HEIGHT) / 8;
    
    // Helper to write a 32-bit word to mock_memory
    task automatic write_mem_word(input logic [31:0] addr, input logic [31:0] data);
        integer line_idx;
        integer word_offset;
        line_idx = addr >> 7;
        word_offset = (addr >> 2) & 31;
        dut.dut_memory.mem[line_idx][word_offset*32 +: 32] = data;
    endtask
    
    // Helper: Encode 64-bit instruction
    function logic [63:0] encode_inst(
        logic [7:0] op,
        logic [7:0] rd,
        logic [7:0] rs1,
        logic [7:0] rs2,
        logic [7:0] rs3,
        logic [3:0] pred,
        logic [19:0] imm
    );
        return {op, rd, rs1, rs2, pred, rs3, imm};
    endfunction
    
    initial begin
        $display("========================================");
        $display("TEST: Parallel Perspective Cube (SIMT)");
        $display("========================================");
        
        // Reset
        rst_n = 0;
        cycle = 0;
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);
        
        // Initialize 3D vertex data in memory @ 0x1000
        // (x, y, z) triplets - 3 words per vertex (12 bytes)
        // Back face (z = -16)
        write_mem_word(32'h1000, 32'shfffffff0); write_mem_word(32'h1004, 32'shfffffff0); write_mem_word(32'h1008, 32'shfffffff0); // V0 (-16,-16,-16)
        write_mem_word(32'h100c, 32'sd16);       write_mem_word(32'h1010, 32'shfffffff0); write_mem_word(32'h1014, 32'shfffffff0); // V1 ( 16,-16,-16)
        write_mem_word(32'h1018, 32'sd16);       write_mem_word(32'h101c, 32'sd16);       write_mem_word(32'h1020, 32'shfffffff0); // V2 ( 16, 16,-16)
        write_mem_word(32'h1024, 32'shfffffff0); write_mem_word(32'h1028, 32'sd16);       write_mem_word(32'h102c, 32'shfffffff0); // V3 (-16, 16,-16)
        // Front face (z = 16)
        write_mem_word(32'h1030, 32'shfffffff0); write_mem_word(32'h1034, 32'shfffffff0); write_mem_word(32'h1038, 32'sd16);       // V4 (-16,-16, 16)
        write_mem_word(32'h103c, 32'sd16);       write_mem_word(32'h1040, 32'shfffffff0); write_mem_word(32'h1044, 32'sd16);       // V5 ( 16,-16, 16)
        write_mem_word(32'h1048, 32'sd16);       write_mem_word(32'h104c, 32'sd16);       write_mem_word(32'h1050, 32'sd16);       // V6 ( 16, 16, 16)
        write_mem_word(32'h1054, 32'shfffffff0); write_mem_word(32'h1058, 32'sd16);       write_mem_word(32'h105c, 32'sd16);       // V7 (-16, 16, 16)
        
        // Clear framebuffer
        for (int i = 0; i < FB_SIZE; i += 4) begin
            write_mem_word(FB_BASE + i, 32'h0);
        end
        
        // ASSEMBLY PROGRAM: SIMT Parallel Execution
        pc = 0;
        // R20 = 0 (Constant source)
        for (int t=0; t<8; t++)
             dut.oc_inst.rf_bank_phys[0][t][0][5] = 32'h0; 

        
        // Setup Constants
        // R21 = cos(30) = 0x6EDA (1.15)
        // R22 = sin(30) = 0x4000 (1.15)
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 21, 20, 0, 0, 4'h7, 20'h6EDA);
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 22, 20, 0, 0, 4'h7, 20'h4000);
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 2, 20, 0, 0, 4'h7, 20'h2000); // R2 = FB Base

        // [PARALLEL] Calculate Vertex Pointer based on TID
        // R30 = TID (0-7)
        // Offset = TID * 12 (3 words * 4 bytes) -> R30 * 12
        // R0 = 0x1000 + Offset
        dut.prog_mem[0][pc++] = encode_inst(OP_TID, 30, 0, 0, 0, 4'h7, 20'h0);
        dut.prog_mem[0][pc++] = encode_inst(OP_IMAD, 31, 30, 20, 0, 4'h7, 20'd12); // R31 = TID * 12 (Using IMAD with 12 imm? No, using MUL logic or shifts)
        // Wait, IMAD is a*b+c. Can use MUL R31, R30, 12? No, immediate is 20-bit.
        // Let's use MUL R31, R30, R_const_12. Or shifts. 12 = 8 + 4.
        // R31 = (TID << 3) + (TID << 2)
        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 29, 30, 20, 0, 4'h7, 20'd3); // TID * 8
        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 28, 30, 20, 0, 4'h7, 20'd2); // TID * 4
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 31, 29, 28, 0, 4'h7, 20'd0); // R31 = Offset
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 0, 31, 20, 0, 4'h7, 20'h1000); // R0 = Base + Offset

        // Setup Y-Rotation: θ injected into R15 by TB
        // R16 = cos(θ), R17 = sin(θ)
        dut.prog_mem[0][pc++] = encode_inst(OP_SFU_COS, 16, 15, 20, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_SFU_SIN, 17, 15, 20, 0, 4'h7, 20'd0);

        // Load (x, y, z) - Each thread loads its own vertex
        dut.prog_mem[0][pc++] = encode_inst(OP_LDR, 3, 0, 20, 0, 4'h7, 20'd0);  // x
        dut.prog_mem[0][pc++] = encode_inst(OP_LDR, 4, 0, 20, 0, 4'h7, 20'd4);  // y
        dut.prog_mem[0][pc++] = encode_inst(OP_LDR, 18, 0, 20, 0, 4'h7, 20'd8); // z

        // 1. Rotate around Y-axis (dynamic angle θ)
        // x' = x*cos(θ) + z*sin(θ)
        // z' = z*cos(θ) - x*sin(θ)
        dut.prog_mem[0][pc++] = encode_inst(OP_MUL, 5, 3, 16, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_MUL, 6, 18, 17, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 7, 5, 6, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_SHA, 7, 7, 20, 0, 4'h7, 20'd15); // R7 = x'

        dut.prog_mem[0][pc++] = encode_inst(OP_MUL, 8, 18, 16, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_MUL, 9, 3, 17, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_SUB, 10, 8, 9, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_SHA, 10, 10, 20, 0, 4'h7, 20'd15); // R10 = z'

        // 2. Rotate around X-axis (static 30 deg)
        // y'' = y*cos(30) - z'*sin(30)
        // z'' = y*sin(30) + z'*cos(30)
        dut.prog_mem[0][pc++] = encode_inst(OP_MUL, 5, 4, 21, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_MUL, 6, 10, 22, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_SUB, 11, 5, 6, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_SHA, 11, 11, 20, 0, 4'h7, 20'd15); // R11 = y''

        dut.prog_mem[0][pc++] = encode_inst(OP_MUL, 8, 4, 22, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_MUL, 9, 10, 21, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 12, 8, 9, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_SHA, 12, 12, 20, 0, 4'h7, 20'd15); // R12 = z''

        // 3. Perspective Projection
        // x_proj = (x' * focal_length) / (z'' + distance)
        // y_proj = (y'' * focal_length) / (z'' + distance)
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 12, 12, 20, 0, 4'h7, 20'd128); // z_cam = z'' + 128

        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 5, 7, 20, 0, 4'h7, 20'd7);     // x' * 128
        dut.prog_mem[0][pc++] = encode_inst(OP_IDIV, 3, 5, 12, 0, 4'h7, 20'd0);   // x_proj
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 3, 3, 20, 0, 4'h7, 20'd32);   // x_scr

        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 6, 11, 20, 0, 4'h7, 20'd7);    // y'' * 128
        dut.prog_mem[0][pc++] = encode_inst(OP_IDIV, 4, 6, 12, 0, 4'h7, 20'd0);   // y_proj
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 4, 4, 20, 0, 4'h7, 20'd32);   // y_scr

        // Framebuffer Write (standard pixel bitmask logic)
        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 5, 4, 20, 0, 4'h7, 20'd3); // y << 3
        dut.prog_mem[0][pc++] = encode_inst(OP_SHR, 6, 3, 20, 0, 4'h7, 20'd5); // x >> 5
        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 7, 6, 20, 0, 4'h7, 20'd2); // R6 << 2
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 8, 5, 7, 0, 4'h7, 20'd0);
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 9, 2, 8, 0, 4'h7, 20'd0);  // R9 = Byte Address
        dut.prog_mem[0][pc++] = encode_inst(OP_AND, 10, 3, 20, 0, 4'h7, 20'd31);
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 11, 20, 0, 0, 4'h7, 20'd1);
        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 12, 11, 10, 0, 4'h7, 20'd0); // R12 = Bit Mask

        // SERIALIZATION LOOP: To prevent R-M-W hazards on Global Memory
        // Loop k = 0 to 7
        // Use R23 (Bank 3) for k, R27 (Bank 3) for limit to avoid conflicts
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 23, 20, 0, 0, 4'h7, 20'd0); // k = 0
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 27, 20, 0, 0, 4'h7, 20'd8); // limit = 8
        
        loop_start_pc = pc;
        // P1 = (TID == k) -> ISETP.EQ(0) P1, R30, R23
        dut.prog_mem[0][pc++] = encode_inst(OP_ISETP, 1, 30, 23, 0, 4'h7, 20'd0); 
        
        // Critical Section Guarded by @P1 (Pred=1)
        dut.prog_mem[0][pc++] = encode_inst(OP_LDR, 13, 9, 20, 0, 4'h1, 20'd0); // Load Old
        dut.prog_mem[0][pc++] = encode_inst(OP_OR, 14, 13, 12, 0, 4'h1, 20'd0); // OR Mask
        dut.prog_mem[0][pc++] = encode_inst(OP_STR, 0, 9, 14, 0, 4'h1, 20'd0);  // Store New
        
        // Loop Control
        dut.prog_mem[0][pc++] = encode_inst(OP_NOP, 0, 0, 0, 0, 4'h7, 20'd0);   // Delay
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 23, 23, 20, 0, 4'h7, 20'd1); // k++
        // FIX: OP_BNE compares RS1 and RS2. RD is ignored (set to 0).
        // args: op, rd, rs1, rs2, rs3, pred, imm
        dut.prog_mem[0][pc++] = encode_inst(OP_BNE, 0, 23, 27, 0, 4'h7, 20'($signed(loop_start_pc - pc)));
        
        // SYNC: Barrier to ensure specific point reached
        dut.prog_mem[0][pc++] = encode_inst(OP_BAR, 0, 0, 0, 0, 4'h7, 20'd0);
        
        // NO LOOP (Parallel Execution) - Just Exit
        dut.prog_mem[0][pc++] = encode_inst(OP_EXIT, 0, 0, 0, 0, 4'h7, 20'd0);
        
        // Multi-frame Animation Loop (48 frames @ 24fps)
        for (int frame = 0; frame < 48; frame++) begin
            $display("--- Generating Frame %02d/48 ---", frame + 1);
            
            // 1. Hardware Reset between frames
            rst_n = 0;
            repeat(10) @(posedge clk);
            rst_n = 1;
            repeat(5) @(posedge clk);

            // 2. Re-initialize essential software state for ALL active threads (0-7)
            for (int t = 0; t < 8; t++) begin
                // R20 = 0 (Constant source)
                dut.oc_inst.rf_bank_phys[0][t][0][5] = 32'h0; 
                // R15 = Angle (0x0000 to 0xFFFF)
                dut.oc_inst.rf_bank_phys[3][t][0][3] = (frame * 32'h0555) & 32'hFFFF;
            end
            
            // 3. Clear Framebuffer for next frame
            for (int i = 0; i < FB_SIZE; i += 4) begin
                write_mem_word(FB_BASE + i, 32'h0);
            end
            
            // 4. Reset Warps & Enable Threads 0-7 (8 Vertices)
            dut.warp_state[0] = W_READY;
            dut.warp_pc[0] = 0;
            dut.warp_active_mask[0] = 32'hFF; // ENABLE 8 THREADS
            
            // 5. Run until EXIT
            while (dut.warp_state[0] != W_EXIT && cycle < max_cycles * 50) begin
                @(posedge clk);
                cycle++;
            end
            
            // 5. Capture as sequential PPM
            save_framebuffer_ppm($sformatf("frame_%03d.ppm", frame));
        end
        
        $display("Animation generation complete. Total cycles: %0d", cycle);
        $finish;
    end

    task save_framebuffer_ppm(string filename);
        integer fd;
        logic [7:0] fb_byte;
        logic pixel;
        integer y, x;
        integer byte_addr, line_idx, line_byte_offset, bit_pos;
        fd = $fopen(filename, "w");
        $fwrite(fd, "P1\n%0d %0d\n", FB_WIDTH, FB_HEIGHT);
        for (y = 0; y < FB_HEIGHT; y++) begin
            for (x = 0; x < FB_WIDTH; x++) begin
                byte_addr = FB_BASE + (y * 8) + (x / 8);
                line_idx = byte_addr >> 7;
                line_byte_offset = byte_addr & 127;
                bit_pos = x % 8;
                fb_byte = (dut.dut_memory.mem[line_idx] >> (line_byte_offset * 8)) & 8'hFF;
                pixel = (fb_byte >> bit_pos) & 1'b1;
                $fwrite(fd, "%0d ", pixel);
            end
            $fwrite(fd, "\n");
        end
        $fclose(fd);
    endtask

endmodule
