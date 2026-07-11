#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KO_DIR="$SCRIPT_DIR/ko-zig"
DIST_DIR="$SCRIPT_DIR/ko-dist"

echo "Building Kō compiler..."

# Check for Zig
if ! command -v zig &> /dev/null; then
    echo "Error: zig not found. Install Zig 0.17 from https://ziglang.org/download/"
    exit 1
fi

ZIG_VERSION=$(zig version 2>/dev/null | head -1)
echo "Found zig: $ZIG_VERSION"

# Build
cd "$KO_DIR"
zig build

if [ ! -f zig-out/bin/ko ]; then
    echo "Build failed!"
    exit 1
fi

# Create dist folder
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/bin"
mkdir -p "$DIST_DIR/std"

# Copy binaries
cp "$KO_DIR/zig-out/bin/ko" "$DIST_DIR/bin/ko"
cp "$KO_DIR/zig-out/bin/ko-lsp" "$DIST_DIR/bin/ko-lsp" 2>/dev/null || true
cp "$KO_DIR/src/ko_runtime.c" "$DIST_DIR/bin/ko_runtime.c" 2>/dev/null || true

# Copy stdlib
cp "$KO_DIR/std/"*.ko "$DIST_DIR/std/"

# Copy examples (optional, nice to have)
mkdir -p "$DIST_DIR/examples"
cp "$KO_DIR/examples/"*.ko "$DIST_DIR/examples/" 2>/dev/null || true

# Copy VS Code extension
mkdir -p "$DIST_DIR/editors/vscode"
cp "$SCRIPT_DIR/vscode-ko/package.json" "$DIST_DIR/editors/vscode/"
cp "$SCRIPT_DIR/vscode-ko/extension.js" "$DIST_DIR/editors/vscode/"
cp "$SCRIPT_DIR/vscode-ko/language-configuration.json" "$DIST_DIR/editors/vscode/"
cp "$SCRIPT_DIR/vscode-ko/syntaxes/"*.json "$DIST_DIR/editors/vscode/syntaxes/" 2>/dev/null || true
mkdir -p "$DIST_DIR/editors/vscode/syntaxes"
cp "$SCRIPT_DIR/vscode-ko/syntaxes/"*.json "$DIST_DIR/editors/vscode/syntaxes/" 2>/dev/null || true
cp "$SCRIPT_DIR/vscode-ko/icon.png" "$DIST_DIR/editors/vscode/" 2>/dev/null || true

# Copy tree-sitter grammar
mkdir -p "$DIST_DIR/editors/tree-sitter"
cp "$SCRIPT_DIR/tree-sitter-ko/grammar.js" "$DIST_DIR/editors/tree-sitter/"
cp "$SCRIPT_DIR/tree-sitter-ko/package.json" "$DIST_DIR/editors/tree-sitter/"
cp -r "$SCRIPT_DIR/tree-sitter-ko/queries" "$DIST_DIR/editors/tree-sitter/"

# Create a symlink at top level for convenience
ln -sf bin/ko "$DIST_DIR/ko"

# Create docs directory
mkdir -p "$DIST_DIR/docs"

# Copy key docs
cp "$SCRIPT_DIR/docs/quick-reference.md" "$DIST_DIR/docs/" 2>/dev/null || true
cp "$SCRIPT_DIR/docs/ko-crash-course.md" "$DIST_DIR/docs/" 2>/dev/null || true
cp "$SCRIPT_DIR/docs/getting-started.md" "$DIST_DIR/docs/" 2>/dev/null || true

# Create language reference (comprehensive single doc)
cat > "$DIST_DIR/docs/language.md" << 'LANGEOF'
# The Kō Language

> **Kō** (光) — "light" in Japanese.

Kō is a small, eager, statically-typed functional language that compiles to native code via LLVM. It has no parentheses for function calls, no null, no exceptions, and no classes. Just data, functions, and pattern matching.

---

## Why Kō?

Most languages make you choose: simple or powerful, fast or safe, readable or concise. Kō tries to be all of them.

**Simple**: 17 keywords, one page grammar. Learn it in an afternoon.

**Safe**: No null. No exceptions. No undefined behavior. The compiler catches mistakes.

**Fast**: Compiles to native code via LLVM. No interpreter overhead.

**Readable**: No parens for calls. No braces for blocks. Code reads like math.

```kō
# Kō
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)

factorial 5   # 120
```

```c
// C
int factorial(int n) {
    if (n == 0) return 1;
    return n * factorial(n - 1);
}
factorial(5);  // 120
```

Same logic. Kō is lighter.

---

## Design Philosophy

### 1. No parentheses for function calls

Application is implicit. `add 1 2` reads better than `add(1, 2)`.

```kō
fn add a b = a + b
add 1 2       # 3
```

### 2. Indentation defines blocks

No curly braces. No `end` keywords. Indentation is the block structure.

```kō
fn greet name =
  if name == "" then
    println "Hello, stranger!"
  else
    println ("Hello, " ++ name ++ "!")
```

### 3. ADTs model the world

