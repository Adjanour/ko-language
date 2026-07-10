# Kō Language (beta)

A minimal, functional-first programming language that compiles to native binaries.

## Quick Start

```bash
echo 'fn main = println "Hello, Kō!"' > hello.ko
./ko hello.ko
```

## Usage

```bash
./ko file.ko              # JIT-execute main()
./ko --run file.ko        # Same as above
./ko --emit-ir out.ll file.ko   # Emit LLVM IR to file
./ko --emit-obj out.o file.ko   # Emit object file
./ko --emit-exe out file.ko     # Emit linked executable
./ko --repl                # Start interactive REPL
```

## Examples

```bash
./ko examples/fibonacci.ko
./ko examples/factorial.ko
./ko examples/tree.ko
```

## Language Basics

```kō
# Functions (no parens needed)
fn add x y = x + y

# Pattern matching
type Maybe a = Just a | Nothing

# Tuples
let t = (1, "hello", true)

# Lambda closures
let f = \x -> x * 2

# Pipe operator
5 |> add 1 |> add 2  # 8

# ADTs
type List a = Cons a (List a) | Nil
let xs = 1 :: 2 :: 3 :: Nil
```

## Known Issues

- Inline comments after `let` bindings break the parser. Put comments on their own line.
- `println (fn_call)` shows `<fn>` — extract to a `let` binding first.

## Learn More

- [Language Reference](docs/language.md) — full language documentation
- [Quick Reference](docs/quick-reference.md) — syntax cheat sheet
- [Crash Course](docs/ko-crash-course.md) — functional programming from scratch
- [Getting Started](docs/getting-started.md) — for Python/JS/C programmers
