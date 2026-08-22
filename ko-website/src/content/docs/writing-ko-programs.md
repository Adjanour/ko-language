---
title: "Writing Kō Programs"
---
# Writing Kō Programs

A practical guide to writing ko programs that actually compile and run.
This covers the constraints and gotchas that aren't obvious from the
syntax guides.

---

## Every program needs `fn main`

Kō compiles to native code via LLVM. The entry point is `fn main`:

```ko
fn main =
  println "Hello, world!"
```

Run it:

```
$ ko hello.ko
Hello, world!
```

There is no `ko --run` flag — just `ko file.ko`.

---

## Top-level `let` bindings don't work (yet)

In ko v0.3.x, top-level `let` bindings are not codegen'd. If you reference
a top-level `let` from `fn main`, you'll get `UndefinedVariable` at runtime:

```ko
# THIS DOES NOT WORK:
let greeting = "Hello"

fn main =
  println greeting   # UndefinedVariable
```

**Workaround:** put everything inside `fn main`, or define only `fn`s at
top level (functions are codegen'd correctly):

```ko
# THIS WORKS:
fn greet name = "Hello, " + name

fn main =
  println (greet "Alice")
```

---

## Multi-line values don't parse

Kō's parser requires values to be on the same line as the `=` sign.
Indented blocks after `let` don't work:

```ko
# THIS DOES NOT PARSE:
let x =
  if 1 > 0 then 1
  else 2
```

**Workaround:** keep the value inline:

```ko
let x = if 1 > 0 then 1 else 2
```

For long expressions, break at function boundaries, not at the `let`:

```ko
fn main =
  let nums = Cons 1 (Cons 2 (Cons 3 Nil))
  let doubled = map (\x -> x * 2) nums
  inspect doubled   # [2, 4, 6]
```

---

## Imports

Kō resolves imports from two places:

1. **Standard library** (`std/`): `import std.List`, `import std.String`
2. **Local modules** (same directory): `import math`, `import utils`

Import syntax:

```ko
import std.List            # full import: List.length, List.map, ...
import std.List.{map, filter}  # selective: map, filter in scope
import std.Int as I        # aliased: I.abs, I.min, ...
```

**Note:** module names are case-sensitive. `import List` (without `std.`)
looks for `List.ko` in the source directory — it won't find the stdlib.

---

## The pipe operator `|>`

Pipe passes the left side as the **first** argument:

```ko
5 |> Int.toString         # Int.toString 5  =  "5"
"hello" |> String.length  # String.length "hello"  =  5
```

A chained pipe:

```ko
5 |> Int.toString |> String.append "n="  # String.append (Int.toString 5) "n="  =  "5n="
```

**Common mistake:** assuming pipe passes as the last argument. It's the first:

```ko
10 |> sub 3  # sub 10 3  =  7  (NOT sub 3 10 = -7)
```

Multi-line pipes work (since Stage 6.3):

```ko
fn main =
  IO.readLine "> "
  |> IO.eprintln
```

---

## If/then/else

`else` is optional:

```ko
if 1 > 0 then 1         # works: returns 1
if 1 > 0 then 1 else 2  # works: returns 1
```

Both branches must return the same type:

```ko
# THIS DOES NOT COMPILE (unit vs int):
if 1 > 0 then 1 else println "no"
```

---

## Pattern matching

Match arms use `|` prefix and `=>`:

```ko
type Maybe a = Just a | Nothing

fn describe m =
  match m
    | Just x => "Got: " + Int.toString x
    | Nothing => "Nothing"
```

**Gotcha:** nested literal patterns inside constructors don't match:

```ko
match Just 0
  | Just 0 => "zero"      # DOES NOT MATCH -- 0 binds as a pattern variable
  | Just _ => "has value"  # this catches Just 0 too
  | Nothing => "empty"
```

This compiles but prints `"has value"`, not `"zero"`.

---

## ADTs and types

Types are defined inline (multi-line with leading `|` doesn't parse):

```ko
# CORRECT:
type Token = Identifier String | Number String | Plus | Minus | Star

# DOES NOT PARSE:
# type Token =
#   | Identifier String
#   | Number String
```

Records use `RecordName { field = value }` syntax:

```ko
type Person = Person { name : String, age : Int }

fn main =
  let p = Person { name = "Alice", age = 30 }
  println p.name    # Alice
```

---

## Linearity warnings

Kō checks that linear variables are used exactly once. The checker is
conservative — you'll see warnings in many working programs:

```ko
fn sum xs =
  match xs             # xs consumed here
    | Cons h t => h + sum t   # AND here -> warning
    | Nil => 0
```

This is a warning, not an error. The program runs correctly. Use
`--skip-linearity` to silence warnings during experimentation, or
prefix unused variable names with `_`:

```ko
fn first xs =
  match xs
    | Cons h _ => h    # _ suppresses warning for unused tail
    | Nil => 0
```

See [linearity-and-ownership.md](linearity-and-ownership.md) for details.

---

## The `?` operator

The `?` (try) operator unwraps `Result` values, returning early on `Err`.
It requires parentheses around the expression:

```ko
fn main =
  let input = "42"
  let n = (String.toInt input)?   # parens required
  println n
```

**Caveat:** `?` is unreliable in v0.3.x — it sometimes falls back to
legacy codegen and produces `UndefinedVariable`. Use `match` instead
for production code:

```ko
fn main =
  let input = "42"
  match String.toInt input
    | Just n => println n
    | Nothing => println "not a number"
```

---

## Running your program

```
$ ko myfile.ko              # compile and run
$ ko --dump-ir myfile.ko    # print LLVM IR to stdout
$ ko --emit-ir out.ll myfile.ko   # write IR to file
$ ko --emit-exe myfile.ko   # compile to native executable
$ ko --check myfile.ko      # parse and check without running
$ ko --repl                 # start interactive REPL
```

There is no separate compile step — `ko file.ko` compiles and runs in one shot.
The `zig build` step is only needed when developing the compiler itself.
