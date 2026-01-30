/*
 * milo_vm.c
 * Milo832 Shader Virtual Machine - Implementation
 * 
 * This is the "golden model" - VHDL output must match this exactly.
 */

#include "milo_vm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/*---------------------------------------------------------------------------
 * Float/Int Conversion Helpers (bit-exact)
 *---------------------------------------------------------------------------*/

static inline float u2f(uint32_t u) {
    union { uint32_t u; float f; } conv;
    conv.u = u;
    return conv.f;
}

static inline uint32_t f2u(float f) {
    union { uint32_t u; float f; } conv;
    conv.f = f;
    return conv.u;
}

static inline int32_t f2i(float f) {
    return (int32_t)f;
}

static inline float i2f(int32_t i) {
    return (float)i;
}

/*---------------------------------------------------------------------------
 * Instruction Decoding
 *---------------------------------------------------------------------------*/

static inline uint8_t inst_opcode(uint64_t inst) { return (inst >> 56) & 0xFF; }
static inline uint8_t inst_rd(uint64_t inst)     { return (inst >> 48) & 0xFF; }
static inline uint8_t inst_rs1(uint64_t inst)    { return (inst >> 40) & 0xFF; }
static inline uint8_t inst_rs2(uint64_t inst)    { return (inst >> 32) & 0xFF; }
/* Extract 20-bit immediate and sign-extend to 32 bits (matching SM behavior) */
static inline int32_t inst_imm(uint64_t inst) {
    int32_t imm20 = inst & 0xFFFFF;
    /* Sign extend from 20-bit to 32-bit */
    if (imm20 & 0x80000) {
        imm20 |= 0xFFF00000;
    }
    return imm20;
}
static inline uint8_t inst_rs3(uint64_t inst)    { return (inst >> 20) & 0xFF; }

/*---------------------------------------------------------------------------
 * SFU Functions (matching VHDL LUT-based implementation)
 *---------------------------------------------------------------------------*/

/* These should match the VHDL SFU tables exactly */
static float sfu_sin(float x) {
    /* Normalize to [0, 2*PI] then use table */
    /* For now, use libm - replace with LUT for exact match */
    return sinf(x);
}

static float sfu_cos(float x) {
    return cosf(x);
}

static float sfu_exp2(float x) {
    return exp2f(x);
}

static float sfu_log2(float x) {
    if (x <= 0.0f) return -INFINITY;
    return log2f(x);
}

static float sfu_rcp(float x) {
    if (x == 0.0f) return INFINITY;
    return 1.0f / x;
}

static float sfu_rsqrt(float x) {
    if (x <= 0.0f) return INFINITY;
    return 1.0f / sqrtf(x);
}

static float sfu_sqrt(float x) {
    if (x < 0.0f) return 0.0f;  /* NaN handling - return 0 for simplicity */
    return sqrtf(x);
}

static float sfu_tanh(float x) {
    return tanhf(x);
}

/*---------------------------------------------------------------------------
 * Texture Sampling
 *---------------------------------------------------------------------------*/

