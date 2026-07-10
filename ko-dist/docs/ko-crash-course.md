# Kō Crash Course: Functional Programming from Scratch

This is a practical guide to thinking functionally and writing Kō code. No prior FP experience required.

---

## Part 1: What Is Functional Programming?

Functional programming is a way of building programs by composing **pure functions** — functions that always produce the same output for the same input and don't change anything outside themselves.

The core ideas:

1. **Functions are values** — you can pass them around like numbers or strings
2. **No mutation** — once a value is created, it never changes
3. **Expressions, not statements** — everything returns something
4. **Types describe data** — you model your domain with types, then write functions that transform between them

### Why Bother?

- **Easier to test** — pure functions are trivially testable
- **Easier to reason about** — no hidden state, no surprises
- **Easier to parallelize** — no shared mutable state means no race conditions
- **Composable** — small functions snap together like LEGO

---

## Part 2: Kō Basics

### Running Kō

```bash
# Execute a program
# JIT-execute a program (default)
ko myfile.ko

# Dump LLVM IR (for debugging)
ko --dump-ir myfile.ko

# Open the REPL (interactive mode)
ko --repl
```

### Hello World

```
# Comments start with #

fn main =
  println "Hello, World!"
```

Save this as `hello.ko` and run: `ko --run hello.ko`

### The REPL

Start the REPL with `ko --repl`. Type expressions and see results:

```
ko> 1 + 2
= 3

ko> "hello" ++ " world"
= "hello world"

ko> :quit
```

Commands: `:quit`, `:type <expr>`, `:env`, `:reset`, `:help`

---

## Part 3: Types and Values

Kō is **statically typed** — every value has a type, and the compiler checks types before running.

### Primitive Types

```
42          # Int (integer)
3.14        # Float (64-bit floating point)
"hello"     # String
'c'         # Char (single character)
True        # Bool (True or False)
()          # Unit (the "nothing" value, like void)
```

### Defining Functions

```
# Named function
fn double x = x * 2

# Lambda (anonymous function)
\x -> x * 2

# Multi-parameter function
fn add a b = a + b

# Function with type annotation
fn double x : Int = x * 2
```

### Calling Functions

```
double 5       # => 10
add 3 4        # => 7

# Kō uses space-separated application (no parentheses needed)
# Parentheses are for grouping:
(double 5) + 3    # => 13
double (5 + 3)    # => 16
```

### Let Bindings

```
let x = 42
let name = "Kō"
let result = add 3 4    # result = 7
```

### If Expressions

In Kō, `if` is an expression — it returns a value:

```
if x > 0 then "positive"
else if x < 0 then "negative"
else "zero"
```

**No curly braces needed.** The indentation defines the blocks.

---

## Part 4: Functions as Values

This is where functional programming gets powerful. Functions are first-class values — you can store them, pass them around, and return them from other functions.

### Higher-Order Functions

A function that takes or returns another function is called a **higher-order function**:

```
# Takes a function as argument
fn apply_to_five f = f 5

# Returns a function
fn make_adder n = \x -> x + n

# Usage
apply_to_five double          # => 10
let add_three = make_adder 3
add_three 10                  # => 13
```

### Common Higher-Order Functions

```
# Map: transform every element
let nums = Cons 1 (Cons 2 (Cons 3 Nil))
map (\x -> x * 2) nums          # => Cons 2 (Cons 4 (Cons 6 Nil))

# Filter: keep elements matching a predicate
filter (\x -> x > 2) nums      # => Cons 3 Nil

# Fold: reduce a list to a single value
fold (\a x -> a + x) 0 nums     # => 6
```

### The Pipe Operator

The pipe operator `|>` passes the result of the left side as the last argument to the right side:

