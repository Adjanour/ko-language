# Pattern Matching & ADTs

How to define your own types and branch on them.

---

## What Are ADTs?

ADT = Algebraic Data Type. It's a type that says "I could be THIS or THAT."

```kō
type Maybe = Just * | Nothing
```

This says: "A Maybe is either a Just (holding one value) or Nothing (holding nothing)."

**Real-world analogy:** A light switch is either ON or OFF. It can't be both. That's an ADT.

---

## Defining ADTs

```kō
// No values (like an enum)
type Color = Red | Green | Blue

// One value
type Maybe = Just * | Nothing

// Two values
type Pair = Pair * *

// Many constructors
type Shape = Circle * | Rectangle * * | Triangle * * *
```

The `*` marks where values go. Count the stars = number of values.

---

## Using ADTs with Pattern Matching

```kō
type Maybe = Just * | Nothing

fn describe mx =
  match mx
    Just x -> "Got: " + to_string x
    Nothing -> "Nothing"
```

**What happens:**
1. `describe (Just 42)` → matches `Just x`, so `x = 42` → "Got: 42"
2. `describe Nothing` → matches `Nothing` → "Nothing"

---

## Pattern Matching Is Destructuring

```kō
type List = Cons * * | Nil

fn sum xs =
  match xs
    Cons x rest -> x + sum rest
    Nil -> 0
```

When you write `Cons x rest`, you're saying:
- If it's a Cons, give me the head (`x`) and the tail (`rest`)
- Use them in the body

**Visual:**

```
sum (Cons 1 (Cons 2 (Cons 3 Nil)))

match Cons 1 (Cons 2 (Cons 3 Nil))
  Cons x rest → x=1, rest=Cons 2 (Cons 3 Nil)
  → 1 + sum (Cons 2 (Cons 3 Nil))
  
  match Cons 2 (Cons 3 Nil)
    Cons x rest → x=2, rest=Cons 3 Nil
    → 2 + sum (Cons 3 Nil)
    
    match Cons 3 Nil
      Cons x rest → x=3, rest=Nil
      → 3 + sum Nil
      
      match Nil
        Nil → 0
      
    → 3 + 0 = 3
  → 2 + 3 = 5
→ 1 + 5 = 6
```

---

## Wildcards

Use `_` to match anything you don't care about:

```kō
fn is_just mx =
  match mx
    Just _ -> true    // we don't need the value
    Nothing -> false
```

---

## Nested Patterns

You can match deep inside structures:

```kō
type Nested = Nest * | Leaf

fn get_depth tree =
  match tree
    Nest (Nest _) -> 2    // two levels deep
    Nest _ -> 1
    Leaf -> 0
```

---

## Exhaustiveness Checking

The compiler checks that you handle ALL cases:

```kō
type Color = Red | Green | Blue

fn is_red c =
  match c
    Red -> true
    // ERROR: What about Green and Blue?
```

Fix it by adding all cases:

```kō
fn is_red c =
  match c
    Red -> true
    Green -> false
    Blue -> false
```

Or use a wildcard:

```kō
fn is_red c =
  match c
    Red -> true
    _ -> false
```

---

## Common ADT Patterns

### Maybe — "might not have a value"
```kō
type Maybe = Just * | Nothing

fn safe_divide a b =
  if b == 0 then Nothing
  else Just (a / b)
```

### Result — "might fail"
```kō
type Result = Ok * | Err *

fn parse_int s =
  // ... parsing logic ...
  if valid then Ok (to_int s)
  else Err "not a number"
```

### Either — "one of two types"
```kō
type Either = Left * | Right *

fn process input =
  match input
    Left err -> "Error: " + err
    Right value -> "Got: " + to_string value
```

---

## ADTs + Pattern Matching = Powerful

```kō
type Expr = 
  | Add * *
  | Mul * *
  | Lit *
  | Var *

fn eval env expr =
  match expr
    Add a b -> (eval env a) + (eval env b)
    Mul a b -> (eval env a) * (eval env b)
    Lit n -> n
    Var name -> lookup env name
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

**Rule:** Uppercase = constructor pattern (destructure). Lowercase = variable binding (capture).
