/*
 * shader_verify.c
 * Shader verification tool - generates test cases and compares VM vs VHDL output
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include "milo_glsl.h"
#include "milo_asm.h"
#include "milo_vm.h"

/*---------------------------------------------------------------------------
 * Test Case Structure
 *---------------------------------------------------------------------------*/

typedef struct {
    char name[64];
    float inputs[32];      /* Fragment shader inputs (u, v, nx, ny, nz, r, g, b, a...) */
    float expected[4];     /* Expected RGBA output */
    float tolerance;       /* Allowed error per component */
} test_case_t;

/*---------------------------------------------------------------------------
 * Generate Hex File for VHDL
 *---------------------------------------------------------------------------*/

static bool write_hex_file(const char *filename, const uint64_t *code, uint32_t size) {
    FILE *f = fopen(filename, "w");
    if (!f) return false;
    
    for (uint32_t i = 0; i < size; i++) {
        fprintf(f, "%016llX\n", (unsigned long long)code[i]);
    }
    
    fclose(f);
    return true;
}

/*---------------------------------------------------------------------------
 * Generate Input Memory File for VHDL
 * Format: One 32-bit value per line (hex)
 *---------------------------------------------------------------------------*/

static bool write_input_mem(const char *filename, const float *inputs, int count) {
    FILE *f = fopen(filename, "w");
    if (!f) return false;
    
    for (int i = 0; i < count; i++) {
        union { float f; uint32_t u; } conv;
        conv.f = inputs[i];
        fprintf(f, "%08X\n", conv.u);
    }
    
    fclose(f);
    return true;
}

/*---------------------------------------------------------------------------
 * Read Output Memory File from VHDL
 *---------------------------------------------------------------------------*/

static bool read_output_mem(const char *filename, float *outputs, int count) {
    FILE *f = fopen(filename, "r");
    if (!f) return false;
    
    for (int i = 0; i < count; i++) {
        uint32_t u;
        if (fscanf(f, "%X", &u) != 1) {
            fclose(f);
            return false;
        }
        union { float f; uint32_t u; } conv;
        conv.u = u;
        outputs[i] = conv.f;
    }
    
    fclose(f);
    return true;
}

/*---------------------------------------------------------------------------
 * Run VM Test
 *---------------------------------------------------------------------------*/

static bool run_vm_test(milo_vm_t *vm, const float *inputs, float *outputs) {
    milo_fragment_in_t frag_in = {
        .x = 0.0f, .y = 0.0f, .z = 0.5f,
        .u = inputs[0], .v = inputs[1],
        .nx = inputs[2], .ny = inputs[3], .nz = inputs[4],
        .r = inputs[5], .g = inputs[6], .b = inputs[7], .a = inputs[8]
    };
    
    milo_fragment_out_t frag_out;
    if (!milo_vm_exec_fragment(vm, &frag_in, &frag_out)) {
        return false;
    }
    
    outputs[0] = frag_out.r;
    outputs[1] = frag_out.g;
    outputs[2] = frag_out.b;
    outputs[3] = frag_out.a;
    
    return true;
}

/*---------------------------------------------------------------------------
 * Compare Results
 *---------------------------------------------------------------------------*/

static bool compare_results(const float *vm_out, const float *vhdl_out, 
                           float tolerance, char *diff_msg) {
    bool match = true;
    diff_msg[0] = '\0';
    
    for (int i = 0; i < 4; i++) {
        float diff = fabsf(vm_out[i] - vhdl_out[i]);
        if (diff > tolerance) {
            match = false;
            char comp[64];
            snprintf(comp, sizeof(comp), "%c: VM=%.6f VHDL=%.6f diff=%.6f; ", 
                    "RGBA"[i], vm_out[i], vhdl_out[i], diff);
            strcat(diff_msg, comp);
        }
    }
    
    return match;
}

/*---------------------------------------------------------------------------
 * Generate All Test Files
 *---------------------------------------------------------------------------*/

typedef struct {
    const char *name;
    const char *source;
} shader_def_t;

