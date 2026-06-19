#!/usr/bin/env python3
"""Kō Compiler - Main entry point"""

import sys
import os
import subprocess
from lexer import tokenize, LexerError
from parser import (
    parse, ParseError, Program, FnDef, LetBinding, TypeDef, TypeConstructor,
    IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral,
    Identifier, Wildcard, BinaryOp, UnaryOp, FnCall, IfExpr, MatchExpr,
    MatchArm, Block, LetExpr, Lambda, RefExpr, DerefExpr, SetExpr, ComptimeExpr,
    PatLiteral, PatIdent, PatWildcard, PatConstructor,
)
from codegen import generate_c
from semantic import check_exhaustiveness


def _resolve_import_file(path: str, current_dir: str, search_paths: list = None) -> str:
    """Resolve an import to an on-disk file path."""
    if search_paths is None:
        search_paths = []
    
    # Try relative path first
    if path.startswith('"') and path.endswith('"'):
        # Relative path
        rel_path = path[1:-1]
        full_path = os.path.join(current_dir, rel_path)
        if os.path.exists(full_path):
            return os.path.abspath(full_path)
    else:
        # Module name - search in search paths
        for search_path in search_paths:
            full_path = os.path.join(search_path, f"{path}.ko")
            if os.path.exists(full_path):
                return os.path.abspath(full_path)
        
        # Try current directory
        full_path = os.path.join(current_dir, f"{path}.ko")
        if os.path.exists(full_path):
            return os.path.abspath(full_path)
    
    raise FileNotFoundError(f"Could not find module: {path}.ko (searched: {search_paths + [current_dir]})")


def load_import(path: str, current_dir: str, search_paths: list = None) -> str:
    """Load an imported file. Returns the source code."""
    full_path = _resolve_import_file(path, current_dir, search_paths)
    with open(full_path) as f:
        return f.read()


def resolve_imports(program: Program, current_dir: str, search_paths: list = None, filename: str = "<input>", visited: set = None):
    """Resolve imports by loading and parsing imported files."""
    if not program.imports:
        return program

    if visited is None:
        visited = set()
    
    all_definitions = []
    all_imports = []
    
    for imp in program.imports:
        try:
            resolved_path = _resolve_import_file(imp.path, current_dir, search_paths)
            if resolved_path in visited:
                raise Exception(f"Circular import detected: {resolved_path}")
            visited.add(resolved_path)

            source = load_import(imp.path, current_dir, search_paths)
            tokens = tokenize(source)
            imported_program = parse(tokens, imp.path)
            
            # Recursively resolve imports in imported file
            imported_dir = os.path.dirname(resolved_path)
            imported_program = resolve_imports(imported_program, imported_dir, search_paths, imp.path, visited)
            
            # Add imported definitions (with optional alias prefix)
            if imp.alias:
                all_definitions.extend(_prefix_import_definitions(imported_program.definitions, imp.alias))
            else:
                all_definitions.extend(imported_program.definitions)
            visited.remove(resolved_path)
        except FileNotFoundError as e:
            # Create a simple error with location info
            error_msg = str(e)
            if imp.loc:
                error_msg = f"{imp.loc.file}:{imp.loc.line}:{imp.loc.col}: {error_msg}"
            raise Exception(error_msg)
    
    # Combine: imported definitions first, then current program's definitions
    all_definitions.extend(program.definitions)
    return Program([], all_definitions)


def _prefix_import_definitions(definitions, prefix: str):
    name_map = {}

    for defn in definitions:
        if isinstance(defn, FnDef):
            name_map[defn.name] = f"{prefix}_{defn.name}"
        elif isinstance(defn, LetBinding):
            name_map[defn.name] = f"{prefix}_{defn.name}"
        elif isinstance(defn, TypeDef):
            name_map[defn.name] = f"{prefix}_{defn.name}"
            for ctor in defn.constructors:
                name_map[ctor.name] = f"{prefix}_{ctor.name}"

    return [_rename_definition(defn, name_map) for defn in definitions]


def _rename_definition(defn, name_map):
    if isinstance(defn, FnDef):
        return FnDef(
            name_map.get(defn.name, defn.name),
            list(defn.params),
            _rename_expr(defn.body, name_map),
            _rename_type_expr(defn.type_ann, name_map) if defn.type_ann else None,
            defn.comptime,
            defn.loc,
        )
    if isinstance(defn, LetBinding):
        return LetBinding(
            name_map.get(defn.name, defn.name),
            _rename_expr(defn.value, name_map),
            defn.loc,
        )
    if isinstance(defn, TypeDef):
        return TypeDef(
            name_map.get(defn.name, defn.name),
            list(defn.type_params),
            [
                TypeConstructor(
                    name_map.get(ctor.name, ctor.name),
                    ctor.fields,
                    list(ctor.field_types) if ctor.field_types else None,
                    ctor.loc,
                )
                for ctor in defn.constructors
            ],
            defn.loc,
        )
    return defn