uint32_t milo_texture_sample(const milo_texture_t *tex, float u, float v) {
    if (!tex || !tex->pixels) {
        return 0xFFFF00FF;  /* Magenta = missing texture */
    }
    
    /* Wrap coordinates */
    if (tex->wrap_s) {
        u = u - floorf(u);
    } else {
        u = fmaxf(0.0f, fminf(1.0f, u));
    }
    
    if (tex->wrap_t) {
        v = v - floorf(v);
    } else {
        v = fmaxf(0.0f, fminf(1.0f, v));
    }
    
    /* Convert to pixel coordinates */
    float fx = u * (tex->width - 1);
    float fy = v * (tex->height - 1);
    
    if (tex->filter) {
        /* Bilinear filtering */
        int x0 = (int)floorf(fx);
        int y0 = (int)floorf(fy);
        int x1 = x0 + 1;
        int y1 = y0 + 1;
        
        if (x1 >= tex->width) x1 = tex->width - 1;
        if (y1 >= tex->height) y1 = tex->height - 1;
        
        float dx = fx - x0;
        float dy = fy - y0;
        
        uint32_t p00 = tex->pixels[y0 * tex->width + x0];
        uint32_t p10 = tex->pixels[y0 * tex->width + x1];
        uint32_t p01 = tex->pixels[y1 * tex->width + x0];
        uint32_t p11 = tex->pixels[y1 * tex->width + x1];
        
        /* Interpolate each channel */
        uint32_t result = 0;
        for (int c = 0; c < 4; c++) {
            int shift = c * 8;
            float c00 = (p00 >> shift) & 0xFF;
            float c10 = (p10 >> shift) & 0xFF;
            float c01 = (p01 >> shift) & 0xFF;
            float c11 = (p11 >> shift) & 0xFF;
            
            float c0 = c00 + dx * (c10 - c00);
            float c1 = c01 + dx * (c11 - c01);
            float cf = c0 + dy * (c1 - c0);
            
            int ci = (int)(cf + 0.5f);
            if (ci < 0) ci = 0;
            if (ci > 255) ci = 255;
            result |= (ci << shift);
        }
        return result;
    } else {
        /* Nearest neighbor */
        int x = (int)(fx + 0.5f);
        int y = (int)(fy + 0.5f);
        if (x >= tex->width) x = tex->width - 1;
        if (y >= tex->height) y = tex->height - 1;
        return tex->pixels[y * tex->width + x];
    }
}

/*---------------------------------------------------------------------------
 * VM Implementation
 *---------------------------------------------------------------------------*/

void milo_vm_init(milo_vm_t *vm) {
    memset(vm, 0, sizeof(*vm));
    vm->max_cycles = 100000;  /* Prevent infinite loops */
}

bool milo_vm_load_binary(milo_vm_t *vm, const uint64_t *code, uint32_t size) {
    if (size > VM_MAX_CODE) {
        snprintf(vm->error, sizeof(vm->error), "Code too large (%u > %d)", size, VM_MAX_CODE);
        return false;
    }
    memcpy(vm->code, code, size * sizeof(uint64_t));
    vm->code_size = size;
    return true;
}

bool milo_vm_load_asm(milo_vm_t *vm, const char *asm_text) {
    milo_asm_t as;
    milo_asm_init(&as);
    
    if (!milo_asm_source(&as, asm_text)) {
        snprintf(vm->error, sizeof(vm->error), "Assembly error: %s", milo_asm_get_error(&as));
        return false;
    }
    
    uint32_t size;
    const uint64_t *code = milo_asm_get_code(&as, &size);
    if (!milo_vm_load_binary(vm, code, size)) {
        return false;
    }
    
    /* Parse .data directives to load constant table into memory */
    const char *p = asm_text;
    while ((p = strstr(p, ".data ")) != NULL) {
        /* Format: .data 0xADDR, 0xVALUE */
        p += 6;  /* Skip ".data " */
        
        /* Skip whitespace */
        while (*p == ' ' || *p == '\t') p++;
        
        /* Parse address */
        uint32_t addr = 0;
        if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
            p += 2;
            while ((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f') || (*p >= 'A' && *p <= 'F')) {
                addr = addr * 16;
                if (*p >= '0' && *p <= '9') addr += *p - '0';
                else if (*p >= 'a' && *p <= 'f') addr += *p - 'a' + 10;
                else addr += *p - 'A' + 10;
                p++;
            }
        }
        
        /* Skip comma and whitespace */
        while (*p == ',' || *p == ' ' || *p == '\t') p++;
        
        /* Parse value */
        uint32_t value = 0;
        if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
            p += 2;
            while ((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f') || (*p >= 'A' && *p <= 'F')) {
                value = value * 16;
                if (*p >= '0' && *p <= '9') value += *p - '0';
                else if (*p >= 'a' && *p <= 'f') value += *p - 'a' + 10;
                else value += *p - 'A' + 10;
                p++;
            }
        }
        
        /* Store in memory */
        if (addr < VM_MEM_SIZE) {
            vm->mem[addr / 4] = value;
        }
    }
    
    return true;
}

