// ============================================================================
// Testbench: test_shader_verify
// Description: 
//   Verifies that compiled shaders produce identical results between
//   the C emulator (golden model) and the SystemVerilog SM.
//
//   This testbench:
//   1. Reads a compiled shader binary from a hex file (with wrapper prologue)
//   2. Reads input values from a hex file (loads via memory)
//   3. Runs the shader in the SM
//   4. Writes output values to a hex file for comparison
//
// The shader is wrapped with prologue/epilogue to load inputs and store outputs.
// ============================================================================
`timescale 1ns/1ps

module test_shader_verify;
    import simt_pkg::*;
    import sfu_pkg::*;

    // Parameters
    localparam NUM_WARPS = 24;
    localparam WARP_SIZE = 32;
    
    // Test configuration - set via +define
    `ifndef SHADER_NAME
        `define SHADER_NAME "gradient"
    `endif
    `ifndef TEST_INDEX
        `define TEST_INDEX 0
    `endif
    `ifndef TEST_DIR
        `define TEST_DIR "verify_tests"
    `endif

    // Signals
    logic clk;
    logic rst_n;

    // Instantiate DUT
    streaming_multiprocessor #(
        .NUM_WARPS(NUM_WARPS),
        .WARP_SIZE(WARP_SIZE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .done()
    );

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Test data
    logic [63:0] shader_code [0:255];
    logic [31:0] input_mem [0:31];
    logic [31:0] output_mem [0:31];
    int shader_size;

    // File paths
    string shader_name;
    int test_idx;
    string test_dir;
    string prog_file;
    string input_file;
    string output_file;

    // Error counter
    int errors = 0;

    // Helper to encode instruction
    function automatic logic [63:0] encode_inst(
        logic [7:0] op, logic [7:0] rd=0, logic [7:0] rs1=0, logic [7:0] rs2=0, 
        logic [7:0] rs3=0, logic [3:0] pg=4'h7, logic [31:0] imm=0
    );
        return {op, rd, rs1, rs2, pg, rs3, imm[19:0]};
    endfunction

    // Load shader from hex file
    task load_shader();
        int fd;
        logic [63:0] inst;
        
        prog_file = {test_dir, "/", shader_name, "_prog.hex"};
        $display("Loading shader from %s", prog_file);
        
        fd = $fopen(prog_file, "r");
        if (fd == 0) begin
            $error("Cannot open shader file: %s", prog_file);
            $finish;
        end
        
        shader_size = 0;
        while (!$feof(fd)) begin
            if ($fscanf(fd, "%h\n", inst) == 1) begin
                shader_code[shader_size] = inst;
                shader_size++;
                if (shader_size >= 256) break;
            end
        end
        
        $fclose(fd);
        $display("Loaded %0d shader instructions", shader_size);
    endtask

    // Load input values from hex file into memory
    task load_inputs();
        int fd;
        logic [31:0] val;
        int count;
        
        input_file = {test_dir, "/", shader_name, "_input_", $sformatf("%0d", test_idx), ".hex"};
        $display("Loading inputs from %s", input_file);
        
        fd = $fopen(input_file, "r");
        if (fd == 0) begin
            $error("Cannot open input file: %s", input_file);
            $finish;
        end
        
        count = 0;
        while (!$feof(fd) && count < 32) begin
            if ($fscanf(fd, "%h\n", val) == 1) begin
                input_mem[count] = val;
                count++;
            end
        end
        
        $fclose(fd);
        $display("Loaded %0d input values", count);
        
        // Store input values in mock memory at address 0
        // Input layout: u, v, nx, ny, nz, r, g, b, a (9 values)
        // Memory format: each value at consecutive 4-byte addresses
        for (int i = 0; i < count; i++) begin
            dut.dut_memory.mem[0][i*32 +: 32] = input_mem[i];
            $display("  Input[%0d] = %08h", i, input_mem[i]);
        end
    endtask
    
    // Load constant table from hex file into memory
    task load_constants();
        int fd;
        logic [31:0] addr;
        logic [31:0] val;
        int count;
        string const_file;
        
        const_file = {test_dir, "/", shader_name, "_const.hex"};
        $display("Loading constants from %s", const_file);
        
        fd = $fopen(const_file, "r");
        if (fd == 0) begin
            $display("  No constant file (this may be okay)");
            return;
        end
        
        count = 0;
        while (!$feof(fd)) begin
            if ($fscanf(fd, "%h %h\n", addr, val) == 2) begin
                // Store in mock memory at the specified byte address
                // Mock memory is word-addressed: mem[0][word*32 +: 32]
                int word_idx = addr / 4;
                dut.dut_memory.mem[0][word_idx*32 +: 32] = val;
                $display("  Const[0x%04h] = %08h", addr, val);
                count++;
            end
        end
        
        $fclose(fd);
        $display("Loaded %0d constants", count);
    endtask

    // Build the wrapped program:
    // - Prologue: Load inputs from memory into registers
    // - Shader code
    // - Epilogue: Store outputs to memory
    task build_program();
        int pc;
        
        pc = 0;
        
        // Prologue: Load input values from memory into expected registers
        // v_texcoord (r2, r3) <- mem[0], mem[4]
        dut.prog_mem[0][pc] = encode_inst(OP_LDR, 2, 0, 0, 0, 4'h7, 0);  pc++;  // r2 = mem[0] = u
        dut.prog_mem[0][pc] = encode_inst(OP_LDR, 3, 0, 0, 0, 4'h7, 4);  pc++;  // r3 = mem[4] = v
        // v_normal (r4, r5, r6) <- mem[8], mem[12], mem[16]
        // Note: These may not be used by gradient shader, but include for completeness
        // (Compiler allocates them in the declared order)
        
        // Copy shader code (it should end with EXIT)
        // The shader expects inputs already in r2-r3 and writes output to r4-r7
        for (int i = 0; i < shader_size; i++) begin
            // Check if it's EXIT - we'll handle output first
            if (shader_code[i][63:56] == OP_EXIT) begin
                // Before EXIT, store outputs (r4-r7) to memory at address 100-112
                dut.prog_mem[0][pc] = encode_inst(OP_STR, 0, 0, 4, 0, 4'h7, 100); pc++;
                dut.prog_mem[0][pc] = encode_inst(OP_STR, 0, 0, 5, 0, 4'h7, 104); pc++;
                dut.prog_mem[0][pc] = encode_inst(OP_STR, 0, 0, 6, 0, 4'h7, 108); pc++;
                dut.prog_mem[0][pc] = encode_inst(OP_STR, 0, 0, 7, 0, 4'h7, 112); pc++;
                // Now EXIT
                dut.prog_mem[0][pc] = encode_inst(OP_EXIT); pc++;
            end else begin
                dut.prog_mem[0][pc] = shader_code[i]; pc++;
            end
        end
        
        // Fill rest with EXIT as safety
        for (int i = pc; i < 256; i++) begin
            dut.prog_mem[0][i] = encode_inst(OP_EXIT);
        end
        
        $display("Built program with %0d instructions", pc);
        
        // Debug: print first few instructions
        for (int i = 0; i < pc && i < 20; i++) begin
            $display("  prog[%2d] = %016h", i, dut.prog_mem[0][i]);
        end
    endtask

    // Save output values to hex file
    task save_outputs();
        int fd;
        
        output_file = {test_dir, "/", shader_name, "_vhdl_", $sformatf("%0d", test_idx), ".hex"};
        $display("Saving outputs to %s", output_file);
        
        // Read output from memory addresses 100-112 (stored by epilogue)
        // Memory format: dut.dut_memory.mem[0][word_idx*32 +: 32]
        // Address 100 = word 25, 104 = word 26, etc.
        output_mem[0] = dut.dut_memory.mem[0][25*32 +: 32]; // Address 100
        output_mem[1] = dut.dut_memory.mem[0][26*32 +: 32]; // Address 104
        output_mem[2] = dut.dut_memory.mem[0][27*32 +: 32]; // Address 108
        output_mem[3] = dut.dut_memory.mem[0][28*32 +: 32]; // Address 112
        
        fd = $fopen(output_file, "w");
        if (fd == 0) begin
            $error("Cannot open output file: %s", output_file);
            return;
        end
        
        for (int i = 0; i < 4; i++) begin
            $fdisplay(fd, "%08H", output_mem[i]);
        end
        
        $fclose(fd);
        
        // Display output values
        $display("Output values (from memory):");
        $display("  R = %08h", output_mem[0]);
        $display("  G = %08h", output_mem[1]);
        $display("  B = %08h", output_mem[2]);
        $display("  A = %08h", output_mem[3]);
    endtask

    // Main test
    initial begin
        longint start_time;
        
        // Get test parameters
        shader_name = `SHADER_NAME;
        test_idx = `TEST_INDEX;
        test_dir = `TEST_DIR;
        
        $display("============================================");
        $display("Shader Verification Test");
        $display("  Shader: %s", shader_name);
        $display("  Test Index: %0d", test_idx);
        $display("  Test Directory: %s", test_dir);
        $display("============================================\n");
        
        // Load shader and inputs BEFORE reset
        load_shader();
        load_inputs();
        load_constants();
        
        // Reset
        rst_n = 0;
        #20;
        
        // Build program and set state during reset
        build_program();
        
        // Release reset
        rst_n = 1;
        #10;
        
        // Set warp state AFTER reset release, wait a cycle for SM to initialize
        @(posedge clk);
        for (int w = 0; w < NUM_WARPS; w++) begin
            dut.warp_state[w] = (w == 0) ? W_READY : W_IDLE;
            dut.warp_pc[w] = 0;
            dut.warp_active_mask[w] = (w == 0) ? {WARP_SIZE{1'b1}} : '0;
        end
        @(posedge clk);
        
        // Run simulation
        start_time = $time;
        $display("\nRunning shader...");
        
        wait(dut.warp_state[0] == W_EXIT || $time > start_time + 500000);
        
        if (dut.warp_state[0] != W_EXIT) begin
            $error("Shader did not complete - timeout or infinite loop");
            errors++;
        end else begin
            $display("Shader completed in %0t ns", $time - start_time);
        end
        
        // Wait for memory writebacks
        #10000;
        
        // Save outputs
        save_outputs();
        
        // Done
        $display("\n============================================");
        if (errors == 0) begin
            $display("Test completed - check output file for comparison");
        end else begin
            $display("Test completed with %0d errors", errors);
        end
        $display("============================================\n");
        
        $finish;
    end

    // Timeout
    initial begin
        #1000000;
        $display("TIMEOUT: Test exceeded maximum time");
        $finish;
    end

endmodule
