# Functional Programming in Kō

A plain-English guide to the functional stuff in this language.

---

## The Big Idea

In normal programming (imperative), you tell the computer **what to do step by step**:

```
x = 0
x = x + 1
x = x + 1
print x
```

In functional programming, you describe **what things ARE**:

```
let x = 1 + 1
print x
```

Both give the same result. But functional code is easier to reason about because nothing changes. Once you create `x`, it stays `1` forever.

---

## 1. Let Bindings — "give a name to a value"

```kō
let x = 42
let name = "hello"
let result = x + 10
```

`let` creates an **immutable** binding. You can't reassign it:

```kō
let x = 10
x = 20    # ERROR — can't reassign
```

This is intentional. It forces you to think about values, not mutations.

**Why immutable?** Because when you read code like:

```kō
let total = calculate_total items
let tax = total * 0.1
let final = total + tax
```

You know `total` never changes. No surprises.

---

## 2. Functions — "first-class values"

In Kō, functions are values just like numbers or strings. You can pass them around.

```kō
fn add a b = a + b
fn double x = x * 2
```

You can pass functions as arguments to other functions:

```kō
fn apply_twice f x = f (f x)

println (apply_twice double 3)  # 12 — double(double(3))
```

`apply_twice` takes a function `f` and applies it twice to `x`. That's the power of first-class functions.

---

## 3. Lambdas — "anonymous functions"

Sometimes you need a function but don't want to give it a name. Use `\` (backslash):

```kō
let double = \x -> x * 2
let add = \a b -> a + b

println (double 5)   # 10
println (add 3 4)    # 7
```

The `\` means "this is a function." The `->` separates params from body.

**When to use lambdas:** For short one-off functions:

```kō
let nums = Cons 1 (Cons 2 (Cons 3 (Cons 4 (Cons 5 Nil))))
let doubled = map (\x -> x * 2) nums
```

---

## 4. Currying — "one argument at a time"

This is the weirdest part of Kō. Every function takes **exactly one argument**.

When you write:

```kō
fn add a b = a + b
```

It's actually sugar for:

```kō
fn add = \a -> \b -> a + b
```

`add` takes `a`, returns a **new function** that takes `b`, then returns `a + b`.

So `add 3 4` is really two steps:

```kō
let add_3 = add 3       # add_3 is now \b -> 3 + b
let result = add_3 4    # result is 3 + 4 = 7
```

**Why currying?** It lets you partially apply functions:

```kō
fn add a b = a + b
let add_ten = add 10     # partial application
println (add_ten 5)      # 15
println (add_ten 20)     # 30
```

You created a specialized function `add_ten` that always adds 10.

---

## 5. Higher-Order Functions — "functions that take functions"

A higher-order function is one that takes a function as input OR returns a function.

```kō
type List a = Cons a (List a) | Nil

fn map f list =
  match list
    | Cons x rest => Cons (f x) (map f rest)
    | Nil => Nil

fn filter f list =
  match list
    | Cons x rest =>
      if f x then Cons x (filter f rest)
      else filter f rest
    | Nil => Nil
```

**map** applies a function to every element:

```kō
let nums = Cons 1 (Cons 2 (Cons 3 Nil))
let doubled = map (\x -> x * 2) nums
# doubled is Cons 2 (Cons 4 (Cons 6 Nil))
```

**filter** keeps only elements that pass a test:

```kō
let evens = filter (\x -> x % 2 == 0) nums
# evens is Cons 2 Nil
```

These are the building blocks. Once you have `map`, `filter`, and `fold`, you can process any list.

---

## 6. Closures — "functions that remember"

A closure is a function that **captures variables from outside its own scope**.

```kō
let secret = 10
let add_secret = \x -> x + secret  # "secret" is captured

println (add_secret 5)  # 15 — it remembers secret=10
```

Without closures, `add_secret` wouldn't know what `secret` is because it's defined outside the function. But closures "grab" that variable and hold onto it.

**A practical example — counters:**

```kō
let counter = ref 0

let increment = \_ ->
  counter := (!counter + 1)

increment 0
increment 0
increment 0
println !counter  # 3
```

The `increment` function captures the `counter` ref cell. Even though `counter` is defined outside, `increment` remembers it and can mutate it.

---

## 7. Pattern Matching — "destructuring with branches"

Pattern matching lets you destructure values and branch based on their shape:

```kō
type Maybe a = Just a | Nothing

fn get_value mx =
  match mx
    | Just x => x      # if Just, extract x
    | Nothing => 0      # if Nothing, return 0
```

**With lists:**

```kō
type List a = Cons a (List a) | Nil

fn sum xs =
  match xs
    | Cons x rest => x + sum rest  # head + sum of tail
    | Nil => 0
```

**With multiple patterns:**

```kō
fn describe x =
  match x
    | 0 => "zero"
    | 1 => "one"
    | n => "some number"  # wildcard catches everything else
```

**Exhaustiveness checking:** The compiler warns if you miss a case:

```kō
type Color = Red | Green | Blue

fn is_red c =
  match c
    | Red => True
    # ERROR: missing Green and Blue!