```
# Without pipes (read inside-out):
let nums = Cons 1 (Cons 2 (Cons 3 Nil))
sort (filter (\x -> x > 2) (map (\x -> x * 2) nums))

# With pipes (read top-to-bottom):
Cons 1 (Cons 2 (Cons 3 Nil))
  |> map (\x -> x * 2)
  |> filter (\x -> x > 2)
  |> sort
```

Pipes make chains of transformations readable.

---

## Part 5: Algebraic Data Types (ADTs)

ADTs are how you model your domain in Kō. They come in two flavors: **sum types** (a value is one of several variants) and **record types** (a value has named fields).

### Sum Types (Tagged Unions)

```
# Define a type with variants
type Shape =
  | Circle Float           # A circle with a radius
  | Rectangle Float Float  # A rectangle with width and height
  | Triangle Float Float   # A triangle with base and height
```

Each variant is a **constructor** — it wraps data in a named tag:

```
let c = Circle 5.0
let r = Rectangle 3.0 4.0
```

### Pattern Matching

Use `match` to destructure and handle each variant:

```
fn area shape =
  match shape
    | Circle r => 3.14159 * r * r
    | Rectangle w h => w * h
    | Triangle b h => 0.5 * b * h
```

Pattern matching is **exhaustive** — the compiler ensures you handle every variant. If you miss one, you get a type error.

### Enums (No Data)

Types with no data are just tags:

```
type Direction = North | South | East | West

fn turn_left dir =
  match dir
    | North => West
    | West => South
    | South => East
    | East => North
```

### Recursive Types

Types can reference themselves — essential for lists and trees:

```
type List a = Cons a (List a) | Nil

# Create a list: 1 → 2 → 3 → Nil
let xs = Cons 1 (Cons 2 (Cons 3 Nil))
```

### Record Types

Records are named groups of fields:

```
type Person = { name: String, age: Int, email: String }

let alice = Person { name = "Alice", age = 30, email = "alice@example.com" }

# Access fields with dot notation
alice.name    # => "Alice"
alice.age     # => 30
```

### Working with Records

```
# Use field access (record pattern matching not yet supported)
fn greet person =
  "Hello " ++ person.name ++ ", you are " ++ intToString person.age
```

### Error Handling with Result

`Result` is Kō's way of handling errors without exceptions:

```
type Result a b = Ok a | Err b

# A function that might fail
fn divide a b =
  if b == 0 then Err "division by zero"
  else Ok (a / b)

# Handle with match
match divide 10 2
  | Ok v => println v      # 5
  | Err e => println e
```

#### The ? Operator (Try)

The `?` operator unwraps an `Ok` value, or returns early from the enclosing function with the `Err`:

```
fn safe_divides x y z =
  let a = divide x y?    # if Err, return immediately
  let b = divide a z?    # if Err, return immediately
  Ok (a + b)

# safe_divides 10 2 5 => Ok 7
# safe_divides 10 0 5 => Err "division by zero"
```

This eliminates nested match chains. Each `?` is an early return on error.

#### Result Operations (built-in, no import needed)

```
Result.map f r         # apply f to Ok value, pass through Err
Result.unwrap default r # get Ok value, or use default on Err
Result.fold ok_fn err_fn r # handle both cases with functions
Result.and_then f r    # chain operations that return Result
Result.is_ok r         # True if Ok
Result.is_err r        # True if Err
```

#### Combining ? with match

```
fn process_input input =
  let parsed = parse_int input?
  let doubled = parsed * 2
  Ok doubled

match process_input "42"
  | Ok v => println v     # 84
  | Err e => println e
```

---

## Part 6: Lists

Lists are Kō's bread and butter. They're built with `Cons` (add to front) and `Nil` (empty):

```
type List a = Cons a (List a) | Nil

let empty = Nil
let one = Cons 1 Nil
let three = Cons 1 (Cons 2 (Cons 3 Nil))
```

### The `::` Operator

`::` is syntactic sugar for `Cons`:

```
let three = 1 :: 2 :: 3 :: Nil
```

