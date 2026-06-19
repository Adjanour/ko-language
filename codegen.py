"""Kō Codegen - C code generator for the Kō language"""

from dataclasses import dataclass
from typing import Dict, List, Set
from parser import (
    Program, FnDef, LetBinding, TypeDef, TypeConstructor,
    IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral,
    Identifier, Wildcard, BinaryOp, UnaryOp, FnCall, IfExpr, MatchExpr,
    MatchArm, PatLiteral, PatIdent, PatWildcard, PatConstructor,
    Block, LetExpr, Lambda, RefExpr, DerefExpr, SetExpr, ComptimeExpr
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


def escape_c_string(value: str) -> str:
    """Escape a string for inclusion in generated C source."""
    # First convert raw escape sequences (from lexer) to actual characters
    value = value.replace('\\n', '\n').replace('\\t', '\t').replace('\\r', '\r')
    # Then escape for C string literal
    return value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t').replace('\r', '\\r')


def escape_c_char(value: str) -> str:
    """Escape a char literal for inclusion in generated C source."""
    # First convert raw escape sequences (from lexer) to actual characters
    value = value.replace('\\n', '\n').replace('\\t', '\t').replace('\\r', '\r')
    # Then escape for C char literal
    return value.replace('\\', '\\\\').replace("'", "\\'").replace('\n', '\\n').replace('\t', '\\t').replace('\r', '\\r')


@dataclass
class CodeGen:
    def __init__(self):
        self.output = []
        self.indent = 0
        self.type_tags = {}  # constructor_name -> tag_number
        self.type_info = {}  # type_name -> [constructors]
        self.ctor_to_type = {}  # constructor_name -> type_name (for switch optimization)
        self.current_tag = 0
        self.defined_fns = set()
        self.needs_runtime = False
        self.name_map = {}  # original_name -> sanitized_name
        self.lambda_count = 0
        self.lambda_functions = []  # generated lambda functions to prepend
        self.env_counter = 0  # for unique environment variable names
        self.local_vars = []  # track local variables for dec_ref cleanup
        self.comptime_env = {}  # name -> ComptimeFn or Python value (for compile-time evaluation)
        self.comptime_step_limit = 10000  # prevent infinite loops at compile time


@dataclass
class ComptimeFn:
    """A function that can be evaluated at compile time."""
    params: List[str]
    body: 'Expr'
    env: Dict[str, object]  # captured environment

    def free_vars(self, expr, bound=None) -> Set[str]:
        """Find free variables in an expression.
        bound: set of variables bound in the current scope"""
        if bound is None:
            bound = set()
        
        # Stdlib functions are not free variables
        STDLIB_FUNCS = {'len', 'concat', 'char_at', 'substring', 'contains',
                       'to_upper', 'to_lower', 'trim', 'starts_with', 'ends_with',
                       'repeat', 'split', 'join', 'replace',
                       'abs', 'min', 'max', 'pow', 'sqrt', 'floor', 'ceil',
                       'mod', 'to_string', 'to_int', 'to_float', 'type_of',
                       'is_int', 'is_float', 'is_string', 'is_bool', 'is_null',
                       'ord', 'chr', 'parse_int', 'parse_float',
                       'read_line', 'read_file', 'write_file', 'append_file',
                       'run', 'get_env', 'args_count', 'args_get', 'exit', 'now',
                       'random', 'seed', 'assert', 'assert_eq', 'test', 'run_tests',
                       'print', 'println', 'inspect', 'panic',
                       'file_exists', 'sleep',
                       'head', 'tail', 'append', 'reverse', 'sum', 'product'}
        
        if isinstance(expr, Identifier):
            if expr.name not in bound and expr.name not in STDLIB_FUNCS:
                return {expr.name}
            return set()
        
        elif isinstance(expr, (IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral)):
            return set()
        
        elif isinstance(expr, BinaryOp):
            return self.free_vars(expr.left, bound) | self.free_vars(expr.right, bound)
        
        elif isinstance(expr, UnaryOp):
            return self.free_vars(expr.expr, bound)
        
        elif isinstance(expr, FnCall):
            result = self.free_vars(expr.func, bound)
            for arg in expr.args:
                result |= self.free_vars(arg, bound)
            return result
        
        elif isinstance(expr, IfExpr):
            result = self.free_vars(expr.cond, bound)
            result |= self.free_vars(expr.then_branch, bound)
            if expr.else_branch:
                result |= self.free_vars(expr.else_branch, bound)
            return result
        
        elif isinstance(expr, MatchExpr):
            result = self.free_vars(expr.value, bound)
            for arm in expr.arms:
                # Pattern bindings are added to bound
                arm_bound = bound | self.pattern_vars(arm.pattern)
                result |= self.free_vars(arm.body, arm_bound)
            return result
        
        elif isinstance(expr, Block):
            result = set()
            for e in expr.exprs:
                result |= self.free_vars(e, bound)
            return result
        
        elif isinstance(expr, LetExpr):
            result = self.free_vars(expr.value, bound)
            result |= self.free_vars(expr.body, bound | {expr.name})
            return result
        
        elif isinstance(expr, Lambda):
            # Lambda params are bound in the body
            body_bound = bound | set(expr.params)
            return self.free_vars(expr.body, body_bound)
        
        elif isinstance(expr, RefExpr):
            return self.free_vars(expr.value, bound)
        
        elif isinstance(expr, DerefExpr):
            return self.free_vars(expr.ref, bound)
        
        elif isinstance(expr, SetExpr):
            return self.free_vars(expr.ref, bound) | self.free_vars(expr.value, bound)
        
        return set()


# The generator methods are defined below at module scope.
# Bind them onto `CodeGen` after the definitions load.
    
    def pattern_vars(self, pattern) -> Set[str]:
        """Get variables bound by a pattern."""
        if isinstance(pattern, PatIdent):
            return {pattern.name}
        elif isinstance(pattern, PatWildcard):
            return set()
        elif isinstance(pattern, PatConstructor):
            result = set()
            for arg in pattern.args:
                result |= self.pattern_vars(arg)
            return result
        return set()
    
    def _generate_lambda_body(self, expr, fvs: List[str], fv_indices: dict, bound: Set[str] = None) -> str:
        """Generate C code for a lambda body, replacing free variable refs with env_unpack.
        Returns the C expression string."""
        if bound is None:
            bound = set()
        
        if isinstance(expr, Identifier):
            if expr.name in fv_indices and expr.name not in bound:
                idx = fv_indices[expr.name]
                return f"env_unpack(env, {idx})"
            return sanitize_name(expr.name)
        
        elif isinstance(expr, IntLiteral):
            return f"make_int({expr.value})"
        
        elif isinstance(expr, FloatLiteral):
            return f"make_float({expr.value})"
        
        elif isinstance(expr, StringLiteral):
            escaped = escape_c_string(expr.value)
            return f'make_string("{escaped}")'
        
        elif isinstance(expr, CharLiteral):
            inner = expr.value[1:-1]  # strip outer quotes from 'c'
            return f"make_char('{escape_c_char(inner)}')"
        
        elif isinstance(expr, BoolLiteral):
            return f"make_bool({str(expr.value).lower()})"
        
        elif isinstance(expr, BinaryOp):
            left = self._generate_lambda_body(expr.left, fvs, fv_indices, bound)
            right = self._generate_lambda_body(expr.right, fvs, fv_indices, bound)
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
                return self._eq_expr(left, right)
            elif expr.op == '!=':
                return self._ne_expr(left, right)
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
        
        elif isinstance(expr, FnCall):
            # For now, assume it's a simple function call
            func = self._generate_lambda_body(expr.func, fvs, fv_indices, bound)
            args = [self._generate_lambda_body(a, fvs, fv_indices, bound) for a in expr.args]
            return f"{func}({', '.join(args)})"
        
        elif isinstance(expr, IfExpr):
            cond = self._generate_lambda_body(expr.cond, fvs, fv_indices, bound)
            then = self._generate_lambda_body(expr.then_branch, fvs, fv_indices, bound)
            else_ = self._generate_lambda_body(expr.else_branch, fvs, fv_indices, bound) if expr.else_branch else "make_unit()"
            return f"({cond}.as.bool_val ? {then} : {else_})"
        
        elif isinstance(expr, Block):
            # Block in expression context - last expr is the value
            if not expr.exprs:
                return "make_unit()"
            result = "make_unit()"
            for e in expr.exprs:
                result = self._generate_lambda_body(e, fvs, fv_indices, bound)
            return result
        
        elif isinstance(expr, RefExpr):
            value = self._generate_lambda_body(expr.value, fvs, fv_indices, bound)
            return f"ko_ref({value})"
        
        elif isinstance(expr, DerefExpr):
            ref = self._generate_lambda_body(expr.ref, fvs, fv_indices, bound)
            return f"ko_deref({ref})"
        
        elif isinstance(expr, SetExpr):
            ref = self._generate_lambda_body(expr.ref, fvs, fv_indices, bound)
            value = self._generate_lambda_body(expr.value, fvs, fv_indices, bound)
            return f"ko_set({ref}, {value})"
        
        # Default: use the regular generate_expr
        return self.generate_expr(expr)

    def emit(self, line: str):
        self.output.append("  " * self.indent + line)

    def emit_raw(self, line: str):
        self.output.append(line)

    def generate(self, program: Program) -> str:
        # First pass: collect type info
        user_defined_list = False
        for defn in program.definitions:
            if isinstance(defn, TypeDef):
                self.register_type(defn)
                if "Nil" in self.type_tags and "Cons" in self.type_tags:
                    user_defined_list = True

        # Register built-in list type (Nil/Cons) if not user-defined
        # Tags must match runtime.h: Cons=0, Nil=1
        if not user_defined_list:
            self.type_tags["Nil"] = 1
            self.type_tags["Cons"] = 0
            self.current_tag = 2  # user types start after built-in list tags

        # Second pass: register comptime functions
        for defn in program.definitions:
            if isinstance(defn, FnDef) and defn.comptime:
                self.comptime_env[defn.name] = ComptimeFn(defn.params, defn.body, self.comptime_env)

        # Type checking pass (validate annotations)
        self.type_check(program)

        # Generate runtime header
        self.generate_runtime()

        # Generate CONSTRUCTOR_NAMES array for inspect (always needed by runtime.h)
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
        else:
            self.emit("static const char* CONSTRUCTOR_NAMES[] = {\"__none__\"};")
        self.emit_raw("")

        # Generate type definitions
        for defn in program.definitions:
            if isinstance(defn, TypeDef):
                self.generate_type(defn)

        # Generate built-in list type (Nil/Cons) if we registered it (not user-defined)
        if not user_defined_list and "Nil" in self.type_tags and "Cons" in self.type_tags:
            nil_tag = self.type_tags["Nil"]
            cons_tag = self.type_tags["Cons"]
            self.emit(f"enum {{")
            self.indent += 1
            self.emit(f"TAG_CONS = {cons_tag},")
            self.emit(f"TAG_NIL = {nil_tag},")
            self.indent -= 1
            self.emit(f"}};")
            self.emit_raw("")

            # Generate Nil constructor (no args)
            self.emit(f"Value ko_Nil() {{")
            self.indent += 1
            self.emit(f"return make_constructor(TAG_NIL, 0);")
            self.indent -= 1
            self.emit("}")
            self.emit_raw("")

            # Generate Cons constructor (2 args)
            self.emit(f"Value ko_Cons(Value arg0, Value arg1) {{")
            self.indent += 1
            self.emit(f"Value v = make_constructor(TAG_CONS, 2);")
            self.emit(f"v.as.constructor->args[0] = arg0;")
            self.emit(f"v.as.constructor->args[1] = arg1;")
            self.emit(f"return v;")
            self.indent -= 1
            self.emit("}")
            self.emit_raw("")

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
            self.emit("int main(int argc, char* argv[]) {")
            self.indent += 1
            self.emit("_argc = argc;")
            self.emit("_argv = argv;")
            self.emit("_ko_main();")
            self.emit("return 0;")
            self.indent -= 1
            self.emit("}")

        # Generate lambda functions (collected during codegen)
        # They need to be before main, so we check if main exists and insert before it
        if self.lambda_functions:
            # Find where main is in the output and insert before it
            main_idx = None
            for i, line in enumerate(self.output):
                if 'int main(' in line:
                    main_idx = i
                    break
            
            # Add forward declarations for lambda functions
            lambda_forward = [""]
            lambda_forward.append("// Lambda function forward declarations")
            for lambda_func in self.lambda_functions:
                # Extract function signature for forward declaration
                first_line = lambda_func.split('\n')[0]
                if first_line.startswith('Value '):
                    # Add forward declaration
                    sig = first_line.rstrip(' {') + ';'
                    lambda_forward.append(sig)
            
            lambda_lines = [""]
            lambda_lines.append("// Lambda functions")
            for lambda_func in self.lambda_functions:
                # Split multi-line lambda functions into individual lines
                for line in lambda_func.split('\n'):
                    if line.strip():  # Skip empty lines
                        lambda_lines.append(line)
            
            if main_idx is not None:
                # Insert forward declarations before function forward declarations
                # Find where function forward declarations end
                func_fwd_idx = None
                for i, line in enumerate(self.output):
                    if line.startswith('Value ') and line.endswith(');'):
                        func_fwd_idx = i
                        break
                
                if func_fwd_idx is not None:
                    # Insert forward declarations after the last function forward declaration
                    # Find the end of forward declarations (first empty line after func_fwd_idx)
                    insert_idx = func_fwd_idx + 1
                    while insert_idx < len(self.output) and self.output[insert_idx].strip():
                        insert_idx += 1
                    self.output = self.output[:insert_idx] + lambda_forward + self.output[insert_idx:]
                    
                    # Re-find main_idx after insertion
                    for i, line in enumerate(self.output):
                        if 'int main(' in line:
                            main_idx = i
                            break
                
                # Insert lambda functions before main
                self.output = self.output[:main_idx] + lambda_lines + self.output[main_idx:]
            else:
                # No main, just append
                self.output.extend(lambda_forward)
                self.output.extend(lambda_lines)

        return "\n".join(self.output)

    def register_type(self, typedef: TypeDef):
        constructors = []
        for ctor in typedef.constructors:
            tag = self.current_tag
            self.type_tags[ctor.name] = tag
            self.ctor_to_type[ctor.name] = typedef.name
            constructors.append((ctor.name, ctor.fields))
            self.current_tag += 1
        self.type_info[typedef.name] = constructors

    def type_check(self, program: Program):
        """Simple type checking: validate type annotations against actual usage.
        For now, just check that annotated functions have matching definitions."""
        for defn in program.definitions:
            if isinstance(defn, FnDef) and defn.type_ann is not None:
                # Check that the function has parameters
                if not defn.params:
                    # Type annotation only (no body yet) - skip
                    continue
                # For now, just print a warning if the function has a type annotation
                # Full type checking would require inference
                pass

    def generate_runtime(self):
        import os
        runtime_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'runtime.h')
        with open(runtime_path) as f:
            runtime = f.read()
        self.emit_raw(runtime)

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
                    self.emit(f"v.as.constructor->args[{i}] = arg{i};")
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
        # Add function name to name map so references resolve to sanitized name
        self.name_map[fndef.name] = name
        # Sanitize parameter names and add to name map
        params = []
        saved_locals = self.local_vars
        self.local_vars = []
        for p in fndef.params:
            sanitized = sanitize_name(p)
            self.name_map[p] = sanitized
            params.append(f"Value {sanitized}")
        self.emit(f"Value {name}({', '.join(params)}) {{")
        self.indent += 1

        self.generate_statement(fndef.body)

        # For _ko_main, emit cleanup for let-bound variables
        if name == "_ko_main" and self.local_vars:
            for var in self.local_vars:
                self.emit(f"dec_ref({var});")

        self.indent -= 1
        self.emit("}")
        self.emit_raw("")
        self.local_vars = saved_locals

    def generate_statement(self, expr):
        if isinstance(expr, Block):
            for i, e in enumerate(expr.exprs):
                if i < len(expr.exprs) - 1:
                    # Non-final: generate as expression statement
                    self.emit(f"{self.generate_expr(e)};")
                else:
                    # Last expression is the return value
                    self.generate_statement(e)
        elif isinstance(expr, LetExpr):
            sanitized = sanitize_name(expr.name)
            self.name_map[expr.name] = sanitized
            self.local_vars.append(sanitized)
            self.emit(f"Value {sanitized} = {self.generate_expr(expr.value)};")
            self.generate_statement(expr.body)
        elif isinstance(expr, IfExpr):
            cond = self.generate_condition(expr.cond)
            saved_count = len(self.local_vars)
            self.emit(f"if ({cond}) {{")
            self.indent += 1
            self.generate_statement(expr.then_branch)
            then_count = len(self.local_vars)
            self.local_vars = self.local_vars[:saved_count]
            self.indent -= 1
            if expr.else_branch:
                self.emit("} else {")
                self.indent += 1
                self.generate_statement(expr.else_branch)
                self.local_vars = self.local_vars[:saved_count]
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
        # I/O functions that should be statements (discard return value)
        elif isinstance(expr, FnCall) and isinstance(expr.func, Identifier) and expr.func.name in ('write_file', 'append_file', 'exit', 'assert', 'assert_eq', 'test', 'run_tests', 'panic'):
            STDLIB_MAP = {'write_file': 'write_file', 'append_file': 'append_file', 'exit': 'exit_with',
                          'assert': 'ko_assert', 'assert_eq': 'ko_assert_eq', 'test': 'ko_test', 'run_tests': 'ko_run_tests',
                          'panic': 'panic_value'}
            func_name = STDLIB_MAP[expr.func.name]
            args = [self.generate_expr(a) for a in expr.args]
            self.emit(f"{func_name}({', '.join(args)});")
        else:
            result_expr = self.generate_expr(expr)
            if self.local_vars:
                self.emit(f"Value _ko_result = {result_expr};")
                for var in self.local_vars:
                    self.emit(f"dec_ref({var});")
                self.emit("return _ko_result;")
            else:
                self.emit(f"return {result_expr};")

    def generate_match_statement(self, match_expr: MatchExpr):
        if self._match_is_switch_eligible(match_expr):
            return self.generate_match_statement_switch(match_expr)

        value_var = f"_match_{id(match_expr)}"
        self.emit(f"Value {value_var} = {self.generate_expr(match_expr.value)};")

        saved_local_count = len(self.local_vars)
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
            # Remove any variables added inside this arm from tracking
            self.local_vars = self.local_vars[:saved_local_count]
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
                return f"match_string({value_var}, \"{escape_c_string(pattern.value)}\")"
        if isinstance(pattern, PatIdent):
            return "true"  # Always matches
        if isinstance(pattern, PatConstructor):
            tag = self.type_tags.get(pattern.name, -1)
            condition = f"{value_var}.type == VAL_CONSTRUCTOR && {value_var}.as.constructor->tag == TAG_{pattern.name.upper()}"
            if pattern.args:
                conditions = [condition]
                for i, arg in enumerate(pattern.args):
                    sub_var = f"{value_var}.as.constructor->args[{i}]"
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
                sub_var = f"{value_var}.as.constructor->args[{i}]"
                bindings.update(self.extract_pattern_bindings(arg, sub_var))
        return bindings

    def _eq_expr(self, left, right):
        """Generate C equality expression that handles strings."""
        return f"(({left}).type == VAL_STRING && ({right}).type == VAL_STRING ? make_bool(strcmp(({left}).as.string->data, ({right}).as.string->data) == 0) : make_bool(({left}).as.int_val == ({right}).as.int_val))"

    def _ne_expr(self, left, right):
        """Generate C inequality expression that handles strings."""
        return f"(({left}).type == VAL_STRING && ({right}).type == VAL_STRING ? make_bool(strcmp(({left}).as.string->data, ({right}).as.string->data) != 0) : make_bool(({left}).as.int_val != ({right}).as.int_val))"

    def generate_condition(self, expr) -> str:
        """Generate a raw C boolean expression for use in if/while conditions."""
        if isinstance(expr, BoolLiteral):
            return "true" if expr.value else "false"
        if isinstance(expr, BinaryOp):
            left = self.generate_expr(expr.left)
            right = self.generate_expr(expr.right)
            if expr.op == '==':
                return f"(({left}).type == VAL_STRING && ({right}).type == VAL_STRING ? strcmp(({left}).as.string->data, ({right}).as.string->data) == 0 : ({left}).as.int_val == ({right}).as.int_val)"
            elif expr.op == '!=':
                return f"(({left}).type == VAL_STRING && ({right}).type == VAL_STRING ? strcmp(({left}).as.string->data, ({right}).as.string->data) != 0 : ({left}).as.int_val != ({right}).as.int_val)"
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
            return f"make_string(\"{escape_c_string(expr.value)}\")"
        if isinstance(expr, CharLiteral):
            inner = expr.value[1:-1]
            return f"make_char('{escape_c_char(inner)}')"
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
            # Handle nullary stdlib functions
            NULLARY_STDLIB = {'args_count': 'args_count', 'now': 'ko_now', 'seed': 'ko_seed', 'run_tests': 'ko_run_tests'}
            if expr.name in NULLARY_STDLIB:
                return f"{NULLARY_STDLIB[expr.name]}()"
            # If it's a function reference (used as argument), wrap as closure
            if expr.name in self.defined_fns:
                # Wrap function as closure with NULL env
                return f"make_closure(NULL, (ClosureFn){sanitize_name(name)})"
            return name
        if isinstance(expr, Wildcard):
            return "make_unit()"
        if isinstance(expr, Block):
            # Block in expression context - last expr is the value
            result = "make_unit()"
            for e in expr.exprs:
                result = self.generate_expr(e)
            return result
        if isinstance(expr, Lambda):
            # Closure conversion: hoist lambda to top level with env parameter
            # If lambda has multiple params, curry it: \a b -> body becomes \a -> \b -> body
            if len(expr.params) > 1:
                # Curry the lambda
                inner_body = Lambda(expr.params[1:], expr.body)
                curried = Lambda([expr.params[0]], inner_body)
                return self.generate_expr(curried)
            
            self.lambda_count += 1
            lambda_name = f"_ko_lambda_{self.lambda_count}"
            
            # Find free variables
            fvs = sorted(self.free_vars(expr))
            
            # Generate the hoisted function: Value name(Env* env, Value param1, ...)
            env_param = "Env* env"
            params = [f"Value {sanitize_name(p)}" for p in expr.params]
            all_params = [env_param] + params
            
            # Generate body with variable references replaced by env_unpack
            # We need to track which free vars are at which index
            fv_indices = {v: i for i, v in enumerate(fvs)}
            
            # Generate the function body
            body_code = self._generate_lambda_body(expr.body, fvs, fv_indices)
            
            func_code = f"Value {lambda_name}({', '.join(all_params)}) {{\n"
            func_code += f"  return {body_code};\n"
            func_code += "}\n"
            self.lambda_functions.append(func_code)
            
            # Generate closure creation at the call site
            if not fvs:
                # No free variables - can use NULL env
                return f"make_closure(NULL, (ClosureFn){lambda_name})"
            else:
                # Pack free variables into environment
                helper_name = f"_ko_make_closure_{self.lambda_count}"
                helper_code = f"Value {helper_name}("
                helper_code += ", ".join([f"Value {sanitize_name(fv)}" for fv in fvs])
                helper_code += f") {{\n"
                helper_code += f"  Env* _env = make_env({len(fvs)});\n"
                for i, fv in enumerate(fvs):
                    helper_code += f"  env_pack(_env, {i}, {sanitize_name(fv)});\n"
                helper_code += f"  return make_closure(_env, (ClosureFn){lambda_name});\n"
                helper_code += "}\n"
                self.lambda_functions.append(helper_code)
                return f"{helper_name}({', '.join([sanitize_name(fv) for fv in fvs])})"
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
                return self._eq_expr(left, right)
            elif expr.op == '!=':
                return self._ne_expr(left, right)
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

            # Standard library functions
            STDLIB = {
                'len': 'len', 'concat': 'concat', 'char_at': 'char_at',
                'substring': 'substring', 'contains': 'contains',
                'to_upper': 'to_upper', 'to_lower': 'to_lower',
                'trim': 'trim', 'starts_with': 'starts_with', 'ends_with': 'ends_with',
                'repeat': 'repeat', 'split': 'ko_split', 'join': 'ko_join',
                'replace': 'ko_replace',
                'abs': 'ko_abs', 'min': 'ko_min', 'max': 'ko_max',
                'pow': 'ko_pow', 'sqrt': 'ko_sqrt', 'floor': 'ko_floor', 'ceil': 'ko_ceil',
                'mod': 'mod', 'to_string': 'to_string', 'to_int': 'to_int',
                'to_float': 'to_float', 'type_of': 'type_of',
                'is_int': 'is_int', 'is_float': 'is_float',
                'is_string': 'is_string', 'is_bool': 'is_bool', 'is_null': 'ko_is_null',
                'ord': 'ko_ord', 'chr': 'ko_chr',
                'parse_int': 'ko_parse_int', 'parse_float': 'ko_parse_float',
                # I/O (functional - all return values)
                'read_line': 'read_line', 'read_file': 'read_file',
                'write_file': 'write_file', 'append_file': 'append_file',
                'run': 'run_command', 'get_env': 'get_env',
                'args_count': 'args_count', 'args_get': 'args_get',
                'exit': 'exit_with', 'now': 'ko_now',
                'panic': 'panic_value',
                # Random (pure)
                'random': 'ko_random', 'seed': 'ko_seed',
                # Testing
                'assert': 'ko_assert', 'assert_eq': 'ko_assert_eq',
                'test': 'ko_test', 'run_tests': 'ko_run_tests',
                # File system
                'file_exists': 'ko_file_exists',
                'sleep': 'ko_sleep',
                # List operations
                'head': 'ko_head', 'tail': 'ko_tail',
                'append': 'ko_append', 'reverse': 'ko_reverse',
                'sum': 'ko_sum', 'product': 'ko_product',
            }

            if isinstance(expr.func, Identifier) and expr.func.name in STDLIB:
                func_name = STDLIB[expr.func.name]
                args = [self.generate_expr(a) for a in expr.args]
                return f"{func_name}({', '.join(args)})"

            func = self.generate_expr(expr.func)
            # Sanitize function names
            if isinstance(expr.func, Identifier):
                func = sanitize_name(expr.func.name)
            args = [self.generate_expr(a) for a in expr.args]
            
            # Check if this is a closure (not a known named function)
            if isinstance(expr.func, Identifier) and expr.func.name in self.defined_fns:
                # Known named function - direct call
                return f"{func}({', '.join(args)})"
            elif isinstance(expr.func, Identifier) and expr.func.name in STDLIB:
                # Stdlib function - direct call
                return f"{func}({', '.join(args)})"
            else:
                # Could be a closure - use apply_value with appropriate arity
                if len(args) == 1:
                    return f"apply_value({func}, {args[0]})"
                elif len(args) == 2:
                    return f"apply_value_2({func}, {args[0]}, {args[1]})"
                elif len(args) == 3:
                    return f"apply_value_3({func}, {args[0]}, {args[1]}, {args[2]})"
                else:
                    # For more than 3 args, chain apply_value calls
                    result = f"apply_value({func}, {args[0]})"
                    for arg in args[1:]:
                        result = f"apply_value({result}, {arg})"
                    return result
        if isinstance(expr, IfExpr):
            cond = self.generate_expr(expr.cond)
            then = self.generate_expr(expr.then_branch)
            else_ = self.generate_expr(expr.else_branch) if expr.else_branch else "make_unit()"
            return f"({cond}.as.bool_val ? {then} : {else_})"
        if isinstance(expr, MatchExpr):
            return self.generate_match_expr(expr)
        if isinstance(expr, RefExpr):
            value = self.generate_expr(expr.value)
            return f"ko_ref({value})"
        if isinstance(expr, DerefExpr):
            ref = self.generate_expr(expr.ref)
            return f"ko_deref({ref})"
        if isinstance(expr, SetExpr):
            ref = self.generate_expr(expr.ref)
            value = self.generate_expr(expr.value)
            return f"ko_set({ref}, {value})"
        if isinstance(expr, ComptimeExpr):
            # Evaluate at compile time
            result = self.eval_comptime(expr.expr)
            if isinstance(result, int):
                return f"make_int({result})"
            elif isinstance(result, float):
                return f"make_float({result})"
            elif isinstance(result, bool):
                return f"make_bool({'true' if result else 'false'})"
            elif isinstance(result, str):
                escaped = result.replace('\\', '\\\\').replace('"', '\\"')
                return f'make_string("{escaped}")'
            # If we can't evaluate, just generate normally
            return self.generate_expr(expr.expr)

        return "make_unit()"
    
    def eval_comptime(self, expr, steps=0) -> object:
        """Evaluate an expression at compile time. Returns a Python value or None if not possible."""
        if steps > self.comptime_step_limit:
            return None  # Prevent infinite loops

        if isinstance(expr, IntLiteral):
            return expr.value
        elif isinstance(expr, FloatLiteral):
            return expr.value
        elif isinstance(expr, BoolLiteral):
            return expr.value
        elif isinstance(expr, StringLiteral):
            return expr.value
        elif isinstance(expr, Identifier):
            # Look up in comptime environment
            if expr.name in self.comptime_env:
                return self.comptime_env[expr.name]
            return None
        elif isinstance(expr, BinaryOp):
            left = self.eval_comptime(expr.left, steps + 1)
            right = self.eval_comptime(expr.right, steps + 1)
            if left is None or right is None:
                return None
            if expr.op == '+': return left + right
            elif expr.op == '-': return left - right
            elif expr.op == '*': return left * right
            elif expr.op == '/': return left // right if isinstance(left, int) and isinstance(right, int) else left / right
            elif expr.op == '%': return left % right
            elif expr.op == '==': return left == right
            elif expr.op == '!=': return left != right
            elif expr.op == '<': return left < right
            elif expr.op == '>': return left > right
            elif expr.op == '<=': return left <= right
            elif expr.op == '>=': return left >= right
            elif expr.op == '&&': return left and right
            elif expr.op == '||': return left or right
        elif isinstance(expr, UnaryOp):
            val = self.eval_comptime(expr.expr, steps + 1)
            if val is None: return None
            if expr.op == '-': return -val
            elif expr.op == '!': return not val
        elif isinstance(expr, IfExpr):
            cond = self.eval_comptime(expr.cond, steps + 1)
            if cond is None: return None
            if cond:
                return self.eval_comptime(expr.then_branch, steps + 1)
            elif expr.else_branch:
                return self.eval_comptime(expr.else_branch, steps + 1)
        elif isinstance(expr, FnCall):
            # Evaluate the function
            func_val = self.eval_comptime(expr.func, steps + 1)
            if isinstance(func_val, ComptimeFn):
                # Evaluate arguments
                args = [self.eval_comptime(a, steps + 1) for a in expr.args]
                if any(a is None for a in args):
                    return None
                if len(args) != len(func_val.params):
                    return None
                # Create child environment with params bound to arg values
                child_env = {**func_val.env}
                for param, arg in zip(func_val.params, args):
                    child_env[param] = arg
                # Evaluate body in the child environment
                saved_env = self.comptime_env
                self.comptime_env = child_env
                try:
                    result = self.eval_comptime(func_val.body, steps + 1)
                finally:
                    self.comptime_env = saved_env
                return result
            return None
        elif isinstance(expr, LetExpr):
            val = self.eval_comptime(expr.value, steps + 1)
            if val is None:
                return None
            saved = self.comptime_env.get(expr.name)
            self.comptime_env[expr.name] = val
            try:
                result = self.eval_comptime(expr.body, steps + 1)
            finally:
                if saved is not None:
                    self.comptime_env[expr.name] = saved
                elif expr.name in self.comptime_env:
                    del self.comptime_env[expr.name]
            return result
        elif isinstance(expr, Block):
            # Evaluate all expressions in the block, return the last one
            result = None
            for e in expr.exprs:
                result = self.eval_comptime(e, steps + 1)
            return result
        return None

    def generate_match_expr(self, match_expr: MatchExpr) -> str:
        """Generate a match expression used in expression context (e.g., let x = match ...).
        
        Emits the if/else chain and returns the result variable name.
        """
        if self._match_is_switch_eligible(match_expr):
            return self.generate_match_expr_switch(match_expr)

        value_var = f"_m{abs(hash(str(match_expr))) % 10000}"
        result_var = f"_result_{abs(hash(str(match_expr))) % 10000}"

        # Generate value
        value_code = self.generate_expr(match_expr.value)
        self.emit(f"Value {value_var} = {value_code};")
        self.emit(f"Value {result_var};")

        # Build if/else chain
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

            body_result = self.generate_expr(arm.body)
            self.emit(f"{result_var} = {body_result};")
            self.indent -= 1
        self.emit("}")

        return result_var

    # ===== Switch Optimization =====

    def _match_is_switch_eligible(self, match_expr: MatchExpr) -> bool:
        """Check if a match expression can use C switch on constructor tag."""
        if len(match_expr.arms) < 4:
            return False

        constructor_arms = 0
        first_type = None

        for arm in match_expr.arms:
            if isinstance(arm.pattern, PatConstructor):
                type_name = self.ctor_to_type.get(arm.pattern.name)
                if type_name is None:
                    return False
                if first_type is None:
                    first_type = type_name
                elif type_name != first_type:
                    return False
                # Check for literal args (can't switch on those easily)
                if self._pattern_has_literal_args(arm.pattern):
                    return False
                constructor_arms += 1
            elif isinstance(arm.pattern, (PatWildcard, PatIdent)):
                pass
            else:
                return False

        return constructor_arms >= 4

    def _pattern_has_literal_args(self, pattern: PatConstructor) -> bool:
        """Check if any argument of a PatConstructor is a PatLiteral."""
        for arg in pattern.args:
            if isinstance(arg, PatLiteral):
                return True
            if isinstance(arg, PatConstructor) and self._pattern_has_literal_args(arg):
                return True
        return False

    def generate_match_statement_switch(self, match_expr: MatchExpr):
        """Generate a switch statement for match expressions with ≥4 constructor arms."""
        value_var = f"_match_{id(match_expr)}"
        self.emit(f"Value {value_var} = {self.generate_expr(match_expr.value)};")

        saved_local_count = len(self.local_vars)
        self.emit(f"if ({value_var}.type == VAL_CONSTRUCTOR) {{")
        self.indent += 1
        self.emit(f"switch ({value_var}.as.constructor->tag) {{")
        self.indent += 1

        for arm in match_expr.arms:
            if isinstance(arm.pattern, PatConstructor):
                tag_name = f"TAG_{arm.pattern.name.upper()}"
                self.emit(f"case {tag_name}: {{")
                self.indent += 1

                # Generate bindings from constructor args
                bindings = self.extract_pattern_bindings(arm.pattern, value_var)
                for name in bindings:
                    sanitized = sanitize_name(name)
                    self.name_map[name] = sanitized
                    self.emit(f"Value {sanitized} = {bindings[name]};")

                # Generate sub-pattern checks (for nested constructors in args)
                sub_conditions = self._collect_sub_pattern_conditions(arm.pattern, value_var)
                if sub_conditions:
                    self.emit(f"if ({' && '.join(sub_conditions)}) {{")
                    self.indent += 1

                self.generate_statement(arm.body)

                if sub_conditions:
                    self.indent -= 1
                    self.emit("}")
                self.emit("break;")
                self.indent -= 1
                self.emit("}")
            elif isinstance(arm.pattern, (PatWildcard, PatIdent)):
                self.emit("default: {")
                self.indent += 1
                if isinstance(arm.pattern, PatIdent):
                    sanitized = sanitize_name(arm.pattern.name)
                    self.name_map[arm.pattern.name] = sanitized
                    self.emit(f"Value {sanitized} = {value_var};")
                self.generate_statement(arm.body)
                self.emit("break;")
                self.indent -= 1
                self.emit("}")

            self.local_vars = self.local_vars[:saved_local_count]

        self.indent -= 1
        self.emit("}")
        self.indent -= 1
        self.emit("}")

    def generate_match_expr_switch(self, match_expr: MatchExpr) -> str:
        """Generate a switch expression for match expressions with ≥4 constructor arms."""
        value_var = f"_m{abs(hash(str(match_expr))) % 10000}"
        result_var = f"_result_{abs(hash(str(match_expr))) % 10000}"

        value_code = self.generate_expr(match_expr.value)
        self.emit(f"Value {value_var} = {value_code};")
        self.emit(f"Value {result_var};")

        self.emit(f"if ({value_var}.type == VAL_CONSTRUCTOR) {{")
        self.indent += 1
        self.emit(f"switch ({value_var}.as.constructor->tag) {{")
        self.indent += 1

        saved_local_count = len(self.local_vars)
        for arm in match_expr.arms:
            if isinstance(arm.pattern, PatConstructor):
                tag_name = f"TAG_{arm.pattern.name.upper()}"
                self.emit(f"case {tag_name}: {{")
                self.indent += 1

                bindings = self.extract_pattern_bindings(arm.pattern, value_var)
                for name in bindings:
                    sanitized = sanitize_name(name)
                    self.name_map[name] = sanitized
                    self.emit(f"Value {sanitized} = {bindings[name]};")

                sub_conditions = self._collect_sub_pattern_conditions(arm.pattern, value_var)
                if sub_conditions:
                    self.emit(f"if ({' && '.join(sub_conditions)}) {{")
                    self.indent += 1

                body_result = self.generate_expr(arm.body)
                self.emit(f"{result_var} = {body_result};")

                if sub_conditions:
                    self.indent -= 1
                    self.emit("}")
                self.emit("break;")
                self.indent -= 1
                self.emit("}")
            elif isinstance(arm.pattern, (PatWildcard, PatIdent)):
                self.emit("default: {")
                self.indent += 1
                if isinstance(arm.pattern, PatIdent):
                    sanitized = sanitize_name(arm.pattern.name)
                    self.name_map[arm.pattern.name] = sanitized
                    self.emit(f"Value {sanitized} = {value_var};")
                body_result = self.generate_expr(arm.body)
                self.emit(f"{result_var} = {body_result};")
                self.emit("break;")
                self.indent -= 1
                self.emit("}")

            self.local_vars = self.local_vars[:saved_local_count]

        self.indent -= 1
        self.emit("}")
        self.indent -= 1
        self.emit("}")

        return result_var

    def _collect_sub_pattern_conditions(self, pattern: PatConstructor, value_var: str) -> list:
        """Collect conditions for sub-patterns (nested constructors in args)."""
        conditions = []
        for i, arg in enumerate(pattern.args):
            if isinstance(arg, PatConstructor):
                sub_var = f"{value_var}.as.constructor->args[{i}]"
                cond = self.generate_pattern_condition(arg, sub_var)
                if cond != "true":
                    conditions.append(cond)
        return conditions


def generate_c(program: Program) -> str:
    codegen = CodeGen()
    return codegen.generate(program)


for _name, _value in list(ComptimeFn.__dict__.items()):
    if callable(_value) and not _name.startswith('__'):
        setattr(CodeGen, _name, _value)
