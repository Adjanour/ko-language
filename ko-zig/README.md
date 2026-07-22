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

# JIT execute
./zig-out/bin/ko --run hello.ko

# Start REPL
./zig-out/bin/ko --repl
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
| [Typechecking](docs/TYPECHECKING.md) | How Hindley-Milner type inference works |
| [Theory](docs/THEORY.md) | Theoretical foundations and references |

### Project

| Document | Description |
|----------|-------------|
| [Status](docs/STATUS.md) | Current state and completed work |
| [Known Issues](docs/KNOWN_ISSUES.md) | Bugs and limitations |
| [Roadmap](ROADMAP.md) | Future plans and phases |
| [Vision](VISION.md) | Long-term vision and philosophy |

## Features

- **Hindley-Milner type inference** — no type annotations required
- **Sum types and pattern matching** — algebraic data types with exhaustive matching
- **Reference counting** — deterministic memory management, no GC pauses
- **Compile-time evaluation** — `comptime` functions evaluated during compilation
- **LLVM backend** — native code optimization via LLVM
- **LSP server** — editor support with hover, completion, diagnostics
- **REPL** — interactive development environment

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
# I/O
println x        # Print with newline
print x          # Print without newline
inspect x        # Debug print

# String operations
String.length s
String.append a b
String.contains s sub
String.toUpperCase s
String.toLowerCase s
String.trim s
String.replace s old new
String.split s sep

# Int operations
Int.toString n
Int.abs n
Int.pow b e

# Float operations
Float.sqrt f
Float.sin f
Float.cos f
```

## Compiler Usage

```bash
ko file.ko                 # Dump LLVM IR (default)
ko --run file.ko           # JIT execute
ko --repl                  # Interactive REPL
ko --emit-ir out.ll file   # Write LLVM IR to file
ko --emit-obj out.o file   # Emit object file
ko --emit-exe out file     # Emit linked executable
```

## Building

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run tests
zig build test --summary all
```

## License

MIT

---

*Kō (光) means "light" in Japanese. The language is lightweight, illuminating, and fast.*
