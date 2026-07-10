# Getting Started with Kō

A practical guide for programmers coming from Python, JavaScript, C, or similar languages.

---

## 5-Minute Setup

### Prerequisites

- **Zig 0.17** — `zig version` should show 0.17.x
- **LLVM 22** — required for the compiler backend

### Build

```bash
cd ko-zig
zig build
```

The compiler binary is at `zig-out/bin/ko`.

### Verify it works

```bash
echo 'fn main = println "Hello, Kō!"' > hello.ko
./zig-out/bin/ko --run hello.ko
```

---

## What Kō Is (and Isn't)

Kō is a **small, functional-first language** that compiles to native code. Think of it as "OCaml with no parentheses, no exceptions, and no garbage collector."

### What Kō has
- Functions, pattern matching, algebraic data types (ADTs)
- Immutable values by default
- Hindley-Milner type inference (the compiler figures out types for you)
- Reference counting (no garbage collector pauses)
- Compiles to fast native code via LLVM

### What Kō does NOT have
- **No `for` loops** — use recursion and `map`/`filter`/`fold`
- **No `null`** — use `Maybe` or `Result` types
- **No exceptions** — use `Result` for error handling
- **No classes/objects** — use ADTs + functions
- **No semicolons, no curly braces** — indentation defines blocks
- **No parentheses for function calls** — `add 1 2` not `add(1, 2)`

---

## Hello World

```kō
fn main =
  println "Hello, World!"
```

Save as `hello.ko` and run: `ko --run hello.ko`

### How it works
- `fn main =` defines the entry point (every Ko program needs this)
- `println` prints a value and adds a newline
- Indentation defines the function body — no curly braces needed

---

## The REPL

Start the interactive REPL:

```bash
ko --repl
```

Try expressions:

```
ko> 1 + 2
= 3

ko> "hello" ++ " world"
= "hello world"

ko> :type 42
Int

ko> :quit
```

Commands: `:quit`, `:type <expr>`, `:env`, `:reset`, `:help`

---

## Variables and Values

### Variables are immutable

```kō
fn main =
  let x = 42
  let name = "Kō"
  let pi = 3.14
  let flag = True

  println x
  println name
  println pi
  println flag
```

**Key difference from Python/JS:** Once you create a value, it never changes. No `x = x + 1`. If you need mutation, use a `ref`:

```kō
fn main =
  let counter = ref 0
  counter := !counter + 1
  println !counter  # 1
```

- `ref 0` creates a mutable reference
- `!counter` reads the value (dereference)
- `counter := 100` writes a new value

---

## Functions

### No parentheses for calls

```kō
fn add a b = a + b

fn main =
  let result = add 1 2
  println result  # 3
```

**Key difference:** In Python you'd write `add(1, 2)`. In Ko, just `add 1 2`.

### Functions are values

```kō
fn double x = x * 2
fn apply f x = f x

fn main =
  println (apply double 5)  # 10
```

### Lambdas (anonymous functions)

```kō
fn main =
  let double = \x -> x * 2
  let add = \a b -> a + b

  println (double 5)   # 10
  println (add 3 4)    # 7
```

### Pipe operator

Chain functions left-to-right with `|>`:

```kō
fn main =
  let result = 5 |> add 1 |> double
  println result  # 12
```

This reads as: start with 5, add 1, then double.

---

## Conditionals

```kō
fn main =
  let x = 42

  # if/then/else (must have else)
  let desc = if x > 0 then "positive" else "non-positive"
  println desc

  # Multi-line blocks (indent the body)
  let big =
    if x > 100 then
      let doubled = x * 2
      doubled
    else
      x
  println big
```

---

## Pattern Matching

Pattern matching is Ko's superpower. It replaces `switch`/`case` and `if-else` chains.

### Basic matching

```kō
type Shape = Circle Int | Rect Int Int

fn area shape =
  match shape
    Circle r => r * r
    Rect w h => w * h

fn main =
  println (area (Circle 5))    # 25
  println (area (Rect 3 4))    # 12
```

### Matching with variables

```kō
type Maybe a = Just a | Nothing

fn from_just default mx =
  match mx
    Just x => x
    Nothing => default

fn main =
  let x = from_just 0 (Just 42)
  println x  # 42
```

### Exhaustive matching

The compiler checks that you handle every case. If you miss one, it's an error:

```kō
type Color = Red | Green | Blue

fn name c =
  match c
    Red => "red"
    Green => "green"
    # Missing Blue — compiler error!
```

---

## Algebraic Data Types (ADTs)

ADTs are how you model data in Ko. Think of them as "tagged unions" or "enums with data."

### Sum types (variants)

```kō
type Result a b = Ok a | Err b
type Maybe a = Just a | Nothing
type Shape = Circle Int | Rect Int Int | Triangle Int Int Int
```

### Records (named fields)

```kō
type Point = {
  x: Int,
  y: Int
}

fn main =
  let p = Point { x = 3, y = 4 }
  println p.x  # 3
```

### Tuples

```kō
fn main =
  let pair = (1, "hello")
  let (num, str) = pair
  println num  # 1
  println str  # hello
```

