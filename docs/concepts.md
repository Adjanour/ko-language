# Core Concepts

> Learn Kō by understanding its ideas, not its syntax.

---

## 1. Everything is an Expression

In Kō, everything returns a value. There are no statements.

```kō
# In other languages, if is a statement:
# if x > 0 { return x; } else { return -x; }

# In Kō, if is an expression:
if x > 0 then x else -x
```

This means you can use `if` anywhere:

```kō
let result = if x > 0 then x else -x
println (if x > 0 then "positive" else "non-positive")
```

The same is true for `match`, blocks, and `let`:

```kō
# match is an expression
let description = match shape
  | Circle r => "circle"
  | Rect w h => "rectangle"

# blocks are expressions
let x = 
  let a = 10
  let b = 20
  a + b

# let is an expression
let x = (let a = 10 in a + 5)
```

**Why this matters:** You can compose expressions freely. No need for temporary variables or return statements.

---

## 2. Immutability by Default

Once you create a value, it never changes.

```kō
let x = 42
x := 100  # Error! Can't reassign let bindings
```

This is the default in Kō. If you want mutation, you must ask for it explicitly:

```kō
let counter = ref 0      # Create a mutable reference
counter := !counter + 1   # Mutate it
println !counter           # 1
```

**Why this matters:** Immutable code is easier to reason about. You know that `x` will always be `42`. No surprises.

---

## 3. Functions are Values

Functions can be passed around like any other value.

```kō
fn add a b = a + b
fn apply f x = f x

apply add 5    # Returns 5 + ... wait, this is curried
apply (\x -> x * 2) 5  # Returns 10
```

This is the foundation of higher-order functions:

```kō
type List a = Cons a (List a) | Nil

fn map f list =
  match list
    | Cons x rest => Cons (f x) (map f rest)
    | Nil => Nil

# Pass a function to map
let nums = Cons 1 (Cons 2 (Cons 3 Nil))
let doubled = map (\x -> x * 2) nums
```

**Why this matters:** You can abstract patterns. Instead of writing the same logic repeatedly, you write it once and pass it as a function.

---

## 4. Currying

All functions in Kō are curried. This means they take one argument and return a function that takes the next argument.

```kō
fn add a b = a + b

# This is actually:
fn add a = \b -> a + b

# So:
add 1 2      # Returns 3
add 1        # Returns \b -> 1 + b
```

This is why you can do:

```kō
let add5 = add 5
add5 10      # Returns 15
```

**Why this matters:** Partial application is free. You can create specialized functions from general ones.

---

## 5. Algebraic Data Types (ADTs)

ADTs let you define your own types. They're the core of modeling in Kō.

```kō
type Maybe a = Just a | Nothing
type Result a b = Ok a | Err b
type List a = Cons a (List a) | Nil
type Shape = Circle Float | Rect Float Float
type Expr = Add Expr Expr | Mul Expr Expr | Lit Int
```

Each constructor can hold typed data. The compiler generates:
- A tag for each variant (0, 1, 2, ...)
- Constructor functions: `Just 42`, `Nothing`, `Cons 1 Nil`
- Pattern matching via tag checks

**Why this matters:** You can model any data structure. No need for classes or objects.

---

## 6. Records

Records are named field types. They use braces.

```kō
type Point = { x: Int, y: Int }
type Person = { name: String, age: Int }

# Create a record
let pt = Point { x = 3, y = 4 }

# Access fields
let x_val = pt.x
let y_val = pt.y
```

**Why this matters:** Records give you named, typed fields. Unlike tuples, fields have names and can be accessed by name.

---

## 7. Tuples

Tuples group values of different types. They use parentheses with commas.

```kō
let t = (1, 2, 3)           # triple
let pair = (1, "hello")     # pair
let single = (42,)           # singleton tuple
```

**Why this matters:** Tuples are lightweight data containers. Use them when you need to group a few values without defining a full record type.

---

## 8. Pattern Matching

Pattern matching is how you destructure ADTs.

```kō
type Maybe a = Just a | Nothing

fn from-just default mx =
  match mx
    | Just x => x
    | Nothing => default
```

The compiler checks that you handle every case:

```kō
fn dangerous xs =
  match xs
    | Cons x _ => x
    # Warning: Nil case not handled!
```

**Why this matters:** You never miss a case. The compiler catches it.

---

## 9. Closures

Closures capture variables from their surrounding scope.

```kō
fn make_adder n =
  \x -> x + n    # n is captured from the outer scope

let add5 = make_adder 5
add5 10    # Returns 15
```

This is how you create "remembering" functions:

