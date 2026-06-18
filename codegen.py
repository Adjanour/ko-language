"""Kō Codegen - C code generator for the Kō language"""

from typing import List, Set
from parser import (
    Program, FnDef, LetBinding, TypeDef, TypeConstructor,
    IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral,
    Identifier, Wildcard, BinaryOp, UnaryOp, FnCall, IfExpr, MatchExpr,
    MatchArm, PatLiteral, PatIdent, PatWildcard, PatConstructor,
    Block, LetExpr
)

# C reserved keywords that need to be renamed
C_RESERVED = {'default', 'auto', 'break', 'case', 'char', 'const', 'continue',
              'do', 'double', 'else', 'enum', 'extern', 'float', 'for', 'goto',
              'if', 'inline', 'int', 'long', 'register', 'restrict', 'return',
              'short', 'signed', 'sizeof', 'static', 'struct', 'switch', 'typedef',
              'union', 'unsigned', 'void', 'volatile', 'while',
              # C standard library functions/types that conflict
              'abs', 'div', 'exit', 'free', 'malloc', 'printf', 'scanf',
              'strlen', 'strcmp', 'strcpy', 'strcat', 'memcpy', 'memset',
              'true', 'false', 'bool', 'NULL'}


def sanitize_name(name: str) -> str:
    """Sanitize a name for use in C code"""
    name = name.replace('-', '_')
    if name in C_RESERVED:
        return f"ko_{name}"
    return name


