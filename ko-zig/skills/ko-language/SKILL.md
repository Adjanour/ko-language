---
name: ko-language
description: Write Kō (光) programs — a minimal functional language with no parens, ADTs, pattern matching, and LLVM native compilation. Use when asked to "write Kō", "create a .ko file", "help with Kō code", "Kō syntax", or "functional programming in Kō".
license: MIT
metadata:
  author: ko-language
  version: "0.2.0"
---

# Kō Language Skill

Write correct, idiomatic Kō code. Kō is a small, eager, functional language that compiles to native code via LLVM.

## Syntax at a glance

```ko
# Comments start with #

# Functions — no parens, no braces, indentation defines body
fn add a b = a + b

# Let bindings
let x = 42
let name = "Kō"

# Lambda
let double = \x -> x * 2

# Named parameters
fn greet ~name ~age = println (name ++ " is " ++ Int.toString age)
greet ~name:"Kō" ~age:1

# If-then-else (must be on one line or indented)
let abs x = if x < 0 then 0 - x else x

# Multi-line if
let classify x =
  if x > 0 then "positive"
  else if x < 0 then "negative"
  else "zero"

# Pattern matching
type List a = Cons a (List a) | Nil

fn length xs =
  match xs
    | Cons _ rest => 1 + length rest
    | Nil => 0

# Type definitions
type Maybe a = Just a | Nothing
type Result a b = Ok a | Err b
type Shape = Circle Float | Rect Float Float

# Records
type Point = { x : Int, y : Int }
let pt = Point { x = 3, y = 4 }
println pt.x  # 3

# Refs (explicit mutation)
let counter = ref 0
counter := !counter + 1
println !counter  # 1

# Compile-time evaluation
comptime fn fib n =
  if n <= 1 then n
  else fib (n - 1) + fib (n - 2)

let x = comptime fib 30  # computed at compile time

# Modules
import std.Math.{abs}
import std.List.{map, filter}

# Main function (entry point)
fn main =
  println "Hello, Kō!"
  0
```

## Core patterns

### ADTs + pattern matching (the primary abstraction)

```ko
type Expr =
  Num Int
  | Add Expr Expr
  | Mul Expr Expr

fn eval expr =
  match expr
    | Num n => n
    | Add a b => eval a + eval b
    | Mul a b => eval a * eval b
```

### Recursive data structures

```ko
type Tree a = Branch (Tree a) (Tree a) | Leaf a

fn tree_sum tree =
  match tree
    | Branch l r => tree_sum l + tree_sum r
    | Leaf n => n
```

### Higher-order functions

```ko
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

fn foldl f acc xs =
  match xs
    | Cons x rest => foldl f (f acc x) rest
    | Nil => acc
```

### Error handling with Result

```ko
fn divide a b =
  if b == 0 then Err "division by zero"
  else Ok (a / b)

match divide 10 2
  | Ok result => println result
  | Err msg => println msg
```

### The ? operator (try/propagate)

```ko
fn safe_divide a b = if b == 0 then Err "zero" else Ok (a / b)

fn compute x y =
  let a = safe_divide x y?
  let b = safe_divide a 2?
  Ok (a + b)
```

## Gotchas

1. **No parentheses for function calls.** `add 1 2` not `add(1, 2)`. Exception: grouped expressions `(add 1 2)`.

2. **Indentation matters.** Use spaces (not tabs). Nested blocks need more indentation.

3. **`match` arms use `|` not `case`.** Each arm starts with `|`.

4. **Constructors are uppercase.** `Cons`, `Nil`, `Ok`, `Err`, `Just`, `Nothing`.

5. **`ref` for mutation.** `let x = ref 0` then `x := !x + 1`. `!x` dereferences.

6. **`comptime` functions must also work at runtime.** They're regular functions with an extra optimization.

7. **String concatenation is `++`.** `"Hello " ++ name`.

8. **`println` is polymorphic.** It prints any type correctly.

9. **`main` must return an int.** End with `0` for success.

10. **`::` is cons (list prepend).** `1 :: [2, 3]` gives `[1, 2, 3]`.

## Built-in functions

```
println x          # print value + newline (polymorphic)
print x            # print value (polymorphic)
inspect x          # debug print with type info

Int.toString n     # int to string
Int.abs n          # absolute value
Int.pow base exp   # power
Int.isqrt n        # integer square root

Float.ofInt n      # int to float
Float.sqrt f       # square root
Float.floor f      # floor

String.length s    # string length
String.append a b  # concatenation (same as ++)

True / False       # Bool constructors
```

## File structure

```
my-project/
├── src/
│   └── main.ko     # entry point with fn main
├── lib/
│   └── utils.ko    # helper functions
└── std/            # standard library (imported automatically)
```

## Running code

```bash
ko file.ko              # JIT execute
ko --dump-ir file.ko    # show LLVM IR
ko --emit-obj out.o file.ko   # compile to object file
ko --emit-exe out file.ko     # compile to executable
ko --repl                # interactive REPL
```

## Idioms

```ko
# Pipeline style
let result = xs |> map (\x -> x * 2) |> filter (\x -> x > 10)

# Guard-style matches
fn describe x =
  match x
    | 0 => "zero"
    | n if n > 0 => "positive"
    | _ => "negative"

# Accumulator pattern
fn reverse xs = foldl (\acc x -> Cons x acc) Nil xs

# Composition
let compose = \f g -> \x -> f (g x)
let double_then_inc = compose (\x -> x + 1) (\x -> x * 2)
```