```kō
fn make_counter =
  let count = ref 0
  \() -> 
    count := !count + 1
    !count

let counter = make_counter
counter ()  # 1
counter ()  # 2
```

**Why this matters:** Closures let you encapsulate state without classes.

---

## 10. Higher-Order Functions

Functions that take or return other functions.

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

fn fold f acc list =
  match list
    | Cons x rest => fold f (f acc x) rest
    | Nil => acc
```

These are the building blocks of functional programming:

```kō
let nums = Cons 1 (Cons 2 (Cons 3 (Cons 4 (Cons 5 Nil))))

# Double all numbers
let doubled = map (\x -> x * 2) nums

# Keep only even numbers
let evens = filter (\x -> mod x 2 == 0) nums

# Sum all numbers
let total = fold (\acc x -> acc + x) 0 nums
```

**Why this matters:** You can process data declaratively. No loops, no indices, no mutation.

---

## 11. Pipe Operator

The pipe operator `|>` passes the result of one expression as the last argument to the next function:

```kō
fn add x y = x + y
fn double x = x * 2

# Without pipe:
double (add 1 5)    # 12

# With pipe:
5 |> add 1 |> double  # 12
```

**Why this matters:** Pipes make data processing pipelines read left-to-right, top-to-bottom, like a sequence of transformations.

---

## 12. Modules and Imports

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

Or import the whole module:

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

**Why this matters:** You control exactly what's in scope. No namespace pollution.

---

## 13. Pattern Matching in Functions

You can match on function parameters directly:

```kō
fn head xs =
  match xs
    | Cons x _ => x
    | Nil => panic "empty list"

fn is-empty xs =
  match xs
    | Cons _ _ => False
    | Nil => True
```

Or use `if` with pattern matching:

```kō
fn safe-divide a b =
  if b == 0 then Err "division by zero"
  else Ok (a / b)
```

**Why this matters:** You handle edge cases explicitly. No null checks, no exceptions.

---

## 14. Reference Counting

Kō uses reference counting for memory management. No garbage collector.

```kō
let x = "hello"    # refcount = 1
let y = x           # refcount = 2
# When x goes out of scope, refcount = 1
# When y goes out of scope, refcount = 0, memory freed
```

This is automatic. You don't need to think about it.

**Why this matters:** Deterministic memory management. No GC pauses.

---

## 15. Compile to LLVM

Kō compiles to LLVM IR. This means:

```kō
fn add a b = a + b
```

Becomes LLVM IR (SSA form), which LLVM compiles to optimized machine code. You can run it directly (JIT) or emit an object file:

```bash
ko file.ko               # JIT-execute (default)
ko --dump-ir file.ko     # Dump LLVM IR
ko --emit-obj out.o file.ko  # Emit object file
ko --emit-exe out file.ko    # Link to executable
```

**Why this matters:** LLVM's optimizer handles constant folding, dead code elimination, inlining, and more. You get industrial-strength optimization for free.

---

## 16. Type Inference

Kō uses Hindley-Milner type inference. You rarely need type annotations.

```kō
fn add a b = a + b
# Compiler infers: add : Int -> Int -> Int

fn map f list =
  match list
    | Cons x rest => Cons (f x) (map f rest)
    | Nil => Nil
# Compiler infers: map : (a -> b) -> List a -> List b
```

You can add parameter annotations:

```kō
fn add a b : Int = a + b
fn add a b = a + b
```

**Why this matters:** Less typing, more clarity. The compiler figures out the types.

---

## 17. LSP Support

Kō comes with a language server (`ko-lsp`) that provides editor integration:

- **Hover** — see the type of any expression
- **Completion** — autocomplete function and variable names
- **Diagnostics** — type errors as you type
- **Go to definition** — jump to where a name is defined
- **Document symbols** — outline of your code

Works with VS Code (via the `ko-language` extension) and Neovim.

---

## Putting It All Together

Here's a small program that uses all these concepts:

```kō
type Maybe a = Just a | Nothing
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

fn fold f acc list =
  match list
    | Cons x rest => fold f (f acc x) rest
    | Nil => acc

fn head xs =
  match xs
    | Cons x _ => Just x
    | Nil => Nothing

fn main =
  let nums = Cons 1 (Cons 2 (Cons 3 (Cons 4 (Cons 5 Nil))))
  
  # Functional pipeline
  let result = fold (\acc x -> acc + x) 0 
    (filter (\x -> mod x 2 == 0) 
      (map (\x -> x * 2) nums))
  
  println result  # 30 (2+4+6+8+10)
```

This is Kō: simple, expressive, and powerful.
