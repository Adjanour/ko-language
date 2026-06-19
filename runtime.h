#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <ctype.h>
#include <math.h>
#include <time.h>

// ===== Main argc/argv (needed by stdlib) =====
static int _argc = 0;
static char** _argv = NULL;

// ===== Value representation with reference counting =====

typedef enum {
    VAL_INT,
    VAL_FLOAT,
    VAL_BOOL,
    VAL_STRING,
    VAL_CHAR,
    VAL_CONSTRUCTOR,
    VAL_CLOSURE,
    VAL_UNIT,
    VAL_REF
} ValueType;

// Forward declarations
typedef struct Value Value;
typedef struct Constructor Constructor;
typedef struct Closure Closure;
typedef struct Env Env;
typedef struct RefCell RefCell;
typedef struct KoString KoString;

// Heap-allocated string with refcount
struct KoString {
    int refcount;
    char* data;
};

// Heap-allocated constructor with refcount
struct Constructor {
    int refcount;
    int tag;
    int arity;
    Value* args;
};

// Function pointer type for closures
typedef Value (*ClosureFn)(Env*, Value);

// Environment: array of Values
struct Env {
    int refcount;
    int size;
    Value* vars;
};

// Heap-allocated closure with refcount
struct Closure {
    int refcount;
    ClosureFn func;
    Env* env;
};

// Value type
struct Value {
    ValueType type;
    union {
        long int_val;
        double float_val;
        bool bool_val;
        KoString* string;
        char char_val;
        Constructor* constructor;
        Closure* closure;
        RefCell* ref;
    } as;
};

// RefCell (mutable reference)
struct RefCell {
    int refcount;
    Value value;
};

// ===== Forward declarations for RC =====
void inc_ref(Value v);
void dec_ref(Value v);
void print_value(Value v);

// ===== Constructors (stack-allocated, no RC) =====

Value make_int(long v) { return (Value){VAL_INT, .as.int_val = v}; }
Value make_float(double v) { return (Value){VAL_FLOAT, .as.float_val = v}; }
Value make_bool(bool v) { return (Value){VAL_BOOL, .as.bool_val = v}; }
Value make_char(char v) { return (Value){VAL_CHAR, .as.char_val = v}; }
Value make_unit() { return (Value){VAL_UNIT}; }

// ===== Heap-allocated constructors (with RC) =====

Constructor* make_constructor_raw(int tag, int arity) {
    Constructor* c = malloc(sizeof(Constructor));
    c->refcount = 1;
    c->tag = tag;
    c->arity = arity;
    if (arity > 0) c->args = malloc(sizeof(Value) * arity);
    else c->args = NULL;
    return c;
}

Value make_constructor(int tag, int arity) {
    Value v = {VAL_CONSTRUCTOR, .as.constructor = make_constructor_raw(tag, arity)};
    return v;
}

Value constructor_get(Value v, int i) { return v.as.constructor->args[i]; }

// ===== Strings (heap-allocated with RC) =====

Value make_string(char* data) {
    KoString* s = malloc(sizeof(KoString));
    s->refcount = 1;
    s->data = strdup(data);
    return (Value){VAL_STRING, .as.string = s};
}

// Make a string from existing malloc'd buffer (takes ownership)
Value make_string_owned(char* data) {
    KoString* s = malloc(sizeof(KoString));
    s->refcount = 1;
    s->data = data;
    return (Value){VAL_STRING, .as.string = s};
}

char* string_data(Value v) { return v.as.string->data; }

// ===== Environments (heap-allocated with RC) =====

Env* make_env(int size) {
    Env* env = malloc(sizeof(Env));
    env->refcount = 1;
    env->size = size;
    env->vars = malloc(sizeof(Value) * size);
    return env;
}

Env* env_incref(Env* env) { if (env) env->refcount++; return env; }

void env_decref(Env* env) {
    if (!env) return;
    if (--env->refcount == 0) {
        for (int i = 0; i < env->size; i++) {
            dec_ref(env->vars[i]);
        }
        free(env->vars);
        free(env);
    }
}

void env_pack(Env* env, int index, Value val) {
    if (index < 0 || index >= env->size) {
        fprintf(stderr, "env_pack: index out of bounds\n");
        exit(1);
    }
    inc_ref(val);
    env->vars[index] = val;
}

Value env_unpack(Env* env, int index) {
    if (index < 0 || index >= env->size) {
        fprintf(stderr, "env_unpack: index out of bounds\n");
        exit(1);
    }
    return env->vars[index];
}

