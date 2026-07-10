# Kō (kō) — v0.1.0-alpha

A minimal, functional-first programming language that compiles to native binaries via LLVM.

> [github.com/Adjanour/ko-language](https://github.com/Adjanour/ko-language)

No parens for function calls (`add 1 2`), indentation-based blocks, uppercase constructors, ADTs, pattern matching, immutable by default, with Hindley-Milner type inference.

**Status: Alpha.** Expect bugs, missing features, and rough edges. Feedback and contributions welcome.

## Quick start

```bash
git clone https://github.com/Adjanour/ko-language.git
cd ko-language
./build.sh
echo 'fn main = println "Hello, Kō!"' > hello.ko
./ko-dist/ko hello.ko
```

**New to functional programming?** Read the [Getting Started Guide](docs/getting-started.md) — it's written for Python/JS/C programmers.

## Installation

### Pre-built (recommended)

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
~/ko/ko hello.ko
```

No `npm install`. No `brew`. No virtualenv. One folder.

### Build from source

Requires Zig 0.17 and LLVM 22:

```bash
git clone https://github.com/Adjanour/ko-language.git
cd ko-language/ko-zig
zig build
```

The compiler binary is at `zig-out/bin/ko`. Run tests with:

```bash
zig build test --summary all
```

## What works

- **Lexer**: hex (`0xFF`), underscores, comments, operators, string literals
- **Parser**: ADTs, pattern matching, functions, let bindings, if/then/else, lambdas, tuples, records, modules, imports, pipe operator, named args, type annotations
- **Typechecker**: Hindley-Milner type inference, let-polymorphism, ref types, type annotations
- **Codegen**: LLVM IR via kassane/llvm-zig bindings; JIT execution and AOT compilation (`--emit-obj`, `--emit-exe`)
- **Memory management**: Reference counting for heap-allocated objects (tuples, records, constructors, closures)
- **Currying**: Multi-param functions support partial application
- **Modules**: `module Name` definitions with `pub` visibility
- **Stdlib**: Bool, Int, Float, String, List, Math — built-in, no import needed
- **LSP**: `ko-lsp` built alongside the compiler
- **REPL**: `ko --repl` for interactive evaluation
- **78 of 78 tests passing**

## CLI

```bash
ko <file.ko>                Run program (default)
ko --repl                   Start interactive REPL
ko --dump-ir <file.ko>      Show generated LLVM IR
ko --emit-ir <out> <file>   Write LLVM IR to file
ko --emit-obj <out> <file>  Compile to object file
ko --emit-exe <out> <file>  Compile to executable
```

No args shows help. Errors include file and location:

```
error at hello.ko:1:11: undefined name 'x'
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

# Compile-time evaluation
comptime fn factorial n =
  if n == 0 then 1 else n * factorial (n - 1)
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

## Known Issues (v0.1.0-alpha)

- **Inline comments after `let` bindings break the parser.** The comment consumes the newline, so the next line doesn't see the binding. Workaround: put comments on their own line.
- **`println (fn_call)` prints `<fn>` instead of the actual value.** Workaround: extract to a `let` binding first: `let n = f x; println n`
- **Imported module type info doesn't propagate** to the main typechecker (shows type variables instead of concrete types)
- **No circular import detection**
- **No package/module system** — just flat file imports
- **Generics not implemented** — can't write polymorphic functions over type parameters yet
- **Result type resolution** — built-in Result operations (`Result.is_ok`, `Result.map`, etc.) can't find locally-defined `Result` types in all cases
- **Multi-line match bodies** — a multi-line `match` followed by another expression can confuse the parser. Workaround: extract match into a helper function.

## Roadmap

- [x] Lexer, parser, typechecker, codegen
- [x] Reference counting (heap-allocated objects)
- [x] Recursive ADTs (binary trees, lists)
- [x] Stack overflow detection
- [x] Partial application / currying
- [x] LSP server
- [x] REPL with pretty-printing
- [x] Better error messages with source locations
- [ ] Generics (monomorphization)
- [ ] Standard library expansion (String.split, List.sort, Map/Dict)
- [ ] Trait/typeclass system

## License

[MIT](LICENSE)