Read right-to-left: start with `Nil`, add `3`, add `2`, add `1`.

### List Operations

```
# Length
fn length xs =
  match xs
    | Nil => 0
    | Cons _ rest => 1 + length rest

# Map
fn map_list f xs =
  match xs
    | Nil => Nil
    | Cons x rest => Cons (f x) (map_list f rest)

# Filter
fn filter_list p xs =
  match xs
    | Nil => Nil
    | Cons x rest =>
      if p x then Cons x (filter_list p rest)
      else filter_list p rest

# Sum
fn sum xs =
  match xs
    | Nil => 0
    | Cons x rest => x + sum rest
```

### Using List Operations

```
let numbers = 1 :: 2 :: 3 :: 4 :: 5 :: Nil

sum numbers                    # => 15
map_list (\x -> x * 2) numbers # => 2 :: 4 :: 6 :: 8 :: 10 :: Nil
filter_list (\x -> x > 3) numbers # => 4 :: 5 :: Nil
```

---

## Part 7: Pattern Matching Deep Dive

Pattern matching is Kō's most powerful feature. It's not just for ADTs.

### Matching Literals

```
fn describe n =
  match n
    | 0 => "zero"
    | 1 => "one"
    | _ => "something else"    # _ is the wildcard
```

### Matching Tuples

```
fn swap pair =
  match pair
    | (a, b) => (b, a)

swap (1, "hello")  # => ("hello", 1)
```

### Matching Nested Structures

```
type Tree a = Node (Tree a) a (Tree a) | Leaf

fn tree_sum tree =
  match tree
    | Leaf => 0
    | Node left val right => tree_sum left + val + tree_sum right
```

### Conditional Logic in Match

Use `if` in the match arm body for conditions:

```
fn classify x =
  match x
    | n =>
      if n < 0 then "negative"
      else if n == 0 then "zero"
      else if n > 0 and n < 10 then "small positive"
      else "large positive"
```

### Exhaustiveness

The compiler **forces** you to handle every case:

```
# This WON'T compile (missing Nil case):
fn length xs =
  match xs
    | Cons _ rest => 1 + length rest
# Error: non-exhaustive pattern match
```

---

## Part 8: Closures and Lexical Scope

A **closure** is a function that "closes over" variables from its surrounding scope:

```
fn make_counter =
  let count = ref 0       # ref creates a mutable reference
  let increment = \_ ->
    count := !count + 1    # ! deref, := assign
    !count
  increment

let counter = make_counter
counter ()    # => 1
counter ()    # => 2
counter ()    # => 3
```

### Why Closures Matter

They let you create **functions with memory**:

```
fn make_multiplier n =
  \x -> x * n

let triple = make_multiplier 3
let double = make_multiplier 2

triple 5    # => 15
double 5    # => 10
```

The `n` is captured from the surrounding scope and remembered.

---

## Part 9: References and Mutation

Kō is functional by default, but allows controlled mutation through **references**:

```
# Create a reference
let x = ref 0

# Read (dereference)
!x          # => 0

# Write (assign)
x := 5
!x          # => 5
```

### When to Use Refs

- **Counters and accumulators** in loops
- **Shared state** that multiple functions need to modify
- **Performance** — avoid copying large data structures

### When NOT to Use Refs