// ===== Closures (heap-allocated with RC) =====

Value make_closure(Env* env, ClosureFn func) {
    Closure* c = malloc(sizeof(Closure));
    c->refcount = 1;
    c->func = func;
    c->env = env_incref(env);
    return (Value){VAL_CLOSURE, .as.closure = c};
}

Value apply_closure(Value closure, Value arg) {
    if (closure.type != VAL_CLOSURE) {
        fprintf(stderr, "apply_closure: not a closure\n");
        exit(1);
    }
    Closure* c = closure.as.closure;
    return c->func(c->env, arg);
}

Value apply_value(Value fn, Value arg) {
    if (fn.type == VAL_CLOSURE) return apply_closure(fn, arg);
    fprintf(stderr, "apply_value: not callable\n");
    exit(1);
}

Value apply_value_2(Value fn, Value arg1, Value arg2) {
    if (fn.type == VAL_CLOSURE) {
        Value partial = apply_closure(fn, arg1);
        return apply_closure(partial, arg2);
    }
    fprintf(stderr, "apply_value_2: not callable\n");
    exit(1);
}

Value apply_value_3(Value fn, Value arg1, Value arg2, Value arg3) {
    if (fn.type == VAL_CLOSURE) {
        Value partial = apply_closure(fn, arg1);
        partial = apply_closure(partial, arg2);
        return apply_closure(partial, arg3);
    }
    fprintf(stderr, "apply_value_3: not callable\n");
    exit(1);
}

// ===== Reference counting =====

void inc_ref(Value v) {
    switch (v.type) {
        case VAL_CONSTRUCTOR: v.as.constructor->refcount++; break;
        case VAL_CLOSURE: v.as.closure->refcount++; break;
        case VAL_STRING: v.as.string->refcount++; break;
        case VAL_REF: v.as.ref->refcount++; break;
        default: break;
    }
}

void dec_ref(Value v) {
    switch (v.type) {
        case VAL_CONSTRUCTOR: {
            Constructor* c = v.as.constructor;
            if (--c->refcount == 0) {
                for (int i = 0; i < c->arity; i++) dec_ref(c->args[i]);
                free(c->args);
                free(c);
            }
            break;
        }
        case VAL_CLOSURE: {
            Closure* c = v.as.closure;
            if (--c->refcount == 0) {
                env_decref(c->env);
                free(c);
            }
            break;
        }
        case VAL_STRING: {
            KoString* s = v.as.string;
            if (--s->refcount == 0) {
                free(s->data);
                free(s);
            }
            break;
        }
        case VAL_REF: {
            RefCell* r = v.as.ref;
            if (--r->refcount == 0) {
                dec_ref(r->value);
                free(r);
            }
            break;
        }
        default: break;
    }
}

// ===== Ref cells =====

Value ko_ref(Value v) {
    RefCell* r = malloc(sizeof(RefCell));
    r->refcount = 1;
    r->value = v;
    inc_ref(v);
    return (Value){VAL_REF, .as.ref = r};
}

Value ko_deref(Value r) {
    if (r.type != VAL_REF) {
        fprintf(stderr, "ko_deref: expected ref, got ");
        print_value(r);
        fprintf(stderr, "\n");
        exit(1);
    }
    return r.as.ref->value;
}

Value ko_set(Value r, Value v) {
    RefCell* cell = r.as.ref;
    dec_ref(cell->value);
    cell->value = v;
    inc_ref(v);
    return r;
}

// ===== Pattern matching helpers =====

bool match_int(Value v, long expected) { return v.type == VAL_INT && v.as.int_val == expected; }
bool match_bool(Value v, bool expected) { return v.type == VAL_BOOL && v.as.bool_val == expected; }
bool match_string(Value v, char* expected) {
    return v.type == VAL_STRING && strcmp(v.as.string->data, expected) == 0;
}

void inspect_value(Value v);

Value panic_value(char* msg) {
    fprintf(stderr, "panic: %s\n", msg);
    exit(1);
}

// ===== Print / Inspect =====

void print_value(Value v) {
    switch (v.type) {
        case VAL_INT: printf("%ld", v.as.int_val); break;
        case VAL_FLOAT: printf("%g", v.as.float_val); break;
        case VAL_BOOL: printf("%s", v.as.bool_val ? "true" : "false"); break;
        case VAL_STRING: printf("%s", v.as.string->data); break;
        case VAL_CHAR: printf("'%c'", v.as.char_val); break;
        case VAL_UNIT: printf("()"); break;
        case VAL_CONSTRUCTOR: printf("Constructor(%d)", v.as.constructor->tag); break;
        case VAL_CLOSURE: printf("<function>"); break;
        case VAL_REF: printf("<ref>"); break;
        default: printf("<unknown>"); break;
    }
}

