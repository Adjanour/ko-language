# Kō Marketing Kit

## Twitter/X Thread

**Tweet 1 (hook):**
I built a programming language in 3 weeks.

No parentheses. No curly braces. No semicolons. Just code.

It's called Kō (光 — "light" in Japanese).

Here's what it looks like 👇

**Tweet 2 (hello world):**
```
fn main = println "Hello, Kō!"
```

That's it. That's the whole program.

No `public static void main(String[] args)`.
No `func main() { fmt.Println("...") }`.
Just `fn main = println "Hello, Kō!"`.

**Tweet 3 (ADTs):**
Algebraic data types in 2 lines:

```
type Result a b = Ok a | Err b
type List a = Cons a (List a) | Nil
```

Pattern matching handles the rest:
```
fn length xs =
  match xs
    | Cons _ rest => 1 + length rest
    | Nil => 0
```

**Tweet 4 (tree example):**
A binary tree with sum, count, height, and map — 20 lines:

```
type Tree = Branch Tree Tree | Leaf Int

fn tree_sum tree =
  match tree
    | Branch l r => tree_sum l + tree_sum r
    | Leaf n => n

fn tree_map f tree =
  match tree
    | Leaf n => Leaf (f n)
    | Branch l r => Branch (tree_map f l) (tree_map f r)
```

**Tweet 5 (comptime):**
Compile-time evaluation — zero runtime cost:

```
comptime fn fib n =
  if n <= 1 then n
  else fib (n - 1) + fib (n - 2)

let result = comptime fib 30  # computed at compile time
```

**Tweet 6 (named params):**
Named parameters when you need clarity:

```
fn make_point ~x ~y ~label = { x = x, y = y, label = label }

let pt = make_point ~x:3 ~y:4 ~label:"origin"
```

**Tweet 7 (try it):**
Want to try it?

```
git clone https://github.com/Adjanour/ko-language.git
cd ko-language
./build.sh
echo 'fn main = println "Hello, Kō!"' > hello.ko
./ko-dist/ko hello.ko
```

One folder. No install. No dependencies.

**Tweet 8 (closing):**
Kō compiles to native code via LLVM.

JIT for development. AOT for production.
HM type inference. Reference counting.
Pattern matching. ADTs. Closures.

It's small. It's fast. It's yours.

github.com/Adjanour/ko-language

---

## Hacker News "Show HN" Post

**Title:** Show HN: Kō — a minimal functional language that compiles to native code

**Body:**

I've been building a programming language called Kō (光 — "light" in Japanese). It's a small, eager, functional language that compiles to native binaries via LLVM.

Key design decisions:
- No parentheses for function calls: `add 1 2` not `add(1, 2)`
- Indentation-based blocks (like Python)
- Algebraic data types + pattern matching (like Haskell/OCaml)
- Immutable by default, explicit mutation via refs
- Hindley-Milner type inference
- Compile-time evaluation (`comptime`)
- Named parameters (`~name:value`)
- Reference counting for memory management
- JIT and AOT compilation

The compiler is written in Zig (~6000 lines) with LLVM 22 backend. It runs on Linux and macOS.

Try it:
```
git clone https://github.com/Adjanour/ko-language.git
cd ko-language && ./build.sh
echo 'fn main = println "Hello, Kō!"' > hello.ko
./ko-dist/ko hello.ko
```

Example — binary tree operations in 20 lines:
```
type Tree = Branch Tree Tree | Leaf Int

fn tree_sum tree =
  match tree
    | Branch l r => tree_sum l + tree_sum r
    | Leaf n => n

fn tree_map f tree =
  match tree
    | Leaf n => Leaf (f n)
    | Branch l r => Branch (tree_map f l) (tree_map f r)
```

GitHub: https://github.com/Adjanour/ko-language

---

## One-Liner Showcase (for social media)

```
# Hello world
fn main = println "Hello, Kō!"

# Factorial
fn factorial n = if n == 0 then 1 else n * factorial (n - 1)

# Fibonacci
fn fib n = if n <= 1 then n else fib (n-1) + fib (n-2)

# List length
fn length xs = match xs | Cons _ rest => 1 + length rest | Nil => 0

# QuickSort
fn qsort xs = match xs | Nil => Nil | Cons x rest =>
  let lo = qsort (filter (\y -> y <= x) rest)
  let hi = qsort (filter (\y -> y > x) rest)
  lo ++ Cons x hi

# Maybe type
type Maybe a = Just a | Nothing

# Result type
type Result a b = Ok a | Err b

# Comptime — computed at compile time
comptime fn fib n = if n <= 1 then n else fib (n-1) + fib (n-2)
let x = comptime fib 30

# Named parameters
fn greet ~name ~age = println ("Hi " ++ name ++ ", age " ++ Int.toString age)
greet ~name:"Kō" ~age:1
```

---

## Reddit Post (r/programming, r/functionalprogramming)

**Title:** I built Kō — a minimal functional language that compiles to native code via LLVM

**Body:**

Hey everyone,

I've been working on a programming language called Kō (光 — "light" in Japanese). It's a small, eager, functional language with a Zig compiler and LLVM backend.

**What makes it different:**
- No parentheses for function calls — `add 1 2` instead of `add(1, 2)`
- Indentation-based blocks (like Python)
- ADTs + pattern matching as the primary abstraction
- Immutable by default with explicit refs for mutation
- Compile-time evaluation (`comptime`) for zero-cost abstractions
- Named parameters (`~name:value`) for clarity
- Compiles to native code via LLVM (JIT + AOT)

**Example — binary tree:**
```
type Tree = Branch Tree Tree | Leaf Int

fn tree_sum tree =
  match tree
    | Branch l r => tree_sum l + tree_sum r
    | Leaf n => n
```

**Status:** Alpha — 78 passing tests, 12 examples, working LSP, REPL.

It runs on Linux and macOS. The compiler is ~6000 lines of Zig.

Would love feedback: https://github.com/Adjanour/ko-language

---

## Discord/Slack Message

```
Hey, I built a programming language called Kō — it's like Haskell meets Python, compiles to native code via LLVM.

No parens, no braces, no semicolons. Just:
  fn factorial n = if n == 0 then 1 else n * factorial (n - 1)

Try it: github.com/Adjanour/ko-language
```
