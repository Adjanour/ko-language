---
title: "---"
---
---
title: "Writing Kō Programs"
---

# Writing Kō Programs

How to write ko programs that compile and run. This covers the patterns
you will use every day and the few things that work differently from
other languages.

---

## Entry Point

Every ko program starts with `fn main`:

```ko
fn main =
    println "Hello, world!"
```

Run it:

```bash
ko hello.ko
```

Kō compiles and runs in one shot. There is no separate compile step.

## Functions

Define functions with `fn`. No parentheses around arguments:

```ko
fn add x y = x + y
fn double x = x * 2
fn greet name = "Hello, " + name + "!"

fn main =
    println (add 3 4)       # 7
    println (double 5)      # 10
    println (greet "Alice")  # Hello, Alice!
```

Call functions by putting a space between the name and arguments. No commas, no parens for simple calls.

## Let Bindings

Use `let` to name values. Values are immutable:

```ko
fn main =
    let x = 10
    let y = x + 5
    println (x + y)       # 15
```

The value must be on the same line as `=`:

```ko
# Works
let x = if 1 > 0 then 1 else 2

# Does not work — keep it inline
```

## If Expressions

`if` returns a value. `else` is optional:

```ko
fn abs x =
    if x >= 0 then x else -x

fn classify n =
    if n > 0 then "positive"
    else if n < 0 then "negative"
    else "zero"

fn main =
    println (abs (-5))     # 5
    println (classify 42)  # positive
```

## Pattern Matching

Use `match` to destructure data:

```ko
type Maybe a = Just a | Nothing

fn from-just default mx =
    match mx
        | Just x => x
        | Nothing => default

fn main =
    println (from-just 0 (Just 42))    # 42
    println (from-just 0 Nothing)      # 0
```

Match arms use `|` prefix and `=>`:

```ko
fn describe b =
    match b
        | True => "yes"
        | False => "no"
```

The wildcard `_` matches anything:

```ko
fn first xs =
    match xs
        | Cons h _ => h
        | Nil => 0
```

## Types

Sum types are compact one-liners:

```ko
type Shape = Circle Float | Rect Float Float
type Token = Id String | Num String | Plus | Minus
```

Records use braces:

```ko
type Person = Person { name : String, age : Int }

fn main =
    let p = Person { name = "Alice", age = 30 }
    println p.name    # Alice
```

Type annotations go on parameters:

```ko
fn add (a : Int) (b : Int) -> Int = a + b
```

## Lists

Define the List type yourself:

```ko
type List a = Cons a (List a) | Nil

fn main =
    let xs = Cons 1 (Cons 2 (Cons 3 Nil))
    let ys = 1 :: 2 :: 3 :: Nil
```

Import list operations from the stdlib:

```ko
import std.List.{map, filter, foldl}

fn main =
    let xs = 1 :: 2 :: 3 :: 4 :: Nil
    let doubled = map (\x -> x * 2) xs
    let evens = filter (\x -> x % 2 == 0) xs
    inspect doubled    # [2, 4, 6, 8]
    inspect evens      # [2, 4]
```

## Pipe Operator

Chain operations with `|>`. The left side becomes the first argument:

```ko
fn main =
    # These are equivalent
    println (Int.toString 5)
    5 |> Int.toString

    # Chained
    5 |> Int.toString |> String.append "n="   # "5n="
```

Multi-line pipes work:

```ko
fn main =
    IO.readLine "> "
    |> IO.eprintln
```

## Lambdas

Anonymous functions with `\`:

```ko
fn main =
    let double = \x -> x * 2
    let add = \x y -> x + y
    println (double 5)    # 10
    println (add 3 4)     # 7
```

## Imports

Standard library:

```ko
import std.List
import std.String
import std.Int
```

Selective imports:

```ko
import std.List.{map, filter}
import std.String.{length, append}
```

Local modules (same directory):

```ko
import math   # looks for math.ko nearby
```

Module names are case-sensitive. `import List` looks for a local file,
not the stdlib. Use `import std.List` for the standard library.

## References

Use `ref` for mutable state:

```ko
fn main =
    let counter = ref 0
    counter := !counter + 1
    println (!counter)     # 1
```

`ref` creates a reference cell. `!` reads it. `:=` writes to it.

## Running Your Program

```bash
ko myfile.ko                     # compile and run
ko --check myfile.ko             # type-check only
ko --dump-ir myfile.ko           # print LLVM IR
ko --emit-ir out.ll myfile.ko    # write IR to file
ko --emit-exe myfile.ko          # compile to executable
ko --repl                        # interactive REPL
```

---

*See also: [Error Messages](error-messages) if something does not compile, and
[Modules and Imports](modules) for details on the module system.*