Algebraic data types are the primary way to model data. No classes. No inheritance.

```kō
type Maybe a = Just a | Nothing
type Result a b = Ok a | Err b
type List a = Cons a (List a) | Nil
type Shape = Circle Int | Rect Int Int
```

### 4. Pattern matching handles it

Don't check types with if-else. Match the shape of your data.

```kō
fn area shape =
  match shape
    | Circle r => 3 * r * r
    | Rect w h => w * h
```

The compiler checks that you handled every case.

### 5. Immutability by default

Values don't change. Use `ref` for explicit mutation when you need it.

```kō
let x = 42
# x := 100  # Error! Can't reassign

let r = ref 42   # But refs work
r := 100          # Mutate
!r                # Dereference: 100
```

### 6. Functions are values

Pass them around. Return them. Store them.

```kō
let double = \x -> x * 2
let apply = \f x -> f x
apply double 5   # 10
```

### 7. Errors are values

No exceptions. No null. Use `Result`.

```kō
type Result a b = Ok a | Err b

fn divide a b =
  if b == 0 then Err "division by zero"
  else Ok (a / b)
```

---

## Getting Started

### Install

Build from source (requires Zig 0.17 + LLVM 22):

```bash
git clone https://github.com/Adjanour/ko-language.git
cd ko-language
./build.sh
```

This creates `ko-dist/` with everything you need.

### Your First Program

```bash
echo 'fn main = println "Hello, Kō!"' > hello.ko
./ko-dist/ko hello.ko
```

### Run Examples

```bash
./ko-dist/ko examples/fibonacci.ko
./ko-dist/ko examples/tree.ko
```

---

## Language Basics

### Comments

```kō
# This is a comment
```

### Numbers

```kō
42          # decimal
0xFF        # hex
0b1010      # binary
0o77        # octal
3.14        # float
```

### Strings

```kō
"hello"
"count: " ++ Int.toString 42   # string concatenation
```

### Booleans

```kō
True
False
True and False    # False
True or False     # True
not True          # False
```

### Functions

```kō
# Definition
fn add a b = a + b

# Calling (no parens!)
add 1 2    # 3

# Lambdas
let double = \x -> x * 2
double 5   # 10

# Multi-line
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)
```

### Let Bindings

```kō
let x = 42
let name = "Kō"
let result = add 1 2
```

### If Expressions

```kō
if x > 0 then "positive"
else if x == 0 then "zero"
else "negative"
```

Everything returns a value. `if` is an expression, not a statement.

---

## Types

### Built-in Types

| Type | Example | Description |
|------|---------|-------------|
| `Int` | `42` | 64-bit integer |
| `Float` | `3.14` | 64-bit float |
| `Bool` | `True` | Boolean |
| `String` | `"hello"` | String |
| `Char` | `'c'` | Character |
| `()` | `()` | Unit (like void) |

### Sum Types (ADTs)

```kō
type Maybe a = Just a | Nothing
type Result a b = Ok a | Err b
type List a = Cons a (List a) | Nil
type Color = Red | Green | Blue
type Shape = Circle Int | Rect Int Int
```

### Record Types

```kō
type Point = { x: Int, y: Int }
type Person = { name: String, age: Int }

# Construct
let pt = Point { x = 3, y = 4 }

# Access
println pt.x   # 3
```

### Tuples

```kō
let t = (1, "hello", true)
let (a, b, c) = t
```

---

## Pattern Matching

The `match` expression destructures data and dispatches on constructors.

```kō
fn describe color =
  match color
    | Red => "warm"
    | Green => "cool"
    | Blue => "cool"
```

### With Values

```kō
fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0
```

### With Tuples

```kō
fn add pair =
  match pair
    | (a, b) => a + b
```

### Exhaustive

The compiler checks that every case is covered. Missing a case is a compile error.

---

## Advanced Features

### Pipe Operator

Left-to-right function application. Makes chains read top-to-bottom.

```kō
fn add x y = x + y
fn double x = x * 2

5 |> add 1 |> double   # 12
```

### Partial Application (Currying)

Multi-param functions automatically support partial application.

```kō
fn add a b = a + b
let add5 = add 5
add5 3   # 8
```

### Ref Cells

Explicit mutable references. Everything else is immutable.

```kō
let counter = ref 0
counter := !counter + 1
println !counter   # 1
```

### Closures

Lambdas capture their environment.

```kō
fn make_adder x =
  \y -> x + y

let add10 = make_adder 10
add10 5   # 15
```

### Compile-Time Evaluation

Evaluate code at compile time when all inputs are known.

```kō
let x = comptime (2 + 3)   # x = 5
```

---

## Error Handling

Kō uses `Result` instead of exceptions. The `?` operator unwraps `Ok` values or propagates `Err` early.

```kō
type Result a b = Ok a | Err b

fn divide a b =
  if b == 0 then Err "division by zero"
  else Ok (a / b)

fn compute x y z =
  let a = divide x y?
  let b = divide a z?
  Ok b

# compute 10 2 5 => Ok 1
# compute 10 0 5 => Err "division by zero"
```