- Default to immutable values
- Only use refs when mutation is clearly simpler
- Never use refs inside pure functions (unless that's the point)

---

## Part 10: Putting It All Together

Here's a complete program that demonstrates the key concepts:

```
# A simple contact book

type Contact = { name: String, phone: String, email: String }

type ContactBook = Cons Contact (ContactBook) | Nil

type MaybeContact = Just Contact | Nothing

fn add_contact book contact =
  Cons contact book

fn find_by_name book target =
  match book
    | Nil => Nothing
    | Cons c rest =>
      if c.name == target then Just c
      else find_by_name rest target

fn show_contacts book =
  match book
    | Nil => ()
    | Cons c rest =>
      println (c.name ++ ": " ++ c.phone)
      show_contacts rest

fn main =
  let book = Nil
    |> add_contact { name = "Alice", phone = "555-0101", email = "alice@example.com" }
    |> add_contact { name = "Bob", phone = "555-0102", email = "bob@example.com" }
    |> add_contact { name = "Charlie", phone = "555-0103", email = "charlie@example.com" }

  show_contacts book

  match find_by_name book "Bob"
    | Just c => println ("Found: " ++ c.email)
    | Nothing => println "Not found"
```

### Key Patterns Used

1. **Type definitions** to model the domain
2. **Pattern matching** for control flow
3. **Recursion** instead of loops
4. **Pipelines** for readable data transformations
5. **Higher-order functions** for composition

---

## Part 11: Mental Models

### Think in Transformations

Don't think "do this, then do that." Think "this data becomes that data."

```
# Imperative mindset (don't do this in Kō):
let result = []
for x in list:
  if x > 0:
    result.append(x * 2)

# Functional mindset (do this):
let result = list |> filter (\x -> x > 0) |> map (\x -> x * 2)
```

### Think in Types

Before writing functions, define your types:

```
# What are we working with?
type Order = { items: (List Item), customer: Customer, total: Float }
type Item = { name: String, price: Float, quantity: Int }

# What do we need to do with it?
fn calculate_total order = ...
fn add_tax order rate = ...
fn format_receipt order = ...
```

### Think in Composition

Build complex behavior from small, focused functions:

```
# One function, one job
fn is_even n = n % 2 == 0
fn square n = n * n
fn negate n = 0 - n

# Compose them for complex behavior
let result = numbers |> filter is_even |> map square |> map negate
```

---

## Part 12: Common Pitfalls

### 1. Forgetting That `if` Is an Expression

```
# Wrong (no return value):
if x > 0 then println "positive"

# Right (returns a value):
let msg = if x > 0 then "positive" else "non-positive"
println msg
```

### 2. Trying to Mutate Values

```
# Wrong (values can't be reassigned):
let x = 5
x = 10     # Error!

# Right (use ref for mutation):
let x = ref 5
x := 10
```

### 3. Forgetting Parentheses in Complex Expressions

```
# Wrong (parser sees this as two arguments):
add (1 + 2) (3 * 4)

# Right (explicit grouping):
(add (1 + 2)) (3 * 4)
```

### 4. Using `==` for Equality vs `:=` for Assignment

```
x == 5     # Equality check
x := 5     # Assignment (to a ref)
```

### 5. Not Handling All Cases

```
# Wrong (incomplete):
fn safe_divide a b =
  a / b     # Crashes if b is 0!

# Right (handle edge cases):
fn safe_divide a b =
  if b == 0 then 0
  else a / b
```

---

## Quick Reference

| Syntax | Meaning |
|--------|---------|
| `fn name params = body` | Define a function |
| `\x -> body` | Lambda (anonymous function) |
| `let x = value` | Bind a value |
| `if cond then a else b` | Conditional expression |
| `match x \| pat => expr` | Pattern matching |
| `type T = A \| B` | Sum type definition |
| `type T = { field: Type }` | Record type definition |
| `ref x` | Create a mutable reference |
| `!x` | Dereference (read) |
| `x := v` | Assign (write) |
| `a \|> f` | Pipe: `f a` |
| `# comment` | Comment |
| `::` | Cons operator (prepend to list) |
| `++` | String concatenation |

---

## Next Steps

1. **Write a list processing program** — implement map, filter, fold from scratch
2. **Build a simple calculator** — use pattern matching for operations
3. **Create a tree data structure** — practice recursive types and traversal
4. **Use the REPL** — experiment with expressions interactively
5. **Read the examples** — `examples/` directory has working programs

The best way to learn functional programming is to **write code**. Start small, experiment in the REPL, and build up to larger programs.