void milo_vm_set_uniform_float(milo_vm_t *vm, int index, float value) {
    if (index >= 0 && index < VM_MAX_UNIFORMS) {
        vm->uniforms[index].f = value;
    }
}

void milo_vm_set_uniform_vec2(milo_vm_t *vm, int index, float x, float y) {
    if (index >= 0 && index < VM_MAX_UNIFORMS) {
        vm->uniforms[index].v2[0] = x;
        vm->uniforms[index].v2[1] = y;
    }
}

void milo_vm_set_uniform_vec3(milo_vm_t *vm, int index, float x, float y, float z) {
    if (index >= 0 && index < VM_MAX_UNIFORMS) {
        vm->uniforms[index].v3[0] = x;
        vm->uniforms[index].v3[1] = y;
        vm->uniforms[index].v3[2] = z;
    }
}

void milo_vm_set_uniform_vec4(milo_vm_t *vm, int index, float x, float y, float z, float w) {
    if (index >= 0 && index < VM_MAX_UNIFORMS) {
        vm->uniforms[index].v4[0] = x;
        vm->uniforms[index].v4[1] = y;
        vm->uniforms[index].v4[2] = z;
        vm->uniforms[index].v4[3] = w;
    }
}

void milo_vm_set_uniform_mat4(milo_vm_t *vm, int index, const float *m) {
    if (index >= 0 && index < VM_MAX_UNIFORMS) {
        memcpy(vm->uniforms[index].m4, m, 16 * sizeof(float));
    }
}

void milo_vm_bind_texture(milo_vm_t *vm, int unit, milo_texture_t *tex) {
    if (unit >= 0 && unit < VM_MAX_TEXTURES) {
        vm->textures[unit] = tex;
    }
}

