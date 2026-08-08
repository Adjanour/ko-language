# Kō (光)

**A minimal, eager, purely functional language that compiles to native code via LLVM.**

Kō means "light" in Japanese. The language is lightweight, illuminating, and fast.

---

## Quick Start

```bash
# Install
git clone https://github.com/Adjanour/ko-language.git
cd ko-zig
zig build -Doptimize=ReleaseFast

# Run a program
echo 'fn main = println "Hello, World!"' > hello.ko
./zig-out/bin/ko hello.ko

# Start REPL
./zig-out/bin/ko --repl
```

## Building

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run tests (use --summary all to see clean output)
zig build test --summary all
```

## Compiler Usage

```bash
ko file.ko                 # Run program (JIT)
ko --repl                  # Interactive REPL
ko --dump-ir file.ko       # Dump LLVM IR
ko --emit-ir out.ll file   # Write LLVM IR to file
ko --emit-obj out.o file   # Emit object file
ko --emit-exe out file     # Emit linked executable
```

## Example

```ko
type List a = Cons a (List a) | Nil

fn map f lst =
  match lst
    Cons x rest => Cons (f x) (map f rest)
    Nil => Nil

fn main =
  let xs = 1 :: 2 :: 3 :: Nil
  let doubled = map (\x -> x * 2) xs
  inspect doubled   # [2, 4, 6]
```

## Features

- **Bidirectional type inference** — no type annotations required
- **Sum types and pattern matching** — algebraic data types with exhaustive matching
- **Reference counting** — deterministic memory management, no GC pauses
- **Compile-time evaluation** — `comptime` functions evaluated during compilation
- **LIR pipeline** — AST → HIR → LIR → LLVM IR (multi-pass)
- **Linearity checker** — HIR pass verifying linear variable usage
- **LLVM backend** — native code via kassane/llvm-zig bindings
- **LSP server** — hover, completion, diagnostics
- **Linenoise REPL** — arrow key history, tab completion, multi-line expressions
- **Stack overflow detection** — clear error instead of segfault

## Built-in Types

```
Int         # 64-bit integer
Float       # 64-bit float
Bool        # True | False
Char        # Single character
String      # Immutable string
()          # Unit type
```

## Built-in Functions

```ko
println x        # Print with newline
print x          # Print without newline
inspect x        # Debug print

String.length s
String.append a b
Int.toString n
Int.abs n
Float.sqrt f
Float.sin f
```

## Documentation

### For Users

| Document | Description |
|----------|-------------|
| [Tutorial](docs/TUTORIAL.md) | Beginner guide — start here |
| [Language Reference](docs/LANGUAGE_REFERENCE.md) | Complete syntax reference |
| [Syntax Cheat Sheet](docs/SYNTAX_CHEAT_SHEET.md) | Quick reference card |

### For Contributors

| Document | Description |
|----------|-------------|
| [Handbook](docs/HANDBOOK.md) | How to add features to the compiler |
| [Codegen](docs/CODEGEN.md) | How LLVM IR generation works |
| [Typechecking](docs/TYPECHECKING.md) | How type inference works |
| [REPL Architecture](docs/REPL_ARCHITECTURE.md) | REPL design and implementation |

### Project

| Document | Description |
|----------|-------------|
| [Status](docs/STATUS.md) | Current state and completed work |
| [Known Issues](docs/KNOWN_ISSUES.md) | Bugs and limitations |
| [Roadmap](ROADMAP.md) | Future plans and phases |
| [Vision](VISION.md) | Long-term vision and philosophy |

## File Structure

```
ko-zig/
├── build.zig          # Build configuration
├── src/
│   ├── main.zig       # Entry point
│   ├── lexer.zig      # Tokenizer
│   ├── parser.zig     # Recursive descent parser
│   ├── ast.zig        # AST node types
│   ├── typecheck.zig  # Bidirectional type inference
│   ├── linearity.zig  # Linearity checker (HIR pass)
│   ├── codegen.zig    # Legacy codegen (frozen)
│   ├── codegen_lir.zig # LIR pipeline (active)
│   ├── stdlib.zig     # Zig stdlib implementations
│   ├── stdlib_codegen.zig # LLVM IR for builtins
│   ├── comptime.zig   # Compile-time evaluator
│   ├── module_loader.zig # File-based imports
│   ├── prettyprint.zig # Value pretty-printing
│   ├── repl.zig       # Linenoise REPL
│   ├── lsp.zig        # LSP server
│   ├── tests.zig      # All 256 tests
│   └── tests_ko/      # .ko test programs
└── std/               # Kō stdlib (written in Kō)
```

## License

MIT

---

*Kō (光) means "light" in Japanese. The language is lightweight, illuminating, and fast.*
