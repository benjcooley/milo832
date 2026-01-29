/*
 * miloc.c
 * Milo832 Shader Compiler - Main Driver
 * 
 * Usage:
 *   miloc [options] <input.glsl>
 * 
 * Options:
 *   -o <file>   Output file (default: stdout)
 *   -S          Output assembly (default)
 *   -c          Output binary
 *   -v          Vertex shader
 *   -f          Fragment shader (default)
 *   --dump-ast  Dump AST
 *   --help      Show help
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include "milo_glsl.h"
#include "milo_asm.h"

static void print_usage(const char *prog) {
    fprintf(stderr, "Milo832 Shader Compiler\n\n");
    fprintf(stderr, "Usage: %s [options] <input.glsl>\n\n", prog);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -o <file>   Output file (default: stdout)\n");
    fprintf(stderr, "  -S          Output assembly (default)\n");
    fprintf(stderr, "  -c          Output binary\n");
    fprintf(stderr, "  -v          Vertex shader\n");
    fprintf(stderr, "  -f          Fragment shader (default)\n");
    fprintf(stderr, "  --dump-ast  Dump AST\n");
    fprintf(stderr, "  --help      Show this help\n");
}

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Error: Cannot open '%s'\n", path);
        return NULL;
    }
    
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    char *buf = malloc(size + 1);
    if (!buf) {
        fprintf(stderr, "Error: Out of memory\n");
        fclose(f);
        return NULL;
    }
    
    size_t n = fread(buf, 1, size, f);
    buf[n] = '\0';
    fclose(f);
    
    return buf;
}

int main(int argc, char **argv) {
    const char *input_file = NULL;
    const char *output_file = NULL;
    bool output_binary = false;
    bool is_vertex = false;
    bool dump_ast = false;
    
    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "-o") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Error: -o requires an argument\n");
                return 1;
            }
            output_file = argv[i];
        } else if (strcmp(argv[i], "-S") == 0) {
            output_binary = false;
        } else if (strcmp(argv[i], "-c") == 0) {
            output_binary = true;
        } else if (strcmp(argv[i], "-v") == 0) {
            is_vertex = true;
        } else if (strcmp(argv[i], "-f") == 0) {
            is_vertex = false;
        } else if (strcmp(argv[i], "--dump-ast") == 0) {
            dump_ast = true;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "Error: Unknown option '%s'\n", argv[i]);
            return 1;
        } else {
            input_file = argv[i];
        }
    }
    
    if (!input_file) {
        fprintf(stderr, "Error: No input file specified\n");
        print_usage(argv[0]);
        return 1;
    }
    
    /* Read input */
    char *source = read_file(input_file);
    if (!source) {
        return 1;
    }
    
    /* Compile */
    milo_compiler_t compiler;
    milo_glsl_init(&compiler);
    
    bool ok = milo_glsl_compile(&compiler, source, is_vertex);
    
    if (!ok) {
        const char *errors[32];
        int n = milo_glsl_get_errors(&compiler, errors, 32);
        for (int i = 0; i < n; i++) {
            fprintf(stderr, "%s: %s\n", input_file, errors[i]);
        }
        free(source);
        return 1;
    }
    
    if (dump_ast) {
        milo_glsl_dump_ast(&compiler, stderr);
    }
    
    /* Get generated assembly */
    const char *asm_code = milo_glsl_get_asm(&compiler);
    
    /* Output */
    FILE *out = stdout;
    if (output_file) {
        out = fopen(output_file, output_binary ? "wb" : "w");
        if (!out) {
            fprintf(stderr, "Error: Cannot create '%s'\n", output_file);
            free(source);
            return 1;
        }
    }
    
    if (output_binary) {
        /* Assemble to binary */
        milo_asm_t as;
        milo_asm_init(&as);
        
        if (!milo_asm_source(&as, asm_code)) {
            fprintf(stderr, "Assembly error: %s\n", milo_asm_get_error(&as));
            if (output_file) fclose(out);
            free(source);
            return 1;
        }
        
        uint32_t size;
        const uint64_t *code = milo_asm_get_code(&as, &size);
        
        /* Write binary header */
        uint32_t magic = 0x4D494C4F;  /* "MILO" */
        uint32_t version = 1;
        fwrite(&magic, 4, 1, out);
        fwrite(&version, 4, 1, out);
        fwrite(&size, 4, 1, out);
        
        /* Write code */
        fwrite(code, 8, size, out);
        
        fprintf(stderr, "Generated %u instructions (%lu bytes)\n", 
                size, (unsigned long)(size * 8 + 12));
    } else {
        /* Output assembly */
        fputs(asm_code, out);
    }
    
    if (output_file) {
        fclose(out);
    }
    
    milo_glsl_free(&compiler);
    free(source);
    
    return 0;
}
