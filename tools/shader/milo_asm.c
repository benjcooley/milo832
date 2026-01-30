/*
 * milo_asm.c
 * Milo832 GPU Assembler - Implementation
 */

#include "milo_asm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/*---------------------------------------------------------------------------
 * Opcode Table
 *---------------------------------------------------------------------------*/

typedef struct {
    const char *name;
    uint8_t     opcode;
    int         num_args;   /* -1 = variable */
    const char *format;     /* r=reg, i=imm, l=label */
} opcode_entry_t;

static const opcode_entry_t opcode_table[] = {
    /* Control */
    {"nop",     OP_NOP,     0, ""},
    {"exit",    OP_EXIT,    0, ""},
    {"mov",     OP_MOV,     2, "rr"},
    
    /* Integer Arithmetic */
    {"add",     OP_ADD,     3, "rrr"},
    {"sub",     OP_SUB,     3, "rrr"},
    {"mul",     OP_MUL,     3, "rrr"},
    {"imad",    OP_IMAD,    4, "rrrr"},
    {"neg",     OP_NEG,     2, "rr"},
    {"idiv",    OP_IDIV,    3, "rrr"},
    {"irem",    OP_IREM,    3, "rrr"},
    {"iabs",    OP_IABS,    2, "rr"},
    {"imin",    OP_IMIN,    3, "rrr"},
    {"imax",    OP_IMAX,    3, "rrr"},
    
    /* Integer Comparison */
    {"slt",     OP_SLT,     3, "rrr"},
    {"sle",     OP_SLE,     3, "rrr"},
    {"seq",     OP_SEQ,     3, "rrr"},
    
    /* Logic */
    {"and",     OP_AND,     3, "rrr"},
    {"or",      OP_OR,      3, "rrr"},
    {"xor",     OP_XOR,     3, "rrr"},
    {"not",     OP_NOT,     2, "rr"},
    
    /* Shift */
    {"shl",     OP_SHL,     3, "rrr"},
    {"shr",     OP_SHR,     3, "rrr"},
    {"sha",     OP_SHA,     3, "rrr"},
    
    /* Memory */
    {"ldr",     OP_LDR,     2, "rr"},
    {"str",     OP_STR,     2, "rr"},
    {"lds",     OP_LDS,     2, "rr"},
    {"sts",     OP_STS,     2, "rr"},
    
    /* Control Flow */
    {"beq",     OP_BEQ,     3, "rrl"},
    {"bne",     OP_BNE,     3, "rrl"},
    {"bra",     OP_BRA,     1, "l"},
    {"ssy",     OP_SSY,     1, "l"},
    {"join",    OP_JOIN,    0, ""},
    {"bar",     OP_BAR,     1, "i"},
    {"tid",     OP_TID,     1, "r"},
    {"call",    OP_CALL,    1, "l"},
    {"ret",     OP_RET,     0, ""},
    
    /* Floating Point */
    {"fadd",    OP_FADD,    3, "rrr"},
    {"fsub",    OP_FSUB,    3, "rrr"},
    {"fmul",    OP_FMUL,    3, "rrr"},
    {"fdiv",    OP_FDIV,    3, "rrr"},
    {"ffma",    OP_FFMA,    4, "rrrr"},
    {"ftoi",    OP_FTOI,    2, "rr"},
    {"itof",    OP_ITOF,    2, "rr"},
    {"fmin",    OP_FMIN,    3, "rrr"},
    {"fmax",    OP_FMAX,    3, "rrr"},
    {"fabs",    OP_FABS,    2, "rr"},
    {"fneg",    OP_FNEG,    2, "rr"},
    
    /* Float Comparison */
    {"fslt",    OP_FSLT,    3, "rrr"},
    {"fsle",    OP_FSLE,    3, "rrr"},
    {"fseq",    OP_FSEQ,    3, "rrr"},
    
    /* Bit Manipulation */
    {"popc",    OP_POPC,    2, "rr"},
    {"clz",     OP_CLZ,     2, "rr"},
    {"brev",    OP_BREV,    2, "rr"},
    {"cnot",    OP_CNOT,    2, "rr"},
    
    /* Predicates */
    {"isetp",   OP_ISETP,   3, "rrr"},
    {"fsetp",   OP_FSETP,   3, "rrr"},
    {"selp",    OP_SELP,    4, "rrrr"},
    
    /* SFU */
    {"sin",     OP_SFU_SIN,  2, "rr"},
    {"cos",     OP_SFU_COS,  2, "rr"},
    {"ex2",     OP_SFU_EX2,  2, "rr"},
    {"lg2",     OP_SFU_LG2,  2, "rr"},
    {"rcp",     OP_SFU_RCP,  2, "rr"},
    {"rsq",     OP_SFU_RSQ,  2, "rr"},
    {"sqrt",    OP_SFU_SQRT, 2, "rr"},
    {"tanh",    OP_SFU_TANH, 2, "rr"},
    
    /* Texture */
    {"tex",     OP_TEX,     3, "rrr"},
    {"txl",     OP_TXL,     4, "rrrr"},
    {"txb",     OP_TXB,     4, "rrrr"},
    
    /* Immediate variants */
    {"addi",    OP_ADD,     3, "rri"},
    {"subi",    OP_SUB,     3, "rri"},
    {"muli",    OP_MUL,     3, "rri"},
    {"andi",    OP_AND,     3, "rri"},
    {"ori",     OP_OR,      3, "rri"},
    {"xori",    OP_XOR,     3, "rri"},
    {"shli",    OP_SHL,     3, "rri"},
    {"shri",    OP_SHR,     3, "rri"},
    {"shai",    OP_SHA,     3, "rri"},
    
    {NULL, 0, 0, NULL}
};

