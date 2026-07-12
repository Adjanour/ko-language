# Kō Language Guide for AI Assistants

This file helps AI coding assistants write correct Kō code. Copy this into your project root as `CLAUDE.md` or `.cursorrules` or `.github/copilot-instructions.md`.

## What is Kō?

Kō (光 — "light") is a minimal functional language. No parentheses for function calls, indentation-based blocks, ADTs, pattern matching, HM type inference, compiles to native code via LLVM.

## Syntax rules

1. **No parens for calls:** `add 1 2` not `add(1, 2)`
2. **Indentation = blocks:** spaces, not tabs
3. **`fn` for functions:** `fn name param1 param2 = body`
4. **`let` for bindings:** `let x = expr`
5. **`match` for pattern matching:** `match expr | Pattern => result`
6. **Constructors are uppercase:** `Cons`, `Nil`, `Ok`, `Err`
7. **`|` separates match arms** (not `case`, not `->`)
8. **`++` for string concat**
9. **`::` for list prepend** (cons)
10. **`ref` for mutation:** `let x = ref 0` then `x := !x + 1`
11. **`comptime` for compile-time eval**
12. **`~name:value` for named args**
13. **`?` postfix try operator** (propagates Err)
14. **`#` for comments**

## Quick reference

```ko
# Function
fn add a b = a + b

# Lambda
let f = \x -> x * 2

# Let
let x = 42

# If-else
let abs x = if x < 0 then 0 - x else x

# Match
match xs
  | Cons x rest => x + sum rest
  | Nil => 0

# Type
type Maybe a = Just a | Nothing

# Record
type Point = { x : Int, y : Int }

# Ref
let r = ref 0
r := !r + 1

# Comptime
comptime fn fib n = if n <= 1 then n else fib (n-1) + fib (n-2)

# Import
import std.Math.{abs}

# Named args
fn greet ~name = println name
greet ~name:"Kō"
```

## Gotchas

- `match` arms use `|` then pattern then `=>` then result
- Multi-line `if` needs `else` on same line or indented
- `main` must return an int (end with `0`)
- `println` is polymorphic — prints any type
- No null — use `Maybe` or `Result`
- No exceptions — use `Result` with `?` operator
- String concat is `++` not `+`
- `True`/`False` are constructors, not keywords

## Built-in functions

```
println x, print x, inspect x
Int.toString, Int.abs, Int.pow, Int.isqrt
Float.ofInt, Float.sqrt, Float.floor
String.length, String.append
```

## Running

```bash
ko file.ko              # JIT
ko --emit-exe out file.ko  # AOT
ko --repl                # REPL
```
