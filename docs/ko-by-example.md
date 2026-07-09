# Kō by Example

A step-by-step guide to functional programming in Kō.

Each section builds on the previous one. All code examples are complete programs you can run.

---

## 1. Hello World

### Running your first program

Create a file called `hello.ko`:

```
fn main =
  println "Hello, world!"
```

Run it:

```bash
ko hello.ko
```

Output:

```
Hello, world!
```

### How it works

- `fn main =` defines the entry point. Every Kō program needs a `main` function.
- `println` prints a value and adds a newline — strings print without quotes.
- Indentation defines the function body — no curly braces needed.

### `inspect` for debugging

`inspect` prints any value with its type information. Use it to see what's happening:

```
fn main =
  inspect 42
  inspect "hello"
  inspect True
  inspect 3.14
```

Output:

```
42"hello"True3.140000
```

- `inspect 42` prints the integer `42`.
- `inspect "hello"` prints the string with quotes (debug format).
- `inspect True` prints `True`.
- `inspect 3.14` prints the float with trailing zeros.

---

## 2. Values & Types

### Integers

Kō supports decimal, hex (`0x`), binary (`0b`), and octal (`0o`) literals:

```
fn main =
  let decimal = 42
  let hex = 0xFF
  let binary = 0b1010
  let big = 1_000_000

  inspect decimal
  inspect hex
  inspect binary
  inspect big
```

Output:

```
42255101000000
```

### Strings and characters

Strings use double quotes, characters use single quotes:

```
fn main =
  let greeting = "hello"
  let letter = 'x'

  inspect greeting
  inspect letter
```

Output:

```
"hello"'x'
```

### Booleans

Kō has built-in `True` and `False`:

```
fn main =
  let a = True
  let b = False

  inspect a
  inspect b
```

Output:

```
TrueFalse
```

---

## 3. Functions

### Defining functions

Use `fn` followed by the function name and parameters:

```
fn add a b = a + b

fn main =
  inspect (add 1 2)
  inspect (add 10 20)
```

Output:

```
330
```

### Type annotations

You can annotate parameter types with `:` after the parameter name:

```
fn double x : Int = x * 2

fn main =
  inspect (double 5)
  inspect (double 10)
```

Output:

```
1020
```

### Recursion

Kō uses recursion instead of loops:

```
fn factorial n =
  if n <= 1 then 1
  else n * factorial (n - 1)

fn main =
  inspect (factorial 5)
  inspect (factorial 10)
```

Output:

```
1203628800
```

### Lambda expressions

Anonymous functions use `\` (backslash):

```
fn main =
  let double = \x -> x * 2
  let add = \a b -> a + b

  inspect (double 5)
  inspect (add 1 2)
```

Output:

```
103
```

---

## 4. Expressions

### If/else

`if` is an expression — it returns a value:

```
fn main =
  let x = if 1 > 0 then "positive" else "negative"
  inspect x
```

Output:

```
"positive"
```

### Chained conditionals

Nest `else if` for multiple branches:

```
fn classify n =
  if n > 0 then "positive"
  else if n < 0 then "negative"
  else "zero"

fn main =
  inspect (classify 5)
  inspect (classify (-3))
  inspect (classify 0)
```

Output:

```
"positive""negative""zero"
```

### Let bindings

Let bindings chain sequentially:

```
fn main =
  let a = 5
  let b = 10
  let result = a + b
  inspect result
```

Output:

```
15
```

---

## 5. Lists

### Building lists

Define a list type and use `::` (cons) to build lists:

```
type List a = Cons a (List a) | Nil

fn length xs =
  match xs
    | Cons _ rest => 1 + length rest
    | Nil => 0

fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0

fn main =
  let xs = 1 :: 2 :: 3 :: Nil
  inspect (length xs)
  inspect (sum xs)
```

Output:

```
36
```

### Working with Maybe

The `Maybe` type represents optional values:

```
type Maybe a = Just a | Nothing

fn from-just m =
  match m
    | Just value => value
    | Nothing => 0

fn main =
  inspect (from-just (Just 42))
  inspect (from-just Nothing)
