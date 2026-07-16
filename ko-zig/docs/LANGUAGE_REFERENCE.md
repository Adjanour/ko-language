# Kō Language Reference

A concise reference for the Kō programming language.

---

## Basics

### Comments

```ko
# This is a comment
x = 42  # This is an inline comment
```

### Literals

```ko
42          # Int
0x1A        # Hex Int
0b1010      # Binary Int
0o77        # Octal Int
1_000_000   # Int with underscores
3.14        # Float
'A'         # Char
"hello"     # String
True        # Bool
False       # Bool
()          # Unit
```

### Identifiers

```ko
x           # Simple identifier
my-var      # Hyphenated identifier
map-maybe   # Hyphenated identifier
_x          # Underscore prefix (valid identifier)
```

### Operators

```ko
# Arithmetic
+ - * / %

# Comparison
== != < <= > >=

# Logical
and or not

# Pipe
|>

# Cons (list construction)
::

# String concatenation
++

# Assignment
:=

# Deref (dereference ref)
!expr

# Field access
record.field
```

---

## Functions

### Definition

```ko
fn add x y = x + y

fn greet ~name ~age =
  "Hello, " ++ name ++ "! You are " ++ Int.toString age
```

### Multi-line Body

```ko
fn abs n =
  if n < 0 then -n
  else n
```

### Lambdas

```ko
\x -> x + 1
\x y -> x + y
```

### Partial Application

```ko
fn add x y = x + y

let add5 = add 5
add5 3  # 8
```

### Recursion

```ko
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)

# Mutual recursion works automatically
fn isEven n =
  if n == 0 then True
  else isOdd (n - 1)

fn isOdd n =
  if n == 0 then False
  else isEven (n - 1)
```

---

## Types

### Primitive Types

```ko
Int         # 64-bit integer
Float       # 64-bit float
Bool        # True or False
Char        # Single character
String      # Immutable string
()          # Unit type
```

### Sum Types (ADTs)

```ko
type Option a = Some a | None
type List a = Cons a (List a) | Nil
type Result a b = Ok a | Err b
type Expr = Num Int | Add Expr Expr | Mul Expr Expr
```

### Record Types

```ko
type Point = { x : Int, y : Int }
type Person = { name : String, age : Int }
```

### Tuple Types

```ko
(1, "hello")         # (Int, String)
(1, 2, 3)            # (Int, Int, Int)
```

### Function Types

```ko
Int -> Int             # Function from Int to Int
Int -> Int -> Int      # Curried function
(a -> b) -> List a -> List b  # Higher-order function
```

---

## Pattern Matching

### Basic Match

```ko
match x
  | 0 => "zero"
  | 1 => "one"
  | _ => "other"
```

### Constructor Matching

```ko
match xs
  | Cons x rest => x + sum rest
  | Nil => 0
```

### Nested Patterns

```ko
match xs
  | Cons x (Cons y rest) => x + y
  | Cons x Nil => x
  | Nil => 0
```

### Record Patterns

```ko
match person
  | { name, age } => name ++ " is " ++ Int.toString age
```

### Wildcard Patterns

```ko
match x
  | Cons _ _ => "non-empty list"
  | Nil => "empty list"
```

---

## Control Flow

### If-Then-Else

```ko
if x > 0 then "positive"
else if x < 0 then "negative"
else "zero"
```

### Multi-line If

```ko
if x > 0 then
  let y = x * 2
  y + 1
else
  0
```

### Match as Expression

```ko
let description = match x
  | 0 => "zero"
  | _ => "non-zero"
```

---

## Let Bindings

```ko
let x = 42
let y = x + 1
let (a, b) = (1, 2)           # Tuple destructuring
let { name, age } = person    # Record destructuring
```

### Nested Let

```ko
let x = 1 in
let y = 2 in
x + y
```

---

## References (Mutation)

```ko
let r = ref 0         # Create mutable reference
!r                    # Dereference (read)
r := !r + 1           # Update (write)
```

### Example: Counter

```ko
fn counter () =
  let r = ref 0
  let increment = \ -> r := !r + 1
  let get = \ -> !r
  (increment, get)

let (inc, get) = counter ()
inc ()
inc ()
get ()  # 2
```

---

## Modules and Imports

### Import

```ko
import std.math.{add, mul}
import std.list as L
import std.{String, Int}
```

### Module Declarations

```ko
package std.math

pub fn add x y = x + y
```

### Selective Import

```ko
import std.math.{add}
add 1 2  # 3
```

---

## Built-in Functions

### I/O

```ko
println x        # Print x with newline (polymorphic)
print x          # Print x without newline (polymorphic)
inspect x        # Debug print with type tags
```

### Int Operations

```ko
Int.toString n    # Int -> String
Int.abs n         # Int -> Int
Int.min a b       # Int -> Int -> Int
Int.max a b       # Int -> Int -> Int
Int.pow b e       # Int -> Int -> Int
Int.gcd a b       # Int -> Int -> Int
Int.lcm a b       # Int -> Int -> Int
Int.factorial n   # Int -> Int
Int.isqrt n       # Int -> Int
```

### Float Operations

```ko
Float.ofInt n     # Int -> Float
Float.toInt f     # Float -> Int
Float.sqrt f      # Float -> Float
Float.pow b e     # Float -> Float -> Float
Float.sin f       # Float -> Float
Float.cos f       # Float -> Float
Float.tan f       # Float -> Float
Float.log f       # Float -> Float
Float.log2 f      # Float -> Float
Float.log10 f     # Float -> Float
Float.exp f       # Float -> Float
Float.floor f     # Float -> Float
Float.ceil f      # Float -> Float
Float.abs f       # Float -> Float
```

### String Operations