def _rename_expr(expr, name_map):
    if expr is None:
        return None
    if isinstance(expr, (IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral, Wildcard)):
        return expr
    if isinstance(expr, Identifier):
        return Identifier(name_map.get(expr.name, expr.name), expr.loc)
    if isinstance(expr, BinaryOp):
        return BinaryOp(expr.op, _rename_expr(expr.left, name_map), _rename_expr(expr.right, name_map), expr.loc)
    if isinstance(expr, UnaryOp):
        return UnaryOp(expr.op, _rename_expr(expr.expr, name_map), expr.loc)
    if isinstance(expr, FnCall):
        return FnCall(_rename_expr(expr.func, name_map), [_rename_expr(a, name_map) for a in expr.args], expr.loc)
    if isinstance(expr, IfExpr):
        return IfExpr(_rename_expr(expr.cond, name_map), _rename_expr(expr.then_branch, name_map), _rename_expr(expr.else_branch, name_map), expr.loc)
    if isinstance(expr, MatchExpr):
        return MatchExpr(
            _rename_expr(expr.value, name_map),
            [_rename_match_arm(arm, name_map) for arm in expr.arms],
            expr.loc,
        )
    if isinstance(expr, Block):
        return Block([_rename_expr(e, name_map) for e in expr.exprs], expr.loc)
    if isinstance(expr, LetExpr):
        return LetExpr(expr.name, _rename_expr(expr.value, name_map), _rename_expr(expr.body, name_map), expr.loc)
    if isinstance(expr, Lambda):
        return Lambda(list(expr.params), _rename_expr(expr.body, name_map), expr.loc)
    if isinstance(expr, RefExpr):
        return RefExpr(_rename_expr(expr.value, name_map), expr.loc)
    if isinstance(expr, DerefExpr):
        return DerefExpr(_rename_expr(expr.ref, name_map), expr.loc)
    if isinstance(expr, SetExpr):
        return SetExpr(_rename_expr(expr.ref, name_map), _rename_expr(expr.value, name_map), expr.loc)
    if isinstance(expr, ComptimeExpr):
        return ComptimeExpr(_rename_expr(expr.expr, name_map), expr.loc)
    return expr


def _rename_match_arm(arm, name_map):
    return MatchArm(_rename_pattern(arm.pattern, name_map), _rename_expr(arm.body, name_map), arm.loc)


def _rename_pattern(pattern, name_map):
    if isinstance(pattern, PatLiteral):
        return pattern
    if isinstance(pattern, PatIdent):
        return PatIdent(pattern.name, pattern.loc)
    if isinstance(pattern, PatWildcard):
        return pattern
    if isinstance(pattern, PatConstructor):
        return PatConstructor(name_map.get(pattern.name, pattern.name), [_rename_pattern(a, name_map) for a in pattern.args], pattern.loc)
    return pattern


def _rename_type_expr(type_expr, name_map):
    if type_expr is None:
        return None
    from parser import TypeInt, TypeFloat, TypeBool, TypeString, TypeChar, TypeUnit, TypeVar, TypeArrow, TypeApp
    if isinstance(type_expr, (TypeInt, TypeFloat, TypeBool, TypeString, TypeChar, TypeUnit, TypeVar)):
        return type_expr
    if isinstance(type_expr, TypeArrow):
        return TypeArrow(_rename_type_expr(type_expr.from_type, name_map), _rename_type_expr(type_expr.to_type, name_map), type_expr.loc)
    if isinstance(type_expr, TypeApp):
        return TypeApp(name_map.get(type_expr.name, type_expr.name), [_rename_type_expr(a, name_map) for a in type_expr.args], type_expr.loc)
    return type_expr