/* Execute single instruction, returns false if execution should stop */
static bool vm_step(milo_vm_t *vm) {
    if (vm->pc >= vm->code_size) {
        snprintf(vm->error, sizeof(vm->error), "PC out of bounds: %u", vm->pc);
        return false;
    }
    
    uint64_t inst = vm->code[vm->pc];
    uint8_t op = inst_opcode(inst);
    uint8_t rd = inst_rd(inst);
    uint8_t rs1 = inst_rs1(inst);
    uint8_t rs2 = inst_rs2(inst);
    uint32_t imm = inst_imm(inst);
    uint8_t rs3 = inst_rs3(inst);
    
    /* Register 0 is always 0 */
    vm->regs[0].u = 0;
    
    float f1 = vm->regs[rs1].f;
    float f2 = vm->regs[rs2].f;
    int32_t i1 = vm->regs[rs1].i;
    int32_t i2 = vm->regs[rs2].i;
    uint32_t u1 = vm->regs[rs1].u;
    uint32_t u2 = vm->regs[rs2].u;
    
    vm->pc++;
    vm->cycle_count++;
    
    switch (op) {
        /* NOP / Control */
        case OP_NOP:
            break;
            
        case OP_EXIT:
            vm->running = false;
            return false;
            
        case OP_MOV:
            vm->regs[rd].u = u1;
            break;
            
        /* Integer Arithmetic */
        case OP_ADD:
            if (imm != 0) {
                vm->regs[rd].i = i1 + (int32_t)imm;
            } else {
                vm->regs[rd].i = i1 + i2;
            }
            break;
            
        case OP_SUB:
            vm->regs[rd].i = i1 - i2;
            break;
            
        case OP_MUL:
            vm->regs[rd].i = i1 * i2;
            break;
            
        case OP_NEG:
            vm->regs[rd].i = -i1;
            break;
            
        case OP_IDIV:
            if (i2 == 0) {
                vm->regs[rd].i = 0;
            } else {
                vm->regs[rd].i = i1 / i2;
            }
            break;
            
        case OP_IREM:
            if (i2 == 0) {
                vm->regs[rd].i = 0;
            } else {
                vm->regs[rd].i = i1 % i2;
            }
            break;
            
        case OP_IABS:
            vm->regs[rd].i = (i1 < 0) ? -i1 : i1;
            break;
            
        case OP_IMIN:
            vm->regs[rd].i = (i1 < i2) ? i1 : i2;
            break;
            
        case OP_IMAX:
            vm->regs[rd].i = (i1 > i2) ? i1 : i2;
            break;
            
        case OP_IMAD:
            vm->regs[rd].i = i1 * i2 + vm->regs[rs3].i;
            break;
            
        /* Integer Comparison */
        case OP_SLT:
            vm->regs[rd].i = (i1 < i2) ? 1 : 0;
            break;
            
        case OP_SLE:
            vm->regs[rd].i = (i1 <= i2) ? 1 : 0;
            break;
            
        case OP_SEQ:
            vm->regs[rd].i = (i1 == i2) ? 1 : 0;
            break;
            
        /* Logic */
        case OP_AND:
            vm->regs[rd].u = u1 & u2;
            break;
            
        case OP_OR:
            vm->regs[rd].u = u1 | u2;
            break;
            
        case OP_XOR:
            vm->regs[rd].u = u1 ^ u2;
            break;
            
        case OP_NOT:
            vm->regs[rd].u = ~u1;
            break;
            
        /* Shift */
        case OP_SHL:
            vm->regs[rd].u = u1 << (u2 & 31);
            break;
            
        case OP_SHR:
            vm->regs[rd].u = u1 >> (u2 & 31);
            break;
            
        case OP_SHA:  /* Arithmetic shift right */
            vm->regs[rd].i = i1 >> (u2 & 31);
            break;
            
        /* Floating Point */
        case OP_FADD:
            vm->regs[rd].f = f1 + f2;
            break;
            
        case OP_FSUB:
            vm->regs[rd].f = f1 - f2;
            break;
            
        case OP_FMUL:
            vm->regs[rd].f = f1 * f2;
            break;
            
        case OP_FDIV:
            vm->regs[rd].f = (f2 != 0.0f) ? f1 / f2 : 0.0f;
            break;
            
        case OP_FFMA:
            vm->regs[rd].f = f1 * f2 + vm->regs[rs3].f;
            break;
            
        case OP_FNEG:
            vm->regs[rd].f = -f1;
            break;
            
        case OP_FABS:
            vm->regs[rd].f = fabsf(f1);
            break;
            
        case OP_FMIN:
            vm->regs[rd].f = fminf(f1, f2);
            break;
            
        case OP_FMAX:
            vm->regs[rd].f = fmaxf(f1, f2);
            break;
            
        case OP_FTOI:
            vm->regs[rd].i = f2i(f1);
            break;
            
        case OP_ITOF:
            vm->regs[rd].f = i2f(i1);
            break;
            
        /* Float Comparison (extension) */
        case 0x72:  /* FSLT */
            vm->regs[rd].i = (f1 < f2) ? 1 : 0;
            break;
            
        case 0x73:  /* FSLE */
            vm->regs[rd].i = (f1 <= f2) ? 1 : 0;
            break;
            
        case 0x74:  /* FSEQ */
            vm->regs[rd].i = (f1 == f2) ? 1 : 0;
            break;
            
        /* SFU */
        case OP_SFU_SIN:
            vm->regs[rd].f = sfu_sin(f1);
            break;
            
        case OP_SFU_COS:
            vm->regs[rd].f = sfu_cos(f1);
            break;
            
        case OP_SFU_EX2:
            vm->regs[rd].f = sfu_exp2(f1);
            break;
            
        case OP_SFU_LG2:
            vm->regs[rd].f = sfu_log2(f1);
            break;
            
        case OP_SFU_RCP:
            vm->regs[rd].f = sfu_rcp(f1);
            break;
            
        case OP_SFU_RSQ:
            vm->regs[rd].f = sfu_rsqrt(f1);
            break;
            
        case OP_SFU_SQRT:
            vm->regs[rd].f = sfu_sqrt(f1);
            break;
            
        case OP_SFU_TANH:
            vm->regs[rd].f = sfu_tanh(f1);
            break;
            
        /* Bit manipulation */
        case OP_POPC: {
            uint32_t v = u1;
            int count = 0;
            while (v) { count += (v & 1); v >>= 1; }
            vm->regs[rd].i = count;
            break;
        }
            
        case OP_CLZ: {
            uint32_t v = u1;
            int count = 0;
            for (int i = 31; i >= 0; i--) {
                if (v & (1u << i)) break;
                count++;
            }
            vm->regs[rd].i = count;
            break;
        }
            
        case OP_BREV: {
            uint32_t v = u1;
            uint32_t r = 0;
            for (int i = 0; i < 32; i++) {
                r |= ((v >> i) & 1) << (31 - i);
            }
            vm->regs[rd].u = r;
            break;
        }
            
        case OP_CNOT:
            vm->regs[rd].u = (u1 == 0) ? 1 : 0;
            break;
            
        /* Predicates */
        case OP_SELP:
            vm->regs[rd].u = (vm->regs[rs3].i != 0) ? u1 : u2;
            break;
            
        /* Control Flow */
        case OP_BRA:
            vm->pc = imm;
            break;
            
        case OP_BEQ:
            if (i1 == i2) {
                vm->pc = imm;
            }
            break;
            
        case OP_BNE:
            if (i1 != i2) {
                vm->pc = imm;
            }
            break;
            
        case OP_SSY:
            /* Push sync point for SIMT divergence */
            if (vm->div_sp < VM_STACK_SIZE) {
                vm->div_stack[vm->div_sp++] = imm;
            }
            break;
            
        case OP_JOIN:
            /* Pop sync point */
            if (vm->div_sp > 0) {
                vm->div_sp--;
            }
            break;
            
        case OP_CALL:
            if (vm->ret_sp < VM_STACK_SIZE) {
                vm->ret_stack[vm->ret_sp++] = vm->pc;
            }
            vm->pc = imm;
            break;
            
        case OP_RET:
            if (vm->ret_sp > 0) {
                vm->pc = vm->ret_stack[--vm->ret_sp];
            } else {
                vm->running = false;
                return false;
            }
            break;
            
        case OP_TID:
            /* Thread ID - for single-threaded sim, always 0 */
            vm->regs[rd].i = 0;
            break;
            
        case OP_BAR:
            /* Barrier - no-op in single-threaded sim */
            break;
            
        /* Texture */
        case OP_TEX: {
            int unit = (int)u1;
            float u = f2;
            float v = vm->regs[rs2 + 1].f;  /* V is in next register */
            
            if (unit >= 0 && unit < VM_MAX_TEXTURES && vm->textures[unit]) {
                uint32_t rgba = milo_texture_sample(vm->textures[unit], u, v);
                /* Unpack to float4 in consecutive registers */
                vm->regs[rd].f = ((rgba >> 0) & 0xFF) / 255.0f;
                vm->regs[rd + 1].f = ((rgba >> 8) & 0xFF) / 255.0f;
                vm->regs[rd + 2].f = ((rgba >> 16) & 0xFF) / 255.0f;
                vm->regs[rd + 3].f = ((rgba >> 24) & 0xFF) / 255.0f;
            } else {
                vm->regs[rd].f = 1.0f;
                vm->regs[rd + 1].f = 0.0f;
                vm->regs[rd + 2].f = 1.0f;
                vm->regs[rd + 3].f = 1.0f;
            }
            break;
        }
            
        /* Memory operations */
        case OP_LDR: {
            /* LDR rd, rs1, imm - Load word from memory[rs1 + imm] */
            uint32_t addr = vm->regs[rs1].u + imm;
            if (addr < VM_MEM_SIZE) {
                uint32_t word_idx = addr / 4;
                vm->regs[rd].u = vm->mem[word_idx];
            } else {
                /* Out of bounds - return zero */
                vm->regs[rd].u = 0;
            }
            break;
        }
        case OP_STR: {
            /* STR rd, rs1, imm - Store word to memory[rs1 + imm] */
            uint32_t addr = vm->regs[rs1].u + imm;
            if (addr < VM_MEM_SIZE) {
                uint32_t word_idx = addr / 4;
                vm->mem[word_idx] = vm->regs[rs2].u;  /* rs2 is source for STR */
            }
            break;
        }
        case OP_LDS:
        case OP_STS:
            /* Shared memory - not implemented */
            break;
            
        default:
            snprintf(vm->error, sizeof(vm->error), "Unknown opcode: 0x%02X at PC %u", op, vm->pc - 1);
            return false;
    }
    
    /* Always keep r0 as zero */
    vm->regs[0].u = 0;
    
    return true;
}

