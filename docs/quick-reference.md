# Kō Quick Reference

Everything in one page.

---

## Basic Syntax

```kō
// Comments
# Hash comments
// Double-slash comments
/* Block comments */

// Function definition
fn add a b = a + b

// Let binding (immutable)
let x = 42
let name = "hello"

// Lambda
let double = \x -> x * 2

// If expression
if x > 0 then "positive" else "negative"

// Multi-line block
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)
```

---

## Types

```kō
// Built-in types
Int         // 42, 0xFF, 0b1010
Float       // 3.14
Bool        // true, false
String      // "hello"
Char        // 'c'
Unit        // () — like void

// Custom types (ADTs)
type Maybe = Just * | Nothing
type List = Cons * * | Nil
type Result = Ok * | Err *
```

---

## Pattern Matching

```kō
// Basic match
match x
  Just value -> value
  Nothing -> 0

// With conditions
match x
  Cons h t when h > 0 -> h
  _ -> 0

// Nested patterns
match xs
  Cons (Cons x _) _ -> x
  _ -> 0
```

---

## Operators

```kō
// Arithmetic
+  -  *  /  %

// Comparison
==  !=  <  >  <=  >=

// Logical
&&  ||  !

// String
concat a b    // "hello" ++ " world"
len s         // length
```

---

## Standard Library

```kō
// I/O
print x           // no newline
println x         // with newline
inspect x         // detailed debug info
panic msg         // exit with error

// Strings
len s             // length
concat a b        // concatenate
char_at s i       // character at index
substring s a b   // extract substring
contains s sub    // check if contains
to_upper s        // uppercase
to_lower s        // lowercase
trim s            // strip whitespace
to_string x       // convert to string

// Math
abs n             // absolute value
min a b           // smaller
max a b           // larger
pow a b           // a^b
sqrt n            // square root
floor n           // round down
ceil n            // round up
mod a b           // modulo

// Conversion
to_int x          // convert to int
to_float x        // convert to float

// Type checking
type_of x         // returns type name as string
is_int x          // true if int
is_float x        // true if float
is_string x       // true if string
is_bool x         // true if bool

// Testing
assert cond       // assert condition
assert_eq a b     // assert equality
test name body    // define test
run_tests         // run all tests
```

---

## Ref Cells (Mutable References)

```kō
let r = ref 0       // create
println !r           // dereference: 0
r := 42              // mutate
println !r           // 42
```

---

## Compile-Time Evaluation

```kō
let x = comptime (2 + 3)           // x = 5
let y = comptime (10 * 5)          // y = 50
let z = comptime (if true then 1 else 0)  // z = 1
```

---

## Imports

```kō
import math           // import math.ko
import "path/file"    // relative path import
import list as L      // with alias (not yet)
```

---

## Complete Example

```kō
type List = Cons * * | Nil
type Maybe = Just * | Nothing

fn sum xs =
  match xs
    Cons x rest -> x + sum rest
    Nil -> 0

fn map f xs =
  match xs
    Cons x rest -> Cons (f x) (map f rest)
    Nil -> Nil

fn filter f xs =
  match xs
    Cons x rest ->
      if f x then Cons x (filter f rest)
      else filter f rest
    Nil -> Nil

fn main =
  let nums = Cons 1 (Cons 2 (Cons 3 (Cons 4 (Cons 5 Nil))))
  let evens = filter (\x -> x % 2 == 0) nums
  let doubled = map (\x -> x * 2) evens
  let total = sum doubled
  
  println "Total of doubled evens:"
  println total
  // Output: 12 (2+4 from [2,4])
```