void println_value(Value v) {
    print_value(v);
    printf("\n");
}

// Forward declaration for per-file CONSTRUCTOR_NAMES
static const char* CONSTRUCTOR_NAMES[];

void inspect_value(Value v) {
    printf("Value{type=");
    switch (v.type) {
        case VAL_INT: printf("Int, value=%ld", v.as.int_val); break;
        case VAL_FLOAT: printf("Float, value=%g", v.as.float_val); break;
        case VAL_BOOL: printf("Bool, value=%s", v.as.bool_val ? "true" : "false"); break;
        case VAL_STRING: printf("String, value=\"%s\", len=%zu", v.as.string->data, strlen(v.as.string->data)); break;
        case VAL_CHAR: printf("Char, value='%c'", v.as.char_val); break;
        case VAL_UNIT: printf("Unit"); break;
        case VAL_CONSTRUCTOR: printf("Constructor(tag=%d, name=%s, arity=%d)", v.as.constructor->tag, CONSTRUCTOR_NAMES[v.as.constructor->tag], v.as.constructor->arity); break;
        case VAL_CLOSURE: printf("Closure"); break;
        case VAL_REF: printf("Ref"); break;
        default: printf("Unknown"); break;
    }
    printf("}\n");
}

// ===== Standard Library =====

Value len(Value v) {
    if (v.type == VAL_STRING) return make_int(strlen(v.as.string->data));
    if (v.type == VAL_CHAR) return make_int(1);
    fprintf(stderr, "length: expected string or char\n");
    exit(1);
}

Value concat(Value a, Value b) {
    if (a.type == VAL_STRING && b.type == VAL_STRING) {
        char* result = malloc(strlen(a.as.string->data) + strlen(b.as.string->data) + 1);
        strcpy(result, a.as.string->data);
        strcat(result, b.as.string->data);
        return make_string_owned(result);
    }
    fprintf(stderr, "concat: expected two strings\n");
    exit(1);
}

Value char_at(Value s, Value i) {
    if (s.type == VAL_STRING && i.type == VAL_INT) {
        long idx = i.as.int_val;
        if (idx < 0 || idx >= (long)strlen(s.as.string->data)) {
            fprintf(stderr, "char_at: index out of bounds\n");
            exit(1);
        }
        return make_char(s.as.string->data[idx]);
    }
    fprintf(stderr, "char_at: expected string and int\n");
    exit(1);
}

Value substring(Value s, Value start, Value end) {
    if (s.type == VAL_STRING && start.type == VAL_INT && end.type == VAL_INT) {
        long st = start.as.int_val;
        long en = end.as.int_val;
        long len = (long)strlen(s.as.string->data);
        if (st < 0) st = 0;
        if (en > len) en = len;
        if (st >= en) return make_string("");
        char* result = malloc(en - st + 1);
        memcpy(result, s.as.string->data + st, en - st);
        result[en - st] = '\0';
        return make_string_owned(result);
    }
    fprintf(stderr, "substring: expected string, int, int\n");
    exit(1);
}

Value contains(Value s, Value sub) {
    if (s.type == VAL_STRING && sub.type == VAL_STRING) {
        return make_bool(strstr(s.as.string->data, sub.as.string->data) != NULL);
    }
    fprintf(stderr, "contains: expected two strings\n");
    exit(1);
}

Value to_upper(Value s) {
    if (s.type == VAL_STRING) {
        long len = strlen(s.as.string->data);
        char* result = malloc(len + 1);
        for (long i = 0; i < len; i++) result[i] = toupper((unsigned char)s.as.string->data[i]);
        result[len] = '\0';
        return make_string_owned(result);
    }
    fprintf(stderr, "to_upper: expected string\n");
    exit(1);
}

Value to_lower(Value s) {
    if (s.type == VAL_STRING) {
        long len = strlen(s.as.string->data);
        char* result = malloc(len + 1);
        for (long i = 0; i < len; i++) result[i] = tolower((unsigned char)s.as.string->data[i]);
        result[len] = '\0';
        return make_string_owned(result);
    }
    fprintf(stderr, "to_lower: expected string\n");
    exit(1);
}