bool milo_vm_exec_fragment(milo_vm_t *vm, const milo_fragment_in_t *in, milo_fragment_out_t *out) {
    /* Reset state */
    memset(vm->regs, 0, sizeof(vm->regs));
    vm->pc = 0;
    vm->div_sp = 0;
    vm->ret_sp = 0;
    vm->running = true;
    vm->discarded = false;
    vm->cycle_count = 0;
    vm->error[0] = '\0';
    
    /* Set up input registers (matching compiler's register allocation) */
    /* r0 = zero, r1 = return value */
    /* r2-r3 = v_texcoord (vec2) */
    vm->regs[2].f = in->u;
    vm->regs[3].f = in->v;
    /* r4-r6 = v_normal (vec3) */
    vm->regs[4].f = in->nx;
    vm->regs[5].f = in->ny;
    vm->regs[6].f = in->nz;
    /* r7-r10 = v_color (vec4) */
    vm->regs[7].f = in->r;
    vm->regs[8].f = in->g;
    vm->regs[9].f = in->b;
    vm->regs[10].f = in->a;
    
    /* Run until exit or error */
    while (vm->running && vm->cycle_count < vm->max_cycles) {
        if (!vm_step(vm)) {
            break;
        }
    }
    
    if (vm->cycle_count >= vm->max_cycles) {
        snprintf(vm->error, sizeof(vm->error), "Exceeded max cycles (%d)", vm->max_cycles);
        return false;
    }
    
    /* Extract output from fragColor register
     * For simple shaders: r4-r7 (first out vec4 after inputs)
     * For complex shaders: varies based on layout
     * TODO: Pass output register location from compiler
     */
    out->r = vm->regs[4].f;
    out->g = vm->regs[5].f;
    out->b = vm->regs[6].f;
    out->a = vm->regs[7].f;
    out->discard = vm->discarded;
    out->depth = in->z;
    
    return vm->error[0] == '\0';
}

