/*
 * milo_asm.h
 * Milo832 GPU Assembler - Header
 * 
 * Assembles text assembly into binary machine code for the Milo832 SIMT core.
 */

#ifndef MILO_ASM_H
#define MILO_ASM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

/*---------------------------------------------------------------------------
 * Instruction Set Architecture - Opcodes
 *---------------------------------------------------------------------------*/

/* No Operation / Control */
#define OP_NOP      0x00
#define OP_MOV      0x07
#define OP_EXIT     0xFF

/* Integer Arithmetic */
#define OP_ADD      0x01
#define OP_SUB      0x02
#define OP_MUL      0x03
#define OP_IMAD     0x05
#define OP_NEG      0x06
#define OP_IDIV     0x36
#define OP_IREM     0x37
#define OP_IABS     0x38
#define OP_IMIN     0x39
#define OP_IMAX     0x3A

/* Integer Comparison */
#define OP_SLT      0x04
#define OP_SLE      0x70
#define OP_SEQ      0x71

/* Logic Operations */
#define OP_AND      0x50
#define OP_OR       0x51
#define OP_XOR      0x52
#define OP_NOT      0x53

/* Shift Operations */
#define OP_SHL      0x60
#define OP_SHR      0x61
#define OP_SHA      0x62

/* Memory Operations */
#define OP_LDR      0x10
#define OP_STR      0x11
#define OP_LDS      0x12
#define OP_STS      0x13

/* Control Flow */
#define OP_BEQ      0x20
#define OP_BNE      0x21
#define OP_BRA      0x22
#define OP_SSY      0x23
#define OP_JOIN     0x24
#define OP_BAR      0x25
#define OP_TID      0x26
#define OP_CALL     0x27
#define OP_RET      0x28

/* Floating Point Operations */
#define OP_FADD     0x30
#define OP_FSUB     0x31
#define OP_FMUL     0x32
#define OP_FDIV     0x33
#define OP_FTOI     0x34
#define OP_FFMA     0x35
#define OP_FMIN     0x3B
#define OP_FMAX     0x3C
#define OP_FABS     0x3D
#define OP_ITOF     0x3E
#define OP_FNEG     0x54

/* Floating Point Comparison */
#define OP_FSLT     0x72
#define OP_FSLE     0x73
#define OP_FSEQ     0x74

/* Bit Manipulation */
#define OP_POPC     0x68
#define OP_CLZ      0x69
#define OP_BREV     0x6A
#define OP_CNOT     0x6B

/* Predicate Operations */
#define OP_ISETP    0x80
#define OP_FSETP    0x81
#define OP_SELP     0x82

/* Special Function Unit */
#define OP_SFU_SIN  0x40
#define OP_SFU_COS  0x41
#define OP_SFU_EX2  0x42
#define OP_SFU_LG2  0x43
#define OP_SFU_RCP  0x44
#define OP_SFU_RSQ  0x45
#define OP_SFU_SQRT 0x46
#define OP_SFU_TANH 0x47

/* Texture Operations */
#define OP_TEX      0x90
#define OP_TXL      0x91
#define OP_TXB      0x92

/*---------------------------------------------------------------------------
 * Instruction Encoding
 *---------------------------------------------------------------------------
 * 64-bit instruction format:
 *   [63:56] opcode  (8 bits)
 *   [55:48] rd      (8 bits) - destination register
 *   [47:40] rs1     (8 bits) - source register 1
 *   [39:32] rs2     (8 bits) - source register 2
 *   [31:0]  imm     (32 bits) - immediate value
 * 
 * Alternative format for 3-operand instructions:
 *   [63:56] opcode  (8 bits)
 *   [55:48] rd      (8 bits)
 *   [47:40] rs1     (8 bits)
 *   [39:32] rs2     (8 bits)
 *   [31:28] pred    (4 bits) - predicate guard
 *   [27:20] rs3     (8 bits) - source register 3
 *   [19:0]  imm20   (20 bits) - short immediate
 */

typedef struct {
    uint8_t  opcode;
    uint8_t  rd;
    uint8_t  rs1;
    uint8_t  rs2;
    uint8_t  rs3;
    uint8_t  pred;
    uint32_t imm;
    bool     has_imm;
    bool     has_rs3;
} milo_inst_t;

/* Encode instruction to 64-bit word */
uint64_t milo_encode_inst(const milo_inst_t *inst);

/* Decode 64-bit word to instruction */
void milo_decode_inst(uint64_t word, milo_inst_t *inst);

/*---------------------------------------------------------------------------
 * Assembler Interface
 *---------------------------------------------------------------------------*/

#define MILO_MAX_LABELS     256
#define MILO_MAX_CODE_SIZE  4096
#define MILO_MAX_LINE_LEN   256

typedef struct {
    char     name[64];
    uint32_t address;
} milo_label_t;

typedef struct {
    uint64_t     code[MILO_MAX_CODE_SIZE];
    uint32_t     code_size;
    milo_label_t labels[MILO_MAX_LABELS];
    uint32_t     label_count;
    char         error[256];
    int          error_line;
} milo_asm_t;

/* Initialize assembler state */
void milo_asm_init(milo_asm_t *as);

/* Assemble a single line (returns false on error) */
bool milo_asm_line(milo_asm_t *as, const char *line, int line_num);

/* Assemble complete source (returns false on error) */
bool milo_asm_source(milo_asm_t *as, const char *source);

/* Resolve labels after first pass */
bool milo_asm_resolve(milo_asm_t *as);

/* Get assembled binary */
const uint64_t *milo_asm_get_code(const milo_asm_t *as, uint32_t *size);

/* Get error message */
const char *milo_asm_get_error(const milo_asm_t *as);

/*---------------------------------------------------------------------------
 * Disassembler Interface
 *---------------------------------------------------------------------------*/

/* Disassemble single instruction to string */
void milo_disasm_inst(uint64_t word, char *buf, size_t buf_size);

/* Disassemble program to file */
void milo_disasm_program(const uint64_t *code, uint32_t size, FILE *out);

#endif /* MILO_ASM_H */
