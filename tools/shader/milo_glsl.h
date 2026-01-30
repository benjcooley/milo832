/*
 * milo_glsl.h
 * Milo832 GLSL ES 3.0 Subset Compiler - Header
 * 
 * Compiles a subset of GLSL ES 3.0 to Milo832 assembly.
 * 
 * Supported features:
 *   - Basic types: float, int, vec2, vec3, vec4, mat3, mat4
 *   - Uniforms, inputs (in), outputs (out)
 *   - Arithmetic: +, -, *, /
 *   - Built-in functions: sin, cos, sqrt, abs, min, max, dot, normalize, etc.
 *   - Texture sampling: texture()
 *   - Control flow: if/else, for loops
 *   - Swizzling: .xyzw, .rgba
 */

#ifndef MILO_GLSL_H
#define MILO_GLSL_H

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

/*---------------------------------------------------------------------------
 * Token Types
 *---------------------------------------------------------------------------*/

typedef enum {
    TOK_EOF,
    TOK_ERROR,
    
    /* Literals */
    TOK_INT_LIT,
    TOK_FLOAT_LIT,
    TOK_IDENT,
    
    /* Keywords */
    TOK_VOID,
    TOK_FLOAT,
    TOK_INT,
    TOK_VEC2,
    TOK_VEC3,
    TOK_VEC4,
    TOK_MAT3,
    TOK_MAT4,
    TOK_SAMPLER2D,
    TOK_IN,
    TOK_OUT,
    TOK_UNIFORM,
    TOK_CONST,
    TOK_IF,
    TOK_ELSE,
    TOK_FOR,
    TOK_WHILE,
    TOK_RETURN,
    TOK_BREAK,
    TOK_CONTINUE,
    TOK_DISCARD,
    TOK_TRUE,
    TOK_FALSE,
    TOK_PRECISION,
    TOK_HIGHP,
    TOK_MEDIUMP,
    TOK_LOWP,
    TOK_VERSION,
    TOK_LAYOUT,
    TOK_LOCATION,
    
    /* Operators */
    TOK_PLUS,
    TOK_MINUS,
    TOK_STAR,
    TOK_SLASH,
    TOK_PERCENT,
    TOK_EQ,
    TOK_NE,
    TOK_LT,
    TOK_GT,
    TOK_LE,
    TOK_GE,
    TOK_AND,
    TOK_OR,
    TOK_NOT,
    TOK_ASSIGN,
    TOK_PLUS_ASSIGN,
    TOK_MINUS_ASSIGN,
    TOK_STAR_ASSIGN,
    TOK_SLASH_ASSIGN,
    TOK_INC,
    TOK_DEC,
    
    /* Punctuation */
    TOK_LPAREN,
    TOK_RPAREN,
    TOK_LBRACE,
    TOK_RBRACE,
    TOK_LBRACKET,
    TOK_RBRACKET,
    TOK_COMMA,
    TOK_SEMICOLON,
    TOK_DOT,
    TOK_QUESTION,
    TOK_COLON,
    TOK_HASH,
} milo_token_type_t;

typedef struct {
    milo_token_type_t type;
    const char       *start;
    int               length;
    int               line;
    union {
        int32_t  int_val;
        float    float_val;
    };
} milo_token_t;

/*---------------------------------------------------------------------------
 * AST Node Types
 *---------------------------------------------------------------------------*/

typedef enum {
    /* Types */
    TYPE_VOID,
    TYPE_FLOAT,
    TYPE_INT,
    TYPE_VEC2,
    TYPE_VEC3,
    TYPE_VEC4,
    TYPE_MAT3,
    TYPE_MAT4,
    TYPE_SAMPLER2D,
} milo_type_t;

typedef enum {
    NODE_PROGRAM,
    NODE_FUNCTION,
    NODE_VAR_DECL,
    NODE_PARAM,
    NODE_BLOCK,
    NODE_IF,
    NODE_FOR,
    NODE_WHILE,
    NODE_RETURN,
    NODE_DISCARD,
    NODE_BREAK,
    NODE_CONTINUE,
    NODE_EXPR_STMT,
    NODE_BINARY,
    NODE_UNARY,
    NODE_CALL,
    NODE_INDEX,
    NODE_MEMBER,
    NODE_IDENT,
    NODE_INT_LIT,
    NODE_FLOAT_LIT,
    NODE_ASSIGN,
    NODE_TERNARY,
    NODE_CONSTRUCTOR,
} milo_node_type_t;

typedef struct milo_node milo_node_t;

struct milo_node {
    milo_node_type_t type;
    milo_type_t      data_type;
    int              line;
    
    union {
        /* Literals */
        int32_t  int_val;
        float    float_val;
        