bool milo_vm_exec_vertex(milo_vm_t *vm, const milo_vertex_in_t *in, milo_vertex_out_t *out) {
    /* Similar to fragment shader, but different register mapping */
    memset(vm->regs, 0, sizeof(vm->regs));
    vm->pc = 0;
    vm->div_sp = 0;
    vm->ret_sp = 0;
    vm->running = true;
    vm->cycle_count = 0;
    vm->error[0] = '\0';
    
    /* Set up input registers */
    vm->regs[2].f = in->x;
    vm->regs[3].f = in->y;
    vm->regs[4].f = in->z;
    vm->regs[5].f = in->u;
    vm->regs[6].f = in->v;
    vm->regs[7].f = in->r;
    vm->regs[8].f = in->g;
    vm->regs[9].f = in->b;
    vm->regs[10].f = in->a;
    vm->regs[11].f = in->nx;
    vm->regs[12].f = in->ny;
    vm->regs[13].f = in->nz;
    
    while (vm->running && vm->cycle_count < vm->max_cycles) {
        if (!vm_step(vm)) {
            break;
        }
    }
    
    /* Extract output */
    out->x = vm->regs[1].f;  /* Return value */
    out->y = vm->regs[2].f;
    out->z = vm->regs[3].f;
    out->w = vm->regs[4].f;
    
    return vm->error[0] == '\0';
}

