/*
 * shader_test.c
 * Test program for Milo832 shader compiler and VM
 * 
 * Compiles a GLSL shader, executes it on the VM, and outputs an image.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "milo_glsl.h"
#include "milo_asm.h"
#include "milo_vm.h"

/*---------------------------------------------------------------------------
 * Test Shaders
 *---------------------------------------------------------------------------*/

/* Simple gradient shader */
static const char *gradient_shader = 
    "// Gradient test shader\n"
    "in vec2 v_texcoord;\n"
    "out vec4 fragColor;\n"
    "\n"
    "void main() {\n"
    "    fragColor = vec4(v_texcoord.x, v_texcoord.y, 0.5, 1.0);\n"
    "}\n";

/* Texture sampling shader */
static const char *texture_shader = 
    "// Texture sampling shader\n"
    "in vec2 v_texcoord;\n"
    "uniform sampler2D u_texture;\n"
    "out vec4 fragColor;\n"
    "\n"
    "void main() {\n"
    "    fragColor = texture(u_texture, v_texcoord);\n"
    "}\n";

/* Animated wave shader */
static const char *wave_shader = 
    "// Animated wave shader\n"
    "in vec2 v_texcoord;\n"
    "uniform float u_time;\n"
    "out vec4 fragColor;\n"
    "\n"
    "void main() {\n"
    "    float x = v_texcoord.x;\n"
    "    float y = v_texcoord.y;\n"
    "    float wave = sin(x * 10.0 + u_time) * 0.5 + 0.5;\n"
    "    float dist = abs(y - wave * 0.3 - 0.35);\n"
    "    float intensity = 1.0 - min(dist * 10.0, 1.0);\n"
    "    fragColor = vec4(intensity * 0.2, intensity * 0.5, intensity, 1.0);\n"
    "}\n";

/* Checkerboard shader */
static const char *checker_shader = 
    "// Checkerboard shader\n"
    "in vec2 v_texcoord;\n"
    "out vec4 fragColor;\n"
    "\n"
    "void main() {\n"
    "    float u = v_texcoord.x * 8.0;\n"
    "    float v = v_texcoord.y * 8.0;\n"
    "    float check = sin(u * 3.14159) * sin(v * 3.14159);\n"
    "    float c = check > 0.0 ? 1.0 : 0.3;\n"
    "    fragColor = vec4(c, c, c, 1.0);\n"
    "}\n";

/* Circle shader */
static const char *circle_shader =
    "// Circle shader\n"
    "in vec2 v_texcoord;\n"
    "out vec4 fragColor;\n"
    "\n"
    "void main() {\n"
    "    float x = v_texcoord.x - 0.5;\n"
    "    float y = v_texcoord.y - 0.5;\n"
    "    float dist = sqrt(x * x + y * y);\n"
    "    float c = dist < 0.4 ? 1.0 : 0.0;\n"
    "    fragColor = vec4(1.0 - dist * 2.0, 0.3, dist * 2.0, 1.0);\n"
    "}\n";

/*---------------------------------------------------------------------------
 * Test Helpers
 *---------------------------------------------------------------------------*/

static bool compile_and_load(milo_compiler_t *compiler, milo_vm_t *vm, 
                             const char *source, const char *name) {
    printf("Compiling %s...\n", name);
    
    milo_glsl_init(compiler);
    if (!milo_glsl_compile(compiler, source, false)) {
        const char *errors[8];
        int n = milo_glsl_get_errors(compiler, errors, 8);
        for (int i = 0; i < n; i++) {
            fprintf(stderr, "  Error: %s\n", errors[i]);
        }
        return false;
    }
    
    const char *asm_code = milo_glsl_get_asm(compiler);
    printf("Generated assembly:\n%s\n", asm_code);
    
    if (!milo_vm_load_asm(vm, asm_code)) {
        fprintf(stderr, "  VM load error: %s\n", milo_vm_get_error(vm));
        return false;
    }
    
    printf("Loaded %u instructions\n\n", vm->code_size);
    return true;
}

static void run_test(const char *name, const char *source, 
                     milo_texture_t *tex, float time_value) {
    milo_compiler_t compiler;
    milo_vm_t vm;
    
    milo_vm_init(&vm);
    
    if (!compile_and_load(&compiler, &vm, source, name)) {
        return;
    }
    
    /* Set up framebuffer */
    int width = 256;
    int height = 256;
    milo_framebuffer_t *fb = milo_fb_create(width, height);
    if (!fb) {
        fprintf(stderr, "Failed to create framebuffer\n");
        return;
    }
    
    milo_fb_clear(fb, 0xFF000000, 1.0f);  /* Black background */
    
    /* Bind texture and set uniforms */
    if (tex) {
        milo_vm_bind_texture(&vm, 0, tex);
        /* Set texture unit in uniform slot 11 (matching compiler output) */
        vm.regs[11].i = 0;  /* Texture unit 0 */
    }
    
    /* Set time uniform (register 2 based on simple uniform layout) */
    vm.uniforms[0].f = time_value;
    
    /* Render fullscreen quad */
    printf("Rendering %s...\n", name);
    milo_render_fullscreen(&vm, fb);
    
    /* Save output */
    char filename[64];
    snprintf(filename, sizeof(filename), "test_%s.ppm", name);
    if (milo_fb_save_ppm(fb, filename)) {
        printf("Saved %s\n\n", filename);
    } else {
        fprintf(stderr, "Failed to save %s\n\n", filename);
    }
    
    milo_fb_free(fb);
    milo_glsl_free(&compiler);
}

/*---------------------------------------------------------------------------
 * Main
 *---------------------------------------------------------------------------*/

int main(int argc, char **argv) {
    printf("===========================================\n");
    printf("Milo832 Shader Compiler/VM Test Suite\n");
    printf("===========================================\n\n");
    
    /* Create test textures */
    milo_texture_t *checker_tex = milo_texture_create_checker(64, 64, 
        0xFFFFFFFF, 0xFF404040, 8);
    
    /* Run tests */
    run_test("gradient", gradient_shader, NULL, 0.0f);
    run_test("checker", checker_shader, NULL, 0.0f);
    run_test("circle", circle_shader, NULL, 0.0f);
    run_test("wave", wave_shader, NULL, 1.5f);
    run_test("texture", texture_shader, checker_tex, 0.0f);
    
    /* Cleanup */
    milo_texture_free(checker_tex);
    
    printf("===========================================\n");
    printf("Tests complete. Check test_*.ppm files.\n");
    printf("===========================================\n");
    
    /* Convert PPMs to PNGs if possible */
    printf("\nConverting to PNG (if ImageMagick available)...\n");
    system("which convert > /dev/null 2>&1 && for f in test_*.ppm; do convert $f ${f%.ppm}.png && rm $f; done");
    
    return 0;
}