### Result Operations

```kō
Result.map f r         # apply f to Ok value
Result.unwrap default r # get Ok value or default
Result.fold ok_fn err_fn r # reduce to single value
Result.and_then f r    # chain (flatmap)
Result.is_ok r         # True if Ok
Result.is_err r        # True if Err
```

---

## Standard Library

Built-in functions are always available (no import needed).

### I/O

```kō
print x           # no newline
println x         # with newline
inspect x         # debug format (with quotes on strings)
```

### Int Operations

```kō
Int.toString n    # 42 -> "42"
Int.abs n         # absolute value
Int.pow base exp  # exponentiation
Int.gcd a b       # greatest common divisor
Int.factorial n   # n!
Int.isqrt n       # integer square root
```

### Float Operations

```kō
Float.ofInt n     # Int -> Float
Float.toInt f     # Float -> Int
Float.sqrt f      # square root
Float.sin f       # sine
Float.cos f       # cosine
```

### String Operations

```kō
String.length s       # length
String.append a b     # concatenation (or ++ operator)
```

### List Operations (import std.List)

```kō
import std.List

length xs         # count elements
map f xs          # apply f to each
filter f xs       # keep where predicate holds
foldl f acc xs    # left fold
foldr f acc xs    # right fold
head xs           # first element
tail xs           # rest
reverse xs        # reverse
append xs ys      # concatenate
sum xs            # sum of numbers
```

---

## CLI Reference

```bash
ko file.ko                  # JIT-execute main()
ko --run file.ko            # same as above
ko --dump-ir file.ko        # dump LLVM IR to stdout
ko --emit-ir out.ll file.ko # emit LLVM IR to file
ko --emit-obj out.o file.ko # emit object file
ko --emit-exe out file.ko   # link to executable
ko --repl                   # start interactive REPL
```

### REPL Commands

```bash
:quit      # exit
:type expr # show type of expression
:env       # show accumulated definitions
:reset     # clear all definitions
:help      # show help
```

---

## Example: Binary Tree

```kō
type Tree = Branch Tree Tree | Leaf Int

fn tree_sum tree =
  match tree
    | Branch left right => tree_sum left + tree_sum right
    | Leaf n => n

fn tree_map f tree =
  match tree
    | Leaf n => Leaf (f n)
    | Branch left right => Branch (tree_map f left) (tree_map f right)

fn main =
  let t = Branch (Leaf 1) (Branch (Leaf 2) (Leaf 3))
  let doubled = tree_map (\x -> x * 2) t
  println (tree_sum doubled)   # 12
```

---

## Example: Linked List

```kō
type List a = Cons a (List a) | Nil

fn length xs =
  match xs
    | Cons _ rest => 1 + length rest
    | Nil => 0

fn map f xs =
  match xs
    | Cons x rest => Cons (f x) (map f rest)
    | Nil => Nil

fn main =
  let xs = Cons 1 (Cons 2 (Cons 3 Nil))
  let ys = map (\x -> x * 10) xs
  println (length ys)   # 3
```

---

## Known Issues

- **Inline comments after `let` bindings break the parser.** Put comments on their own line.
- `println (fn_call)` shows `<fn>` instead of the value. Extract to a `let` binding first.
- Imported modules have limited type propagation.

---

## What Kō Is For

- CLI tools
- Compilers and transpilers
- Data transforms
- Build and automation tooling
- Small-to-medium systems programs

## What Kō Is Not

- An object-oriented language
- A feature kitchen sink
- A syntax zoo
- A language with many interchangeable ways to express the same idea

---

## Learn More

- [Quick Reference](quick-reference.md) — syntax cheat sheet
- [Crash Course](ko-crash-course.md) — functional programming from scratch
- [Getting Started](getting-started.md) — for Python/JS/C programmers
- [Language Charter](https://github.com/Adjanour/ko-language/blob/main/LANGUAGE_CHARTER.md) — canonical vision
- [GitHub](https://github.com/Adjanour/ko-language) — source code
LANGEOF

# Create README
cat > "$DIST_DIR/README.md" << 'READMEEOF'
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
READMEEOF

echo ""
echo "Built: $DIST_DIR/"
echo ""
echo "Contents:"
echo "  bin/ko          - compiler binary"
echo "  bin/ko-lsp      - language server"
echo "  std/            - standard library"
echo "  examples/       - example programs"
echo "  editors/        - VS Code extension + tree-sitter grammar"
echo "  ko -> bin/ko    - convenience symlink"
echo ""
echo "Try it:"
echo "  echo 'fn main = println \"Hello, Kō!\"' > /tmp/hello.ko"
echo "  $DIST_DIR/ko /tmp/hello.ko"
echo ""
echo "Editor setup:"
echo "  code --install-extension $DIST_DIR/editors/vscode/ko-language-0.5.0.vsix  # VS Code"
echo "  See docs/editor-setup.md for Neovim, Vim, Helix, and more"
echo ""
echo "Move it anywhere:"
echo "  cp -r $DIST_DIR ~/ko"
echo "  ~/ko/ko some_program.ko"