```

---

## 8. Algebraic Data Types — "define your own types"

ADTs let you create types that describe **what something could be**:

```kō
type Maybe a = Just a | Nothing
type List a = Cons a (List a) | Nil
type Result a b = Ok a | Err b
```

**Why ADTs?** They make invalid states unrepresentable:

```kō
type LoginResult = Success User | WrongPassword | AccountLocked
```

You can't accidentally return a "half-logged-in" state. It's either success, wrong password, or locked.

---

## 9. Records — "named fields"

Records group named, typed fields:

```kō
type Point = { x: Int, y: Int }
type Person = { name: String, age: Int }

# Create
let pt = Point { x = 3, y = 4 }

# Access
println pt.x   # 3
println pt.y   # 4
```

**Why records?** Unlike tuples, fields have names. `pt.x` is clearer than `fst pt`.

---

## 10. Tuples — " unnamed groups"

Tuples group values without names:

```kō
let t = (1, 2, 3)
let pair = ("hello", 42)
```

**When to use tuples:** For quick groupings where names aren't needed.

---

## 11. Pipe Operator — "flow data through functions"

The pipe operator `|>` passes the left side as the last argument to the right side:

```kō
fn add x y = x + y
fn double x = x * 2

# Without pipe:
double (add 1 5)    # 12

# With pipe:
5 |> add 1 |> double  # 12
```

**Why pipes?** They make pipelines read left-to-right:

```kō
# Instead of this (inside-out):
fold (\a x -> a + x) 0 (filter (\x -> x > 2) (map (\x -> x * 2) nums))

# Write this (top-down):
nums
  |> map (\x -> x * 2)
  |> filter (\x -> x > 2)
  |> fold (\a x -> a + x) 0
```

---

## 12. Ref Cells — "escape from immutability"

Everything in Kō is immutable by default. Ref cells are the **one exception**:

```kō
let counter = ref 0    # create a box holding 0
counter := 42          # put 42 in the box
println !counter       # take the value out: 42
```

Think of it like a variable that lives in a box. You can't change the box, but you can swap what's inside.

**When to use ref cells:**

- Counters
- Accumulators
- State in games
- Anything that genuinely needs to change

**When NOT to use ref cells:**

- Most of the time! Try immutable first.
- If you find yourself using refs everywhere, you're fighting the language.

---

## 13. Modules and Imports

Kō has three kinds of names available to your program:

| Kind | How to use it | Example |
|------|---------------|---------|
| **Built-ins** | No import required | `println`, `Int.pow`, `String.length` |
| **Stdlib modules** | `import std.<Name>` | `import std.List` |
| **Local modules** | `import <Name>` | `import Math` |

Import specific names from a local module:

```kō
import Math.{add, double}

fn main =
  println (add 1 2)     # 3
  println (double 5)    # 10
```

Or import everything:

```kō
import Math

fn main =
  println (Math.add 1 2)    # 3
```

Import from the standard library using the reserved `std.` namespace:

```kō
import std.List

fn main =
  let xs = Cons 1 (Cons 2 Nil)
  println (List.length xs)
```

---

## 14. Compile-Time Evaluation — "compute before running"

`comptime` tells the compiler to evaluate an expression at compile time:

```kō
let x = comptime (2 + 3)  # x is literally 5 in the LLVM IR
let y = comptime (10 * comptime (2 + 3))  # y is 50
```

**Why?** It produces faster code. The computation happens once during compilation, not every time the program runs.

**When to use:** For constant expressions that never change:

```kō
let pi = comptime 3.14159
let max_size = comptime 1024
```

---

## 15. LSP Support

Kō comes with a language server that provides:

- **Hover** — see the type of any expression
- **Completion** — autocomplete names
- **Diagnostics** — type errors as you type
- **Go to definition** — jump to where a name is defined
- **Document symbols** — outline of your code

Works with VS Code (via the `ko-language` extension) and Neovim.

---

## The Mental Model

Think of Kō code as **math equations**, not instructions:

```kō
# This is math:
let x = 1 + 2
let y = x * 3
println y  # 9

# NOT this:
# x = 1 + 2
# y = x * 3
# print y
```

In math, you don't "change" `x`. You give it a value and it stays that way. That's how Kō works.

When you NEED mutation (like a game loop), use ref cells. But start with immutable values and pure functions. Only reach for refs when you really need them.

---

## Quick Reference

| Concept | Syntax | What it does |
|---------|--------|--------------|
| Let binding | `let x = 42` | Create immutable value |
| Function | `fn add a b = a + b` | Define named function |
| Lambda | `\x -> x * 2` | Anonymous function |
| Closure | `\x -> x + y` | Function that captures `y` |
| Pattern match | `\| Pat => body` | Destructure and branch |
| ADT | `type Maybe a = Just a \| Nothing` | Define custom type |
| Record | `type Pt = { x: Int, y: Int }` | Named field type |
| Tuple | `(1, "hello")` | Unnamed group |
| Ref cell | `let r = ref 0` | Mutable reference |
| Dereference | `!r` | Read ref cell |
| Set ref | `r := 42` | Write to ref cell |
| Pipe | `x \|> f` | Pass x as last arg to f |
| Comptime | `comptime (2 + 3)` | Compile-time evaluation |
| Local module | `import Math` | Import a `.ko` file from the same directory |
| Stdlib module | `import std.List` | Import from the `std/` standard library |
| Selective import | `import Math.{add, double}` | Import specific names |
| Map | `map f list` | Apply function to all elements |
| Filter | `filter f list` | Keep matching elements |
| Fold | `fold f acc list` | Reduce list to single value |
