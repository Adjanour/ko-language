# Kō (kō)

A minimal, functional-first programming language that compiles to native binaries via LLVM.

> [github.com/Adjanour/ko-language](https://github.com/Adjanour/ko-language)

No parens for function calls (`add 1 2`), indentation-based blocks, uppercase constructors, ADTs, pattern matching, immutable by default, with Hindley-Milner type inference.

## Quick start

```bash
git clone <repo-url>
cd <repo-name>
./build.sh
echo 'fn main = println "Hello, Kō!"' > hello.ko
./ko-dist/ko hello.ko
```

**New to functional programming?** Read the [Getting Started Guide](docs/getting-started.md) — it's written for Python/JS/C programmers.

## Installation

### Distribution (beta)

Build a self-contained folder you can move anywhere — one binary, the full standard library, and example programs. No install, no system-wide dependencies at runtime.

```bash
./build.sh
```

This produces `ko-dist/`:

```
ko-dist/
├── bin/ko        # compiler binary
├── std/          # standard library (Bool, Int, Float, String, List, Math)
├── examples/     # example .ko programs
└── ko -> bin/ko  # convenience symlink
```

Drop it anywhere and run:

```bash
cp -r ko-dist ~/ko
~/ko/ko file.ko
```

No `npm install`. No `brew`. No virtualenv. One folder.

### Build from source (for contributors)

Requires Zig 0.17 and LLVM 22:

```bash
git clone <repo-url>
cd <repo-name>/ko-zig
zig build
```

The compiler binary is at `zig-out/bin/ko`. Run tests with:

```bash
zig build test
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
- **Stdlib**: shipped as source in `ko-zig/std/` (Bool, Int, Float, String, List, Math); copied into `ko-dist/std/` by `build.sh`, or resolved from `KO_STDLIB_PATH` or a sibling `std/` directory near the `ko` binary
- **76 of 78 tests passing** (lexer, parser, typechecker, codegen, integration, 51 `.ko` test programs)
- **LSP**: `ko-lsp` is built alongside the compiler

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
│   ├── comptime.zig     # Compile-time evaluator
│   ├── module_loader.zig # File and stdlib import resolution
│   ├── repl.zig         # Interactive REPL
│   ├── stdlib_codegen.zig # Built-in/stdlib codegen helpers
│   ├── ko_runtime.c     # C runtime (println, print, inspect, RC)
│   └── tests_ko/        # 51 .ko test programs
├── std/                 # Standard library modules (Bool, Int, Float, String, List, Math)
├── build.zig            # Zig build definition
└── AGENTS.md            # Zig 0.17 API patterns, LLVM codegen patterns

build.sh                 # One-command build that produces ko-dist/
ko-dist/                 # Portable distribution folder (created by build.sh)
archive/python-compiler/ # Original Python compiler (archived)
examples/                # .ko example programs
social/                  # Social media assets
docs/                    # Guides and reference
tree-sitter-ko/          # Tree-sitter grammar
vscode-ko/               # VS Code extension
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
5 |> add 1 |> add 2  # 8

# Partial application
let add1 = add 1
add1 2  # 3

# References (mutable)
let r = ref 42
r := 100
!r  # 100
```

## Docs

- [Getting Started](docs/getting-started.md) — **Start here if you're new to functional programming**
- [Language Charter](LANGUAGE_CHARTER.md) — canonical vision and syntax freeze
- [Formal Grammar](GRAMMAR.md) — EBNF spec
- [Idiomatic Programs](KO_PROGRAMS.md) — example programs
- [Crash Course](docs/ko-crash-course.md) — functional programming from scratch
- [Ko by Example](docs/ko-by-example.md) — step-by-step guide
- [Core Concepts](docs/concepts.md) — language concepts
- [Quick Reference](docs/quick-reference.md) — syntax cheat sheet

## CLI

```bash
ko --run file.ko         # JIT-execute main() and print result
ko file.ko               # Dump LLVM IR
ko --dump-ir file.ko     # Dump LLVM IR
ko --emit-ir out.ll file.ko   # Emit LLVM IR to file
ko --emit-obj out.o file.ko   # Emit object file
ko --emit-exe out file.ko     # Emit linked executable
ko --repl                 # Start interactive REPL
```

## Design decisions

- **No parens** for function calls — `add 1 2` not `add(1, 2)`
- **Minimal indentation** — only for function bodies and blocks
- **Uppercase = constructors** — `Just` vs `x`
- **`type` for ADTs and records** — `type Maybe a = Just a | Nothing`
- **Immutability by default** — `ref` for explicit mutation
- **`match` with `=>`** — exhaustive pattern matching
- **`!` for deref, `not` for boolean negation**
- **`|>` pipe operator** — left-to-right function application
- **Reference counting** — automatic memory management for heap objects
- **`comptime` expressions** — evaluate code at compile time

## Known Issues (v0.3.x)

- Comptime expressions with parentheses can trigger parser errors in some contexts
- Tuple destructuring in `let` bindings is not yet fully supported
- Recursive ADTs (e.g., binary trees) can trigger LLVM backend errors
- Multi-closure captures may segfault in certain patterns
- The `::` operator has type inference issues with string lists
- Error messages do not yet include precise source locations

## TODO

- [x] File-based imports
- [ ] General recursion safety (stack overflow prevention)
- [ ] Closure codegen for multi-param lambdas
- [ ] Full decref for intermediate variables
- [ ] Better error messages with source locations
- [ ] Standard library expansion (String.split, String.replace, List.sort, Map/Dict)
- [ ] Generics (monomorphization)
- [ ] Trait/typeclass system
