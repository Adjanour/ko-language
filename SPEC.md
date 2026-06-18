# Kō Language Specification (v0.1)

> A minimal functional language with innovative syntax

## Design Philosophy

- Minimal syntax, maximum expressiveness
- No parentheses for function calls
- Pattern matching as core feature
- Compile to C for fast execution

## Syntax Overview

### Literals

```
42          # integer
3.14        # float  
true        # boolean
"hello"     # string
'c'         # char
_            # wildcard
```

### Types (ADTs)

```
type Maybe = Just * | Nothing
type Result = Ok * | Err *
type List = Cons * * | Nil
type Shape = Circle * | Rect * *
```

### Functions

```
# Simple function
fn add a b = a + b

# With body (multi-expression)
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)

# Pattern matching in function
fn head xs =
  match xs
    Cons x _ -> x
    Nil -> panic "empty list"

# Anonymous function / lambda
fn x -> x * 2
```

### Pattern Matching

```
match value
  pattern1 -> result1
  pattern2 -> result2
  _ -> default

# Nested patterns
match xs
  Cons (Cons x _) _ -> x
  Cons x Nil -> x
  Nil -> 0
```

### Let Bindings

```
let x = 42
let double = fn x -> x * 2
let result = add 1 2
```

### Control Flow

```
if condition then expr else expr
```

### Expressions

```
# Arithmetic
a + b, a - b, a * b, a / b, a % b

# Comparison
a == b, a != b, a < b, a > b, a <= b, a >= b

# Logical
a && b, a || b, !a

# Function application (left-to-right)
add 1 2           # == add(1, 2)
map (fn x -> x * 2) xs
```

## Example Programs

### Maybe Map

```
type Maybe = Just * | Nothing

fn map-maybe f mx =
  match mx
    Just x -> Just (f x)
    Nothing -> Nothing
```

### Factorial

```
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)
```

### List Sum

```
type List = Cons * * | Nil

fn sum xs =
  match xs
    Cons x rest -> x + sum rest
    Nil -> 0
```

### Higher-Order Functions

```
fn map f xs =
  match xs
    Cons x rest -> Cons (f x) (map f rest)
    Nil -> Nil

fn filter pred xs =
  match xs
    Cons x rest ->
      if pred x then Cons x (filter pred rest)
      else filter pred rest
    Nil -> Nil
```

## Compilation Target

- C99 output
- ADTs become tagged unions
- Pattern matching becomes switch statements
- Closures via environment passing (for v1: no closures, just functions)
