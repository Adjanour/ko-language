# Kō (光) — v0.3.1-alpha

A minimal, eager, purely functional language that compiles to native code via LLVM.

Kō means "light" in Japanese. The language is lightweight, illuminating, and fast.

> [github.com/Adjanour/ko-language](https://github.com/Adjanour/ko-language)

No parens for function calls (`add 1 2`), indentation-based blocks, uppercase constructors, ADTs, pattern matching, immutable by default, with bidirectional type inference.

**Status: Alpha.** Expect bugs, missing features, and rough edges. Feedback and contributions welcome.

---

## Quick Start

```bash
git clone https://github.com/Adjanour/ko-language.git
cd ko-language
./build.sh
echo 'fn main = println "Hello, Kō!"' > hello.ko
./ko-dist/ko hello.ko
```

## Building

### Pre-built (recommended)

```bash
./build.sh
```

This produces `ko-dist/` — one binary, the full standard library, and examples. No npm, no brew, no virtualenv. One folder.

### From source

Requires Zig 0.17 and LLVM 22.

**Linux:**
```bash
sudo apt install llvm-22-dev zlib1g-dev
# or: sudo pacman -S llvm zlib

git clone https://github.com/Adjanour/ko-language.git
cd ko-language/ko-zig
zig build
```

**macOS:**
```bash
brew install llvm@22
export PATH="/opt/homebrew/opt/llvm@22/bin:$PATH"

git clone https://github.com/Adjanour/ko-language.git
cd ko-language/ko-zig
zig build
```

**Windows:** Not yet supported.

## What Works

- **Lexer**: hex (`0xFF`), underscores, comments, operators, string literals
- **Parser**: ADTs, pattern matching, functions, let bindings, if/then/else, lambdas, tuples, records, modules, imports, pipe operator, named args, type annotations
- **Typechecker**: Bidirectional type inference with let-polymorphism
- **Codegen**: LIR pipeline (AST → HIR → LIR → LLVM IR) via kassane/llvm-zig bindings; JIT and AOT compilation (`--emit-obj`, `--emit-exe`)
- **Memory management**: Reference counting for heap-allocated objects
- **Currying**: Multi-param functions support partial application
- **Modules**: `module Name` definitions with `pub` visibility
- **Stdlib**: Bool, Int, Float, String, List, Math — built-in, no import needed
- **LSP**: `ko-lsp` with hover, completion, diagnostics, error locations
- **REPL**: `ko --repl` — Linenoise-powered with arrow key history, tab completion, multi-line expression support
- **Error propagation**: `?` operator unwraps `Ok` or propagates `Err`
- **Stack overflow detection**: Clear error message instead of segfault
- **256 of 256 tests passing**

## CLI

```bash
ko <file.ko>                Run program (default)
ko --repl                   Start interactive REPL
ko --dump-ir <file.ko>      Show generated LLVM IR
ko --emit-ir <out> <file>   Write LLVM IR to file
ko --emit-obj <out> <file>  Compile to object file
ko --emit-exe <out> <file>  Compile to executable
```

Errors include file and location:

```
error at hello.ko:1:11: undefined name 'x'
```

## Language Example

```ko
type List a = Cons a (List a) | Nil

fn map f lst =
  match lst
    Cons x rest => Cons (f x) (map f rest)
    Nil => Nil

fn main =
  let xs = Cons 1 (Cons 2 (Cons 3 Nil))
  let doubled = map (\x -> x * 2) xs
  inspect doubled   # [2, 4, 6]
```

## Design Decisions

- **No parens** for function calls — `add 1 2` not `add(1, 2)`
- **Minimal indentation** — only for function bodies and blocks
- **Uppercase = constructors** — `Just` vs `x`
- **`type` for ADTs and records** — `type Maybe a = Just a | Nothing`
- **Immutability by default** — `ref` for explicit mutation
- **`match` with `=>`** — exhaustive pattern matching
- **`!` for deref, `not` for boolean negation**
- **`|>` pipe operator** — left-to-right function application
- **Reference counting** — automatic memory management for heap objects

## Platform Support

| Platform | JIT | REPL | LSP | `--emit-obj` | `--emit-exe` |
|----------|-----|------|-----|-------------|-------------|
| **Linux x86_64** | Yes | Yes | Yes | Yes | Yes |
| **Linux aarch64** | Partial | Yes | Yes | Partial | No |
| **macOS (Apple Silicon)** | Yes | Yes | Yes | Yes | Yes |
| **macOS (Intel)** | Yes | Yes | Yes | Yes | Yes |
| **Windows** | No | No | No | No | No |

## Editor Setup

Kō ships with a language server (`ko-lsp`) and tree-sitter grammar. See [Editor Setup Guide](docs/editor-setup.md) for details.

**Quick start:**
- **VS Code**: `code --install-extension vscode-ko/ko-language-0.5.0.vsix`
- **Neovim**: `nvim-lspconfig` with `ko-lsp` + `nvim-treesitter`
- **Helix**: add `ko-lsp` to `~/.config/helix/languages.toml`

## AI Coding Assistants

Kō ships with skills for AI assistants:

```bash
# OpenCode
cp -r ko-zig/skills/ko-language ~/.config/opencode/skills/ko-language

# Claude Code / Copilot
cp ko-zig/skills/ko-language/CLAUDE.md /path/to/your/project/CLAUDE.md

# Cursor
cp ko-zig/skills/ko-language/.cursorrules /path/to/your/project/.cursorrules
```

## Docs

- [Getting Started](docs/getting-started.md) — Start here if you're new to functional programming
- [Language Charter](LANGUAGE_CHARTER.md) — canonical vision and syntax freeze
- [Formal Grammar](GRAMMAR.md) — EBNF spec
- [Crash Course](docs/ko-crash-course.md) — functional programming from scratch
- [Ko by Example](docs/ko-by-example.md) — step-by-step guide
- [Quick Reference](docs/quick-reference.md) — syntax cheat sheet
- [Writing Kō Programs](docs/writing-ko-programs.md) — practical constraints and gotchas (fn main, imports, pipes)
- [Error Messages](docs/error-messages.md) — what every compiler error and warning means
- [Compiler Pipeline](docs/compiler-pipeline.md) — how source becomes binary (parser, HIR, LIR, LLVM)
- [Modules & Imports](docs/modules.md) — how `import`, resolution, and the two IO namespaces work
- [Linearity & Ownership](docs/linearity-and-ownership.md) — the consume-once model, borrow vs. consume, and reading the checker's warnings

## Known Issues (v0.3.1-alpha)

- **REPL `let` bindings require `fn` syntax.** `let` at top level isn't codegen'd yet. Use `fn name = expr` instead.
- **Multi-line closures with captured variables** cause codegen errors. Use single-line lambdas or extract to `let` binding.
- **LSP is single-file only.** No cross-file go-to-definition or import navigation.
- **AOT optimization is broken** due to LLVM 22 bugs ([#186403](https://github.com/llvm/llvm-project/issues/186403)). Use JIT mode or post-optimize with `gcc -O2`.

## Roadmap

- [x] Lexer, parser, typechecker, codegen
- [x] Reference counting
- [x] Recursive ADTs (binary trees, lists)
- [x] Stack overflow detection
- [x] Partial application / currying
- [x] LSP server with error locations
- [x] REPL with Linenoise (history, tab completion, multi-line)
- [x] File-based module imports (`import std.Math`)
- [x] `?` operator for Result error propagation
- [x] LIR pipeline (AST → HIR → LIR → LLVM IR)
- [x] Linearity checker (linear types)
- [ ] Monomorphization
- [ ] Generics
- [ ] Trait/typeclass system
- [ ] Package manager

## License

[MIT](LICENSE)