static const shader_def_t test_shaders[] = {
    { "gradient", 
      "in vec2 v_texcoord;\n"
      "out vec4 fragColor;\n"
      "\n"
      "void main() {\n"
      "    fragColor = vec4(v_texcoord.x, v_texcoord.y, 0.5, 1.0);\n"
      "}\n"
    },
    { "math",
      "in vec2 v_texcoord;\n"
      "out vec4 fragColor;\n"
      "\n"
      "void main() {\n"
      "    float a = v_texcoord.x * 2.0;\n"
      "    float b = v_texcoord.y + 0.5;\n"
      "    float c = a * b;\n"
      "    float d = sqrt(c + 0.1);\n"
      "    fragColor = vec4(a, b, c, d);\n"
      "}\n"
    },
    { "sfu",
      "in vec2 v_texcoord;\n"
      "out vec4 fragColor;\n"
      "\n"
      "void main() {\n"
      "    float s = sin(v_texcoord.x * 6.283);\n"
      "    float c = cos(v_texcoord.y * 6.283);\n"
      "    float e = sqrt(v_texcoord.x * v_texcoord.x + v_texcoord.y * v_texcoord.y);\n"
      "    fragColor = vec4(s * 0.5 + 0.5, c * 0.5 + 0.5, e, 1.0);\n"
      "}\n"
    },
};

#define NUM_TEST_SHADERS (sizeof(test_shaders) / sizeof(test_shaders[0]))

/* Test inputs: u, v, nx, ny, nz, r, g, b, a */
static float test_inputs[][9] = {
    { 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f },
    { 0.5f, 0.5f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f },
    { 1.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f },
    { 0.25f, 0.75f, 0.0f, 0.0f, 1.0f, 1.0f, 0.0f, 0.0f, 1.0f },
    { 0.75f, 0.25f, 0.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f, 1.0f },
    { 0.1f, 0.9f, 0.707f, 0.707f, 0.0f, 0.5f, 0.5f, 0.5f, 1.0f },
};

#define NUM_TEST_INPUTS (sizeof(test_inputs) / sizeof(test_inputs[0]))

static bool generate_test_files(const char *output_dir) {
    milo_compiler_t compiler;
    milo_vm_t vm;
    char path[256];
    
    printf("Generating test files in %s/\n", output_dir);
    
    for (size_t s = 0; s < NUM_TEST_SHADERS; s++) {
        const char *name = test_shaders[s].name;
        const char *source = test_shaders[s].source;
        
        printf("\nShader: %s\n", name);
        
        /* Compile shader */
        milo_glsl_init(&compiler);
        if (!milo_glsl_compile(&compiler, source, false)) {
            fprintf(stderr, "  Compile error\n");
            continue;
        }
        
        /* Get assembly and assemble to binary */
        const char *asm_code = milo_glsl_get_asm(&compiler);
        
        milo_vm_init(&vm);
        if (!milo_vm_load_asm(&vm, asm_code)) {
            fprintf(stderr, "  Assembly error: %s\n", milo_vm_get_error(&vm));
            milo_glsl_free(&compiler);
            continue;
        }
        
        /* Write program hex file */
        snprintf(path, sizeof(path), "%s/%s_prog.hex", output_dir, name);
        if (!write_hex_file(path, vm.code, vm.code_size)) {
            fprintf(stderr, "  Failed to write %s\n", path);
        } else {
            printf("  Wrote %s (%u instructions)\n", path, vm.code_size);
        }
        
        /* Write assembly for reference */
        snprintf(path, sizeof(path), "%s/%s.asm", output_dir, name);
        FILE *f = fopen(path, "w");
        if (f) {
            fprintf(f, "%s", asm_code);
            fclose(f);
            printf("  Wrote %s\n", path);
        }
        
        /* Run VM for each test input and write expected outputs */
        for (size_t i = 0; i < NUM_TEST_INPUTS; i++) {
            /* Write input file */
            snprintf(path, sizeof(path), "%s/%s_input_%zu.hex", output_dir, name, i);
            write_input_mem(path, test_inputs[i], 9);
            
            /* Run VM */
            float vm_out[4];
            if (run_vm_test(&vm, test_inputs[i], vm_out)) {
                /* Write expected output */
                snprintf(path, sizeof(path), "%s/%s_expected_%zu.hex", output_dir, name, i);
                write_input_mem(path, vm_out, 4);
                
                printf("  Test %zu: in=(%.2f,%.2f) -> out=(%.4f,%.4f,%.4f,%.4f)\n",
                       i, test_inputs[i][0], test_inputs[i][1],
                       vm_out[0], vm_out[1], vm_out[2], vm_out[3]);
            } else {
                fprintf(stderr, "  Test %zu: VM error: %s\n", i, milo_vm_get_error(&vm));
            }
        }
        
        milo_glsl_free(&compiler);
    }
    
    return true;
}

/*---------------------------------------------------------------------------
 * Verify VHDL Output
 *---------------------------------------------------------------------------*/