const char *milo_vm_get_error(const milo_vm_t *vm) {
    return vm->error[0] ? vm->error : NULL;
}

/*---------------------------------------------------------------------------
 * Texture API
 *---------------------------------------------------------------------------*/

milo_texture_t *milo_texture_create(int width, int height, const uint32_t *pixels) {
    milo_texture_t *tex = calloc(1, sizeof(milo_texture_t));
    if (!tex) return NULL;
    
    tex->width = width;
    tex->height = height;
    tex->pixels = malloc(width * height * sizeof(uint32_t));
    if (!tex->pixels) {
        free(tex);
        return NULL;
    }
    
    if (pixels) {
        memcpy(tex->pixels, pixels, width * height * sizeof(uint32_t));
    }
    
    tex->wrap_s = true;
    tex->wrap_t = true;
    tex->filter = true;
    
    return tex;
}

milo_texture_t *milo_texture_create_solid(int width, int height, uint32_t color) {
    milo_texture_t *tex = milo_texture_create(width, height, NULL);
    if (!tex) return NULL;
    
    for (int i = 0; i < width * height; i++) {
        tex->pixels[i] = color;
    }
    
    return tex;
}

milo_texture_t *milo_texture_create_checker(int width, int height, 
                                            uint32_t color1, uint32_t color2, int check_size) {
    milo_texture_t *tex = milo_texture_create(width, height, NULL);
    if (!tex) return NULL;
    
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int cx = x / check_size;
            int cy = y / check_size;
            tex->pixels[y * width + x] = ((cx + cy) & 1) ? color2 : color1;
        }
    }
    
    return tex;
}

void milo_texture_free(milo_texture_t *tex) {
    if (tex) {
        free(tex->pixels);
        free(tex);
    }
}

/*---------------------------------------------------------------------------
 * Framebuffer API
 *---------------------------------------------------------------------------*/

milo_framebuffer_t *milo_fb_create(int width, int height) {
    milo_framebuffer_t *fb = calloc(1, sizeof(milo_framebuffer_t));
    if (!fb) return NULL;
    
    fb->width = width;
    fb->height = height;
    fb->color = calloc(width * height, sizeof(uint32_t));
    fb->depth = calloc(width * height, sizeof(float));
    
    if (!fb->color || !fb->depth) {
        free(fb->color);
        free(fb->depth);
        free(fb);
        return NULL;
    }
    
    return fb;
}

void milo_fb_free(milo_framebuffer_t *fb) {
    if (fb) {
        free(fb->color);
        free(fb->depth);
        free(fb);
    }
}

void milo_fb_clear(milo_framebuffer_t *fb, uint32_t color, float depth) {
    for (int i = 0; i < fb->width * fb->height; i++) {
        fb->color[i] = color;
        fb->depth[i] = depth;
    }
}

void milo_fb_write(milo_framebuffer_t *fb, int x, int y, uint32_t color, float depth) {
    if (x >= 0 && x < fb->width && y >= 0 && y < fb->height) {
        int idx = y * fb->width + x;
        fb->color[idx] = color;
        fb->depth[idx] = depth;
    }
}

