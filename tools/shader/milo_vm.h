/*
 * milo_vm.h
 * Milo832 Shader Virtual Machine - Header
 * 
 * Executes compiled shader binaries and renders to a bitmap.
 */

#ifndef MILO_VM_H
#define MILO_VM_H

#include <stdint.h>
#include <stdbool.h>
#include "milo_asm.h"

/*---------------------------------------------------------------------------
 * VM Configuration
 *---------------------------------------------------------------------------*/

#define VM_MAX_REGS         64
#define VM_MAX_CODE         4096
#define VM_MAX_UNIFORMS     32
#define VM_MAX_TEXTURES     8
#define VM_STACK_SIZE       256
#define VM_MEM_SIZE         8192    /* Memory for constant tables etc */

/*---------------------------------------------------------------------------
 * Texture
 *---------------------------------------------------------------------------*/

typedef struct {
    uint32_t *pixels;       /* RGBA8888 */
    int       width;
    int       height;
    bool      wrap_s;       /* Wrap in S direction */
    bool      wrap_t;       /* Wrap in T direction */
    bool      filter;       /* Bilinear filtering */
} milo_texture_t;

/*---------------------------------------------------------------------------
 * Shader Types
 *---------------------------------------------------------------------------*/

typedef enum {
    SHADER_VERTEX,
    SHADER_FRAGMENT
} milo_shader_type_t;

/*---------------------------------------------------------------------------
 * Fragment Input/Output
 *---------------------------------------------------------------------------*/

typedef struct {
    float x, y;             /* Fragment position */
    float z;                /* Depth */
    float u, v;             /* Texture coordinates */
    float r, g, b, a;       /* Interpolated color */
    float nx, ny, nz;       /* Interpolated normal */
    /* Additional varyings can be added */
} milo_fragment_in_t;

typedef struct {
    float r, g, b, a;       /* Output color */
    float depth;            /* Output depth (optional) */
    bool  discard;          /* Fragment was discarded */
} milo_fragment_out_t;

/*---------------------------------------------------------------------------
 * Vertex Input/Output
 *---------------------------------------------------------------------------*/

typedef struct {
    float x, y, z;          /* Position */
    float u, v;             /* Texture coordinates */
    float r, g, b, a;       /* Color */
    float nx, ny, nz;       /* Normal */
} milo_vertex_in_t;

typedef struct {
    float x, y, z, w;       /* Clip-space position */
    float u, v;             /* Texture coordinates (to interpolate) */
    float r, g, b, a;       /* Color (to interpolate) */
    float nx, ny, nz;       /* Normal (to interpolate) */
} milo_vertex_out_t;

/*---------------------------------------------------------------------------
 * Uniform Data
 *---------------------------------------------------------------------------*/

typedef union {
    float    f;
    int32_t  i;
    uint32_t u;
    float    v2[2];
    float    v3[3];
    float    v4[4];
    float    m3[9];
    float    m4[16];
} milo_uniform_t;

/*---------------------------------------------------------------------------
 * VM State
 *---------------------------------------------------------------------------*/

typedef struct {
    /* Registers (as float/int union) */
    union {
        float    f;
        int32_t  i;
        uint32_t u;
    } regs[VM_MAX_REGS];
    
    /* Program */
    uint64_t    code[VM_MAX_CODE];
    uint32_t    code_size;
    uint32_t    pc;
    
    /* Divergence stack (for SIMT simulation) */
    uint32_t    div_stack[VM_STACK_SIZE];
    int         div_sp;
    
    /* Return stack */
    uint32_t    ret_stack[VM_STACK_SIZE];
    int         ret_sp;
    
    /* Uniforms */
    milo_uniform_t uniforms[VM_MAX_UNIFORMS];
    int            uniform_count;
    
    /* Textures */
    milo_texture_t *textures[VM_MAX_TEXTURES];
    
    /* Memory (for constant tables, etc) */
    uint32_t    mem[VM_MEM_SIZE / 4];
    
    /* Execution state */
    bool        running;
    bool        discarded;
    int         cycle_count;
    int         max_cycles;
    
    /* Error state */
    char        error[256];
} milo_vm_t;