/*---------------------------------------------------------------------------
 * Helper Functions
 *---------------------------------------------------------------------------*/

static const opcode_entry_t *find_opcode(const char *name) {
    for (int i = 0; opcode_table[i].name != NULL; i++) {
        if (strcasecmp(opcode_table[i].name, name) == 0) {
            return &opcode_table[i];
        }
    }
    return NULL;
}

static bool parse_register(const char *str, uint8_t *reg) {
    if (str[0] != 'r' && str[0] != 'R') {
        return false;
    }
    char *endp;
    long val = strtol(str + 1, &endp, 10);
    if (*endp != '\0' || val < 0 || val > 63) {
        return false;
    }
    *reg = (uint8_t)val;
    return true;
}

static bool parse_immediate(const char *str, uint32_t *imm) {
    char *endp;
    long val;
    
    /* Handle hex */
    if (str[0] == '0' && (str[1] == 'x' || str[1] == 'X')) {
        val = strtol(str, &endp, 16);
    } else {
        val = strtol(str, &endp, 10);
    }
    
    if (*endp != '\0') {
        return false;
    }
    *imm = (uint32_t)val;
    return true;
}

static bool parse_float(const char *str, uint32_t *bits) {
    char *endp;
    float val = strtof(str, &endp);
    if (*endp != '\0' && *endp != 'f' && *endp != 'F') {
        return false;
    }
    /* Reinterpret float bits as uint32 */
    union { float f; uint32_t u; } conv;
    conv.f = val;
    *bits = conv.u;
    return true;
}

static char *trim(char *str) {
    while (isspace(*str)) str++;
    if (*str == '\0') return str;
    
    char *end = str + strlen(str) - 1;
    while (end > str && isspace(*end)) end--;
    *(end + 1) = '\0';
    
    return str;
}

/*---------------------------------------------------------------------------
 * Instruction Encoding
 *---------------------------------------------------------------------------*/

uint64_t milo_encode_inst(const milo_inst_t *inst) {
    uint64_t word = 0;
    
    word |= ((uint64_t)inst->opcode << 56);
    word |= ((uint64_t)inst->rd << 48);
    word |= ((uint64_t)inst->rs1 << 40);
    word |= ((uint64_t)inst->rs2 << 32);
    
    /* Default predicate guard to 0x7 (P7 = always true) if not specified */
    uint8_t pred = inst->pred ? inst->pred : 0x7;
    
    /* Instruction format: {op[8], rd[8], rs1[8], rs2[8], pg[4], rs3[8], imm[20]}
     * For 2-operand instructions without rs3, the format uses full 32-bit lower:
     *   {op[8], rd[8], rs1[8], rs2[8], pg[4], unused[8], imm[20]}
     * But the SM extracts pg from [31:28] always, so we embed it there */
    
    if (inst->has_rs3) {
        /* 3-operand format */
        word |= ((uint64_t)(pred & 0x0F) << 28);
        word |= ((uint64_t)inst->rs3 << 20);
        word |= (inst->imm & 0xFFFFF);
    } else {
        /* 2-operand format - put pg at [31:28], imm at [19:0] */
        word |= ((uint64_t)(pred & 0x0F) << 28);
        word |= (inst->imm & 0xFFFFF);
    }
    
    return word;
}

