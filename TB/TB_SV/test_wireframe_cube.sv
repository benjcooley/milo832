`timescale 1ns/1ps

import simt_pkg::*;

module test_wireframe_cube;
    // DUT signals
    logic clk;
    logic rst_n;
    
    parameter NUM_WARPS = 4;
    parameter WARP_SIZE = 32;
    
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
    integer max_cycles = 100000;  // Increased for full program execution
    integer pc;  // Program counter for loading instructions
    integer loop_start_pc; // To track loop labels dynamically
    
    // Framebuffer parameters
    // Framebuffer parameters
    parameter FB_WIDTH = 64;
    parameter FB_HEIGHT = 64;
    parameter FB_BASE = 32'h2000; // Moved to 8KB to fit in 16KB mock memory
    parameter FB_SIZE = (FB_WIDTH * FB_HEIGHT) / 8; // 512 bytes (1 bit per pixel)
    
    // Helper to write a 32-bit word to mock_memory (1024-bit lines)
    task automatic write_mem_word(input logic [31:0] addr, input logic [31:0] data);
        integer line_idx;
        integer word_offset;
        line_idx = addr >> 7;
        word_offset = (addr >> 2) & 31;
        dut.dut_memory.mem[line_idx][word_offset*32 +: 32] = data;
    endtask
    
    // Pre-calculated 2D vertex coordinates (projected from 3D cube)
    // Cube vertices: 8 corners of unit cube centered at origin
    // Projected: (x+0.5)*64, (y+0.5)*64
    parameter integer VERTICES_2D[8][2] = '{
        '{16, 16},  // v0: back-bottom-left  (-0.5, -0.5, -0.5)
        '{48, 16},  // v1: back-bottom-right (+0.5, -0.5, -0.5)
        '{48, 48},  // v2: back-top-right    (+0.5, +0.5, -0.5)
        '{16, 48},  // v3: back-top-left     (-0.5, +0.5, -0.5)
        '{20, 20},  // v4: front-bottom-left (-0.5, -0.5, +0.5)
        '{44, 20},  // v5: front-bottom-right(+0.5, -0.5, +0.5)
        '{44, 44},  // v6: front-top-right   (+0.5, +0.5, +0.5)
        '{20, 44}   // v7: front-top-left    (-0.5, +0.5, +0.5)
    };
    
    // Cube edges: 12 edges connecting vertices
    parameter integer EDGES[12][2] = '{
        '{0, 1}, '{1, 2}, '{2, 3}, '{3, 0},  // Back face
        '{4, 5}, '{5, 6}, '{6, 7}, '{7, 4},  // Front face
        '{0, 4}, '{1, 5}, '{2, 6}, '{3, 7}   // Connecting edges
    };
    
    // Helper: Encode 64-bit instruction
    // IMPORTANT: Parameter order matches ISA: rs3 comes BEFORE predicate
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
        $display("TEST: Wireframe Cube Rendering");
        $display("========================================");
        $display("Framebuffer: %0dx%0d @ 0x%h", FB_WIDTH, FB_HEIGHT, FB_BASE);
        
        // Reset
        rst_n = 0;
        cycle = 0;
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);
        
        // ====================================================================
        // PROGRAM: Wireframe Cube Renderer
        // ====================================================================
        // For simplicity, we'll draw dots at vertex positions first
        // Full line drawing can be added later
        
        // Program Address Map:
        // 0x0000: Main program
        // 0x1000: Vertex data (8 vertices x 2 coords x 4 bytes)
        // 0x10000: Framebuffer
        
        // Initialize vertex data in memory
        for (int v = 0; v < 8; v++) begin
            integer addr_x = 32'h1000 + (v * 8);
            integer addr_y = 32'h1000 + (v * 8) + 4;
            write_mem_word(addr_x, VERTICES_2D[v][0]);
            write_mem_word(addr_y, VERTICES_2D[v][1]);
            $display("INIT: v%0d @ 0x%h=x=%0d, 0x%h=y=%0d", 
                     v, addr_x, VERTICES_2D[v][0], addr_y, VERTICES_2D[v][1]);
        end
        
        // Clear framebuffer
        for (int i = 0; i < FB_SIZE; i += 4) begin
            write_mem_word(FB_BASE + i, 32'h0);
        end
        
        // ====================================================================
        // ASSEMBLY PROGRAM: Draw vertex dots
        // ====================================================================
        /*
         * R0 = vertex_base (0x1000)
         * R1 = vertex_count (8)
         * R2 = fb_base (0x10000)
         * TID = lane ID (for parallel pixel set)
         * 
         * loop:
         *   Load vertex (x, y) from memory
         *   Calculate framebuffer byte address and bit position
         *   Set pixel in framebuffer
         *   Next vertex
         */
        
        pc = 0;
        
        // Initialize R20 as a zero register (for pure immediate loads)
        dut.oc_inst.rf_bank_phys[0][0][0][5] = 32'h0; // R20 = 0
        
        // Initialize: R0 = 0x1000 (vertex_base)
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 0, 20, 0, 0, 4'h7, 20'h1000);  // R0 = R20 | 0x1000 = 0x1000
        
        // Initialize: R1 = 8 (vertex_count)
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 1, 20, 0, 0, 4'h7, 20'd8);     // R1 = R20 | 8 = 8
        
        // Initialize: R2 = 0x2000 (fb_base)
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 2, 20, 0, 0, 4'h7, 20'h2000); // R2 = R20 | 0x2000 = 0x2000
        
        // Loop: Draw each vertex
        loop_start_pc = pc;
        //   LDR R3, [R0, 0]    // Load x coordinate
        dut.prog_mem[0][pc++] = encode_inst(OP_LDR, 3, 0, 20, 0, 4'h7, 20'd0);
        
        //   LDR R4, [R0, 4]    // Load y coordinate
        dut.prog_mem[0][pc++] = encode_inst(OP_LDR, 4, 0, 20, 0, 4'h7, 20'd4);
        
        //   Calculate word address: y * 8 + (x / 32) * 4
        //   R5 = y * 8 (row start)
        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 5, 4, 20, 0, 4'h7, 20'd3); // y << 3
        
        //   R6 = x / 32 (word index in row)
        dut.prog_mem[0][pc++] = encode_inst(OP_SHR, 6, 3, 20, 0, 4'h7, 20'd5); // x >> 5
        
        //   R7 = R6 * 4 (word offset in row)
        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 7, 6, 20, 0, 4'h7, 20'd2); // R6 << 2
        
        //   R8 = R5 + R7 (total word offset)
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 8, 5, 7, 0, 4'h7, 20'd0);
        
        //   R9 = fb_base + R8 (word memory address)
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 9, 2, 8, 0, 4'h7, 20'd0);
        
        //   Calculate bit position in word: x % 32
        //   R10 = x & 31
        dut.prog_mem[0][pc++] = encode_inst(OP_AND, 10, 3, 20, 0, 4'h7, 20'd31);
        
        //   Create bit mask: 1 << R10
        //   R11 = 1
        dut.prog_mem[0][pc++] = encode_inst(OP_MOV, 11, 20, 0, 0, 4'h7, 20'd1);
        
        //   R12 = 1 << R10
        dut.prog_mem[0][pc++] = encode_inst(OP_SHL, 12, 11, 10, 0, 4'h7, 20'd0);
        
        //   Read current word from framebuffer
        //   LDR R13, [R9, 0]
        dut.prog_mem[0][pc++] = encode_inst(OP_LDR, 13, 9, 20, 0, 4'h7, 20'd0);
        
        //   Set bit: R14 = R13 | R12
        dut.prog_mem[0][pc++] = encode_inst(OP_OR, 14, 13, 12, 0, 4'h7, 20'd0);
        
        //   Write back to framebuffer
        //   STR R14, [R9, 0]
        dut.prog_mem[0][pc++] = encode_inst(OP_STR, 0, 9, 14, 0, 4'h7, 20'd0);
        
        //   Next vertex: R0 = R0 + 8
        dut.prog_mem[0][pc++] = encode_inst(OP_ADD, 0, 0, 20, 0, 4'h7, 20'd8);
        
        //   Decrement counter: R1 = R1 - 1
        dut.prog_mem[0][pc++] = encode_inst(OP_SUB, 1, 1, 20, 0, 4'h7, 20'd1);
        
        //   Branch if not zero (PC=3)
        //   Calculate offset dynamically: target_pc - current_pc
        dut.prog_mem[0][pc++] = encode_inst(OP_BNE, 0, 1, 20, 0, 4'h7, 20'($signed(loop_start_pc - pc)));
        
        //   Exit
        dut.prog_mem[0][pc++] = encode_inst(OP_EXIT, 0, 0, 0, 0, 4'h7, 20'd0);
        
        $display("Program loaded: %0d instructions", pc);
        
        // Set Warp 0 to READY state at PC=0
        dut.warp_state[0] = W_READY;
        dut.warp_pc[0] = 0;
        dut.warp_active_mask[0] = 32'h1; // Only lane 0 active (single-threaded for simplicity)
        
        // Run simulation
        $display("Starting execution...");
        while (cycle < max_cycles && dut.warp_state[0] != W_EXIT) begin
            @(posedge clk);
            cycle++;
            
            if (cycle % 1000 == 0) begin
                $display("[Cycle %0d] Warp 0 PC=%0d State=%0d", cycle, dut.warp_pc[0], dut.warp_state[0]);
            end
            
            // Dump registers after first loop iteration  
            if (cycle == 500) begin
                $display("\n=== Register Dump at Cycle %0d ===", cycle);
                $display("R0 (vertex_base) = 0x%h (expected 0x1000)", dut.oc_inst.rf_bank_phys[0][0][0][0]);
                $display("R1 (vertex_count)= 0x%h (expected 0x7 after first iteration)", dut.oc_inst.rf_bank_phys[1][0][0][0]);
                $display("R2 (fb_base)     = 0x%h (expected 0x10000)", dut.oc_inst.rf_bank_phys[2][0][0][0]);
                $display("R3 (loaded x)    = 0x%h (expected 16 for v0)", dut.oc_inst.rf_bank_phys[3][0][0][0]);
                $display("R4 (loaded y)    = 0x%h (expected 16 for v0)", dut.oc_inst.rf_bank_phys[0][0][0][1]);
                $display("========================\n");
            end
        end
        
        if (dut.warp_state[0] == W_EXIT) begin
            $display("Warp 0 exited at cycle %0d", cycle);
        end else begin
            $display("WARNING: Simulation timeout at cycle %0d", cycle);
        end
        
        // Extract framebuffer and save to file
        $display("Extracting framebuffer...");
        save_framebuffer_ppm("cube_output.ppm");
        
        $display("========================================");
        $display("TEST COMPLETE");
        $display("Output saved to: cube_output.ppm");
        $display("========================================");
        
        $finish;
    end
    
    //=========================================================================
    // Save framebuffer to PPM file (P1 format - ASCII bitmap)
    //=========================================================================
    task save_framebuffer_ppm(string filename);
        integer fd;
        logic [7:0] fb_byte;
        logic pixel;
        integer y, x;
        integer byte_addr, line_idx, line_byte_offset, bit_pos;
        
        fd = $fopen(filename, "w");
        if (fd == 0) begin
            $display("ERROR: Could not open file %s", filename);
            return;
        end
        
        // Write PPM header
        $fwrite(fd, "P1\n");
        $fwrite(fd, "%0d %0d\n", FB_WIDTH, FB_HEIGHT);
        
        // Write pixel data
        for (y = 0; y < FB_HEIGHT; y++) begin
            for (x = 0; x < FB_WIDTH; x++) begin
                byte_addr = FB_BASE + (y * (FB_WIDTH / 8)) + (x / 8);
                line_idx = byte_addr >> 7;
                line_byte_offset = byte_addr & 127;
                bit_pos = x % 8;
                
                fb_byte = (dut.dut_memory.mem[line_idx] >> (line_byte_offset * 8)) & 8'hFF;
                pixel = (fb_byte >> bit_pos) & 1'b1;
                
                $fwrite(fd, "%0d", pixel);
                if (x < FB_WIDTH - 1) $fwrite(fd, " ");
            end
            $fwrite(fd, "\n");
        end
        
        $fclose(fd);
        $display("Framebuffer saved to %s", filename);
    endtask
    
endmodule