/*---------------------------------------------------------------------------
 * VM API
 *---------------------------------------------------------------------------*/

/* Initialize VM */
void milo_vm_init(milo_vm_t *vm);

/* Load program from binary */
bool milo_vm_load_binary(milo_vm_t *vm, const uint64_t *code, uint32_t size);

/* Load program from assembly text */
bool milo_vm_load_asm(milo_vm_t *vm, const char *asm_text);

/* Set uniform value */
void milo_vm_set_uniform_float(milo_vm_t *vm, int index, float value);
void milo_vm_set_uniform_vec2(milo_vm_t *vm, int index, float x, float y);
void milo_vm_set_uniform_vec3(milo_vm_t *vm, int index, float x, float y, float z);
void milo_vm_set_uniform_vec4(milo_vm_t *vm, int index, float x, float y, float z, float w);
void milo_vm_set_uniform_mat4(milo_vm_t *vm, int index, const float *m);

/* Bind texture */
void milo_vm_bind_texture(milo_vm_t *vm, int unit, milo_texture_t *tex);

/* Execute fragment shader */
bool milo_vm_exec_fragment(milo_vm_t *vm, const milo_fragment_in_t *in, milo_fragment_out_t *out);

/* Execute vertex shader */
bool milo_vm_exec_vertex(milo_vm_t *vm, const milo_vertex_in_t *in, milo_vertex_out_t *out);

/* Get error message */
const char *milo_vm_get_error(const milo_vm_t *vm);

/*---------------------------------------------------------------------------
 * Texture API
 *---------------------------------------------------------------------------*/

/* Create texture from RGBA data */
milo_texture_t *milo_texture_create(int width, int height, const uint32_t *pixels);

/* Create solid color texture */
milo_texture_t *milo_texture_create_solid(int width, int height, uint32_t color);

/* Create checkerboard texture */
milo_texture_t *milo_texture_create_checker(int width, int height, 
                                            uint32_t color1, uint32_t color2, int check_size);

/* Free texture */
void milo_texture_free(milo_texture_t *tex);

/* Sample texture at UV coordinates */
uint32_t milo_texture_sample(const milo_texture_t *tex, float u, float v);

/*---------------------------------------------------------------------------
 * Framebuffer API
 *---------------------------------------------------------------------------*/

typedef struct {
    uint32_t *color;        /* RGBA8888 color buffer */
    float    *depth;        /* Depth buffer */
    int       width;
    int       height;
} milo_framebuffer_t;

/* Create framebuffer */
milo_framebuffer_t *milo_fb_create(int width, int height);

/* Free framebuffer */
void milo_fb_free(milo_framebuffer_t *fb);

/* Clear framebuffer */
void milo_fb_clear(milo_framebuffer_t *fb, uint32_t color, float depth);

/* Write pixel */
void milo_fb_write(milo_framebuffer_t *fb, int x, int y, uint32_t color, float depth);

/* Save to PPM file */
bool milo_fb_save_ppm(const milo_framebuffer_t *fb, const char *filename);

/*---------------------------------------------------------------------------
 * Quad Renderer
 *---------------------------------------------------------------------------*/

typedef struct {
    /* Vertex positions (screen space, 0-1 range) */
    float x0, y0, x1, y1;
    
    /* Texture coordinates */
    float u0, v0, u1, v1;
    
    /* Vertex colors */
    float r0, g0, b0, a0;
    float r1, g1, b1, a1;
} milo_quad_t;

/* Render a quad using the fragment shader */
void milo_render_quad(milo_vm_t *vm, milo_framebuffer_t *fb, const milo_quad_t *quad);

/* Render fullscreen quad */
void milo_render_fullscreen(milo_vm_t *vm, milo_framebuffer_t *fb);

#endif /* MILO_VM_H */