---

## Lists

Lists are Ko's primary collection type.

```kō
type List a = Cons a (List a) | Nil

fn main =
  let nums = Cons 1 (Cons 2 (Cons 3 Nil))
  let doubled = map (\x -> x * 2) nums
  let evens = filter (\x -> x % 2 == 0) nums
  let total = foldl (\acc x -> acc + x) 0 nums

  println doubled  # Cons 2 (Cons 4 (Cons 6 Nil))
  println evens    # Cons 2 Nil
  println total    # 6
```

### Common list operations

```kō
import List

fn main =
  let xs = Cons 1 (Cons 2 (Cons 3 Nil))

  println (length xs)       # 3
  println (map (\x -> x * 2) xs)  # Cons 2 (Cons 4 (Cons 6 Nil))
  println (filter (\x -> x > 1) xs)  # Cons 2 (Cons 3 Nil)
  println (foldl (\a x -> a + x) 0 xs)  # 6
  println (head xs)         # 1
  println (tail xs)         # Cons 2 (Cons 3 Nil)
  println (elem 2 xs)      # True
  println (is_empty xs)    # False
```

---

## Error Handling with Result

Ko has no exceptions. Use `Result` for operations that can fail:

```kō
type Result a b = Ok a | Err b

fn divide a b =
  if b == 0 then Err "division by zero"
  else Ok (a / b)

fn main =
  match divide 10 2
    Ok result => println result
    Err msg => eprintln msg
```

### The `?` try operator

Propagate errors up the call stack:

```kō
fn parse_and_double s =
  let n = to_int s?  # if Err, return Err immediately
  Ok (n * 2)

fn main =
  match parse_and_double "42"
    Ok n => println n    # 84
    Err msg => eprintln msg
```

---

## String Operations

```kō
fn main =
  let s = "hello"

  println (String.length s)         # 5
  println (String.append s " world")  # hello world
  println (isEmpty s)              # False
  println (repeat s 3)             # hellohellohello
  println (join ", " (Cons "a" (Cons "b" (Cons "c" Nil))))  # a, b, c
```

---

## Modules and Imports

```kō
# math.ko
pub fn add a b = a + b
pub fn mul a b = a * b

# main.ko
import math

fn main =
  println (math.add 1 2)  # 3
```

### Selective imports

```kō
import math.{add, mul}

fn main =
  println (add 1 2)  # 3
```

### Aliased imports

```kō
import math as m

fn main =
  println (m.add 1 2)  # 3
```

---

## Compile-Time Evaluation

```kō
comptime fn factorial n =
  if n <= 1 then 1
  else n * factorial (n - 1)

fn main =
  # This is computed at compile time, not runtime
  let x = factorial 10
  println x  # 3628800
```

---

## Quick Reference

| Concept | Ko Syntax | Python Equivalent |
|---------|-----------|-------------------|
| Function call | `add 1 2` | `add(1, 2)` |
| Let binding | `let x = 42` | `x = 42` |
| Lambda | `\x -> x * 2` | `lambda x: x * 2` |
| If/else | `if x > 0 then x else 0` | `x if x > 0 else 0` |
| Pattern match | `match x \| Just v => v` | `match x: case Just(v): v` |
| List | `Cons 1 (Cons 2 Nil)` | `[1, 2]` |
| Pipe | `x \|> f \|> g` | `g(f(x))` |
| Ref (mutable) | `let r = ref 0; r := 1` | `r = 0; r = 1` |
| Dereference | `!r` | `r` |
| String concat | `a ++ b` | `a + b` |
| Comment | `# this` | `# this` |

---

## Next Steps

1. **Read the examples** — `examples/` directory has 22 working programs
2. **Try the crash course** — `docs/ko-crash-course.md` goes deeper into FP concepts
3. **Check the quick reference** — `docs/quick-reference.md` for syntax details
4. **Read the spec** — `SPEC.md` for the full language specification

---

## Common Mistakes from Imperative Land

### "I need a for loop"

```kō
# Don't: no for loops
# for i in range(10): print(i)

# Do: use recursion or map
fn count n =
  if n <= 0 then ()
  else
    println n
    count (n - 1)

fn main = count 10
```

### "I need to mutate a variable"

```kō
# Don't: let x = x + 1  (error!)

# Do: use a ref
let x = ref 0
x := !x + 1
```

### "I need null"

```kō
# Don't: no null
# if x is None: ...

# Do: use Maybe
type Maybe a = Just a | Nothing

fn find xs =
  match xs
    Cons x _ => Just x
    Nil => Nothing
```

### "I need an exception"

```kō
# Don't: no try/catch
# try: risky_operation()

# Do: use Result
type Result a b = Ok a | Err b

fn risky_operation input =
  if input == "" then Err "empty input"
  else Ok (process input)
```

### "I need a class"

```kō
# Don't: no classes
# class User:
#   def __init__(self, name, age):
#     self.name = name
#     self.age = age

# Do: use records + functions
type User = { name: String, age: Int }

fn greet user = "Hello, " ++ user.name

fn main =
  let user = User { name = "Alice", age = 30 }
  println (greet user)
```