```

Output:

```
420
```

### Wildcard patterns

Use `_` to ignore parts of a pattern:

```
type List a = Cons a (List a) | Nil

fn head xs =
  match xs
    | Cons x _ => x
    | Nil => 0

fn main =
  let xs = 10 :: 20 :: 30 :: Nil
  inspect (head xs)
```

Output:

```
10
```

---

## 6. Pattern Matching

### Basic match

Use `match` with `|` prefix on each arm:

```
type Maybe a = Just a | Nothing

fn describe m =
  match m
    | Just 0 => "zero"
    | Just _ => "has value"
    | Nothing => "empty"

fn main =
  inspect (describe (Just 0))
  inspect (describe (Just 5))
  inspect (describe Nothing)
```

Output:

```
"zero""has value""empty"
```

---

## 7. Higher-Order Functions

### Map

Apply a function to every element:

```
type List a = Cons a (List a) | Nil

fn map f xs =
  match xs
    | Cons x rest => Cons (f x) (map f rest)
    | Nil => Nil

fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0

fn main =
  let xs = 1 :: 2 :: 3 :: Nil
  let doubled = map (\x -> x * 2) xs
  inspect (sum doubled)
```

Output:

```
12
```

### Filter

Keep elements that pass a test:

```
type List a = Cons a (List a) | Nil

fn filter pred xs =
  match xs
    | Cons x rest =>
        if pred x then Cons x (filter pred rest)
        else filter pred rest
    | Nil => Nil

fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0

fn main =
  let xs = 1 :: 2 :: 3 :: 4 :: 5 :: Nil
  let evens = filter (\x -> x % 2 == 0) xs
  inspect (sum evens)
```

Output:

``
6
```

### Fold

Combine all elements:

```
type List a = Cons a (List a) | Nil

fn foldl f acc xs =
  match xs
    | Cons x rest => foldl f (f acc x) rest
    | Nil => acc

fn main =
  let xs = 1 :: 2 :: 3 :: 4 :: 5 :: Nil
  let total = foldl (\acc x -> acc + x) 0 xs
  inspect total
```

Output:

```
15
```

---

## 8. Closures & Currying

### Closures

Functions capture variables from their environment:

```
fn main =
  let x = 10
  let add-x = \y -> x + y
  inspect (add-x 5)
  inspect (add-x 20)
```

Output:

```
1530
```

### Currying

Multi-parameter functions automatically support partial application:

```
fn add a b = a + b

fn main =
  let add5 = add 5
  inspect (add5 10)
  inspect (add5 20)
```

Output:

```
1525
```

### Building function factories

Combine closures and currying:

```
fn make-adder n = \x -> x + n
fn make-multiplier n = \x -> x * n

fn main =
  let add10 = make-adder 10
  let triple = make-multiplier 3
  inspect (add10 5)
  inspect (triple 4)
```

Output:

```
1512
```

---

## 9. Records & Tuples

### Records

Records group named fields with `{ }`:

```
type Point = { x: Int, y: Int }

fn dist-sq p1 p2 =
  let dx = p1.x - p2.x
  let dy = p1.y - p2.y
  dx * dx + dy * dy

fn main =
  let origin = Point { x = 0, y = 0 }
  let pt = Point { x = 3, y = 4 }
  inspect (dist-sq origin pt)
```

Output:

```
25
```

### Tuples

Tuples group values with `()`:

```
fn main =
  let pair = (1, 2)
  let triple = (1, 2, 3)
  inspect (fst pair)
  inspect (snd pair)
  inspect (thd triple)

fn fst t = match t | (a, _) => a
fn snd t = match t | (_, b) => b
fn thd t = match t | (_, _, c) => c
```

Output:

```
123
```

---

## 10. Reference Cells

### Mutable state with `ref`

Kō is functional by default, but you can use `ref` for mutable state:

```
fn main =
  let counter = ref 0
  counter := !counter + 1
  counter := !counter + 1
  counter := !counter + 1
  let x = !counter
  inspect x
```

Output:

```
3
```

- `ref 0` creates a reference cell holding `0`.
- `!counter` reads the current value.
- `counter := !counter + 1` updates it.

### Stateful closures

Encapsulate state inside a closure:

```
fn main =
  let counter = ref 0
  let next = \_ ->
    counter := !counter + 1
    !counter
  inspect (next 0)
  inspect (next 0)
  inspect (next 0)
```

Output:

```
123
```

Each call to `next` increments and returns the counter.

---

## 11. The Standard Library

Kō has three kinds of names available to your program:

| Kind | How to use it | Example |
|------|---------------|---------|
| **Built-ins** | No import required | `println`, `Int.pow`, `String.length` |
| **Stdlib modules** | `import std.<Name>` | `import std.List` |
| **Local modules** | `import <Name>` | `import Math` |

### Built-in functions

Built-in functions are always in scope — no import needed:

```
fn main =
  println 42
  println True
  inspect (Int.pow 2 10)
  inspect (Int.factorial 6)
  inspect (Float.sqrt 2.0)
  let s = "hello"
  inspect (String.length s)
```

Output:

```
42
True
10247201.4142145
```

### Available functions

**Int operations:** `Int.pow`, `Int.factorial`, `Int.isqrt`, `Int.gcd`, `Int.lcm`, `Int.abs`, `Int.min`, `Int.max`, `Int.clamp`, `Int.sign`, `Int.even`, `Int.odd`, `Int.mod`

**Float operations:** `Float.sqrt`, `Float.sin`, `Float.cos`, `Float.tan`, `Float.exp`, `Float.log`, `Float.log2`, `Float.log10`, `Float.floor`, `Float.ceil`, `Float.abs`, `Float.ofInt`, `Float.toInt`, `Float.pow`

**String operations:** `String.length`, `String.append`, `String.isEmpty`

**I/O:** `println`, `print`, `inspect`

### Stdlib modules

Stdlib modules live in `std/` and are imported with the reserved `std.` namespace. The compiler looks for stdlib source in `KO_STDLIB_PATH` first, then in a `std/` directory near the `ko` executable:

```
import std.List

fn main =
  let xs = Cons 1 (Cons 2 (Cons 3 Nil))
  inspect (List.length xs)
```

Available in `std/`: `List` (25 operations), `Int`, `String`, `Bool`, `Math`

### Local modules

A local module is any `.ko` file in the same directory as the file being compiled. Import it by name without a `std.` prefix:

```
import Math

fn main =
  println (Math.add 1 2)
```

This imports `Math.ko` from the same directory.

---

## 12. Putting It Together

### Building a contact book

Combine records, lists, pattern matching, and higher-order functions:

```
type Contact = { name: String, phone: String }

fn main =
  let contacts =
    Contact { name = "Alice", phone = "555-1234" } ::
    Contact { name = "Bob", phone = "555-5678" } ::
    Contact { name = "Charlie", phone = "555-9012" } ::
    Nil

  let count = length contacts
  inspect count

fn length xs =
  match xs
    | Cons _ rest => 1 + length rest
    | Nil => 0
```

Output:

```
3
```

### Building a calculator

Use pattern matching and recursion:

```
type Expr = Lit Int | Add Expr Expr | Mul Expr Expr | Neg Expr

fn eval e =
  match e
    | Lit n => n
    | Add a b => eval a + eval b
    | Mul a b => eval a * eval b
    | Neg e => 0 - eval e

fn main =
  let expr = Add (Lit 1) (Mul (Lit 2) (Lit 3))
  inspect (eval expr)

  let expr2 = Neg (Lit 5)
  inspect (eval expr2)
```

Output:

```
7-5
```

---

## Next Steps

You now know the core of Kō:

- **Values:** Integers, floats, strings, booleans
- **Functions:** `fn`, lambdas, closures, currying
- **Types:** Sum types, records, tuples, lists
- **Control:** `if/else`, `match`, pattern matching
- **State:** `ref`, `:=`, `!`
- **Higher-order:** `map`, `filter`, `fold`
- **Modules:** `import`, `import std.<Name>`, selective imports

Explore further:

- `docs/concepts.md` — detailed concept explanations
- `docs/functional-guide.md` — functional programming patterns
- `docs/how-closures-work.md` — closure internals
- `docs/pattern-matching-and-adts.md` — advanced patterns
- `examples/` — working example programs
- `std/` — standard library source code