class CodeGen:
    def __init__(self):
        self.output = []
        self.indent = 0
        self.type_tags = {}  # constructor_name -> tag_number
        self.type_info = {}  # type_name -> [constructors]
        self.current_tag = 0
        self.defined_fns = set()
        self.needs_runtime = False
        self.name_map = {}  # original_name -> sanitized_name

    def emit(self, line: str):
        self.output.append("  " * self.indent + line)

    def emit_raw(self, line: str):
        self.output.append(line)

    def generate(self, program: Program) -> str:
        # First pass: collect type info
        for defn in program.definitions:
            if isinstance(defn, TypeDef):
                self.register_type(defn)

        # Generate runtime header
        self.generate_runtime()

        # Generate CONSTRUCTOR_NAMES array for inspect
        if self.type_tags:
            max_tag = max(self.type_tags.values())
            names = ["unknown"] * (max_tag + 1)
            for name, tag in self.type_tags.items():
                names[tag] = name
            self.emit(f"static const char* CONSTRUCTOR_NAMES[] = {{")
            self.indent += 1
            for i, name in enumerate(names):
                self.emit(f'"{name}",')
            self.indent -= 1
            self.emit("};")
            self.emit_raw("")

        # Generate type definitions
        for defn in program.definitions:
            if isinstance(defn, TypeDef):
                self.generate_type(defn)

        # Generate function forward declarations
        for defn in program.definitions:
            if isinstance(defn, FnDef):
                name = sanitize_name(defn.name)
                if defn.name == "main":
                    name = "_ko_main"
                self.emit(f"Value {name}({', '.join(['Value'] * len(defn.params))});")
                self.defined_fns.add(defn.name)

        self.emit_raw("")

        # Generate let bindings and functions
        for defn in program.definitions:
            if isinstance(defn, LetBinding):
                self.generate_let(defn)
            elif isinstance(defn, FnDef):
                self.generate_fn(defn)

        # Generate C entry point if there's a main function
        if 'main' in self.defined_fns:
            self.emit_raw("")
            self.emit("int main() {")
            self.indent += 1
            self.emit("_ko_main();")
            self.emit("return 0;")
            self.indent -= 1
            self.emit("}")

        return "\n".join(self.output)

    def register_type(self, typedef: TypeDef):
        constructors = []
        for ctor in typedef.constructors:
            tag = self.current_tag
            self.type_tags[ctor.name] = tag
            constructors.append((ctor.name, ctor.fields))
            self.current_tag += 1
        self.type_info[typedef.name] = constructors

    def generate_runtime(self):
        self.emit_raw("""#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

// Value representation
typedef enum {
    VAL_INT,
    VAL_FLOAT,
    VAL_BOOL,
    VAL_STRING,
    VAL_CHAR,
    VAL_CONSTRUCTOR,
    VAL_CLOSURE,
    VAL_UNIT
} ValueType;

typedef struct Value {
    ValueType type;
    union {
        long int_val;
        double float_val;
        bool bool_val;
        char* string_val;
        char char_val;
        struct {
            int tag;
            int arity;
            struct Value* args;
        } constructor;
        struct {
            void* env;
            void* func;
        } closure;
    } as;
} Value;

Value make_int(long v) { return (Value){VAL_INT, .as.int_val = v}; }
Value make_float(double v) { return (Value){VAL_FLOAT, .as.float_val = v}; }
Value make_bool(bool v) { return (Value){VAL_BOOL, .as.bool_val = v}; }
Value make_string(char* v) { return (Value){VAL_STRING, .as.string_val = v}; }
Value make_char(char v) { return (Value){VAL_CHAR, .as.char_val = v}; }
Value make_unit() { return (Value){VAL_UNIT}; }

Value make_constructor(int tag, int arity) {
    Value v = {VAL_CONSTRUCTOR, .as.constructor.tag = tag, .as.constructor.arity = arity};
    if (arity > 0) v.as.constructor.args = malloc(sizeof(Value) * arity);
    return v;
}

Value constructor_get(Value v, int i) { return v.as.constructor.args[i]; }

// Pattern matching helper
bool match_int(Value v, long expected) { return v.type == VAL_INT && v.as.int_val == expected; }
bool match_bool(Value v, bool expected) { return v.type == VAL_BOOL && v.as.bool_val == expected; }
bool match_string(Value v, char* expected) { return v.type == VAL_STRING && strcmp(v.as.string_val, expected) == 0; }

void inspect_value(Value v);  // Forward declaration

Value panic_value(char* msg) {
    fprintf(stderr, "panic: %s\\n", msg);
    exit(1);
}

// Print helper
void print_value(Value v) {
    switch (v.type) {
        case VAL_INT: printf("%ld", v.as.int_val); break;
        case VAL_FLOAT: printf("%g", v.as.float_val); break;
        case VAL_BOOL: printf("%s", v.as.bool_val ? "true" : "false"); break;
        case VAL_STRING: printf("%s", v.as.string_val); break;
        case VAL_CHAR: printf("'%c'", v.as.char_val); break;
        case VAL_UNIT: printf("()"); break;
        case VAL_CONSTRUCTOR: printf("Constructor(%d)", v.as.constructor.tag); break;
        default: printf("<unknown>"); break;
    }
}

void println_value(Value v) {
    print_value(v);
    printf("\\n");
}

// Forward declaration for CONSTRUCTOR_NAMES
static const char* CONSTRUCTOR_NAMES[];
void inspect_value(Value v) {
    printf("Value{type=");
    switch (v.type) {
        case VAL_INT: printf("Int, value=%ld", v.as.int_val); break;
        case VAL_FLOAT: printf("Float, value=%g", v.as.float_val); break;
        case VAL_BOOL: printf("Bool, value=%s", v.as.bool_val ? "true" : "false"); break;
        case VAL_STRING: printf("String, value=\\"%s\\", len=%zu", v.as.string_val, strlen(v.as.string_val)); break;
        case VAL_CHAR: printf("Char, value=\\'%c\\'", v.as.char_val); break;
        case VAL_UNIT: printf("Unit"); break;
        case VAL_CONSTRUCTOR: printf("Constructor(tag=%d, name=%s, arity=%d)", v.as.constructor.tag, CONSTRUCTOR_NAMES[v.as.constructor.tag], v.as.constructor.arity); break;
        default: printf("Unknown"); break;
    }
    printf(", addr=%p}\\n", (void*)&v);
}
""")

    def generate_type(self, typedef: TypeDef):
        type_name = typedef.name

        # Enum for tags
        self.emit(f"enum {{")
        self.indent += 1
        for ctor in typedef.constructors:
            tag = self.type_tags[ctor.name]
            self.emit(f"TAG_{ctor.name.upper()} = {tag},")
        self.indent -= 1
        self.emit(f"}};")
        self.emit_raw("")

        # Generate constructor functions
        for ctor in typedef.constructors:
            ctor_name = sanitize_name(ctor.name)
            if ctor.fields == 0:
                # Nullary constructor - generate a function that returns the value
                self.emit(f"Value {ctor_name}() {{")
                self.indent += 1
                self.emit(f"return make_constructor(TAG_{ctor.name.upper()}, 0);")
                self.indent -= 1
                self.emit("}")
            else:
                # N-ary constructor - takes arguments
                params = [f"Value arg{i}" for i in range(ctor.fields)]
                self.emit(f"Value {ctor_name}({', '.join(params)}) {{")
                self.indent += 1
                self.emit(f"Value v = make_constructor(TAG_{ctor.name.upper()}, {ctor.fields});")
                for i in range(ctor.fields):
                    self.emit(f"v.as.constructor.args[{i}] = arg{i};")
                self.emit("return v;")
                self.indent -= 1
                self.emit("}")
            self.defined_fns.add(ctor.name)

    def generate_let(self, binding: LetBinding):
        sanitized = sanitize_name(binding.name)
        self.name_map[binding.name] = sanitized
        self.emit(f"Value {sanitized} = {self.generate_expr(binding.value)};")
        self.defined_fns.add(binding.name)

    def generate_fn(self, fndef: FnDef):
        name = sanitize_name(fndef.name)
        if fndef.name == "main":
            name = "_ko_main"
        # Sanitize parameter names and add to name map
        params = []
        for p in fndef.params:
            sanitized = sanitize_name(p)
            self.name_map[p] = sanitized
            params.append(f"Value {sanitized}")
        self.emit(f"Value {name}({', '.join(params)}) {{")
        self.indent += 1

        self.generate_statement(fndef.body)

        self.indent -= 1
        self.emit("}")
        self.emit_raw("")

    def generate_statement(self, expr):
        if isinstance(expr, Block):
            for i, e in enumerate(expr.exprs):
                if i == len(expr.exprs) - 1:
                    # Last expression is the return value
                    self.generate_statement(e)
                else:
                    self.generate_statement(e)
        elif isinstance(expr, LetExpr):
            sanitized = sanitize_name(expr.name)
            self.name_map[expr.name] = sanitized
            self.emit(f"Value {sanitized} = {self.generate_expr(expr.value)};")
            self.generate_statement(expr.body)
        elif isinstance(expr, IfExpr):
            cond = self.generate_condition(expr.cond)
            self.emit(f"if ({cond}) {{")
            self.indent += 1
            self.generate_statement(expr.then_branch)
            self.indent -= 1
            if expr.else_branch:
                self.emit("} else {")
                self.indent += 1
                self.generate_statement(expr.else_branch)
                self.indent -= 1
            self.emit("}")
        elif isinstance(expr, MatchExpr):
            self.generate_match_statement(expr)
        elif isinstance(expr, FnCall) and isinstance(expr.func, Identifier) and expr.func.name == 'print':
            if expr.args:
                arg_str = self.generate_expr(expr.args[0])
                self.emit(f"print_value({arg_str});")
            else:
                self.emit("print_value(make_unit());")
        elif isinstance(expr, FnCall) and isinstance(expr.func, Identifier) and expr.func.name == 'println':
            if expr.args:
                arg_str = self.generate_expr(expr.args[0])
                self.emit(f"println_value({arg_str});")
            else:
                self.emit("println_value(make_unit());")
        elif isinstance(expr, FnCall) and isinstance(expr.func, Identifier) and expr.func.name == 'inspect':
            if expr.args:
                arg_str = self.generate_expr(expr.args[0])
                self.emit(f"inspect_value({arg_str});")
            else:
                self.emit("inspect_value(make_unit());")
        else:
            self.emit(f"return {self.generate_expr(expr)};")

    def generate_match_statement(self, match_expr: MatchExpr):
        value_var = f"_match_{id(match_expr)}"
        self.emit(f"Value {value_var} = {self.generate_expr(match_expr.value)};")

        for i, arm in enumerate(match_expr.arms):
            condition = self.generate_pattern_condition(arm.pattern, value_var)
            if i == 0:
                self.emit(f"if ({condition}) {{")
            else:
                self.emit(f"}} else if ({condition}) {{")
            self.indent += 1

            # Generate bindings
            bindings = self.extract_pattern_bindings(arm.pattern, value_var)
            for name in bindings:
                sanitized = sanitize_name(name)
                self.name_map[name] = sanitized
                self.emit(f"Value {sanitized} = {bindings[name]};")

            self.generate_statement(arm.body)
            self.indent -= 1
        self.emit("}")

    def generate_pattern_condition(self, pattern, value_var: str) -> str:
        if isinstance(pattern, PatWildcard):
            return "true"
        if isinstance(pattern, PatLiteral):
            if isinstance(pattern.value, int):
                return f"match_int({value_var}, {pattern.value})"
            elif isinstance(pattern.value, bool):
                return f"match_bool({value_var}, {'true' if pattern.value else 'false'})"
            elif isinstance(pattern.value, str):
                return f"match_string({value_var}, \"{pattern.value}\")"
        if isinstance(pattern, PatIdent):
            return "true"  # Always matches
        if isinstance(pattern, PatConstructor):
            tag = self.type_tags.get(pattern.name, -1)
            condition = f"{value_var}.type == VAL_CONSTRUCTOR && {value_var}.as.constructor.tag == TAG_{pattern.name.upper()}"
            if pattern.args:
                conditions = [condition]
                for i, arg in enumerate(pattern.args):
                    sub_var = f"{value_var}.as.constructor.args[{i}]"
                    conditions.append(self.generate_pattern_condition(arg, sub_var))
                return " && ".join(conditions)
            return condition
        return "false"

    def extract_pattern_bindings(self, pattern, value_var: str) -> dict:
        bindings = {}
        if isinstance(pattern, PatIdent):
            bindings[pattern.name] = value_var
        elif isinstance(pattern, PatConstructor):
            for i, arg in enumerate(pattern.args):
                sub_var = f"{value_var}.as.constructor.args[{i}]"
                bindings.update(self.extract_pattern_bindings(arg, sub_var))
        return bindings

    def generate_condition(self, expr) -> str:
        """Generate a raw C boolean expression for use in if/while conditions."""
        if isinstance(expr, BoolLiteral):
            return "true" if expr.value else "false"
        if isinstance(expr, BinaryOp):
            left = self.generate_expr(expr.left)
            right = self.generate_expr(expr.right)
            if expr.op == '==':
                return f"{left}.as.int_val == {right}.as.int_val"
            elif expr.op == '!=':
                return f"{left}.as.int_val != {right}.as.int_val"
            elif expr.op == '<':
                return f"{left}.as.int_val < {right}.as.int_val"
            elif expr.op == '>':
                return f"{left}.as.int_val > {right}.as.int_val"
            elif expr.op == '<=':
                return f"{left}.as.int_val <= {right}.as.int_val"
            elif expr.op == '>=':
                return f"{left}.as.int_val >= {right}.as.int_val"
            elif expr.op == '&&':
                return f"{self.generate_condition(expr.left)} && {self.generate_condition(expr.right)}"
            elif expr.op == '||':
                return f"{self.generate_condition(expr.left)} || {self.generate_condition(expr.right)}"
        if isinstance(expr, UnaryOp) and expr.op == '!':
            return f"!{self.generate_condition(expr.expr)}"
        # Fall back to extracting bool_val from the generated expression
        return f"{self.generate_expr(expr)}.as.bool_val"

    def generate_expr(self, expr) -> str:
        if isinstance(expr, IntLiteral):
            return f"make_int({expr.value})"
        if isinstance(expr, FloatLiteral):
            return f"make_float({expr.value})"
        if isinstance(expr, StringLiteral):
            return f"make_string(\"{expr.value}\")"
        if isinstance(expr, CharLiteral):
            return f"make_char('{expr.value}')"
        if isinstance(expr, BoolLiteral):
            return f"make_bool({'true' if expr.value else 'false'})"
        if isinstance(expr, Identifier):
            # Use sanitized name if available
            name = self.name_map.get(expr.name, expr.name)
            # If it's a nullary constructor, call it as a function
            if expr.name in self.type_tags:
                # It's a constructor - check arity
                for type_name, ctors in self.type_info.items():
                    for ctor_name, arity in ctors:
                        if ctor_name == expr.name and arity == 0:
                            return f"{sanitize_name(name)}()"
            return name
        if isinstance(expr, Wildcard):
            return "make_unit()"
        if isinstance(expr, Block):
            # Block in expression context - last expr is the value
            result = "make_unit()"
            for e in expr.exprs:
                result = self.generate_expr(e)
            return result
        if isinstance(expr, BinaryOp):
            left = self.generate_expr(expr.left)
            right = self.generate_expr(expr.right)
            # For now, assume int operations
            if expr.op == '+':
                return f"make_int({left}.as.int_val + {right}.as.int_val)"
            elif expr.op == '-':
                return f"make_int({left}.as.int_val - {right}.as.int_val)"
            elif expr.op == '*':
                return f"make_int({left}.as.int_val * {right}.as.int_val)"
            elif expr.op == '/':
                return f"make_int({left}.as.int_val / {right}.as.int_val)"
            elif expr.op == '%':
                return f"make_int({left}.as.int_val % {right}.as.int_val)"
            elif expr.op == '==':
                return f"make_bool({left}.as.int_val == {right}.as.int_val)"
            elif expr.op == '!=':
                return f"make_bool({left}.as.int_val != {right}.as.int_val)"
            elif expr.op == '<':
                return f"make_bool({left}.as.int_val < {right}.as.int_val)"
            elif expr.op == '>':
                return f"make_bool({left}.as.int_val > {right}.as.int_val)"
            elif expr.op == '<=':
                return f"make_bool({left}.as.int_val <= {right}.as.int_val)"
            elif expr.op == '>=':
                return f"make_bool({left}.as.int_val >= {right}.as.int_val)"
            elif expr.op == '&&':
                return f"make_bool({left}.as.bool_val && {right}.as.bool_val)"
            elif expr.op == '||':
                return f"make_bool({left}.as.bool_val || {right}.as.bool_val)"
        if isinstance(expr, UnaryOp):
            inner = self.generate_expr(expr.expr)
            if expr.op == '-':
                return f"make_int(-{inner}.as.int_val)"
            elif expr.op == '!':
                return f"make_bool(!{inner}.as.bool_val)"
        if isinstance(expr, FnCall):
            # Handle built-in print
            if isinstance(expr.func, Identifier) and expr.func.name == 'print':
                if expr.args:
                    return f"(print_value({self.generate_expr(expr.args[0])}), make_unit())"
                return "make_unit()"
            # Handle built-in println
            if isinstance(expr.func, Identifier) and expr.func.name == 'println':
                if expr.args:
                    return f"(println_value({self.generate_expr(expr.args[0])}), make_unit())"
                return "make_unit()"
            # Handle built-in inspect
            if isinstance(expr.func, Identifier) and expr.func.name == 'inspect':
                if expr.args:
                    return f"(inspect_value({self.generate_expr(expr.args[0])}), make_unit())"
                return "make_unit()"

            func = self.generate_expr(expr.func)
            # Sanitize function names
            if isinstance(expr.func, Identifier):
                func = sanitize_name(expr.func.name)
            args = [self.generate_expr(a) for a in expr.args]
            return f"{func}({', '.join(args)})"
        if isinstance(expr, IfExpr):
            cond = self.generate_expr(expr.cond)
            then = self.generate_expr(expr.then_branch)
            else_ = self.generate_expr(expr.else_branch) if expr.else_branch else "make_unit()"
            return f"({cond}.as.bool_val ? {then} : {else_})"
        if isinstance(expr, MatchExpr):
            return self.generate_match_expr(expr)

        return "make_unit()"

    def generate_match_expr(self, match_expr: MatchExpr) -> str:
        # For expressions, we use ternary chains
        value_var = f"_m{abs(hash(str(match_expr))) % 10000}"
        result_parts = []

        # Generate value
        value_code = self.generate_expr(match_expr.value)

        # Build ternary chain
        parts = []
        for i, arm in enumerate(match_expr.arms):
            condition = self.generate_pattern_condition(arm.pattern, value_var)
            result = self.generate_expr(arm.body)
            parts.append((condition, result))

        # Build nested ternary
        if not parts:
            return "make_unit()"

        # Simple case: just generate the match as a statement with a result variable
        # This is a workaround for complex match expressions
        result_var = f"_result_{abs(hash(str(match_expr))) % 10000}"
        self.emit(f"Value {result_var};")
        self.emit(f"Value {value_var} = {value_code};")

        for i, (cond, result) in enumerate(parts):
            if i == 0:
                self.emit(f"if ({cond}) {{")
            else:
                self.emit(f"}} else if ({cond}) {{")
            self.indent += 1
            self.emit(f"{result_var} = {result};")
            self.indent -= 1
        self.emit("}")

        return result_var


def generate_c(program: Program) -> str:
    codegen = CodeGen()
    return codegen.generate(program)