def compile_ko(source: str, output_name: str = "output", filename: str = "<input>"):
    """Compile Kō source to C and build"""
    try:
        # Get directory for resolving imports
        current_dir = os.path.dirname(os.path.abspath(filename)) if filename != "<input>" else os.getcwd()
        search_paths = [
            current_dir,
            os.path.join(current_dir, 'lib'),
            os.path.join(os.path.dirname(__file__), 'lib')
        ]
        
        # Tokenize
        tokens = tokenize(source)

        # Parse
        program = parse(tokens, filename)
        
        # Resolve imports
        program = resolve_imports(program, current_dir, search_paths, filename)

        # Semantic analysis (exhaustiveness check)
        source_lines = source.splitlines()
        errors = check_exhaustiveness(program, source_lines, filename)
        if errors.has_errors:
            print(errors.render())
            return False

        # Type inference (optional, non-fatal)
        try:
            from typecheck import TypeInferer, TypeError as KōTypeError
            inferer = TypeInferer()
            inferred_types = inferer.infer(program)
            if inferer.errors:
                for err in inferer.errors:
                    print(f"Type error: {err}")
                return False
            # Print inferred types if verbose
            if os.environ.get('KO_VERBOSE'):
                for name, scheme in inferred_types.items():
                    print(f"  {name}: {scheme}")
        except Exception as e:
            # Type inference is optional; don't block compilation
            if os.environ.get('KO_VERBOSE'):
                print(f"Type inference skipped: {e}")

        # Generate C
        c_code = generate_c(program)

        # Write C file
        c_file = f"{output_name}.c"
        with open(c_file, 'w') as f:
            f.write(c_code)

        print(f"Generated {c_file}")

        # Compile with gcc
        exe_file = output_name
        result = subprocess.run(
            ["gcc", "-o", exe_file, c_file, "-lm"],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            print(f"C compilation failed:\n{result.stderr}")
            return False

        print(f"Compiled to {exe_file}")
        return True

    except LexerError as e:
        print(f"Lexer error: {e}")
        return False
    except ParseError as e:
        print(f"Parse error: {e}")
        return False
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        return False


def repl():
    """Interactive REPL for Kō"""
    import readline

    print("Kō REPL (v0.2.0)")
    print("Type expressions, 'fn ...' for functions, ':help' for commands")
    print()

    definitions = []
    _last_def_count = 0

    def rebuild_and_run(defs, wrap_expr=None):
        """Rebuild all definitions and run. If wrap_expr, evaluate it inline.
        Returns True on success."""
        all_defs = list(defs)
        if wrap_expr is not None:
            fn = FnDef('main', [], wrap_expr)
            all_defs.append(fn)
        prog = Program([], all_defs)
        try:
            c_code = generate_c(prog)
        except Exception as e:
            print(f"Codegen error: {e}")
            return False

        c_path = '/tmp/ko_repl.c'
        exe_path = '/tmp/ko_repl'
        with open(c_path, 'w') as f:
            f.write(c_code)

        result = subprocess.run(
            ["gcc", "-o", exe_path, c_path, "-lm"],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"Compilation error:\n{result.stderr}")
            return False

        result = subprocess.run(
            [exe_path], capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"Runtime error:\n{result.stderr}")
            return False
        if result.stdout:
            print(result.stdout, end='')
        return True

    def show_help():
        print("Commands:")
        print("  :help    Show this help")
        print("  :list    Show all definitions")
        print("  :reset   Clear all definitions")
        print("  :types   Show inferred types")
        print("  :q       Quit")
        print()
        print("Syntax:")
        print("  1 + 2              Evaluate expression")
        print("  fn add x y = x + y  Define function")
        print("  type Maybe = Just * | Nothing  Define type")
        print("  let x = 42          Define binding")
        print("  :import \"file.ko\"   Import file")

    while True:
        try:
            line = input("ko> ")
            # Multi-line: backslash at end continues to next line
            while line.rstrip().endswith('\\'):
                line = line.rstrip()[:-1] + '\n' + input('... ')
            line = line.strip()
            if not line:
                continue

            # Commands
            if line == ':q' or line == ':quit':
                break
            if line == ':help' or line == '?':
                show_help()
                continue
            if line == ':list' or line == ':l':
                if not definitions:
                    print("(no definitions)")
                for d in definitions:
                    if isinstance(d, FnDef):
                        params = ' '.join(d.params) if d.params else ''
                        print(f"  fn {d.name} {params}")
                    elif isinstance(d, LetBinding):
                        print(f"  let {d.name}")
                    elif isinstance(d, TypeDef):
                        ctors = ' | '.join(
                            f"{c.name} {'* ' * c.fields}" for c in d.constructors
                        )
                        print(f"  type {d.name} = {ctors}")
                continue
            if line == ':reset':
                definitions.clear()
                _last_def_count = 0
                print("(definitions cleared)")
                continue
            if line == ':types' or line == ':t':
                if not definitions:
                    print("(no definitions)")
                    continue
                try:
                    from typecheck import TypeInferer
                    prog = Program([], list(definitions))
                    inferer = TypeInferer()
                    types = inferer.infer(prog)
                    if inferer.errors:
                        for err in inferer.errors:
                            print(f"  Type error: {err}")
                    else:
                        for name, scheme in types.items():
                            print(f"  {name} : {scheme}")
                except Exception as e:
                    print(f"  Type inference error: {e}")
                continue
            if line.startswith(':import') or line.startswith(':i '):
                path = line.split(None, 1)[1].strip().strip('"')
                try:
                    with open(path) as f:
                        source = f.read()
                    tokens = tokenize(source)
                    prog = parse(tokens, path)
                    prog = resolve_imports(prog, os.path.dirname(os.path.abspath(path)),
                                           [os.path.dirname(os.path.abspath(path)),
                                            os.path.join(os.path.dirname(__file__), 'lib')],
                                           path)
                    definitions.extend(prog.definitions)
                    ok = rebuild_and_run(definitions)
                    if ok:
                        print(f"Imported {path}")
                except FileNotFoundError:
                    print(f"File not found: {path}")
                except Exception as e:
                    print(f"Import error: {e}")
                continue

            # Parse input
            tokens = tokenize(line)
            program = parse(tokens)

            # Check if this was a bare expression (parser wraps in synthetic main)
            # vs a user-defined definition
            has_user_main = any(
                isinstance(d, FnDef) and d.name == 'main' and not d.body
                for d in program.definitions
            ) if program.definitions else False

            # Detect bare expressions: parser wraps println/inspect/panic in synthetic main
            # For other bare expressions (1+2, add 3 4), parser drops them → 0 definitions
            is_bare_expr = len(program.definitions) == 0
            is_synthetic_main = (
                len(program.definitions) == 1
                and isinstance(program.definitions[0], FnDef)
                and program.definitions[0].name == 'main'
                and not program.definitions[0].params
            )

            if is_bare_expr:
                # Expression that parser couldn't handle — evaluate with stored defs
                try:
                    expr_tokens = tokenize(f"fn __repl_eval =\n  println ({line})")
                    expr_prog = parse(expr_tokens)
                    if expr_prog.definitions:
                        expr_body = expr_prog.definitions[0].body
                        ok = rebuild_and_run(definitions, wrap_expr=expr_body)
                except (LexerError, ParseError) as e:
                    print(f"Error: {e}")
                continue

            if is_synthetic_main:
                # Parser-wrapped expression (println, inspect, etc.) — evaluate it
                synth_main = program.definitions[0]
                ok = rebuild_and_run(definitions, wrap_expr=synth_main.body)
                continue

            # User definition(s) — verify they compile, then add
            new_defs = list(program.definitions)
            # Verify new definitions compile (with existing defs + a dummy main)
            verify_defs = definitions + new_defs + [FnDef('main', [], IntLiteral(0))]
            ok = rebuild_and_run(verify_defs)
            if not ok:
                continue
            definitions.extend(new_defs)

            # Show what was defined
            for d in new_defs:
                if isinstance(d, FnDef):
                    params = ' '.join(d.params) if d.params else ''
                    print(f"  fn {d.name} {params} defined")
                elif isinstance(d, LetBinding):
                    print(f"  let {d.name} defined")
                elif isinstance(d, TypeDef):
                    print(f"  type {d.name} defined")

        except (LexerError, ParseError) as e:
            print(f"Error: {e}")
        except KeyboardInterrupt:
            print("\nBye!")
            break
        except EOFError:
            break


def main():
    if len(sys.argv) < 2:
        repl()
    elif sys.argv[1] == '-e':
        # Execute inline code
        expr = sys.argv[2]
        # If it already has top-level definitions, use as-is
        if any(expr.strip().startswith(kw) for kw in ['fn ', 'type ', 'let ']):
            source = expr
        elif any(expr.strip().startswith(kw) for kw in ['print', 'inspect', 'println', 'panic']):
            # These are expressions that need to be wrapped in main
            source = f"fn main =\n  {expr}"
        else:
            source = f"fn main =\n  {expr}"
        output = sys.argv[3] if len(sys.argv) > 3 else '/tmp/ko_out'
        if compile_ko(source, output):
            subprocess.run([output])
    else:
        # Compile file
        filename = sys.argv[1]
        output = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(filename)[0]
        with open(filename) as f:
            source = f.read()
        compile_ko(source, output, filename)


if __name__ == '__main__':
    main()
