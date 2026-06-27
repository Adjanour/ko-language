# The Zen of Kō

> **Kō** (光) — "light" in Japanese. The language should be as light as its name.

---

## The Principles

```
No parentheses for function calls.
add 1 2 is cleaner than add(1, 2).
The spec fits on a few pages.
If it doesn't, simplify.
ADTs model the world.
Pattern matching handles it.
Immutability by default.
Mutability when you need it.
Compile to native code.
Run everywhere.
Nothing is better than null.
Maybe is better than nothing.
Nothing is better than exceptions.
Result is better than exceptions.
The language should be small.
The library should be big.
Code is read more than written.
Write for the reader.
The compiler is your friend.
It catches your mistakes.
If the compiler can't help, the language is wrong.
Functions are values.
Values are functions.
Everything returns something.
Even nothing.
```

---

## The Philosophy

### 1. Simplicity is the ultimate sophistication

Kō has no parentheses for function calls. No curly braces for blocks. No semicolons. The grammar fits on a page. The spec fits on a few pages. If you can't explain it simply, you don't understand it well enough.

```kō
# This is Kō
fn add a b = a + b
add 1 2

# This is C
int add(int a, int b) { return a + b; }
add(1, 2);

# This is Haskell
add a b = a + b
add 1 2
```

All three do the same thing. Kō is the lightest.

### 2. ADTs model the world

Everything is a value. Values have types. Types are defined by their constructors.

```kō
type Maybe a = Just a | Nothing
type Result a b = Ok a | Err b
type List a = Cons a (List a) | Nil
type Shape = Circle Int | Rect Int Int
```

No classes. No inheritance. No objects. Just data and the functions that transform it.

### 3. Pattern matching is the way

Don't check types. Don't use if-else chains. Match the shape of your data.

```kō
fn describe shape =
  match shape
    | Circle r => r
    | Rect w h => w + h
```

The compiler checks that you handled every case. If you miss one, it tells you.

### 4. Immutability by default

Once you create a value, it never changes. This makes code easier to reason about, easier to test, and easier to parallelize.

```kō
let x = 42
# x := 100  # Error! Can't reassign let bindings

let y = ref 42  # But you can use a ref cell
y := 100        # This works
!y              # Dereference to get value
```

### 5. Functions are values

Pass them around. Store them in lists. Return them from other functions.

```kō
let double = \x -> x * 2
let inc = \x -> x + 1
let apply = \f x -> f x
apply double 5  # 10
```

### 6. Compile to native code

Kō compiles to LLVM IR, then to native code via LLVM. This means:

- Fast execution (no interpreter overhead)
- JIT execution for development (`ko --run`)
- AOT compilation for production (`ko --emit-exe`)
- Easy to interface with C libraries

### 7. Errors are values

No exceptions. No null. No undefined behavior.

```kō
type Result a b = Ok a | Err b

fn divide a b =
  if b == 0 then Err 0
  else Ok (a / b)

match divide 10 2
  | Ok result => result
  | Err _ => 0
```

### 8. The language is small

Kō has:

- 17 keywords
- 12 operators
- 7 expression types
- 1 type system (ADTs + records)

That's it. You can learn it in an afternoon. You can master it in a week.

### 9. The library is big

The standard library provides:

- String operations
- Math operations
- I/O operations
- Type checking
- Testing

All functions return values. No side effects in expressions.

### 10. Code is for humans

The compiler is smart. The programmer is smarter. Write code that humans can read.

```kō
# Good: clear intent
fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0

# Bad: unclear intent
fn f l =
  match l
    | Cons h t => h + f t
    | Nil => 0
```

---

## The Rules

1. **No parentheses for function calls.** `add 1 2` not `add(1, 2)`.
2. **Indentation defines blocks.** No curly braces.
3. **Newlines separate expressions.** No semicolons.
4. **No null.** Use `Maybe` instead.
5. **No exceptions.** Use `Result` instead.
6. **No classes.** Use ADTs + functions instead.
7. **Everything returns a value.** Even `if` and `match`.
8. **Immutability by default.** Use `ref` for mutation.
9. **Functions are values.** Pass them around.
10. **Compile to native code.** Run fast everywhere.

---

## The Mantras

```
# When in doubt, use a match
match x
  | Just v => handle v
  | Nothing => 0

# When in doubt, use a fold
fold (\acc x -> acc + x) 0 xs

# When in doubt, use a type
type Thing = This Int | That String

# When in doubt, keep it simple
fn f x = x
```

---

## The Promise

Kō promises to be:

- **Small**: learnable in a day
- **Simple**: no magic, no hidden behavior
- **Practical**: compiles to real code
- **Functional**: immutable by default
- **Expressive**: ADTs + pattern matching
- **Fast**: compiles to native code via LLVM

Kō promises NOT to be:

- **Large**: no thousands of keywords
- **Complex**: no monads, no type classes (yet)
- **Slow**: no interpreter overhead
- **Unsafe**: no null, no exceptions
- **Magic**: no hidden allocations, no implicit conversions

---

## The Future

Kō is small today. It will grow. But it will always be:

- Simple before complex
- Explicit before implicit
- Practical before theoretical
- Human before machine

---

*The Zen of Kō is not a set of rules. It's a way of thinking.*
*When you write Kō, think simply. Think clearly. Think beautifully.*
*Then the code will write itself.*
