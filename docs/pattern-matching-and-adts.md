# Pattern Matching & ADTs

How to define your own types and branch on them.

---

## What Are ADTs?

ADT = Algebraic Data Type. It's a type that says "I could be THIS or THAT."

```kō
type Maybe a = Just a | Nothing
```

This says: "A Maybe is either a Just (holding one value) or Nothing (holding nothing)."

**Real-world analogy:** A light switch is either ON or OFF. It can't be both. That's an ADT.

---

## Defining ADTs

```kō
# No values (like an enum)
type Color = Red | Green | Blue

# One value
type Maybe a = Just a | Nothing

# Two values
type Pair a b = Pair a b

# Many constructors
type Shape = Circle Float | Rect Float Float | Triangle Float Float Float

# Recursive types
type List a = Cons a (List a) | Nil

# Multiple type parameters
type Result a b = Ok a | Err b
```

The type parameters (like `a`, `b`) go after the type name, before `=`. Each constructor lists the types of its data.

---

## Using ADTs with Pattern Matching

```kō
type Maybe a = Just a | Nothing

fn describe mx =
  match mx
    | Just x => "Got: " + to_string x
    | Nothing => "Nothing"
```

**What happens:**
1. `describe (Just 42)` → matches `Just x`, so `x = 42` → "Got: 42"
2. `describe Nothing` → matches `Nothing` → "Nothing"

---

## Pattern Matching Is Destructuring

```kō
type List a = Cons a (List a) | Nil

fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0
```

When you write `Cons x rest`, you're saying:
- If it's a Cons, give me the head (`x`) and the tail (`rest`)
- Use them in the body

**Visual:**

```
sum (Cons 1 (Cons 2 (Cons 3 Nil)))

match Cons 1 (Cons 2 (Cons 3 Nil))
  | Cons x rest => x=1, rest=Cons 2 (Cons 3 Nil)
  → 1 + sum (Cons 2 (Cons 3 Nil))
  
  match Cons 2 (Cons 3 Nil)
    | Cons x rest => x=2, rest=Cons 3 Nil
    → 2 + sum (Cons 3 Nil)
    
    match Cons 3 Nil
      | Cons x rest => x=3, rest=Nil
      → 3 + sum Nil
      
      match Nil
        | Nil => 0
      
    → 3 + 0 = 3
  → 2 + 3 = 5
→ 1 + 5 = 6
```

---

## Match Arms

Each match arm starts with `|` and uses `=>` to separate the pattern from the body:

```kō
match x
  | Pattern1 => body1
  | Pattern2 => body2
  | Pattern3 => body3
```

The `|` prefix makes it clear where each arm begins, even across multiple lines.

---

## Wildcards

Use `_` to match anything you don't care about:

```kō
fn is_just mx =
  match mx
    | Just _ => True    # we don't need the value
    | Nothing => False
```

---

## Nested Patterns

Match deep inside structures using nested match:

```kō
type Nested = Nest Nested | Leaf

fn get_depth tree =
  match tree
    | Nest inner =>
      match inner
        | Nest _ => 2
        | Leaf => 1
    | Leaf => 0
```

---

## Exhaustiveness Checking

The compiler checks that you handle ALL cases:

```kō
type Color = Red | Green | Blue

fn is_red c =
  match c
    | Red => True
    # ERROR: What about Green and Blue?
```

Fix it by adding all cases:

```kō
fn is_red c =
  match c
    | Red => True
    | Green => False
    | Blue => False
```

Or use a wildcard:

```kō
fn is_red c =
  match c
    | Red => True
    | _ => False
```

---

## Records

Records are named field types. They complement ADTs.

```kō
type Point = { x: Int, y: Int }
type Person = { name: String, age: Int }

# Create
let pt = Point { x = 3, y = 4 }

# Access fields
let x_val = pt.x
let y_val = pt.y

# Access record fields
fn distance pt =
  sqrt (pt.x * pt.x + pt.y * pt.y)
```

**Records vs ADTs:** Records are for "this has these fields." ADTs are for "this could be one of these variants." Use both together:

```kō
type Shape = Circle Point Float | Rect Point Point
```

---

## Tuples

Tuples group values without names:

```kō
let t = (1, 2, 3)
let pair = (1, "hello")

# Match on tuples
fn first pair =
  match pair
    | (a, _) => a
```

---

## Common ADT Patterns

### Maybe — "might not have a value"
```kō
type Maybe a = Just a | Nothing

fn safe_divide a b =
  if b == 0 then Nothing
  else Just (a / b)
```

### Result — "might fail"
```kō
type Result a b = Ok a | Err b

fn parse_int s =
  # ... parsing logic ...
  if valid then Ok (to_int s)
  else Err "not a number"
```

### Either — "one of two types"
```kō
type Either a b = Left a | Right b

fn process input =
  match input
    | Left err => "Error: " + err
    | Right value => "Got: " + to_string value
```

---

## ADTs + Pattern Matching = Powerful

```kō
type Expr = 
  | Add Expr Expr
  | Mul Expr Expr
  | Lit Int
  | Var String

fn eval env expr =
  match expr
    | Add a b => (eval env a) + (eval env b)
    | Mul a b => (eval env a) * (eval env b)
    | Lit n => n
    | Var name => lookup env name
```

You just built a simple interpreter! Pattern matching makes it easy to handle each case.

---

## Quick Reference

| Pattern | Matches | Binds |
|---------|---------|-------|
| `Just x` | Just with value | `x` = the value |
| `Nothing` | Nothing | nothing |
| `_` | anything | nothing |
| `Cons x xs` | Cons with head/tail | `x` = head, `xs` = tail |
| `42` | literal 42 | nothing |
| `"hello"` | literal string | nothing |
| `(a, b)` | tuple | `a`, `b` = elements |
| `Point { x, y }` | record (not yet supported) | use field access instead |

**Rules:**
- Uppercase = constructor pattern (destructure)
- Lowercase = variable binding (capture)
- `_` = wildcard (match anything, bind nothing)
- `|` prefix starts each match arm
- `=>` separates pattern from body