Value trim(Value s) {
    if (s.type == VAL_STRING) {
        char* start = s.as.string->data;
        while (*start && isspace((unsigned char)*start)) start++;
        char* end = start + strlen(start) - 1;
        while (end > start && isspace((unsigned char)*end)) end--;
        long new_len = end - start + 1;
        char* result = malloc(new_len + 1);
        memcpy(result, start, new_len);
        result[new_len] = '\0';
        return make_string_owned(result);
    }
    fprintf(stderr, "trim: expected string\n");
    exit(1);
}

Value starts_with(Value s, Value prefix) {
    if (s.type == VAL_STRING && prefix.type == VAL_STRING) {
        return make_bool(strncmp(s.as.string->data, prefix.as.string->data, strlen(prefix.as.string->data)) == 0);
    }
    fprintf(stderr, "starts_with: expected two strings\n");
    exit(1);
}

Value ends_with(Value s, Value suffix) {
    if (s.type == VAL_STRING && suffix.type == VAL_STRING) {
        size_t slen = strlen(s.as.string->data);
        size_t ulen = strlen(suffix.as.string->data);
        if (ulen > slen) return make_bool(false);
        return make_bool(strcmp(s.as.string->data + slen - ulen, suffix.as.string->data) == 0);
    }
    fprintf(stderr, "ends_with: expected two strings\n");
    exit(1);
}

Value repeat(Value s, Value n) {
    if (s.type == VAL_STRING && n.type == VAL_INT) {
        long count = n.as.int_val;
        if (count < 0) count = 0;
        size_t slen = strlen(s.as.string->data);
        char* result = malloc(slen * count + 1);
        result[0] = '\0';
        for (long i = 0; i < count; i++) strcat(result, s.as.string->data);
        return make_string_owned(result);
    }
    fprintf(stderr, "repeat: expected string and int\n");
    exit(1);
}

Value ko_abs(Value v) {
    if (v.type == VAL_INT) return make_int(v.as.int_val < 0 ? -v.as.int_val : v.as.int_val);
    if (v.type == VAL_FLOAT) return make_float(fabs(v.as.float_val));
    fprintf(stderr, "abs: expected number\n");
    exit(1);
}

Value ko_min(Value a, Value b) {
    if (a.type == VAL_INT && b.type == VAL_INT) return make_int(a.as.int_val < b.as.int_val ? a.as.int_val : b.as.int_val);
    if (a.type == VAL_FLOAT && b.type == VAL_FLOAT) return make_float(a.as.float_val < b.as.float_val ? a.as.float_val : b.as.float_val);
    fprintf(stderr, "min: expected two numbers of same type\n");
    exit(1);
}

Value ko_max(Value a, Value b) {
    if (a.type == VAL_INT && b.type == VAL_INT) return make_int(a.as.int_val > b.as.int_val ? a.as.int_val : b.as.int_val);
    if (a.type == VAL_FLOAT && b.type == VAL_FLOAT) return make_float(a.as.float_val > b.as.float_val ? a.as.float_val : b.as.float_val);
    fprintf(stderr, "max: expected two numbers of same type\n");
    exit(1);
}

Value ko_pow(Value base, Value exp) {
    if (base.type == VAL_INT && exp.type == VAL_INT) {
        long result = 1;
        long b = base.as.int_val;
        long e = exp.as.int_val;
        while (e > 0) { if (e & 1) result *= b; b *= b; e >>= 1; }
        return make_int(result);
    }
    if (base.type == VAL_FLOAT || exp.type == VAL_FLOAT) {
        double b = base.type == VAL_FLOAT ? base.as.float_val : (double)base.as.int_val;
        double e = exp.type == VAL_FLOAT ? exp.as.float_val : (double)exp.as.int_val;
        return make_float(pow(b, e));
    }
    fprintf(stderr, "pow: expected numbers\n");
    exit(1);
}

Value ko_sqrt(Value v) {
    if (v.type == VAL_INT) return make_float(sqrt((double)v.as.int_val));
    if (v.type == VAL_FLOAT) return make_float(sqrt(v.as.float_val));
    fprintf(stderr, "sqrt: expected number\n");
    exit(1);
}

Value ko_floor(Value v) {
    if (v.type == VAL_FLOAT) return make_int((long)floor(v.as.float_val));
    if (v.type == VAL_INT) return v;
    fprintf(stderr, "floor: expected number\n");
    exit(1);
}

Value ko_ceil(Value v) {
    if (v.type == VAL_FLOAT) return make_int((long)ceil(v.as.float_val));
    if (v.type == VAL_INT) return v;
    fprintf(stderr, "ceil: expected number\n");
    exit(1);
}