bool milo_fb_save_ppm(const milo_framebuffer_t *fb, const char *filename) {
    FILE *f = fopen(filename, "wb");
    if (!f) return false;
    
    fprintf(f, "P6\n%d %d\n255\n", fb->width, fb->height);
    
    for (int y = 0; y < fb->height; y++) {
        for (int x = 0; x < fb->width; x++) {
            uint32_t c = fb->color[y * fb->width + x];
            uint8_t rgb[3];
            rgb[0] = (c >> 0) & 0xFF;   /* R */
            rgb[1] = (c >> 8) & 0xFF;   /* G */
            rgb[2] = (c >> 16) & 0xFF;  /* B */
            fwrite(rgb, 1, 3, f);
        }
    }
    
    fclose(f);
    return true;
}

/*---------------------------------------------------------------------------
 * Quad Renderer
 *---------------------------------------------------------------------------*/

static uint32_t float4_to_rgba(float r, float g, float b, float a) {
    int ri = (int)(fminf(fmaxf(r, 0.0f), 1.0f) * 255.0f + 0.5f);
    int gi = (int)(fminf(fmaxf(g, 0.0f), 1.0f) * 255.0f + 0.5f);
    int bi = (int)(fminf(fmaxf(b, 0.0f), 1.0f) * 255.0f + 0.5f);
    int ai = (int)(fminf(fmaxf(a, 0.0f), 1.0f) * 255.0f + 0.5f);
    return (ai << 24) | (bi << 16) | (gi << 8) | ri;
}

void milo_render_quad(milo_vm_t *vm, milo_framebuffer_t *fb, const milo_quad_t *quad) {
    int x0 = (int)(quad->x0 * fb->width);
    int y0 = (int)(quad->y0 * fb->height);
    int x1 = (int)(quad->x1 * fb->width);
    int y1 = (int)(quad->y1 * fb->height);
    
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { int t = y0; y0 = y1; y1 = t; }
    
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            /* Compute interpolation factors */
            float tx = (x1 > x0) ? (float)(x - x0) / (x1 - x0) : 0.0f;
            float ty = (y1 > y0) ? (float)(y - y0) / (y1 - y0) : 0.0f;
            
            /* Interpolate fragment inputs */
            milo_fragment_in_t frag_in;
            frag_in.x = (float)x;
            frag_in.y = (float)y;
            frag_in.z = 0.5f;
            
            frag_in.u = quad->u0 + tx * (quad->u1 - quad->u0);
            frag_in.v = quad->v0 + ty * (quad->v1 - quad->v0);
            
            frag_in.r = quad->r0 + tx * (quad->r1 - quad->r0);
            frag_in.g = quad->g0 + tx * (quad->g1 - quad->g0);
            frag_in.b = quad->b0 + tx * (quad->b1 - quad->b0);
            frag_in.a = quad->a0 + tx * (quad->a1 - quad->a0);
            
            frag_in.nx = 0.0f;
            frag_in.ny = 0.0f;
            frag_in.nz = 1.0f;
            
            /* Execute fragment shader */
            milo_fragment_out_t frag_out;
            if (milo_vm_exec_fragment(vm, &frag_in, &frag_out)) {
                if (!frag_out.discard) {
                    uint32_t color = float4_to_rgba(frag_out.r, frag_out.g, frag_out.b, frag_out.a);
                    milo_fb_write(fb, x, y, color, frag_out.depth);
                }
            }
        }
    }
}

void milo_render_fullscreen(milo_vm_t *vm, milo_framebuffer_t *fb) {
    milo_quad_t quad = {
        .x0 = 0.0f, .y0 = 0.0f, .x1 = 1.0f, .y1 = 1.0f,
        .u0 = 0.0f, .v0 = 0.0f, .u1 = 1.0f, .v1 = 1.0f,
        .r0 = 1.0f, .g0 = 1.0f, .b0 = 1.0f, .a0 = 1.0f,
        .r1 = 1.0f, .g1 = 1.0f, .b1 = 1.0f, .a1 = 1.0f
    };
    milo_render_quad(vm, fb, &quad);
}