```ko
String.length s      # String -> Int
String.append a b    # String -> String -> String
```

### Result Operations

```ko
Result.is_ok r       # Result a b -> Bool
Result.is_err r      # Result a b -> Bool
Result.unwrap d r    # a -> Result a b -> a
Result.map f r       # (a -> c) -> Result a b -> Result c b
Result.fold f g r    # (a -> c) -> (b -> c) -> Result a b -> c
Result.and_then f r  # (a -> Result c b) -> Result a b -> Result c b
expr?                # Postfix try operator
```

### Inspect (Debug Print)

```ko
inspect 42           # Int: 42
inspect 3.14         # Float: 3.14
inspect True         # Bool: True
inspect "hello"      # String: hello
inspect [1, 2, 3]    # [1, 2, 3]  (list sugar)
inspect (Cons 1 Nil) # [1]        (list sugar)
inspect Nil          # []         (list sugar)
```

---

## Compile-Time Evaluation

### Comptime Functions

```ko
comptime fn factorial n =
  if n == 0 then 1 else n * factorial (n - 1)

let x = factorial 10  # Evaluated at compile time
```

### Comptime Expressions

```ko
let x = comptime 2 + 3  # Evaluated at compile time
```

---

## Stdlib

### List Operations (import std.list)

```ko
List.head xs           # List a -> a
List.tail xs           # List a -> List a
List.length xs         # List a -> Int
List.append a b        # List a -> List a -> List a
List.reverse xs        # List a -> List a
List.map f xs          # (a -> b) -> List a -> List b
List.filter f xs       # (a -> Bool) -> List a -> List a
List.foldl f z xs      # (b -> a -> b) -> b -> List a -> b
List.foldr f z xs      # (a -> b -> b) -> b -> List a -> b
List.any f xs          # (a -> Bool) -> List a -> Bool
List.all f xs          # (a -> Bool) -> List a -> Bool
List.find f xs         # (a -> Bool) -> List a -> Maybe a
List.take n xs         # Int -> List a -> List a
List.drop n xs         # Int -> List a -> List a
List.elem x xs         # a -> List a -> Bool
List.zip xs ys         # List a -> List b -> List (a, b)
List.concat xss        # List (List a) -> List a
List.sum xs            # List Int -> Int
List.product xs        # List Int -> Int
List.maximum xs        # List Int -> Int
List.minimum xs        # List Int -> Int
List.flat_map f xs     # (a -> List b) -> List a -> List b
List.flatten xss       # List (List a) -> List a
List.take_while f xs   # (a -> Bool) -> List a -> List a
List.drop_while f xs   # (a -> Bool) -> List a -> List a
List.replicate n x     # Int -> a -> List a
List.contains x xs     # a -> List a -> Bool
List.last xs           # List a -> Maybe a
List.init xs           # List a -> List a
List.nth n xs          # Int -> List a -> Maybe a
```

### Math Operations (import std.math)

```ko
Math.abs n             # Int -> Int
Math.max a b           # Int -> Int -> Int
Math.min a b           # Int -> Int -> Int
Math.clamp lo hi x     # Int -> Int -> Int -> Int
Math.div a b           # Int -> Int -> Int
Math.mod a b           # Int -> Int -> Int
Math.gcd a b           # Int -> Int -> Int
Math.lcm a b           # Int -> Int -> Int
Math.factorial n       # Int -> Int
Math.pow b e           # Int -> Int -> Int
Math.isqrt n           # Int -> Int
```

### Int Operations (import std.int)

```ko
Int.even n             # Int -> Bool
Int.odd n              # Int -> Bool
Int.clamp lo hi x      # Int -> Int -> Int -> Int
Int.sign n             # Int -> Int
```

### String Operations (import std.string)

```ko
String.isEmpty s       # String -> Bool
String.repeat n s      # Int -> String -> String
String.replicate n c   # Int -> Char -> String
```

---

## Example Programs

### Hello World

```ko
fn main =
  println "Hello, World!"
```

### Fibonacci

```ko
fn fib n =
  if n <= 1 then n
  else fib (n - 1) + fib (n - 2)

fn main =
  println (fib 10)
```

### Factorial

```ko
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)

fn main =
  println (factorial 10)
```

### List Sum

```ko
type List a = Cons a (List a) | Nil

fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0

fn main =
  let xs = Cons 1 (Cons 2 (Cons 3 Nil))
  println (sum xs)
```

### Map and Filter

```ko
type List a = Cons a (List a) | Nil

fn map f xs =
  match xs
    | Cons x rest => Cons (f x) (map f rest)
    | Nil => Nil

fn filter pred xs =
  match xs
    | Cons x rest =>
      if pred x then Cons x (filter pred rest)
      else filter pred rest
    | Nil => Nil

fn main =
  let xs = Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil)))
  let doubled = map (\x -> x * 2) xs
  let evens = filter (\x -> x % 2 == 0) xs
  inspect doubled
  inspect evens
```

### Pattern Matching

```ko
type Expr = Num Int | Add Expr Expr | Mul Expr Expr

fn eval expr =
  match expr
    | Num n => n
    | Add a b => eval a + eval b
    | Mul a b => eval a * eval b

fn main =
  let expr = Add (Num 1) (Mul (Num 2) (Num 3))
  println (eval expr)
```

---

## Compiler Usage

```ko
ko --run file.ko           # JIT execute
ko file.ko                 # Dump LLVM IR
ko --emit-ir out.ll file.ko    # Write LLVM IR to file
ko --emit-obj out.o file.ko    # Emit object file
ko --emit-exe out file.ko      # Emit linked executable
ko --repl                   # Interactive REPL
ko --version                # Show version
```

---

*Kō (光) means "light" in Japanese.*