Value mod(Value a, Value b) {
    if (a.type == VAL_INT && b.type == VAL_INT) {
        if (b.as.int_val == 0) { fprintf(stderr, "mod: division by zero\n"); exit(1); }
        return make_int(a.as.int_val % b.as.int_val);
    }
    fprintf(stderr, "mod: expected two ints\n");
    exit(1);
}

Value to_string(Value v) {
    char buf[64];
    switch (v.type) {
        case VAL_INT: snprintf(buf, sizeof(buf), "%ld", v.as.int_val); return make_string(buf);
        case VAL_FLOAT: snprintf(buf, sizeof(buf), "%g", v.as.float_val); return make_string(buf);
        case VAL_BOOL: return make_string(v.as.bool_val ? "true" : "false");
        case VAL_CHAR: buf[0] = v.as.char_val; buf[1] = '\0'; return make_string(buf);
        case VAL_STRING: return v;
        case VAL_UNIT: return make_string("()");
        default: return make_string("<unknown>");
    }
}

Value to_int(Value v) {
    if (v.type == VAL_INT) return v;
    if (v.type == VAL_FLOAT) return make_int((long)v.as.float_val);
    if (v.type == VAL_STRING) return make_int(strtol(v.as.string->data, NULL, 10));
    fprintf(stderr, "to_int: cannot convert\n");
    exit(1);
}

Value to_float(Value v) {
    if (v.type == VAL_FLOAT) return v;
    if (v.type == VAL_INT) return make_float((double)v.as.int_val);
    if (v.type == VAL_STRING) return make_float(strtod(v.as.string->data, NULL));
    fprintf(stderr, "to_float: cannot convert\n");
    exit(1);
}

Value type_of(Value v) {
    switch (v.type) {
        case VAL_INT: return make_string("Int");
        case VAL_FLOAT: return make_string("Float");
        case VAL_BOOL: return make_string("Bool");
        case VAL_STRING: return make_string("String");
        case VAL_CHAR: return make_string("Char");
        case VAL_UNIT: return make_string("Unit");
        case VAL_CONSTRUCTOR: return make_string("Constructor");
        case VAL_CLOSURE: return make_string("Function");
        case VAL_REF: return make_string("Ref");
        default: return make_string("Unknown");
    }
}

Value is_int(Value v) { return make_bool(v.type == VAL_INT); }
Value is_float(Value v) { return make_bool(v.type == VAL_FLOAT); }
Value is_string(Value v) { return make_bool(v.type == VAL_STRING); }
Value is_bool(Value v) { return make_bool(v.type == VAL_BOOL); }

// I/O
Value read_line(Value prompt) {
    if (prompt.type == VAL_STRING) printf("%s", prompt.as.string->data);
    char buf[4096];
    if (fgets(buf, sizeof(buf), stdin)) {
        buf[strcspn(buf, "\n")] = '\0';
        return make_string(buf);
    }
    return make_string("");
}

Value read_file(Value path) {
    if (path.type != VAL_STRING) { fprintf(stderr, "read_file: expected string\n"); exit(1); }
    FILE* f = fopen(path.as.string->data, "r");
    if (!f) { fprintf(stderr, "read_file: cannot open %s\n", path.as.string->data); exit(1); }
    fseek(f, 0, SEEK_END);
    long filelen = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buf = malloc(filelen + 1);
    fread(buf, 1, filelen, f);
    buf[filelen] = '\0';
    fclose(f);
    return make_string_owned(buf);
}

Value write_file(Value path, Value content) {
    if (path.type != VAL_STRING || content.type != VAL_STRING) { fprintf(stderr, "write_file: expected strings\n"); exit(1); }
    FILE* f = fopen(path.as.string->data, "w");
    if (!f) { fprintf(stderr, "write_file: cannot open %s\n", path.as.string->data); exit(1); }
    fputs(content.as.string->data, f);
    fclose(f);
    return make_unit();
}

Value append_file(Value path, Value content) {
    if (path.type != VAL_STRING || content.type != VAL_STRING) { fprintf(stderr, "append_file: expected strings\n"); exit(1); }
    FILE* f = fopen(path.as.string->data, "a");
    if (!f) { fprintf(stderr, "append_file: cannot open %s\n", path.as.string->data); exit(1); }
    fputs(content.as.string->data, f);
    fclose(f);
    return make_unit();
}

Value run_command(Value cmd) {
    if (cmd.type != VAL_STRING) { fprintf(stderr, "run_command: expected string\n"); exit(1); }
    int status = system(cmd.as.string->data);
    return make_int((long)status);
}