void milo_decode_inst(uint64_t word, milo_inst_t *inst) {
    inst->opcode = (word >> 56) & 0xFF;
    inst->rd     = (word >> 48) & 0xFF;
    inst->rs1    = (word >> 40) & 0xFF;
    inst->rs2    = (word >> 32) & 0xFF;
    inst->imm    = word & 0xFFFFFFFF;
    inst->pred   = 0;
    inst->rs3    = 0;
    inst->has_imm = false;
    inst->has_rs3 = false;
}

/*---------------------------------------------------------------------------
 * Assembler Implementation
 *---------------------------------------------------------------------------*/

void milo_asm_init(milo_asm_t *as) {
    memset(as, 0, sizeof(*as));
}

/* Forward declaration for unresolved labels */
typedef struct {
    uint32_t address;
    char     label[64];
    int      line;
} unresolved_t;

static unresolved_t unresolved[MILO_MAX_LABELS];
static int unresolved_count = 0;

bool milo_asm_line(milo_asm_t *as, const char *line, int line_num) {
    char buf[MILO_MAX_LINE_LEN];
    strncpy(buf, line, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    
    /* Remove comments */
    char *comment = strchr(buf, ';');
    if (comment) *comment = '\0';
    comment = strchr(buf, '#');
    if (comment) *comment = '\0';
    
    char *p = trim(buf);
    if (*p == '\0') return true;  /* Empty line */
    
    /* Check for label */
    char *colon = strchr(p, ':');
    if (colon) {
        *colon = '\0';
        char *label = trim(p);
        
        if (as->label_count >= MILO_MAX_LABELS) {
            snprintf(as->error, sizeof(as->error), "Too many labels");
            as->error_line = line_num;
            return false;
        }
        
        strncpy(as->labels[as->label_count].name, label, 63);
        as->labels[as->label_count].address = as->code_size;
        as->label_count++;
        
        p = trim(colon + 1);
        if (*p == '\0') return true;  /* Label only line */
    }
    
    /* Parse mnemonic */
    char mnemonic[32];
    int i = 0;
    while (*p && !isspace(*p) && i < 31) {
        mnemonic[i++] = tolower(*p++);
    }
    mnemonic[i] = '\0';
    
    const opcode_entry_t *op = find_opcode(mnemonic);
    if (!op) {
        snprintf(as->error, sizeof(as->error), "Unknown instruction: %s", mnemonic);
        as->error_line = line_num;
        return false;
    }
    
    /* Skip whitespace */
    while (isspace(*p)) p++;
    
    /* Parse operands */
    char *operands[4] = {NULL, NULL, NULL, NULL};
    int num_operands = 0;
    
    if (*p) {
        operands[num_operands++] = p;
        while (*p) {
            if (*p == ',') {
                *p = '\0';
                p++;
                while (isspace(*p)) p++;
                if (num_operands < 4) {
                    operands[num_operands++] = p;
                }
            } else {
                p++;
            }
        }
    }
    
    /* Trim operands */
    for (int j = 0; j < num_operands; j++) {
        operands[j] = trim(operands[j]);
    }
    
    /* Build instruction */
    milo_inst_t inst = {0};
    inst.opcode = op->opcode;
    
    const char *fmt = op->format;
    int op_idx = 0;
    
    for (int j = 0; fmt[j] && op_idx < num_operands; j++) {
        const char *arg = operands[op_idx++];
        
        switch (fmt[j]) {
            case 'r':  /* Register */
                {
                    uint8_t reg;
                    if (!parse_register(arg, &reg)) {
                        snprintf(as->error, sizeof(as->error), 
                                "Invalid register: %s", arg);
                        as->error_line = line_num;
                        return false;
                    }
                    if (j == 0) inst.rd = reg;
                    else if (j == 1) inst.rs1 = reg;
                    else if (j == 2) inst.rs2 = reg;
                    else inst.rs3 = reg, inst.has_rs3 = true;
                }
                break;
                
            case 'i':  /* Immediate */
                {
                    uint32_t imm;
                    /* Try float first if it has a decimal point */
                    if (strchr(arg, '.')) {
                        if (!parse_float(arg, &imm)) {
                            snprintf(as->error, sizeof(as->error),
                                    "Invalid float: %s", arg);
                            as->error_line = line_num;
                            return false;
                        }
                    } else if (!parse_immediate(arg, &imm)) {
                        snprintf(as->error, sizeof(as->error),
                                "Invalid immediate: %s", arg);
                        as->error_line = line_num;
                        return false;
                    }
                    inst.imm = imm;
                    inst.has_imm = true;
                }
                break;
                
            case 'l':  /* Label */
                {
                    /* Store for later resolution */
                    if (unresolved_count >= MILO_MAX_LABELS) {
                        snprintf(as->error, sizeof(as->error), 
                                "Too many unresolved labels");
                        as->error_line = line_num;
                        return false;
                    }
                    unresolved[unresolved_count].address = as->code_size;
                    strncpy(unresolved[unresolved_count].label, arg, 63);
                    unresolved[unresolved_count].line = line_num;
                    unresolved_count++;
                    inst.imm = 0;  /* Placeholder */
                    inst.has_imm = true;
                }
                break;
        }
    }
    
    /* Emit instruction */
    if (as->code_size >= MILO_MAX_CODE_SIZE) {
        snprintf(as->error, sizeof(as->error), "Code too large");
        as->error_line = line_num;
        return false;
    }
    
    as->code[as->code_size++] = milo_encode_inst(&inst);
    return true;
}

bool milo_asm_resolve(milo_asm_t *as) {
    for (int i = 0; i < unresolved_count; i++) {
        bool found = false;
        for (uint32_t j = 0; j < as->label_count; j++) {
            if (strcmp(unresolved[i].label, as->labels[j].name) == 0) {
                /* Patch the instruction */
                uint64_t word = as->code[unresolved[i].address];
                word = (word & 0xFFFFFFFF00000000ULL) | as->labels[j].address;
                as->code[unresolved[i].address] = word;
                found = true;
                break;
            }
        }
        if (!found) {
            snprintf(as->error, sizeof(as->error), 
                    "Undefined label: %s", unresolved[i].label);
            as->error_line = unresolved[i].line;
            return false;
        }
    }
    unresolved_count = 0;
    return true;
}

bool milo_asm_source(milo_asm_t *as, const char *source) {
    const char *p = source;
    char line[MILO_MAX_LINE_LEN];
    int line_num = 1;
    
    unresolved_count = 0;
    
    while (*p) {
        /* Extract line */
        int i = 0;
        while (*p && *p != '\n' && i < MILO_MAX_LINE_LEN - 1) {
            line[i++] = *p++;
        }
        line[i] = '\0';
        if (*p == '\n') p++;
        
        if (!milo_asm_line(as, line, line_num)) {
            return false;
        }
        line_num++;
    }
    
    return milo_asm_resolve(as);
}

const uint64_t *milo_asm_get_code(const milo_asm_t *as, uint32_t *size) {
    if (size) *size = as->code_size;
    return as->code;
}

const char *milo_asm_get_error(const milo_asm_t *as) {
    if (as->error[0]) {
        static char buf[512];
        snprintf(buf, sizeof(buf), "Line %d: %s", as->error_line, as->error);
        return buf;
    }
    return NULL;
}

/*---------------------------------------------------------------------------
 * Disassembler
 *---------------------------------------------------------------------------*/

void milo_disasm_inst(uint64_t word, char *buf, size_t buf_size) {
    milo_inst_t inst;
    milo_decode_inst(word, &inst);
    
    const char *name = "???";
    for (int i = 0; opcode_table[i].name != NULL; i++) {
        if (opcode_table[i].opcode == inst.opcode) {
            name = opcode_table[i].name;
            break;
        }
    }
    
    snprintf(buf, buf_size, "%-6s r%d, r%d, r%d, 0x%08X",
            name, inst.rd, inst.rs1, inst.rs2, inst.imm);
}

void milo_disasm_program(const uint64_t *code, uint32_t size, FILE *out) {
    char buf[128];
    for (uint32_t i = 0; i < size; i++) {
        milo_disasm_inst(code[i], buf, sizeof(buf));
        fprintf(out, "%04X: %016llX  %s\n", i, 
                (unsigned long long)code[i], buf);
    }
}
