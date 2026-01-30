/*
 * milo_glsl.c
 * Milo832 GLSL ES 3.0 Subset Compiler - Implementation
 */

#include "milo_glsl.h"
#include "milo_asm.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>

/*---------------------------------------------------------------------------
 * Error Reporting
 *---------------------------------------------------------------------------*/

static void error(milo_compiler_t *c, const char *fmt, ...) {
    if (c->error_count >= MILO_MAX_ERRORS) return;
    
    va_list args;
    va_start(args, fmt);
    char buf[200];
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    
    snprintf(c->errors[c->error_count], 256, "Line %d: %s", c->line, buf);
    c->error_count++;
}

/*---------------------------------------------------------------------------
 * Lexer
 *---------------------------------------------------------------------------*/

static bool is_digit(char c) { return c >= '0' && c <= '9'; }
static bool is_alpha(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static bool is_alnum(char c) { return is_alpha(c) || is_digit(c); }

static void skip_whitespace(milo_compiler_t *c) {
    while (*c->current) {
        if (*c->current == ' ' || *c->current == '\t' || *c->current == '\r') {
            c->current++;
        } else if (*c->current == '\n') {
            c->line++;
            c->current++;
        } else if (c->current[0] == '/' && c->current[1] == '/') {
            while (*c->current && *c->current != '\n') c->current++;
        } else if (c->current[0] == '/' && c->current[1] == '*') {
            c->current += 2;
            while (*c->current && !(c->current[0] == '*' && c->current[1] == '/')) {
                if (*c->current == '\n') c->line++;
                c->current++;
            }
            if (*c->current) c->current += 2;
        } else {
            break;
        }
    }
}

static milo_token_t make_token(milo_compiler_t *c, milo_token_type_t type, const char *start, int len) {
    milo_token_t tok;
    tok.type = type;
    tok.start = start;
    tok.length = len;
    tok.line = c->line;
    tok.int_val = 0;
    return tok;
}

static milo_token_type_t check_keyword(const char *start, int len) {
    static const struct { const char *kw; milo_token_type_t type; } keywords[] = {
        {"void", TOK_VOID}, {"float", TOK_FLOAT}, {"int", TOK_INT},
        {"vec2", TOK_VEC2}, {"vec3", TOK_VEC3}, {"vec4", TOK_VEC4},
        {"mat3", TOK_MAT3}, {"mat4", TOK_MAT4}, {"sampler2D", TOK_SAMPLER2D},
        {"in", TOK_IN}, {"out", TOK_OUT}, {"uniform", TOK_UNIFORM},
        {"const", TOK_CONST}, {"if", TOK_IF}, {"else", TOK_ELSE},
        {"for", TOK_FOR}, {"while", TOK_WHILE}, {"return", TOK_RETURN},
        {"break", TOK_BREAK}, {"continue", TOK_CONTINUE}, {"discard", TOK_DISCARD},
        {"true", TOK_TRUE}, {"false", TOK_FALSE},
        {"precision", TOK_PRECISION}, {"highp", TOK_HIGHP},
        {"mediump", TOK_MEDIUMP}, {"lowp", TOK_LOWP},
        {"layout", TOK_LAYOUT}, {"location", TOK_LOCATION},
        {NULL, TOK_EOF}
    };
    
    for (int i = 0; keywords[i].kw; i++) {
        if ((int)strlen(keywords[i].kw) == len && 
            strncmp(start, keywords[i].kw, len) == 0) {
            return keywords[i].type;
        }
    }
    return TOK_IDENT;
}

static milo_token_t scan_token(milo_compiler_t *c) {
    skip_whitespace(c);
    
    if (*c->current == '\0') {
        return make_token(c, TOK_EOF, c->current, 0);
    }
    
    const char *start = c->current;
    char ch = *c->current++;
    
    /* Single-char tokens */
    switch (ch) {
        case '(': return make_token(c, TOK_LPAREN, start, 1);
        case ')': return make_token(c, TOK_RPAREN, start, 1);
        case '{': return make_token(c, TOK_LBRACE, start, 1);
        case '}': return make_token(c, TOK_RBRACE, start, 1);
        case '[': return make_token(c, TOK_LBRACKET, start, 1);
        case ']': return make_token(c, TOK_RBRACKET, start, 1);
        case ',': return make_token(c, TOK_COMMA, start, 1);
        case ';': return make_token(c, TOK_SEMICOLON, start, 1);
        case '.': return make_token(c, TOK_DOT, start, 1);
        case '?': return make_token(c, TOK_QUESTION, start, 1);
        case ':': return make_token(c, TOK_COLON, start, 1);
        case '#': return make_token(c, TOK_HASH, start, 1);
    }
    
    /* Two-char tokens */
    if (ch == '+') {
        if (*c->current == '+') { c->current++; return make_token(c, TOK_INC, start, 2); }
        if (*c->current == '=') { c->current++; return make_token(c, TOK_PLUS_ASSIGN, start, 2); }
        return make_token(c, TOK_PLUS, start, 1);
    }
    if (ch == '-') {
        if (*c->current == '-') { c->current++; return make_token(c, TOK_DEC, start, 2); }
        if (*c->current == '=') { c->current++; return make_token(c, TOK_MINUS_ASSIGN, start, 2); }
        return make_token(c, TOK_MINUS, start, 1);
    }
    if (ch == '*') {
        if (*c->current == '=') { c->current++; return make_token(c, TOK_STAR_ASSIGN, start, 2); }
        return make_token(c, TOK_STAR, start, 1);
    }
    if (ch == '/') {
        if (*c->current == '=') { c->current++; return make_token(c, TOK_SLASH_ASSIGN, start, 2); }
        return make_token(c, TOK_SLASH, start, 1);
    }
    if (ch == '%') return make_token(c, TOK_PERCENT, start, 1);
    if (ch == '=') {
        if (*c->current == '=') { c->current++; return make_token(c, TOK_EQ, start, 2); }
        return make_token(c, TOK_ASSIGN, start, 1);
    }
    if (ch == '!') {
        if (*c->current == '=') { c->current++; return make_token(c, TOK_NE, start, 2); }
        return make_token(c, TOK_NOT, start, 1);
    }
    if (ch == '<') {
        if (*c->current == '=') { c->current++; return make_token(c, TOK_LE, start, 2); }
        return make_token(c, TOK_LT, start, 1);
    }
    if (ch == '>') {
        if (*c->current == '=') { c->current++; return make_token(c, TOK_GE, start, 2); }
        return make_token(c, TOK_GT, start, 1);
    }
    if (ch == '&' && *c->current == '&') { c->current++; return make_token(c, TOK_AND, start, 2); }
    if (ch == '|' && *c->current == '|') { c->current++; return make_token(c, TOK_OR, start, 2); }
    
    /* Numbers */
    if (is_digit(ch)) {
        while (is_digit(*c->current)) c->current++;
        bool is_float = false;
        if (*c->current == '.') {
            is_float = true;
            c->current++;
            while (is_digit(*c->current)) c->current++;
        }
        if (*c->current == 'e' || *c->current == 'E') {
            is_float = true;
            c->current++;
            if (*c->current == '+' || *c->current == '-') c->current++;
            while (is_digit(*c->current)) c->current++;
        }
        if (*c->current == 'f' || *c->current == 'F') c->current++;
        
        milo_token_t tok = make_token(c, is_float ? TOK_FLOAT_LIT : TOK_INT_LIT, 
                                      start, (int)(c->current - start));
        if (is_float) {
            tok.float_val = strtof(start, NULL);
        } else {
            tok.int_val = (int32_t)strtol(start, NULL, 0);
        }
        return tok;
    }
    
    /* Identifiers/keywords */
    if (is_alpha(ch)) {
        while (is_alnum(*c->current)) c->current++;
        int len = (int)(c->current - start);
        milo_token_type_t type = check_keyword(start, len);
        return make_token(c, type, start, len);
    }
    
    error(c, "Unexpected character: '%c'", ch);
    return make_token(c, TOK_ERROR, start, 1);
}

static void advance(milo_compiler_t *c) {
    c->current_token = c->peek_token;
    c->peek_token = scan_token(c);
}

static bool check(milo_compiler_t *c, milo_token_type_t type) {
    return c->current_token.type == type;
}

static bool match(milo_compiler_t *c, milo_token_type_t type) {
    if (!check(c, type)) return false;
    advance(c);
    return true;
}

static bool expect(milo_compiler_t *c, milo_token_type_t type, const char *msg) {
    if (check(c, type)) {
        advance(c);
        return true;
    }
    error(c, "Expected %s", msg);
    return false;
}

/*---------------------------------------------------------------------------
 * AST Allocation
 *---------------------------------------------------------------------------*/

static milo_node_t *alloc_node(milo_compiler_t *c, milo_node_type_t type) {
    milo_node_t *node = calloc(1, sizeof(milo_node_t));
    if (!node) {
        error(c, "Out of memory");
        return NULL;
    }
    node->type = type;
    node->line = c->current_token.line;
    return node;
}

/*---------------------------------------------------------------------------
 * Parser - Forward Declarations
 *---------------------------------------------------------------------------*/

static milo_node_t *parse_expr(milo_compiler_t *c);
static milo_node_t *parse_stmt(milo_compiler_t *c);
static milo_node_t *parse_block(milo_compiler_t *c);

/*---------------------------------------------------------------------------
 * Parser - Types
 *---------------------------------------------------------------------------*/

static milo_type_t parse_type(milo_compiler_t *c) {
    milo_token_type_t t = c->current_token.type;
    advance(c);
    
    switch (t) {
        case TOK_VOID:      return TYPE_VOID;
        case TOK_FLOAT:     return TYPE_FLOAT;
        case TOK_INT:       return TYPE_INT;
        case TOK_VEC2:      return TYPE_VEC2;
        case TOK_VEC3:      return TYPE_VEC3;
        case TOK_VEC4:      return TYPE_VEC4;
        case TOK_MAT3:      return TYPE_MAT3;
        case TOK_MAT4:      return TYPE_MAT4;
        case TOK_SAMPLER2D: return TYPE_SAMPLER2D;
        default:
            error(c, "Expected type");
            return TYPE_VOID;
    }
}

static bool is_type_token(milo_token_type_t t) {
    return t == TOK_VOID || t == TOK_FLOAT || t == TOK_INT ||
           t == TOK_VEC2 || t == TOK_VEC3 || t == TOK_VEC4 ||
           t == TOK_MAT3 || t == TOK_MAT4 || t == TOK_SAMPLER2D;
}

/*---------------------------------------------------------------------------
 * Parser - Expressions
 *---------------------------------------------------------------------------*/

static milo_node_t *parse_primary(milo_compiler_t *c) {
    if (check(c, TOK_INT_LIT)) {
        milo_node_t *node = alloc_node(c, NODE_INT_LIT);
        node->int_val = c->current_token.int_val;
        node->data_type = TYPE_INT;
        advance(c);
        return node;
    }
    
    if (check(c, TOK_FLOAT_LIT)) {
        milo_node_t *node = alloc_node(c, NODE_FLOAT_LIT);
        node->float_val = c->current_token.float_val;
        node->data_type = TYPE_FLOAT;
        advance(c);
        return node;
    }
    
    if (check(c, TOK_TRUE) || check(c, TOK_FALSE)) {
        milo_node_t *node = alloc_node(c, NODE_INT_LIT);
        node->int_val = check(c, TOK_TRUE) ? 1 : 0;
        node->data_type = TYPE_INT;
        advance(c);
        return node;
    }
    
    /* Type constructor: vec3(x, y, z) */
    if (is_type_token(c->current_token.type) && c->current_token.type != TOK_VOID) {
        milo_type_t type = parse_type(c);
        if (!expect(c, TOK_LPAREN, "'('")) return NULL;
        
        milo_node_t *node = alloc_node(c, NODE_CONSTRUCTOR);
        node->constructor.con_type = type;
        node->data_type = type;
        
        milo_node_t **arg_tail = &node->constructor.args;
        while (!check(c, TOK_RPAREN) && !check(c, TOK_EOF)) {
            milo_node_t *arg = parse_expr(c);
            if (!arg) return NULL;
            *arg_tail = arg;
            arg_tail = &arg->next;
            node->constructor.arg_count++;
            if (!match(c, TOK_COMMA)) break;
        }
        
        expect(c, TOK_RPAREN, "')'");
        return node;
    }
    
    if (check(c, TOK_IDENT)) {
        char name[64];
        int len = c->current_token.length < 63 ? c->current_token.length : 63;
        strncpy(name, c->current_token.start, len);
        name[len] = '\0';
        advance(c);
        
        /* Function call */
        if (check(c, TOK_LPAREN)) {
            advance(c);
            milo_node_t *node = alloc_node(c, NODE_CALL);
            strcpy(node->call.name, name);
            
            milo_node_t **arg_tail = &node->call.args;
            while (!check(c, TOK_RPAREN) && !check(c, TOK_EOF)) {
                milo_node_t *arg = parse_expr(c);
                if (!arg) return NULL;
                *arg_tail = arg;
                arg_tail = &arg->next;
                node->call.arg_count++;
                if (!match(c, TOK_COMMA)) break;
            }
            
            expect(c, TOK_RPAREN, "')'");
            return node;
        }
        
        /* Simple identifier */
        milo_node_t *node = alloc_node(c, NODE_IDENT);
        strcpy(node->ident.name, name);
        return node;
    }
    
    if (match(c, TOK_LPAREN)) {
        milo_node_t *expr = parse_expr(c);
        expect(c, TOK_RPAREN, "')'");
        return expr;
    }
    
    error(c, "Expected expression");
    return NULL;
}

static milo_node_t *parse_postfix(milo_compiler_t *c) {
    milo_node_t *expr = parse_primary(c);
    if (!expr) return NULL;
    
    while (true) {
        if (match(c, TOK_DOT)) {
            /* Member/swizzle */
            if (!check(c, TOK_IDENT)) {
                error(c, "Expected member name");
                return NULL;
            }
            milo_node_t *node = alloc_node(c, NODE_MEMBER);
            node->member.object = expr;
            int len = c->current_token.length < 7 ? c->current_token.length : 7;
            strncpy(node->member.member, c->current_token.start, len);
            node->member.member[len] = '\0';
            advance(c);
            expr = node;
        } else if (match(c, TOK_LBRACKET)) {
            /* Array index */
            milo_node_t *node = alloc_node(c, NODE_INDEX);
            node->index.object = expr;
            node->index.index = parse_expr(c);
            expect(c, TOK_RBRACKET, "']'");
            expr = node;
        } else if (match(c, TOK_INC) || match(c, TOK_DEC)) {
            /* Post increment/decrement */
            milo_node_t *node = alloc_node(c, NODE_UNARY);
            node->unary.op = c->current_token.type == TOK_INC ? TOK_INC : TOK_DEC;
            node->unary.operand = expr;
            node->unary.prefix = false;
            expr = node;
        } else {
            break;
        }
    }
    
    return expr;
}

static milo_node_t *parse_unary(milo_compiler_t *c) {
    if (check(c, TOK_MINUS) || check(c, TOK_NOT) || check(c, TOK_INC) || check(c, TOK_DEC)) {
        int op = c->current_token.type;
        advance(c);
        milo_node_t *node = alloc_node(c, NODE_UNARY);
        node->unary.op = op;
        node->unary.operand = parse_unary(c);
        node->unary.prefix = true;
        return node;
    }
    return parse_postfix(c);
}

static milo_node_t *parse_binary(milo_compiler_t *c, int min_prec);

static int get_precedence(milo_token_type_t type) {
    switch (type) {
        case TOK_OR:      return 1;
        case TOK_AND:     return 2;
        case TOK_EQ:
        case TOK_NE:      return 3;
        case TOK_LT:
        case TOK_GT:
        case TOK_LE:
        case TOK_GE:      return 4;
        case TOK_PLUS:
        case TOK_MINUS:   return 5;
        case TOK_STAR:
        case TOK_SLASH:
        case TOK_PERCENT: return 6;
        default:          return 0;
    }
}

static milo_node_t *parse_binary(milo_compiler_t *c, int min_prec) {
    milo_node_t *left = parse_unary(c);
    if (!left) return NULL;
    
    while (true) {
        int prec = get_precedence(c->current_token.type);
        if (prec < min_prec) break;
        
        int op = c->current_token.type;
        advance(c);
        
        milo_node_t *right = parse_binary(c, prec + 1);
        if (!right) return NULL;
        
        milo_node_t *node = alloc_node(c, NODE_BINARY);
        node->binary.op = op;
        node->binary.left = left;
        node->binary.right = right;
        left = node;
    }
    
    return left;
}

static milo_node_t *parse_ternary(milo_compiler_t *c) {
    milo_node_t *cond = parse_binary(c, 1);
    if (!cond) return NULL;
    
    if (match(c, TOK_QUESTION)) {
        milo_node_t *node = alloc_node(c, NODE_TERNARY);
        node->ternary.cond = cond;
        node->ternary.then_expr = parse_expr(c);
        expect(c, TOK_COLON, "':'");
        node->ternary.else_expr = parse_ternary(c);
        return node;
    }
    
    return cond;
}

static milo_node_t *parse_assignment(milo_compiler_t *c) {
    milo_node_t *left = parse_ternary(c);
    if (!left) return NULL;
    
    if (check(c, TOK_ASSIGN) || check(c, TOK_PLUS_ASSIGN) || 
        check(c, TOK_MINUS_ASSIGN) || check(c, TOK_STAR_ASSIGN) ||
        check(c, TOK_SLASH_ASSIGN)) {
        int op = c->current_token.type;
        advance(c);
        milo_node_t *node = alloc_node(c, NODE_ASSIGN);
        node->assign.target = left;
        node->assign.op = op;
        node->assign.value = parse_assignment(c);
        return node;
    }
    
    return left;
}

static milo_node_t *parse_expr(milo_compiler_t *c) {
    return parse_assignment(c);
}

/*---------------------------------------------------------------------------
 * Parser - Statements
 *---------------------------------------------------------------------------*/

static milo_node_t *parse_var_decl(milo_compiler_t *c, bool is_uniform, bool is_in, bool is_out, int location) {
    milo_type_t type = parse_type(c);
    
    if (!check(c, TOK_IDENT)) {
        error(c, "Expected variable name");
        return NULL;
    }
    
    milo_node_t *node = alloc_node(c, NODE_VAR_DECL);
    int len = c->current_token.length < 63 ? c->current_token.length : 63;
    strncpy(node->var_decl.name, c->current_token.start, len);
    node->var_decl.name[len] = '\0';
    node->var_decl.var_type = type;
    node->var_decl.is_uniform = is_uniform;
    node->var_decl.is_in = is_in;
    node->var_decl.is_out = is_out;
    node->var_decl.location = location;
    advance(c);
    
    if (match(c, TOK_ASSIGN)) {
        node->var_decl.init = parse_expr(c);
    }
    
    expect(c, TOK_SEMICOLON, "';'");
    return node;
}

static milo_node_t *parse_if(milo_compiler_t *c) {
    milo_node_t *node = alloc_node(c, NODE_IF);
    
    expect(c, TOK_LPAREN, "'('");
    node->if_stmt.cond = parse_expr(c);
    expect(c, TOK_RPAREN, "')'");
    
    node->if_stmt.then_branch = parse_stmt(c);
    
    if (match(c, TOK_ELSE)) {
        node->if_stmt.else_branch = parse_stmt(c);
    }
    
    return node;
}

static milo_node_t *parse_for(milo_compiler_t *c) {
    milo_node_t *node = alloc_node(c, NODE_FOR);
    
    expect(c, TOK_LPAREN, "'('");
    
    /* Init */
    if (!check(c, TOK_SEMICOLON)) {
        if (is_type_token(c->current_token.type)) {
            node->for_stmt.init = parse_var_decl(c, false, false, false, -1);
        } else {
            node->for_stmt.init = alloc_node(c, NODE_EXPR_STMT);
            node->for_stmt.init->ret.value = parse_expr(c);
            expect(c, TOK_SEMICOLON, "';'");
        }
    } else {
        advance(c);
    }
    
    /* Condition */
    if (!check(c, TOK_SEMICOLON)) {
        node->for_stmt.cond = parse_expr(c);
    }
    expect(c, TOK_SEMICOLON, "';'");
    
    /* Post */
    if (!check(c, TOK_RPAREN)) {
        node->for_stmt.post = parse_expr(c);
    }
    expect(c, TOK_RPAREN, "')'");
    
    node->for_stmt.body = parse_stmt(c);
    return node;
}

static milo_node_t *parse_while(milo_compiler_t *c) {
    milo_node_t *node = alloc_node(c, NODE_WHILE);
    
    expect(c, TOK_LPAREN, "'('");
    node->while_stmt.cond = parse_expr(c);
    expect(c, TOK_RPAREN, "')'");
    node->while_stmt.body = parse_stmt(c);
    
    return node;
}

static milo_node_t *parse_block(milo_compiler_t *c) {
    milo_node_t *node = alloc_node(c, NODE_BLOCK);
    milo_node_t **tail = &node->block.stmts;
    
    while (!check(c, TOK_RBRACE) && !check(c, TOK_EOF)) {
        milo_node_t *stmt = parse_stmt(c);
        if (stmt) {
            *tail = stmt;
            tail = &stmt->next;
            node->block.stmt_count++;
        }
    }
    
    expect(c, TOK_RBRACE, "'}'");
    return node;
}

static milo_node_t *parse_stmt(milo_compiler_t *c) {
    if (match(c, TOK_LBRACE)) {
        return parse_block(c);
    }
    
    if (match(c, TOK_IF)) {
        return parse_if(c);
    }
    
    if (match(c, TOK_FOR)) {
        return parse_for(c);
    }
    
    if (match(c, TOK_WHILE)) {
        return parse_while(c);
    }
    
    if (match(c, TOK_RETURN)) {
        milo_node_t *node = alloc_node(c, NODE_RETURN);
        if (!check(c, TOK_SEMICOLON)) {
            node->ret.value = parse_expr(c);
        }
        expect(c, TOK_SEMICOLON, "';'");
        return node;
    }
    
    if (match(c, TOK_DISCARD)) {
        milo_node_t *node = alloc_node(c, NODE_DISCARD);
        expect(c, TOK_SEMICOLON, "';'");
        return node;
    }
    
    if (match(c, TOK_BREAK)) {
        milo_node_t *node = alloc_node(c, NODE_BREAK);
        expect(c, TOK_SEMICOLON, "';'");
        return node;
    }
    
    if (match(c, TOK_CONTINUE)) {
        milo_node_t *node = alloc_node(c, NODE_CONTINUE);
        expect(c, TOK_SEMICOLON, "';'");
        return node;
    }
    
    /* Variable declaration */
    if (is_type_token(c->current_token.type)) {
        return parse_var_decl(c, false, false, false, -1);
    }
    
    /* Expression statement */
    milo_node_t *node = alloc_node(c, NODE_EXPR_STMT);
    node->ret.value = parse_expr(c);
    expect(c, TOK_SEMICOLON, "';'");
    return node;
}

/*---------------------------------------------------------------------------
 * Parser - Top Level
 *---------------------------------------------------------------------------*/

static milo_node_t *parse_function(milo_compiler_t *c) {
    milo_type_t ret_type = parse_type(c);
    
    if (!check(c, TOK_IDENT)) {
        error(c, "Expected function name");
        return NULL;
    }
    
    milo_node_t *node = alloc_node(c, NODE_FUNCTION);
    int len = c->current_token.length < 63 ? c->current_token.length : 63;
    strncpy(node->func.name, c->current_token.start, len);
    node->func.name[len] = '\0';
    node->func.return_type = ret_type;
    advance(c);
    
    expect(c, TOK_LPAREN, "'('");
    
    /* Parameters */
    milo_node_t **param_tail = &node->func.params;
    while (!check(c, TOK_RPAREN) && !check(c, TOK_EOF)) {
        milo_type_t param_type = parse_type(c);
        
        if (!check(c, TOK_IDENT)) {
            error(c, "Expected parameter name");
            return NULL;
        }
        
        milo_node_t *param = alloc_node(c, NODE_PARAM);
        len = c->current_token.length < 63 ? c->current_token.length : 63;
        strncpy(param->var_decl.name, c->current_token.start, len);
        param->var_decl.name[len] = '\0';
        param->var_decl.var_type = param_type;
        advance(c);
        
        *param_tail = param;
        param_tail = &param->next;
        node->func.param_count++;
        
        if (!match(c, TOK_COMMA)) break;
    }
    
    expect(c, TOK_RPAREN, "')'");
    expect(c, TOK_LBRACE, "'{'");
    
    node->func.body = parse_block(c);
    return node;
}

static void parse_program(milo_compiler_t *c) {
    c->ast = alloc_node(c, NODE_PROGRAM);
    milo_node_t **tail = &c->ast->block.stmts;
    
    while (!check(c, TOK_EOF)) {
        milo_node_t *decl = NULL;
        int location = -1;
        
        /* Skip #version and precision */
        if (match(c, TOK_HASH)) {
            /* Skip entire preprocessor line */
            int start_line = c->current_token.line;
            while (!check(c, TOK_EOF) && c->current_token.line == start_line) {
                advance(c);
            }
            continue;
        }
        
        if (match(c, TOK_PRECISION)) {
            /* precision highp float; */
            advance(c);  /* highp/mediump/lowp */
            advance(c);  /* type */
            expect(c, TOK_SEMICOLON, "';'");
            continue;
        }
        
        /* layout(location = N) */
        if (match(c, TOK_LAYOUT)) {
            expect(c, TOK_LPAREN, "'('");
            if (match(c, TOK_LOCATION)) {
                expect(c, TOK_ASSIGN, "'='");
                if (check(c, TOK_INT_LIT)) {
                    location = c->current_token.int_val;
                    advance(c);
                }
            }
            expect(c, TOK_RPAREN, "')'");
        }
        
        /* Storage qualifiers */
        bool is_uniform = match(c, TOK_UNIFORM);
        bool is_in = match(c, TOK_IN);
        bool is_out = match(c, TOK_OUT);
        bool is_const = match(c, TOK_CONST);
        (void)is_const;  /* TODO: handle const */
        
        if (is_type_token(c->current_token.type)) {
            /* Check if function or variable */
            milo_token_t saved_cur = c->current_token;
            milo_token_t saved_peek = c->peek_token;
            const char *saved_pos = c->current;
            int saved_line = c->line;
            
            parse_type(c);
            bool is_func = false;
            if (check(c, TOK_IDENT)) {
                advance(c);
                is_func = check(c, TOK_LPAREN);
            }
            
            /* Restore */
            c->current_token = saved_cur;
            c->peek_token = saved_peek;
            c->current = saved_pos;
            c->line = saved_line;
            
            if (is_func && !is_uniform && !is_in && !is_out) {
                decl = parse_function(c);
            } else {
                decl = parse_var_decl(c, is_uniform, is_in, is_out, location);
            }
        } else {
            error(c, "Expected declaration");
            advance(c);
            continue;
        }
        
        if (decl) {
            *tail = decl;
            tail = &decl->next;
            c->ast->block.stmt_count++;
        }
    }
}

/*---------------------------------------------------------------------------
 * Code Generation
 *---------------------------------------------------------------------------*/

static void emit(milo_compiler_t *c, const char *fmt, ...) {
    if (c->code_count >= MILO_MAX_CODE) {
        error(c, "Code too large");
        return;
    }
    va_list args;
    va_start(args, fmt);
    vsnprintf(c->code[c->code_count], 128, fmt, args);
    va_end(args);
    c->code_count++;
}

static int alloc_reg(milo_compiler_t *c) {
    return c->next_reg++;
}

static int alloc_label(milo_compiler_t *c) {
    return c->next_label++;
}

/* Add a constant to the constant table and return its memory address */
static int add_constant(milo_compiler_t *c, uint32_t value) {
    /* Check if constant already exists */
    for (int i = 0; i < c->const_count; i++) {
        if (c->constants[i] == value) {
            return MILO_CONST_BASE_ADDR + (i * 4);
        }
    }
    /* Add new constant */
    if (c->const_count >= MILO_MAX_CONSTANTS) {
        error(c, "Too many constants");
        return MILO_CONST_BASE_ADDR;
    }
    int addr = MILO_CONST_BASE_ADDR + (c->const_count * 4);
    c->constants[c->const_count++] = value;
    return addr;
}

static int type_size(milo_type_t t) {
    switch (t) {
        case TYPE_FLOAT:
        case TYPE_INT:      return 1;
        case TYPE_VEC2:     return 2;
        case TYPE_VEC3:     return 3;
        case TYPE_VEC4:     return 4;
        case TYPE_MAT3:     return 9;
        case TYPE_MAT4:     return 16;
        default:            return 1;
    }
}

/* Forward declaration */
static int gen_expr(milo_compiler_t *c, milo_node_t *node);
static void gen_stmt(milo_compiler_t *c, milo_node_t *node);

static int gen_expr(milo_compiler_t *c, milo_node_t *node) {
    if (!node) return -1;
    
    switch (node->type) {
        case NODE_INT_LIT: {
            int r = alloc_reg(c);
            int32_t val = node->int_val;
            /* Check if value fits in 20-bit signed immediate (-524288 to 524287) */
            if (val >= -524288 && val <= 524287) {
                emit(c, "    addi r%d, r0, %d", r, val);
            } else {
                /* Load from constant table */
                int addr = add_constant(c, (uint32_t)val);
                emit(c, "    ldr r%d, r0, %d  ; int %d", r, addr, val);
            }
            return r;
        }
        
        case NODE_FLOAT_LIT: {
            int r = alloc_reg(c);
            union { float f; uint32_t u; } conv;
            conv.f = node->float_val;
            /* Float constants must be loaded from constant table (32-bit values) */
            int addr = add_constant(c, conv.u);
            emit(c, "    ldr r%d, r0, %d  ; %.6f", r, addr, node->float_val);
            return r;
        }
        
        case NODE_IDENT: {
            /* Look up in symbol table */
            for (int i = 0; i < c->symtab.count; i++) {
                if (strcmp(c->symtab.symbols[i].name, node->ident.name) == 0) {
                    return c->symtab.symbols[i].reg;
                }
            }
            error(c, "Undefined variable: %s", node->ident.name);
            return alloc_reg(c);
        }
        
        case NODE_BINARY: {
            int left = gen_expr(c, node->binary.left);
            int right = gen_expr(c, node->binary.right);
            int r = alloc_reg(c);
            
            const char *op;
            switch (node->binary.op) {
                case TOK_PLUS:  op = "fadd"; break;
                case TOK_MINUS: op = "fsub"; break;
                case TOK_STAR:  op = "fmul"; break;
                case TOK_SLASH: op = "fdiv"; break;
                case TOK_LT:    op = "fslt"; break;
                case TOK_LE:    op = "fsle"; break;
                case TOK_GT:    emit(c, "    fslt r%d, r%d, r%d", r, right, left); return r;
                case TOK_GE:    emit(c, "    fsle r%d, r%d, r%d", r, right, left); return r;
                case TOK_EQ:    op = "fseq"; break;
                case TOK_NE:    emit(c, "    fseq r%d, r%d, r%d", r, left, right);
                                emit(c, "    xori r%d, r%d, 1", r, r);
                                return r;
                default:        op = "add"; break;
            }
            emit(c, "    %s r%d, r%d, r%d", op, r, left, right);
            return r;
        }
        
        case NODE_UNARY: {
            int operand = gen_expr(c, node->unary.operand);
            int r = alloc_reg(c);
            
            switch (node->unary.op) {
                case TOK_MINUS:
                    emit(c, "    fneg r%d, r%d", r, operand);
                    break;
                case TOK_NOT:
                    emit(c, "    xori r%d, r%d, 1", r, operand);
                    break;
                default:
                    emit(c, "    mov r%d, r%d", r, operand);
                    break;
            }
            return r;
        }
        
        case NODE_CALL: {
            /* Built-in functions */
            const char *name = node->call.name;
            int arg_regs[8];
            int i = 0;
            for (milo_node_t *arg = node->call.args; arg && i < 8; arg = arg->next) {
                arg_regs[i++] = gen_expr(c, arg);
            }
            
            int r = alloc_reg(c);
            
            if (strcmp(name, "sin") == 0) {
                emit(c, "    sin r%d, r%d", r, arg_regs[0]);
            } else if (strcmp(name, "cos") == 0) {
                emit(c, "    cos r%d, r%d", r, arg_regs[0]);
            } else if (strcmp(name, "sqrt") == 0) {
                emit(c, "    sqrt r%d, r%d", r, arg_regs[0]);
            } else if (strcmp(name, "abs") == 0) {
                emit(c, "    fabs r%d, r%d", r, arg_regs[0]);
            } else if (strcmp(name, "min") == 0) {
                emit(c, "    fmin r%d, r%d, r%d", r, arg_regs[0], arg_regs[1]);
            } else if (strcmp(name, "max") == 0) {
                emit(c, "    fmax r%d, r%d, r%d", r, arg_regs[0], arg_regs[1]);
            } else if (strcmp(name, "clamp") == 0) {
                emit(c, "    fmax r%d, r%d, r%d", r, arg_regs[0], arg_regs[1]);
                emit(c, "    fmin r%d, r%d, r%d", r, r, arg_regs[2]);
            } else if (strcmp(name, "dot") == 0) {
                /* Simplified 3-component dot product */
                int t1 = alloc_reg(c);
                int t2 = alloc_reg(c);
                emit(c, "    fmul r%d, r%d, r%d", r, arg_regs[0], arg_regs[1]);
                emit(c, "    fmul r%d, r%d, r%d", t1, arg_regs[0]+1, arg_regs[1]+1);
                emit(c, "    fmul r%d, r%d, r%d", t2, arg_regs[0]+2, arg_regs[1]+2);
                emit(c, "    fadd r%d, r%d, r%d", r, r, t1);
                emit(c, "    fadd r%d, r%d, r%d", r, r, t2);
            } else if (strcmp(name, "normalize") == 0) {
                /* Simplified normalize */
                int len = alloc_reg(c);
                emit(c, "    ; normalize (simplified)");
                emit(c, "    fmul r%d, r%d, r%d", len, arg_regs[0], arg_regs[0]);
                emit(c, "    rsq r%d, r%d", len, len);
                emit(c, "    fmul r%d, r%d, r%d", r, arg_regs[0], len);
            } else if (strcmp(name, "texture") == 0) {
                emit(c, "    tex r%d, r%d, r%d", r, arg_regs[0], arg_regs[1]);
            } else if (strcmp(name, "mix") == 0) {
                /* mix(a, b, t) = a + t * (b - a) */
                int t = alloc_reg(c);
                emit(c, "    fsub r%d, r%d, r%d", t, arg_regs[1], arg_regs[0]);
                emit(c, "    fmul r%d, r%d, r%d", t, t, arg_regs[2]);
                emit(c, "    fadd r%d, r%d, r%d", r, arg_regs[0], t);
            } else {
                error(c, "Unknown function: %s", name);
            }
            return r;
        }
        
        case NODE_CONSTRUCTOR: {
            int r = alloc_reg(c);
            int size = type_size(node->constructor.con_type);
            
            /* Allocate consecutive registers */
            for (int i = 1; i < size; i++) {
                alloc_reg(c);
            }
            
            int i = 0;
            for (milo_node_t *arg = node->constructor.args; arg && i < size; arg = arg->next) {
                int a = gen_expr(c, arg);
                emit(c, "    mov r%d, r%d", r + i, a);
                i++;
            }
            return r;
        }
        
        case NODE_MEMBER: {
            int obj = gen_expr(c, node->member.object);
            const char *m = node->member.member;
            int r = alloc_reg(c);
            
            /* Simple swizzle */
            int offset = 0;
            if (m[0] == 'x' || m[0] == 'r' || m[0] == 's') offset = 0;
            else if (m[0] == 'y' || m[0] == 'g' || m[0] == 't') offset = 1;
            else if (m[0] == 'z' || m[0] == 'b' || m[0] == 'p') offset = 2;
            else if (m[0] == 'w' || m[0] == 'a' || m[0] == 'q') offset = 3;
            
            emit(c, "    mov r%d, r%d  ; .%s", r, obj + offset, m);
            return r;
        }
        
        case NODE_ASSIGN: {
            int val = gen_expr(c, node->assign.value);
            
            if (node->assign.target->type == NODE_IDENT) {
                const char *name = node->assign.target->ident.name;
                for (int i = 0; i < c->symtab.count; i++) {
                    if (strcmp(c->symtab.symbols[i].name, name) == 0) {
                        int r = c->symtab.symbols[i].reg;
                        int size = type_size(c->symtab.symbols[i].type);
                        
                        if (node->assign.op == TOK_ASSIGN) {
                            /* Copy all components for vector types */
                            for (int j = 0; j < size; j++) {
                                emit(c, "    mov r%d, r%d", r + j, val + j);
                            }
                        } else if (node->assign.op == TOK_PLUS_ASSIGN) {
                            for (int j = 0; j < size; j++) {
                                emit(c, "    fadd r%d, r%d, r%d", r + j, r + j, val + j);
                            }
                        } else if (node->assign.op == TOK_MINUS_ASSIGN) {
                            for (int j = 0; j < size; j++) {
                                emit(c, "    fsub r%d, r%d, r%d", r + j, r + j, val + j);
                            }
                        } else if (node->assign.op == TOK_STAR_ASSIGN) {
                            for (int j = 0; j < size; j++) {
                                emit(c, "    fmul r%d, r%d, r%d", r + j, r + j, val + j);
                            }
                        } else if (node->assign.op == TOK_SLASH_ASSIGN) {
                            for (int j = 0; j < size; j++) {
                                emit(c, "    fdiv r%d, r%d, r%d", r + j, r + j, val + j);
                            }
                        }
                        return r;
                    }
                }
                error(c, "Undefined variable: %s", name);
            }
            return val;
        }
        
        case NODE_TERNARY: {
            int cond = gen_expr(c, node->ternary.cond);
            int then_val = gen_expr(c, node->ternary.then_expr);
            int else_val = gen_expr(c, node->ternary.else_expr);
            int r = alloc_reg(c);
            emit(c, "    selp r%d, r%d, r%d, r%d", r, then_val, else_val, cond);
            return r;
        }
        
        default:
            error(c, "Unsupported expression type");
            return alloc_reg(c);
    }
}

static void gen_stmt(milo_compiler_t *c, milo_node_t *node) {
    if (!node) return;
    
    switch (node->type) {
        case NODE_BLOCK:
            for (milo_node_t *stmt = node->block.stmts; stmt; stmt = stmt->next) {
                gen_stmt(c, stmt);
            }
            break;
            
        case NODE_VAR_DECL: {
            int r = alloc_reg(c);
            int size = type_size(node->var_decl.var_type);
            for (int i = 1; i < size; i++) alloc_reg(c);
            
            /* Add to symbol table */
            if (c->symtab.count < MILO_MAX_SYMBOLS) {
                strcpy(c->symtab.symbols[c->symtab.count].name, node->var_decl.name);
                c->symtab.symbols[c->symtab.count].type = node->var_decl.var_type;
                c->symtab.symbols[c->symtab.count].reg = r;
                c->symtab.count++;
            }
            
            if (node->var_decl.init) {
                int val = gen_expr(c, node->var_decl.init);
                emit(c, "    mov r%d, r%d  ; %s", r, val, node->var_decl.name);
            }
            break;
        }
        
        case NODE_EXPR_STMT:
            gen_expr(c, node->ret.value);
            break;
            
        case NODE_RETURN:
            if (node->ret.value) {
                int val = gen_expr(c, node->ret.value);
                emit(c, "    mov r1, r%d  ; return value", val);
            }
            emit(c, "    ret");
            break;
            
        case NODE_DISCARD:
            emit(c, "    ; discard fragment");
            emit(c, "    exit");
            break;
            
        case NODE_IF: {
            int cond = gen_expr(c, node->if_stmt.cond);
            int else_label = alloc_label(c);
            int end_label = alloc_label(c);
            
            emit(c, "    ssy L%d  ; if", else_label);
            emit(c, "    beq r%d, r0, L%d", cond, else_label);
            gen_stmt(c, node->if_stmt.then_branch);
            
            if (node->if_stmt.else_branch) {
                emit(c, "    bra L%d", end_label);
                emit(c, "L%d:", else_label);
                gen_stmt(c, node->if_stmt.else_branch);
                emit(c, "L%d:", end_label);
            } else {
                emit(c, "L%d:", else_label);
            }
            emit(c, "    join");
            break;
        }
        
        case NODE_FOR: {
            int loop_label = alloc_label(c);
            int end_label = alloc_label(c);
            
            if (node->for_stmt.init) {
                gen_stmt(c, node->for_stmt.init);
            }
            
            emit(c, "L%d:  ; for loop", loop_label);
            emit(c, "    ssy L%d", end_label);
            
            if (node->for_stmt.cond) {
                int cond = gen_expr(c, node->for_stmt.cond);
                emit(c, "    beq r%d, r0, L%d", cond, end_label);
            }
            
            gen_stmt(c, node->for_stmt.body);
            
            if (node->for_stmt.post) {
                gen_expr(c, node->for_stmt.post);
            }
            
            emit(c, "    bra L%d", loop_label);
            emit(c, "L%d:", end_label);
            emit(c, "    join");
            break;
        }
        
        case NODE_WHILE: {
            int loop_label = alloc_label(c);
            int end_label = alloc_label(c);
            
            emit(c, "L%d:  ; while loop", loop_label);
            emit(c, "    ssy L%d", end_label);
            
            int cond = gen_expr(c, node->while_stmt.cond);
            emit(c, "    beq r%d, r0, L%d", cond, end_label);
            
            gen_stmt(c, node->while_stmt.body);
            
            emit(c, "    bra L%d", loop_label);
            emit(c, "L%d:", end_label);
            emit(c, "    join");
            break;
        }
        
        case NODE_BREAK:
            emit(c, "    join  ; break");
            break;
            
        case NODE_CONTINUE:
            /* TODO: need to track loop start label */
            emit(c, "    ; continue (TODO)");
            break;
            
        default:
            break;
    }
}

static void gen_function(milo_compiler_t *c, milo_node_t *node) {
    emit(c, "; Function: %s", node->func.name);
    emit(c, "%s:", node->func.name);
    
    /* Parameters - add to symbol table but don't reset next_reg */
    int param_reg = c->next_reg;
    for (milo_node_t *p = node->func.params; p; p = p->next) {
        if (c->symtab.count < MILO_MAX_SYMBOLS) {
            strcpy(c->symtab.symbols[c->symtab.count].name, p->var_decl.name);
            c->symtab.symbols[c->symtab.count].type = p->var_decl.var_type;
            c->symtab.symbols[c->symtab.count].reg = param_reg;
            c->symtab.count++;
            param_reg += type_size(p->var_decl.var_type);
        }
    }
    /* Keep next_reg at max of current value and param allocation */
    if (param_reg > c->next_reg) {
        c->next_reg = param_reg;
    }
    
    gen_stmt(c, node->func.body);
    
    if (strcmp(node->func.name, "main") == 0) {
        emit(c, "    exit");
    } else {
        emit(c, "    ret");
    }
    emit(c, "");
}

static void gen_program(milo_compiler_t *c) {
    emit(c, "; Milo832 GPU Shader");
    emit(c, "; Generated by milo_glsl compiler");
    emit(c, "");
    
    /* First pass: declare uniforms and inputs/outputs */
    for (milo_node_t *decl = c->ast->block.stmts; decl; decl = decl->next) {
        if (decl->type == NODE_VAR_DECL) {
            int r = alloc_reg(c);
            int size = type_size(decl->var_decl.var_type);
            for (int i = 1; i < size; i++) alloc_reg(c);
            
            if (c->symtab.count < MILO_MAX_SYMBOLS) {
                strcpy(c->symtab.symbols[c->symtab.count].name, decl->var_decl.name);
                c->symtab.symbols[c->symtab.count].type = decl->var_decl.var_type;
                c->symtab.symbols[c->symtab.count].reg = r;
                c->symtab.symbols[c->symtab.count].is_uniform = decl->var_decl.is_uniform;
                c->symtab.symbols[c->symtab.count].is_in = decl->var_decl.is_in;
                c->symtab.symbols[c->symtab.count].is_out = decl->var_decl.is_out;
                c->symtab.symbols[c->symtab.count].location = decl->var_decl.location;
                c->symtab.count++;
            }
            
            const char *qual = "";
            if (decl->var_decl.is_uniform) qual = "uniform ";
            else if (decl->var_decl.is_in) qual = "in ";
            else if (decl->var_decl.is_out) qual = "out ";
            
            emit(c, "; %s%s -> r%d", qual, decl->var_decl.name, r);
        }
    }
    emit(c, "");
    
    /* Second pass: generate function code */
    for (milo_node_t *decl = c->ast->block.stmts; decl; decl = decl->next) {
        if (decl->type == NODE_FUNCTION) {
            gen_function(c, decl);
        }
    }
}

/*---------------------------------------------------------------------------
 * Public API
 *---------------------------------------------------------------------------*/

void milo_glsl_init(milo_compiler_t *c) {
    memset(c, 0, sizeof(*c));
    c->next_reg = 2;  /* r0 = zero, r1 = return */
}

bool milo_glsl_compile(milo_compiler_t *c, const char *source, bool is_vertex) {
    c->source = source;
    c->current = source;
    c->line = 1;
    c->is_vertex = is_vertex;
    c->is_fragment = !is_vertex;
    
    /* Initialize lexer */
    c->current_token = scan_token(c);
    c->peek_token = scan_token(c);
    
    /* Parse */
    parse_program(c);
    
    if (c->error_count > 0) {
        return false;
    }
    
    /* Generate code */
    gen_program(c);
    
    return c->error_count == 0;
}

const char *milo_glsl_get_asm(milo_compiler_t *c) {
    static char buf[MILO_MAX_CODE * 128];
    buf[0] = '\0';
    
    /* Output code */
    for (int i = 0; i < c->code_count; i++) {
        strcat(buf, c->code[i]);
        strcat(buf, "\n");
    }
    
    /* Output constant table data section */
    if (c->const_count > 0) {
        strcat(buf, "\n; Constant data section\n");
        char line[128];
        snprintf(line, sizeof(line), "; Base address: 0x%04X (%d constants)\n", 
                MILO_CONST_BASE_ADDR, c->const_count);
        strcat(buf, line);
        
        for (int i = 0; i < c->const_count; i++) {
            union { uint32_t u; float f; } conv;
            conv.u = c->constants[i];
            snprintf(line, sizeof(line), ".data 0x%04X, 0x%08X  ; %.6f\n", 
                    MILO_CONST_BASE_ADDR + (i * 4), c->constants[i], conv.f);
            strcat(buf, line);
        }
    }
    
    return buf;
}

int milo_glsl_get_errors(milo_compiler_t *c, const char **errors, int max) {
    int n = c->error_count < max ? c->error_count : max;
    for (int i = 0; i < n; i++) {
        errors[i] = c->errors[i];
    }
    return n;
}

void milo_glsl_free(milo_compiler_t *c) {
    /* TODO: free AST nodes */
    (void)c;
}

void milo_glsl_dump_ast(milo_compiler_t *c, FILE *out) {
    (void)c;
    (void)out;
    /* TODO: implement AST dumping */
}
