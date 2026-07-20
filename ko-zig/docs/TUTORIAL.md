# Kō Beginner Tutorial

A hands-on guide to programming in Kō. No prior functional programming experience required.

## 1. Hello World

Create a file called `hello.ko`:

```
fn main =
    println "Hello, World!"
```

Run it:

```bash
ko hello.ko
```

## 2. Numbers and Arithmetic

```
fn main =
    println (1 + 2)       # 3
    println (10 - 3)      # 7
    println (4 * 5)       # 20
    println (15 / 3)      # 5
    println (17 % 5)      # 2
    println (2.5 + 1.5)   # 4.0 (floats)
```

Kō has both integers and floating-point numbers. Arithmetic on two integers returns an integer. If either operand is a float, the result is a float.

## 3. Let Bindings

Use `let` to name values:

```
fn main =
    let x = 10
    let y = 20
    println (x + y)       # 30
```

## 4. Functions

Define functions with `fn`:

```
fn add x y =
    x + y

fn main =
    println (add 3 4)     # 7
```

Functions are called by putting a space between the function name and arguments (no parentheses needed for single arguments).

### Multi-line Functions

```
fn classify n =
    if n > 0 then "positive"
    else if n < 0 then "negative"
    else "zero"

fn main =
    println (classify 5)    # positive
    println (classify -3)   # negative
    println (classify 0)    # zero
```

## 5. Lambdas

Lambdas are anonymous functions with `\`:

```
fn main =
    let double = \x -> x * 2
    println (double 5)     # 10

    let add = \x y -> x + y
    println (add 3 4)      # 7
```

Multi-line lambdas:

```
fn main =
    let f = \x ->
        let y = x + 1
        y * 2
    println (f 5)           # 12
```

## 6. Conditionals

```
fn abs x =
    if x >= 0 then x else -x

fn main =
    println (abs (-5))     # 5
    println (abs 3)        # 3
```

## 7. Pattern Matching

Use `match` to destructure data:

```
type Bool = True | False

fn not b =
    match b
        True => False
        False => True

fn main =
    println (not True)     # False
    println (not False)    # True
```

### Matching on Numbers

```
fn describe n =
    match n
        0 => "zero"
        1 => "one"
        _ => "something else"

fn main =
    println (describe 0)   # zero
    println (describe 1)   # one
    println (describe 42)  # something else
```

The `_` is a wildcard that matches anything.

## 8. Algebraic Data Types

Define custom types with `type`:

```
type Shape =
    Circle Float
    Rectangle Float Float

fn area shape =
    match shape
        Circle r => 3.14 * r * r
        Rectangle w h => w * h

fn main =
    let c = Circle 5.0
    println (area c)       # 78.5
    let r = Rectangle 3.0 4.0
    println (area r)       # 12.0
```

## 9. Lists

Kō has linked lists with `Cons` and `Nil`:

```
type List a = Cons a (List a) | Nil

fn length lst =
    match lst
        Cons _ rest => 1 + length rest
        Nil => 0

fn main =
    let xs = Cons 1 (Cons 2 (Cons 3 Nil))
    println (length xs)    # 3
```

The `::` operator builds lists:

```
fn main =
    let xs = 1 :: 2 :: 3 :: Nil
    println (length xs)    # 3
```

### Common List Operations

```
fn map f lst =
    match lst
        Cons x rest => Cons (f x) (map f rest)
        Nil => Nil

fn filter pred lst =
    match lst
        Cons x rest =>
            if pred x then Cons x (filter pred rest)
            else filter pred rest
        Nil => Nil

fn sum lst =
    match lst
        Cons x rest => x + sum rest
        Nil => 0

fn main =
    let xs = 1 :: 2 :: 3 :: 4 :: Nil
    let doubled = map (\x -> x * 2) xs
    inspect doubled        # [2, 4, 6, 8]
    let evens = filter (\x -> x % 2 == 0) xs
    inspect evens          # [2, 4]
    println (sum xs)       # 10
```

## 10. Tuples

Group values with parentheses and commas:

```
fn main =
    let point = (3, 4)
    let (x, y) = point
    println (x + y)        # 7
```

## 11. Records

Named fields with braces:

```
fn main =
    let person = { name = "Alice", age = 30 }
    println person.name    # Alice
    println person.age     # 30
```

## 12. References

Use `ref` to create mutable references and `!` to dereference:

```
fn main =
    let x = ref 10
    println (!x)           # 10
    x := 20
    println (!x)           # 20
```

## 13. String Operations

```
fn main =
    println (String.length "hello")           # 5
    println (String.append "hello" " world")  # hello world
    println (String.toUpperCase "hello")      # HELLO
    println (String.toLowerCase "HELLO")      # hello
    println (String.trim "  hello  ")         # hello
    println (String.contains "hello" "ell")   # True
    println (String.replace "hello" "l" "r")  # herro

    let parts = String.split "a,b,c" ","
    inspect parts                             # [a, b, c]
```

## 14. The Pipe Operator

Chain operations with `|>`:

```
fn main =
    let result = 5
        |> \x -> x * 2
        |> \x -> x + 1
    println result          # 11
```

## 15. Imports

Import from files:

```
import std.math

fn main =
    println (math.abs (-5))   # 5
```

## Putting It All Together

Here's a complete program that counts words in a sentence:

```
type List a = Cons a (List a) | Nil

fn length lst =
    match lst
        Cons _ rest => 1 + length rest
        Nil => 0

fn main =
    let sentence = "the quick brown fox jumps over the lazy dog"
    let words = String.split sentence " "
    println (length words)   # 9
```

## Next Steps

- Read the [Language Reference](LANGUAGE_REFERENCE.md) for complete syntax details
- See the [Syntax Cheat Sheet](SYNTAX_CHEAT_SHEET.md) for quick reference
- Browse the `examples/` directory for more programs