Value get_env(Value name) {
    if (name.type != VAL_STRING) { fprintf(stderr, "get_env: expected string\n"); exit(1); }
    char* val = getenv(name.as.string->data);
    return val ? make_string(val) : make_string("");
}

Value args_count(void) { return make_int((long)_argc); }

Value args_get(Value idx) {
    if (idx.type != VAL_INT) { fprintf(stderr, "args_get: expected int\n"); exit(1); }
    long i = idx.as.int_val;
    if (i < 0 || i >= _argc) return make_string("");
    return make_string(_argv[i]);
}

Value ko_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return make_int((long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static long _rng_state = 1;
Value ko_random(Value seed, Value lo, Value hi) {
    if (seed.type == VAL_INT) _rng_state = seed.as.int_val;
    long l = lo.type == VAL_INT ? lo.as.int_val : 0;
    long h = hi.type == VAL_INT ? hi.as.int_val : 100;
    _rng_state = _rng_state * 1103515245 + 12345;
    return make_int(l + (long)(((unsigned long)_rng_state >> 16) % (h - l + 1)));
}

Value ko_seed(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    _rng_state = (long)ts.tv_nsec;
    return make_int(_rng_state);
}

Value ko_ord(Value c) {
    if (c.type == VAL_CHAR) return make_int((long)(unsigned char)c.as.char_val);
    if (c.type == VAL_STRING && c.as.string->data[0] != '\0') return make_int((long)(unsigned char)c.as.string->data[0]);
    fprintf(stderr, "ord: expected char or string\n");
    exit(1);
}

Value ko_chr(Value n) {
    if (n.type == VAL_INT) return make_char((char)n.as.int_val);
    fprintf(stderr, "chr: expected int\n");
    exit(1);
}

Value ko_split(Value s, Value delim) {
    if (s.type != VAL_STRING || delim.type != VAL_STRING) { fprintf(stderr, "split: expected strings\n"); exit(1); }
    char* str = s.as.string->data;
    char* d = delim.as.string->data;
    int dlen = strlen(d);
    if (dlen == 0) { fprintf(stderr, "split: empty delimiter\n"); exit(1); }
    /* Count parts */
    int count = 1;
    char* p = str;
    while ((p = strstr(p, d)) != NULL) { count++; p += dlen; }
    /* Build result list: Cons (Cons ... Nil) */
    Value result = make_constructor(1, 0); /* Nil */
    /* Split in reverse order so result is in correct order */
    char** parts = malloc(count * sizeof(char*));
    int* part_lens = malloc(count * sizeof(int));
    p = str;
    int i = 0;
    int offset = 0;
    while (1) {
        char* found = strstr(p, d);
        if (!found) {
            parts[i] = p;
            part_lens[i] = strlen(p);
            break;
        }
        parts[i] = p;
        part_lens[i] = found - p;
        p = found + dlen;
        i++;
    }
    /* Build list from end to start */
    for (i = count - 1; i >= 0; i--) {
        char* part = malloc(part_lens[i] + 1);
        memcpy(part, parts[i], part_lens[i]);
        part[part_lens[i]] = '\0';
        Value item = make_string(part);
        Value cons = make_constructor(0, 2);
        cons.as.constructor->args = malloc(2 * sizeof(Value));
        cons.as.constructor->args[0] = item;
        cons.as.constructor->args[1] = result;
        result = cons;
    }
    free(parts);
    free(part_lens);
    return result;
}

Value ko_join(Value xs, Value sep) {
    if (sep.type != VAL_STRING) { fprintf(stderr, "join: expected string separator\n"); exit(1); }
    /* Calculate total length */
    int total = 0;
    int count = 0;
    Value cur = xs;
    while (cur.type == VAL_CONSTRUCTOR && cur.as.constructor->tag == 0 && cur.as.constructor->arity == 2) {
        Value item = cur.as.constructor->args[0];
        if (item.type == VAL_STRING) total += strlen(item.as.string->data);
        cur = cur.as.constructor->args[1];
        count++;
    }
    if (count > 0) total += (count - 1) * strlen(sep.as.string->data);
    char* buf = malloc(total + 1);
    buf[0] = '\0';
    cur = xs;
    int first = 1;
    while (cur.type == VAL_CONSTRUCTOR && cur.as.constructor->tag == 0 && cur.as.constructor->arity == 2) {
        Value item = cur.as.constructor->args[0];
        if (!first) strcat(buf, sep.as.string->data);
        if (item.type == VAL_STRING) strcat(buf, item.as.string->data);
        first = 0;
        cur = cur.as.constructor->args[1];
    }
    return make_string(buf);
}

Value ko_replace(Value s, Value old, Value new) {
    if (s.type != VAL_STRING || old.type != VAL_STRING || new.type != VAL_STRING) {
        fprintf(stderr, "replace: expected strings\n"); exit(1);
    }
    char* str = s.as.string->data;
    char* search = old.as.string->data;
    char* repl = new.as.string->data;
    int search_len = strlen(search);
    int repl_len = strlen(repl);
    /* Count occurrences */
    int count = 0;
    char* p = str;
    while ((p = strstr(p, search)) != NULL) { count++; p += search_len; }
    if (count == 0) return s;
    /* Build result */
    int result_len = strlen(str) + count * (repl_len - search_len);
    char* result = malloc(result_len + 1);
    result[0] = '\0';
    char* src = str;
    char* found;
    while ((found = strstr(src, search)) != NULL) {
        int prefix_len = found - src;
        memcpy(result + strlen(result), src, prefix_len);
        result[strlen(result) + prefix_len] = '\0';
        strcat(result, repl);
        src = found + search_len;
    }
    strcat(result, src);
    return make_string(result);
}

Value ko_head(Value xs) {
    if (xs.type == VAL_CONSTRUCTOR && xs.as.constructor->tag == 0 && xs.as.constructor->arity == 2) {
        return xs.as.constructor->args[0];
    }
    fprintf(stderr, "head: empty list\n");
    exit(1);
}

Value ko_tail(Value xs) {
    if (xs.type == VAL_CONSTRUCTOR && xs.as.constructor->tag == 0 && xs.as.constructor->arity == 2) {
        return xs.as.constructor->args[1];
    }
    fprintf(stderr, "tail: empty list\n");
    exit(1);
}

Value ko_append(Value xs, Value x) {
    if (xs.type == VAL_CONSTRUCTOR && xs.as.constructor->tag == 1) {
        /* Nil -> Cons x Nil */
        Value cons = make_constructor(0, 2);
        cons.as.constructor->args = malloc(2 * sizeof(Value));
        cons.as.constructor->args[0] = x;
        cons.as.constructor->args[1] = xs;
        return cons;
    }
    if (xs.type == VAL_CONSTRUCTOR && xs.as.constructor->tag == 0 && xs.as.constructor->arity == 2) {
        /* Cons h t -> Cons h (append t x) */
        Value h = xs.as.constructor->args[0];
        Value t = xs.as.constructor->args[1];
        Value new_tail = ko_append(t, x);
        Value cons = make_constructor(0, 2);
        cons.as.constructor->args = malloc(2 * sizeof(Value));
        cons.as.constructor->args[0] = h;
        cons.as.constructor->args[1] = new_tail;
        return cons;
    }
    fprintf(stderr, "append: expected list\n");
    exit(1);
}

Value ko_reverse(Value xs) {
    Value acc = make_constructor(1, 0); /* Nil */
    Value cur = xs;
    while (cur.type == VAL_CONSTRUCTOR && cur.as.constructor->tag == 0 && cur.as.constructor->arity == 2) {
        Value h = cur.as.constructor->args[0];
        Value cons = make_constructor(0, 2);
        cons.as.constructor->args = malloc(2 * sizeof(Value));
        cons.as.constructor->args[0] = h;
        cons.as.constructor->args[1] = acc;
        acc = cons;
        cur = cur.as.constructor->args[1];
    }
    return acc;
}

Value ko_sum(Value xs) {
    long total = 0;
    Value cur = xs;
    while (cur.type == VAL_CONSTRUCTOR && cur.as.constructor->tag == 0 && cur.as.constructor->arity == 2) {
        Value h = cur.as.constructor->args[0];
        if (h.type == VAL_INT) total += h.as.int_val;
        else if (h.type == VAL_FLOAT) total += (long)h.as.float_val;
        cur = cur.as.constructor->args[1];
    }
    return make_int(total);
}

Value ko_product(Value xs) {
    long total = 1;
    Value cur = xs;
    while (cur.type == VAL_CONSTRUCTOR && cur.as.constructor->tag == 0 && cur.as.constructor->arity == 2) {
        Value h = cur.as.constructor->args[0];
        if (h.type == VAL_INT) total *= h.as.int_val;
        else if (h.type == VAL_FLOAT) total *= (long)h.as.float_val;
        cur = cur.as.constructor->args[1];
    }
    return make_int(total);
}

Value ko_is_null(Value v) {
    return make_bool(v.type == VAL_CONSTRUCTOR && v.as.constructor->tag == 1);
}

Value ko_file_exists(Value path) {
    if (path.type != VAL_STRING) { fprintf(stderr, "file_exists: expected string\n"); exit(1); }
    FILE* f = fopen(path.as.string->data, "r");
    if (f) { fclose(f); return make_bool(true); }
    return make_bool(false);
}

Value ko_parse_int(Value s) {
    if (s.type != VAL_STRING) { fprintf(stderr, "parse_int: expected string\n"); exit(1); }
    char* end;
    long val = strtol(s.as.string->data, &end, 10);
    if (*end != '\0' || end == s.as.string->data) {
        /* Return Ok/Err style: constructor tag 1 = Err */
        Value err = make_constructor(1, 1);
        err.as.constructor->args = malloc(sizeof(Value));
        err.as.constructor->args[0] = make_string("invalid integer");
        return err;
    }
    Value ok = make_constructor(0, 1);
    ok.as.constructor->args = malloc(sizeof(Value));
    ok.as.constructor->args[0] = make_int(val);
    return ok;
}

Value ko_parse_float(Value s) {
    if (s.type != VAL_STRING) { fprintf(stderr, "parse_float: expected string\n"); exit(1); }
    char* end;
    double val = strtod(s.as.string->data, &end);
    if (*end != '\0' || end == s.as.string->data) {
        Value err = make_constructor(1, 1);
        err.as.constructor->args = malloc(sizeof(Value));
        err.as.constructor->args[0] = make_string("invalid float");
        return err;
    }
    Value ok = make_constructor(0, 1);
    ok.as.constructor->args = malloc(sizeof(Value));
    ok.as.constructor->args[0] = make_float(val);
    return ok;
}

Value ko_sleep(Value ms) {
    if (ms.type != VAL_INT) { fprintf(stderr, "sleep: expected int (milliseconds)\n"); exit(1); }
    struct timespec ts;
    ts.tv_sec = ms.as.int_val / 1000;
    ts.tv_nsec = (ms.as.int_val % 1000) * 1000000;
    nanosleep(&ts, NULL);
    return make_unit();
}

Value exit_with(Value code) {
    long c = code.type == VAL_INT ? code.as.int_val : 0;
    exit((int)c);
    return make_unit();
}

// ===== Testing Framework =====

static int _test_count = 0;
static int _test_failures = 0;

Value ko_assert(Value v) {
    if (v.type != VAL_BOOL || !v.as.bool_val) {
        fprintf(stderr, "  ASSERT FAILED\n");
        _test_failures++;
    } else {
        _test_count++;
    }
    return make_unit();
}

Value ko_assert_eq(Value a, Value b) {
    int equal = 0;
    if (a.type == VAL_INT && b.type == VAL_INT) equal = (a.as.int_val == b.as.int_val);
    else if (a.type == VAL_FLOAT && b.type == VAL_FLOAT) equal = (a.as.float_val == b.as.float_val);
    else if (a.type == VAL_BOOL && b.type == VAL_BOOL) equal = (a.as.bool_val == b.as.bool_val);
    else if (a.type == VAL_STRING && b.type == VAL_STRING) equal = (strcmp(a.as.string->data, b.as.string->data) == 0);
    else equal = (a.type == b.type);
    if (!equal) {
        fprintf(stderr, "  ASSERT_EQ FAILED\n");
        _test_failures++;
    } else {
        _test_count++;
    }
    return make_unit();
}

static char _test_names[64][128];
static ClosureFn _test_fns[64];
static int _test_idx = 0;

Value ko_test(Value name, Value fn) {
    if (_test_idx < 64 && name.type == VAL_STRING && fn.type == VAL_CLOSURE) {
        strncpy(_test_names[_test_idx], name.as.string->data, 127);
        _test_names[_test_idx][127] = '\0';
        _test_fns[_test_idx] = fn.as.closure->func;
        _test_idx++;
    }
    return make_unit();
}

Value ko_run_tests(void) {
    for (int i = 0; i < _test_idx; i++) {
        printf("  %s... ", _test_names[i]);
        int before = _test_failures;
        _test_fns[i](NULL, make_unit());
        if (_test_failures == before) printf("OK\n");
    }
    printf("\n  %d passed, %d failed\n", _test_count, _test_failures);
    return make_int(_test_failures);
}


// ===== Main entry =====