        /* Identifier */
        struct {
            char name[64];
        } ident;
        
        /* Variable declaration */
        struct {
            char        name[64];
            milo_type_t var_type;
            bool        is_uniform;
            bool        is_in;
            bool        is_out;
            bool        is_const;
            int         location;
            milo_node_t *init;
        } var_decl;
        
        /* Function */
        struct {
            char        name[64];
            milo_type_t return_type;
            milo_node_t *params;
            int         param_count;
            milo_node_t *body;
        } func;
        
        /* Binary expression */
        struct {
            int         op;  /* Token type */
            milo_node_t *left;
            milo_node_t *right;
        } binary;
        
        /* Unary expression */
        struct {
            int         op;
            milo_node_t *operand;
            bool        prefix;
        } unary;
        
        /* Function call */
        struct {
            char        name[64];
            milo_node_t *args;
            int         arg_count;
        } call;
        
        /* Member access (swizzle) */
        struct {
            milo_node_t *object;
            char        member[8];
        } member;
        
        /* Index access */
        struct {
            milo_node_t *object;
            milo_node_t *index;
        } index;
        
        /* Block */
        struct {
            milo_node_t *stmts;
            int         stmt_count;
        } block;
        
        /* If statement */
        struct {
            milo_node_t *cond;
            milo_node_t *then_branch;
            milo_node_t *else_branch;
        } if_stmt;
        
        /* For loop */
        struct {
            milo_node_t *init;
            milo_node_t *cond;
            milo_node_t *post;
            milo_node_t *body;
        } for_stmt;
        
        /* While loop */
        struct {
            milo_node_t *cond;
            milo_node_t *body;
        } while_stmt;
        
        /* Return */
        struct {
            milo_node_t *value;
        } ret;
        
        /* Assignment */
        struct {
            milo_node_t *target;
            milo_node_t *value;
            int         op;  /* = += -= etc */
        } assign;
        
        /* Ternary */
        struct {
            milo_node_t *cond;
            milo_node_t *then_expr;
            milo_node_t *else_expr;
        } ternary;
        
        /* Type constructor: vec3(x, y, z) */
        struct {
            milo_type_t con_type;
            milo_node_t *args;
            int         arg_count;
        } constructor;
    };
    
    /* For lists (params, args, stmts) */
    milo_node_t *next;
};

/*---------------------------------------------------------------------------
 * Symbol Table
 *---------------------------------------------------------------------------*/

typedef struct {
    char        name[64];
    milo_type_t type;
    int         reg;        /* Register number (-1 if not allocated) */
    bool        is_uniform;
    bool        is_in;
    bool        is_out;
    int         location;
    int         scope;
} milo_symbol_t;

#define MILO_MAX_SYMBOLS 256

typedef struct {
    milo_symbol_t symbols[MILO_MAX_SYMBOLS];
    int           count;
    int           current_scope;
} milo_symtab_t;

/*---------------------------------------------------------------------------
 * Compiler State
 *---------------------------------------------------------------------------*/

#define MILO_MAX_CODE 4096
#define MILO_MAX_ERRORS 32
#define MILO_MAX_CONSTANTS 256
#define MILO_CONST_BASE_ADDR 0x1000  /* Memory address for constant table */

typedef struct {
    /* Source */
    const char *source;
    const char *current;
    int         line;
    
    /* Lexer */
    milo_token_t current_token;
    milo_token_t peek_token;
    
    /* AST */
    milo_node_t *ast;
    
    /* Symbol table */
    milo_symtab_t symtab;
    
    /* Code generation */
    char        code[MILO_MAX_CODE][128];
    int         code_count;
    int         next_reg;
    int         next_label;
    
    /* Constant table - float constants loaded from memory */
    uint32_t    constants[MILO_MAX_CONSTANTS];
    int         const_count;
    
    /* Errors */
    char        errors[MILO_MAX_ERRORS][256];
    int         error_count;
    
    /* Shader type */
    bool        is_vertex;
    bool        is_fragment;
} milo_compiler_t;

/*---------------------------------------------------------------------------
 * API
 *---------------------------------------------------------------------------*/

/* Initialize compiler */
void milo_glsl_init(milo_compiler_t *c);

/* Compile GLSL source to assembly */
bool milo_glsl_compile(milo_compiler_t *c, const char *source, bool is_vertex);

/* Get generated assembly */
const char *milo_glsl_get_asm(milo_compiler_t *c);

/* Get error messages */
int milo_glsl_get_errors(milo_compiler_t *c, const char **errors, int max);

/* Free compiler resources */
void milo_glsl_free(milo_compiler_t *c);

/* Dump AST (for debugging) */
void milo_glsl_dump_ast(milo_compiler_t *c, FILE *out);

#endif /* MILO_GLSL_H */
