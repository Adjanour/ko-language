# Writing Kō Programs

Practical constraints and patterns for writing ko programs that compile and run.

---

## Entry Point

Every ko program needs `fn main`:

```ko
fn main =
    println "Hello, world!"
```

Run it:

```bash
ko hello.ko
```

## Top-Level Bindings

Top-level `let` bindings are not codegen'd. Put values inside `fn main`:

```ko
# Values go inside fn main
fn main =
    let greeting = "Hello"
    println greeting

# Functions can live at top level
fn greet name = "Hello, " + name

fn main =
    println (greet "Alice")
```

## Inline Values

Values must appear on the same line as `=`:

```ko
# Works
let x = if 1 > 0 then 1 else 2

# Does not parse
# let x =
#   if 1 > 0 then 1
#   else 2
```

Break long expressions at function boundaries:

```ko
fn main =
    let nums = Cons 1 (Cons 2 (Cons 3 Nil))
    let doubled = map (\x -> x * 2) nums
    inspect doubled   # [2, 4, 6]
```

## Imports

Standard library imports use the `std.` prefix:

```ko
import std.List
import std.String
import std.Int
```

Selective imports bring names into scope:

```ko
import std.List.{map, filter}
import std.String.{length, append}
```

Aliased imports give a short name:

```ko
import std.Int as I
# I.abs, I.min, I.max, ...
```

Local modules resolve from the source directory:

```ko
import math   # looks for math.ko in the same directory
```

Module names are case-sensitive. `import List` without `std.` looks for a local `List.ko`.

## Pipe Operator

Pipe passes the left side as the first argument:

```ko
5 |> Int.toString         # Int.toString 5  =  "5"
"hello" |> String.length  # String.length "hello"  =  5
```

Chained pipes:

```ko
5 |> Int.toString |> String.append "n="  # "5n="
```

Multi-line pipes:

```ko
fn main =
    IO.readLine "> "
    |> IO.eprintln
```

## If Expressions

`else` is optional:

```ko
if 1 > 0 then 1         # returns 1
if 1 > 0 then 1 else 2  # returns 1
```

Both branches must return the same type.

## Pattern Matching

Match arms use `|` prefix and `=>`:

```ko
type Maybe a = Just a | Nothing

fn describe m =
    match m
        | Just x => "Got: " + Int.toString x
        | Nothing => "Nothing"
```

Nested literal patterns inside constructors bind as pattern variables:

```ko
match Just 0
    | Just 0 => "zero"      # 0 is a pattern variable, not a literal match
    | Just _ => "has value"  # catches Just 0
    | Nothing => "empty"
```

## Types

Sum types are defined inline:

```ko
type Token = Identifier String | Number String | Plus | Minus | Star
```

Records use `RecordName { field = value }`:

```ko
type Person = Person { name : String, age : Int }

fn main =
    let p = Person { name = "Alice", age = 30 }
    println p.name    # Alice
```

Type annotations go on parameters and return type:

```ko
fn add (a : Int) (b : Int) -> Int = a + b
```

## Linearity

Kō checks that linear variables are used exactly once. The checker is
conservative — you'll see warnings in working programs:

```ko
fn sum xs =
    match xs
        | Cons h t => h + sum t   # warning: xs used twice
        | Nil => 0
```

Prefix unused variables with `_` to silence warnings:

```ko
fn first xs =
    match xs
        | Cons h _ => h
        | Nil => 0
```

Use `--skip-linearity` to disable the checker entirely.

See [Linearity and Ownership](linearity-and-ownership) for details.

## Try Operator

The `?` operator unwraps `Result` values:

```ko
fn main =
    let input = "42"
    let n = (String.toInt input)?
    println n
```

Parentheses around the expression are required. Use `match` for production code:

```ko
fn main =
    let input = "42"
    match String.toInt input
        | Just n => println n
        | Nothing => println "not a number"
```

## CLI Commands

```bash
ko myfile.ko                     # compile and run
ko --check myfile.ko             # parse and type-check only
ko --dump-ir myfile.ko           # print LLVM IR to stdout
ko --emit-ir out.ll myfile.ko    # write LLVM IR to file
ko --emit-exe myfile.ko          # compile to native executable
ko --repl                        # interactive REPL
```
