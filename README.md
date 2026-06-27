# Kō (kō)

A minimal, functional-first programming language.

No parens for function calls (`add 1 2`), indentation-based blocks, uppercase constructors, ADTs, pattern matching, immutable by default, with Hindley-Milner type inference.

## Quick start

```bash
cd ko-zig
zig build
./zig-out/bin/ko --run ../examples/01_hello.ko
```

## What works

### Zig compiler (current)

- **Lexer**: hex (`0xFF`), underscores, comments, operators, string literals
- **Parser**: ADTs, pattern matching, functions, let bindings, if/then/else, lambdas, tuples, records, modules, imports, pipe operator, named args, type annotations
- **Typechecker**: Hindley-Milner type inference, let-polymorphism, ref types, type annotations
- **Codegen**: LLVM IR via kassane/llvm-zig bindings; JIT execution (`--run`) and AOT compilation (`--emit-obj`, `--emit-exe`)
- **Memory management**: Reference counting for heap-allocated objects (tuples, records, constructors, closures)
- **Currying**: Multi-param functions support partial application
- **Modules**: `module Name` definitions with `pub` visibility
- **75 tests passing** (lexer, parser, typechecker, codegen, integration, .ko test programs)

### Python compiler (archived)

The original Python-based compiler is archived in `archive/python-compiler/`. It compiled to C99 and included closures via lambda lifting, string interpolation, and a standard library.

## Project structure

```bash
ko-zig/                  # Zig compiler (main)
├── src/
│   ├── main.zig         # CLI entry point
│   ├── lexer.zig        # Tokenizer
│   ├── parser.zig       # Recursive descent parser
│   ├── ast.zig          # AST node types
│   ├── typecheck.zig    # HM type inference
│   ├── codegen.zig      # LLVM IR generation
│   ├── ko_runtime.c     # C runtime (println, print, inspect, RC)
│   └── tests_ko/        # 43 .ko test programs
├── AGENTS.md            # Zig 0.17 API patterns, LLVM codegen patterns

archive/python-compiler/  # Original Python compiler (archived)
examples/                 # .ko example programs
docs/                     # Guides and reference
social/                   # Social media assets
tree-sitter-ko/           # Tree-sitter grammar
vscode-ko/                # VS Code extension
```

## Language features

```kō
# Functions
fn add x y = x + y
fn apply f x = f x

# Pattern matching
type Maybe a = Just a | Nothing
fn from-just default mx =
  match mx
    Just x => x
    Nothing => default

# Records
type Point = { x: Int, y: Int }
let p = Point { x = 3, y = 4 }

# Tuples
let t = (1, "hello", true)

# Lambda closures
let x = 10
let f = \y -> x + y
f 5  # 15

# Pipe operator
5 |> add 1 |> double

# Partial application
let add1 = add 1
add1 2  # 3

# References (mutable)
let r = ref 42
r := 100
!r  # 100
```

## Docs

- [Language Charter](LANGUAGE_CHARTER.md) — canonical vision and syntax freeze
- [Formal Grammar](GRAMMAR.md) — EBNF spec
- [Idiomatic Programs](KO_PROGRAMS.md) — example programs
- [Functional Programming Guide](docs/functional-guide.md)
- [Quick Reference](docs/quick-reference.md)

## CLI

```bash
ko --run file.ko         # JIT-execute main() and print result
ko file.ko               # Dump LLVM IR
ko --emit-ir out.ll file.ko   # Emit LLVM IR to file
ko --emit-obj out.o file.ko   # Emit object file
ko --emit-exe out file.ko     # Emit linked executable
```

## Design decisions

- **No parens** for function calls — `add 1 2` not `add(1, 2)`
- **Minimal indentation** — only for function bodies and blocks
- **Uppercase = constructors** — `Just` vs `x`
- **`type` for ADTs and records** — `type Maybe = Just * | Nothing`
- **Immutability by default** — `ref` for explicit mutation
- **`match` with `=>`** — exhaustive pattern matching
- **`!` for deref, `not` for boolean negation**
- **`|>` pipe operator** — left-to-right function application
- **Reference counting** — automatic memory management for heap objects

## TODO

- [ ] File-based imports
- [ ] General recursion safety (stack overflow prevention)
- [ ] Closure codegen for multi-param lambdas
- [ ] Full decref for intermediate variables
- [ ] Better error messages
- [ ] Standard library
