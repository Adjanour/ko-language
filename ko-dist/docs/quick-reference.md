# Kō Quick Reference

Everything in one page.

---

## Basic Syntax

```kō
# Comments
# Hash comments (single line)

# Function definition
fn add a b = a + b

# Let binding (immutable)
let x = 42
let name = "hello"

# Lambda
let double = \x -> x * 2

# If expression
if x > 0 then "positive" else "negative"

# Multi-line block
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)

# Type annotation (param annotation)
fn add a b : Int = a + b
fn add a b = a + b
```

---

## Types

```kō
# Built-in types
Int         # 42, 0xFF, 0b1010
Float       # 3.14
Bool        # True, False
String      # "hello"
Char        # 'c'
Unit        # () — like void

# Sum types (ADTs)
type Maybe a = Just a | Nothing
type List a = Cons a (List a) | Nil
type Result a b = Ok a | Err b
type Color = Red | Green | Blue

# Record types
type Point = { x: Int, y: Int }
type Person = { name: String, age: Int }

# Record literal
let pt = Point { x = 3, y = 4 }

# Field access
println pt.x   # 3
```

---

## Pattern Matching

```kō
# Basic match (arms use | prefix and => separator)
match x
  | Just value => value
  | Nothing => 0

# With if in arm body
match x
  | Cons h t => if h > 0 then h else 0
  | _ => 0

# Nested match (no nested patterns — use nested match)
match xs
  | Cons head rest =>
    match rest
      | Cons x _ => x
      | _ => 0
  | _ => 0

# Tuples
match pair
  | (a, b) => a + b

# Records — use field access (pattern matching not yet supported)
pt.x + pt.y
```

---

## Operators

```kō
# Arithmetic
+  -  *  /  %

# Comparison
==  !=  <  >  <=  >=

# Logical
&&  ||  !        # symbols
and or not        # keyword alternatives

# Pipe
|>                # pass left as last arg to right

# Assignment (ref cells only)
:=                # assign to ref
!                 # dereference ref
ref               # create ref
```

---

## Standard Library

Kō has three kinds of names available to your program:

| Kind | How to use it | Example |
|------|---------------|---------|
| **Built-ins** | No import required | `println`, `Int.pow`, `String.length` |
| **Stdlib modules** | `import std.<Name>` | `import std.List` |
| **Local modules** | `import <Name>` | `import Math` |

### Built-ins

Built-in functions and constructors are always in scope (no import needed):

```kō
# I/O
print x           # no newline, no quotes on strings
println x         # with newline, no quotes on strings
inspect x         # debug format, WITH quotes on strings

# Int operations
Int.toString n    # Int -> String
Int.abs n         # Int -> Int
Int.min a b       # Int -> Int -> Int
Int.max a b       # Int -> Int -> Int
Int.pow base exp  # Int -> Int -> Int
Int.gcd a b       # Int -> Int -> Int
Int.lcm a b       # Int -> Int -> Int
Int.factorial n   # Int -> Int
Int.isqrt n       # Int -> Int (integer square root)

# Float operations
Float.ofInt n     # Int -> Float
Float.toInt f     # Float -> Int
Float.sqrt f      # Float -> Float
Float.pow b e     # Float -> Float -> Float
Float.sin f       # Float -> Float
Float.cos f       # Float -> Float
Float.tan f       # Float -> Float
Float.log f       # Float -> Float (natural log)
Float.log2 f      # Float -> Float
Float.log10 f     # Float -> Float
Float.exp f       # Float -> Float
Float.floor f     # Float -> Float
Float.ceil f      # Float -> Float
Float.abs f       # Float -> Float

# String operations
String.length s   # String -> Int
String.append a b # String -> String -> String

# Bool constructors
True
False
```

### Stdlib modules

Stdlib modules live on disk in `std/` and are imported with the reserved `std.` namespace. The compiler resolves them from `KO_STDLIB_PATH` if set, otherwise from a `std/` directory near the `ko` executable.

```kō
import std.List                 # import whole stdlib module
import std.List.{map, filter}  # selective import
```

Available `std/` modules:

```kō
# List operations (std/List.ko)
type List a = Cons a (List a) | Nil

foldl f acc xs    # left fold
foldr f acc xs    # right fold
head xs           # first element
tail xs           # rest of list
length xs         # count elements
append xs ys      # concatenate lists
reverse xs        # reverse list
map f xs          # apply f to each
filter f xs       # keep elements where f x is True
any f xs          # True if any element satisfies f
all f xs          # True if all elements satisfy f
find f xs         # first element satisfying f
take n xs         # first n elements
drop n xs         # skip first n elements
elem x xs         # True if x is in xs
zip xs ys         # pair elements
concat xss        # flatten list of lists
sum xs            # sum of elements
product xs        # product of elements
maximum xs        # largest element
minimum xs        # smallest element

# Int extras (std/Int.ko)
even n            # n % 2 == 0
odd n             # n % 2 != 0
clamp lo hi x     # clamp to range
sign n            # -1, 0, or 1

# Math operations (std/Math.ko)
abs x             # absolute value
max a b           # maximum of two
min a b           # minimum of two
gcd a b           # greatest common divisor
lcm a b           # least common multiple
factorial n       # n!
pow base exp      # base^exp
isqrt n           # integer square root
sum xs            # sum of list
product xs        # product of list
average xs        # mean of list

# String extras (std/String.ko)
isEmpty s         # True if empty
```

### Local modules

A local module is any `.ko` file in the same directory as the file being compiled. Import it by name without a `std.` prefix:

```kō
import Math                     # import Math.ko from the same directory
import Math.{add, double}        # selective import
import Math as M                # with alias (not yet)
```

---

## Error Handling with Result

```kō
type Result a b = Ok a | Err b

# Create
let good = Ok 42
let bad = Err "something went wrong"

# Pattern match
match good
  | Ok v => println v
  | Err e => println e

# The ? operator (try)
# Unwraps Ok value, or returns early from the enclosing function with Err
fn divide a b =
  if b == 0 then Err "division by zero"
  else Ok (a / b)

fn compute x y z =
  let a = divide x y?
  let b = divide a z?
  Ok b

# compute 10 2 5 => Ok 1
# compute 10 0 5 => Err "division by zero" (early return)
```

### Result Operations (built-in, no import needed)

```kō
Result.map f r         # apply f to Ok value
Result.unwrap default r # get Ok value or default
Result.fold ok_fn err_fn r # reduce to single value
Result.and_then f r    # chain (flatmap)
Result.is_ok r         # True if Ok
Result.is_err r        # True if Err
```

---

## Ref Cells (Mutable References)

```kō
let r = ref 0       # create
println !r           # dereference: 0
r := 42              # mutate
println !r           # 42
```

---

## Tuples

```kō
let t = (1, 2, 3)          # triple
let pair = (1, "hello")    # pair
let a = (1,)               # singleton
```

---

## Records

```kō
type Point = { x: Int, y: Int }

# Create
let pt = Point { x = 3, y = 4 }

# Access
println pt.x   # 3
println pt.y   # 4
```

---

## Compile-Time Evaluation

```kō
let x = comptime (2 + 3)           # x = 5
let y = comptime (10 * 5)          # y = 50
let z = comptime (if True then 1 else 0)  # z = 1
```

---

## Imports

```kō
import std.List                      # stdlib module (reserved std. namespace)
import std.List.{map, filter, foldl} # selective import from stdlib
import Math                          # local module (Math.ko in same directory)
import Math.{add, double}            # selective import from local module
import Math as M                     # with alias (not yet)
```

- `std.<Name>` imports from the Kō standard library (`std/` directory).
- A bare module name imports a `.ko` file from the same directory as the current file.

---

## Pipe Operator

```kō
fn add x y = x + y
fn double x = x * 2

# Pipeline reads top-to-bottom:
5 |> add 1 |> double   # 12
```

---

## CLI

```bash
ko file.ko                # JIT-execute (default)
ko --dump-ir file.ko      # Dump LLVM IR to stdout
ko --emit-ir out.ll file.ko   # Emit LLVM IR to file
ko --emit-obj out.o file.ko   # Emit object file
ko --emit-exe out file.ko     # Link to executable
ko --repl                  # Start REPL
ko-lsp                     # Start LSP server
```

---

## REPL

```bash
ko --repl

# In the REPL:
fn add x y = x + y        # define function
add 3 4                    # evaluate expression
:type add                  # show type
:env                       # show definitions
:reset                     # clear all
:quit                      # exit
```

---

## Complete Example

```kō
type List a = Cons a (List a) | Nil
type Maybe a = Just a | Nothing

fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0

fn map f xs =
  match xs
    | Cons x rest => Cons (f x) (map f rest)
    | Nil => Nil

fn filter f xs =
  match xs
    | Cons x rest =>
      if f x then Cons x (filter f rest)
      else filter f rest
    | Nil => Nil

fn main =
  let nums = Cons 1 (Cons 2 (Cons 3 (Cons 4 (Cons 5 Nil))))
  let evens = filter (\x -> x % 2 == 0) nums
  let doubled = map (\x -> x * 2) evens
  let total = sum doubled
  
  println "Total of doubled evens:"
  println total
  # Output: 12 (2+4 from [2,4])
```