static int verify_vhdl_output(const char *test_dir, float tolerance) {
    int total_tests = 0;
    int passed_tests = 0;
    int failed_tests = 0;
    char path[256];
    
    printf("\nVerifying VHDL output against VM...\n");
    printf("Tolerance: %.6f\n\n", tolerance);
    
    for (size_t s = 0; s < NUM_TEST_SHADERS; s++) {
        const char *name = test_shaders[s].name;
        
        printf("Shader: %s\n", name);
        
        for (size_t i = 0; i < NUM_TEST_INPUTS; i++) {
            /* Read expected output from VM */
            float expected[4];
            snprintf(path, sizeof(path), "%s/%s_expected_%zu.hex", test_dir, name, i);
            if (!read_output_mem(path, expected, 4)) {
                printf("  Test %zu: SKIP (no expected file)\n", i);
                continue;
            }
            
            /* Read actual output from VHDL */
            float actual[4];
            snprintf(path, sizeof(path), "%s/%s_vhdl_%zu.hex", test_dir, name, i);
            if (!read_output_mem(path, actual, 4)) {
                printf("  Test %zu: SKIP (no VHDL output file)\n", i);
                continue;
            }
            
            total_tests++;
            
            /* Compare */
            char diff_msg[256];
            if (compare_results(expected, actual, tolerance, diff_msg)) {
                printf("  Test %zu: PASS\n", i);
                passed_tests++;
            } else {
                printf("  Test %zu: FAIL - %s\n", i, diff_msg);
                failed_tests++;
            }
        }
    }
    
    printf("\n========================================\n");
    printf("Results: %d/%d passed", passed_tests, total_tests);
    if (failed_tests > 0) {
        printf(" (%d FAILED)", failed_tests);
    }
    printf("\n========================================\n");
    
    return failed_tests;
}

/*---------------------------------------------------------------------------
 * Main
 *---------------------------------------------------------------------------*/

static void usage(const char *prog) {
    fprintf(stderr, "Usage: %s <command> [args]\n", prog);
    fprintf(stderr, "Commands:\n");
    fprintf(stderr, "  generate <output_dir>  - Generate test files for VHDL simulation\n");
    fprintf(stderr, "  verify <test_dir> [tolerance] - Verify VHDL output against VM\n");
    fprintf(stderr, "  run <shader.glsl> <u> <v> - Run single shader test\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(argv[0]);
        return 1;
    }
    
    const char *cmd = argv[1];
    
    if (strcmp(cmd, "generate") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: generate requires output directory\n");
            return 1;
        }
        generate_test_files(argv[2]);
        return 0;
    }
    else if (strcmp(cmd, "verify") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: verify requires test directory\n");
            return 1;
        }
        float tolerance = (argc >= 4) ? atof(argv[3]) : 0.001f;
        return verify_vhdl_output(argv[2], tolerance);
    }
    else if (strcmp(cmd, "run") == 0) {
        if (argc < 5) {
            fprintf(stderr, "Usage: %s run <shader.glsl> <u> <v>\n", argv[0]);
            return 1;
        }
        
        /* Read shader file */
        FILE *f = fopen(argv[2], "r");
        if (!f) {
            fprintf(stderr, "Cannot open %s\n", argv[2]);
            return 1;
        }
        fseek(f, 0, SEEK_END);
        long size = ftell(f);
        fseek(f, 0, SEEK_SET);
        char *source = malloc(size + 1);
        fread(source, 1, size, f);
        source[size] = '\0';
        fclose(f);
        
        /* Compile and run */
        milo_compiler_t compiler;
        milo_vm_t vm;
        
        milo_glsl_init(&compiler);
        if (!milo_glsl_compile(&compiler, source, false)) {
            fprintf(stderr, "Compile error\n");
            free(source);
            return 1;
        }
        
        const char *asm_code = milo_glsl_get_asm(&compiler);
        printf("Assembly:\n%s\n", asm_code);
        
        milo_vm_init(&vm);
        if (!milo_vm_load_asm(&vm, asm_code)) {
            fprintf(stderr, "Assembly error: %s\n", milo_vm_get_error(&vm));
            free(source);
            milo_glsl_free(&compiler);
            return 1;
        }
        
        float inputs[9] = { atof(argv[3]), atof(argv[4]), 0, 0, 1, 1, 1, 1, 1 };
        float outputs[4];
        
        if (run_vm_test(&vm, inputs, outputs)) {
            printf("Output: R=%.6f G=%.6f B=%.6f A=%.6f\n",
                   outputs[0], outputs[1], outputs[2], outputs[3]);
        } else {
            fprintf(stderr, "VM error: %s\n", milo_vm_get_error(&vm));
        }
        
        free(source);
        milo_glsl_free(&compiler);
        return 0;
    }
    else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        usage(argv[0]);
        return 1;
    }
}
