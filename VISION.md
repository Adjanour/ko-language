# The Kō Vision

> **Kō** (光) — "light" in Japanese.

---

## What Kō Is

Kō is a small, functional language that compiles to native code.

It is functional by default: immutable data, pure functions, algebraic types. It is explicit when you need mutation: `ref` makes it visible. It is fast: no garbage collector, no interpreter, no runtime overhead.

Kō aims to be the language you reach for when you want the expressiveness of a functional language and the performance of a systems language, without the complexity of either.

---

## The Honest Claim

There is no language today that is simultaneously:

- **Functional by default** (immutable data, ADTs, pattern matching)
- **GC-free** (no garbage collector, no runtime)
- **Small** (spec on a few dozen pages, not a few hundred)
- **C-competitive** (within 10% of C for tree-shaped ownership)

Kō could be that language. But the claim has a boundary, and stating it clearly now costs nothing:

**Tree-shaped ownership** (most programs): C-competitive, no asterisk. Linear types prove single-ownership at compile time. The compiler eliminates reference counting entirely for these cases. Zero overhead.

**Graph/shared ownership** (caches, parent pointers, cycles): You reach for `Rc` (reference-counted shared ownership). This is explicitly a separate, clearly-marked kind in the type system — not a hidden escape hatch. Performance is still good (RC is fast), but you're into reference counting overhead, not zero-cost. The "10% of C" claim applies to tree-shaped code; graph-shaped code is still fast but not zero-cost.

Stating this boundary upfront is honesty, not weakness. Every real language in this space has this boundary. Rust has `Rc<T>` and `Arc<T>`. Swift has `AnyObject`. The ones that hide it end up with two competing mental models. Kō designs it in from day one.

---

## The Position

Most languages force a tradeoff:

- **Haskell, OCaml, Erlang**: Expressive, but managed runtimes. GC pauses. No bare metal.
- **C, C++, Zig**: Fast, but imperative. No algebraic types. No pattern matching.
- **Rust**: Fast and functional-ish, but the borrow checker is complex. The spec is large. The learning curve is steep.
- **Go, Java, C#**: Practical, but GC'd. No functional defaults. Hidden allocation.
- **Koka (Perceus)**: Functional, fast, but RC-based. No bare metal. Sharing is native.

Kō sits in the gap:

- **Functional** like Haskell, but compiles to native code
- **Fast** like Zig, but has ADTs and pattern matching
- **Small** like Lua, but statically typed with inference
- **Simpler than Rust**: Linear types (or Perceus-style RC) instead of borrow scopes. No lifetimes. No variance. A smaller surface for the same guarantees.
- **Better than Koka for bare metal**: No RC runtime needed (if linear types win)

No other language occupies this position.

**The open question:** Should Kō use linear types (compile-time proof, no RC runtime) or Perceus-style RC with static elision (runtime RC, optimized away)? Phase 1 will answer this with benchmarks.

---

## The Design Center: Linear Types

This is the hard problem. Everything else is implementation.

"Immutable by default" + "no GC" only coexist if the type system proves single-ownership at compile time. This means Kō is, at its core, a **linear-type-system project with a language attached.**

### What Linear Types Give You

1. **No hidden allocation**: If the compiler knows you're the only owner, it can stack-allocate, inline, or eliminate the allocation entirely.

2. **No reference counting for tree data**: A `List Int` that's consumed by a `fold` doesn't need RC — the compiler knows it's single-owner and can reuse the memory directly.

3. **Safe mutation without borrowing**: Instead of "borrow for a scope" (Rust), Kō uses "consume and rebuild" (linear). You destructure a value, modify it, and reconstruct it. The type system proves the old value is gone.

4. **Predictable performance**: No GC pauses. No hidden ARC traffic. The cost model is visible in the types.

### The Core Mechanism

```ko
# Linear consumption: match consumes the value
fn sum xs =
  match xs
    Cons x rest -> x + sum rest    # rest is linear, xs is consumed
    Nil -> 0

# Rebuild: destructure, modify, reconstruct
fn update_name person =
  match person
    Person { name, age } -> Person { name = "New " ++ name, age = age }
    # old person is consumed, new one is built
```

The compiler tracks ownership through pattern matching and function application. If a value is used more than once, it's a type error — unless you explicitly use `Rc` (reference-counted shared ownership).

### What This Means for the Spec

The spec will grow from "a few pages" to approximately **Austral-sized** (~50 pages, a weekend to read). This is the tax every real linear-types language pays. Austral pays it最小, and even Austral's spec is not "a day."

**Kō's ceiling**: The spec is allowed to grow to Austral-sized to get real borrowing. This is the explicit choice: we trade "learnable in a day" for "learnable in a weekend" to get zero-cost tree ownership. The core language is still small — the complexity is in the ownership rules, not in features.

### What This Means for the Stdlib

`Rc` is a first-class citizen, not a stdlib type you regretfully use:

```ko
# Linear (default): single owner, zero-cost
let xs = Cons 1 (Cons 2 Nil)
let total = sum xs   # xs is consumed, no RC needed

# Shared (explicit): reference-counted, clearly marked
let shared = Rc.make (Cons 1 (Cons 2 Nil))
let a = Rc.get shared    # a borrows the value
let b = Rc.get shared    # b also borrows — RC incremented
# When both a and b go out of scope, RC reaches 0, memory freed
```

`Rc` is designed into the type system from day one, as a genuinely separate, clearly-marked kind. Not bolted on later.

---

## The Principles

### 1. Small (Within Our Ceiling)

The core language is small. The ownership rules add structure, not bloat.

**Core language**: ~19 keywords, ~20 operators, ADTs, records, pattern matching, `ref` for mutation, `comptime` for compile-time evaluation.

**Ownership rules**: Linear types for tree data. `Rc` for shared data. Consumption via pattern matching. Reconstruction via record update syntax.

The spec is approximately 50 pages. This is the explicit trade: more than "a few pages" (to get real ownership guarantees), but far less than Rust (to stay accessible).

### 2. Explicit

Mutation is visible at the type and syntax level. Ownership is visible in the types. Allocation is explicit when you want it. Side effects go through a module. Nothing is hidden.

The compiler is your friend. It catches your mistakes. If the compiler can't help, the language is wrong.

### 3. Pure by Default

Functions without `ref` are pure. The compiler knows this. It can:

- Memoize (same args → same result)
- Parallelize (no shared state)
- Fold at compile time (comptime)
- Eliminate dead code (unused pure result = no side effects)
- Optimize aggressively (full program visibility)
- **Eliminate reference counting** for linear values (the compiler knows they're single-owner)

Purity isn't a restriction. It's information the compiler uses to make your code faster.

### 4. Mechanical Sympathy

Write code that works *with* the hardware, not against it.

- Contiguous arrays (cache-friendly) over linked lists (pointer chaining)
- Stack allocation (fast) over heap allocation (slow)
- Linear ownership (zero-cost) over shared ownership (RC overhead)
- Direct syscalls (no libc overhead) over printf (formatting overhead)

But mechanical sympathy doesn't mean "always low-level." It means "understand the cost and choose appropriately."

### 5. Functional Pragmatism

Kō doesn't force you to choose between "clean" and "fast."

- Write pure functions → compiler optimizes aggressively
- Use linear types → zero-cost ownership for tree data
- Use `Rc` when you need sharing → explicit, clearly marked
- Use `ref` when you need mutation → explicit, not hidden
- Use `Array` when you need performance → mutable, cache-friendly
- Use `arena` when you need speed → allocate fast, free all at once

The language gives you the tools. You choose when to use them.

---

## The Technical Vision

### Compilation

Kō compiles to LLVM IR directly. Not via C. Not via another language. Directly.

This means:
- Full control over code generation
- No libc dependency in the compiler itself
- LLVM optimizations apply to pure functional code
- Cross-compilation to any LLVM target (eventually)

### Memory Management

**Linear types** for tree-shaped data: The compiler proves single ownership. No reference counting. No garbage collector. The memory is reused directly.

**`Rc`** for shared/graph-shaped data: Reference-counted shared ownership. Clearly marked in the type system. The compiler generates increment/decrement code.

**Explicit allocators** for control:

```ko
arena \a ->
  let arr = Array.init a 10 0
  # arr freed when arena exits
```

The allocator is explicit in the type system. You see it. You control it.

### Type System

Hindley-Milner inference. ADTs. Records. Pattern matching. Exhaustiveness checking. Linear types for ownership. `Rc` for sharing.

No type classes (yet). No higher-kinded types. No dependent types. Just the essentials plus ownership.

The type system catches your mistakes at compile time. The exhaustiveness checker ensures you handle every case. The linear type checker ensures you don't use freed data.

### Compile-Time Evaluation

`comptime` evaluates expressions at compile time. Not macros. Not metaprogramming. Just: if the inputs are known, compute the result now.

```ko
comptime fn fibonacci n =
  if n <= 1 then n else fibonacci (n - 1) + fibonacci (n - 2)

let answer = comptime fibonacci 30  # computed at compile time
```

This is zero-cost abstraction in its purest form.

### Data Structures

- **List**: Functional linked list. Immutable. Pattern-matchable. Linear by default (zero-cost).
- **Array**: Mutable contiguous buffer. Fast. Cache-friendly.
- **Map**: Hash map. O(1) lookup. Insertion-ordered.
- **Set**: Hash set. Unique elements.
- **Tuples**: Fixed-size heterogeneous. Stack or heap.
- **Records**: Named fields. Type-safe access.
- **Rc**: Reference-counted shared ownership. For graph data.

Use the right tool for the job. The language doesn't force one choice.

### I/O

Side effects go through a module:

```ko
import std.io

fn main =
  io.println "Hello"
  match io.readFile "config.ko"
    Ok contents -> process contents
    Err e -> io.eprintln (to_string e)
```

All I/O is in one place. Auditable. Testable. Mockable.

### Error Handling

No exceptions. No null. Use types:

- `Maybe a` for optional values
- `Result a b` for operations that can fail
- `?` operator for error propagation

```ko
fn load_config =
  let contents = io.readFile "config.ko"?   # propagates error
  parse contents
```

Errors are values. You handle them explicitly.

### String Handling

Strings are byte sequences. UTF-8 encoded. Length is O(1).

Characters are bytes. `len` returns byte count. For Unicode, use `std.text`.

```ko
len "hello"           # 5 (bytes)
len "café"            # 5 (bytes, é is 2 bytes in UTF-8)
text.length "café"    # 4 (codepoints, O(n))
```

Simple by default. Correct when you need it.

---

## The Philosophy

### No Null

Nothing is better than null. Maybe is better than nothing.

```ko
type Maybe = Just * | Nothing

fn head xs =
  match xs
    Cons x _ -> Just x
    Nil -> Nothing
```

The compiler forces you to handle the `Nothing` case. No null pointer exceptions.

### No Exceptions

Nothing is better than exceptions. Result is better than nothing.

```ko
type Result a b = Ok a | Err b

fn divide a b =
  if b == 0 then Err DivisionByZero else Ok (a / b)
```

The compiler forces you to handle the `Err` case. No uncaught exceptions.

### No Classes

ADTs + functions cover everything classes do, without the complexity.

```ko
type Shape =
  Circle Float
  | Rectangle Float Float
  | Triangle Float Float Float

area shape =
  match shape
    Circle r -> Float.pi *. r *. r
    Rectangle w h -> w *. h
    Triangle a b c ->
      let s = (a +. b +. c) /. 2.0
      Float.sqrt (s *. (s -. a) *. (s -. b) *. (s -. c))
```

No inheritance. No virtual dispatch. No `this`. Just data and functions.

### No Hidden Behavior

Everything in Kō is visible:

- Ownership: linear types make it explicit
- Mutation: `ref` makes it explicit
- Sharing: `Rc` makes it explicit
- Allocation: `arena` makes it explicit
- Side effects: `io` module makes it explicit
- Errors: `Result` makes it explicit
- Type conversions: no implicit coercions

If you can't see it in the code, it's not there.

### Exhaustiveness

Pattern matches must handle every case. The compiler checks.

```ko
type Color = Red | Green | Blue

fn name c =
  match c
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
    # compiler warns if a case is missing
```

No forgotten cases. No runtime surprises.

---

## The Sequencing

This is the most important section. The previous version listed goals that look parallel but are actually sequential, with strict dependencies.

### Phase 1: Prove the Thesis (v0.3.0 — v0.4.0)

**Goal:** Linear types on one platform (Linux/x86-64). Prove or disprove the core thesis.

**What this means:**
- Linear type checker: track ownership through pattern matching and function application
- Consumption semantics: `match` consumes, functions consume, values are single-owner by default
- `Rc` type: explicit shared ownership, clearly marked in the type system
- Zero-cost trees: linear `List`, `Tree`, `Expr` with no RC overhead
- One platform: Linux/x86-64 only. No cross-compilation. No bare metal.
- Working stdlib: Array, Map, String, I/O, Math — all with linear types

**What this does NOT include:**
- Bare metal support
- Windows/macOS
- Package manager
- Self-hosting

**Why this is first:** If linear types don't work for Kō's use cases, nothing else matters. This is the existential risk. Prove it works on one platform before anything else.

### Phase 2: Widen the Platform (v0.5.0)

**Goal:** Once linear types work, widen to more platforms.

**What this means:**
- macOS support
- Windows support
- Cross-compilation
- Replace libc step by step (allocators, syscalls, CRT)

**Why this is second:** Platform support is backend labor. Any competent systems team can do it once the frontend is right. It's not the hard problem.

### Phase 3: Ecosystem (v1.0.0)

**Goal:** Once the platform is stable, build the ecosystem.

**What this means:**
- Package manager
- Self-hosting (Kō compiles itself)
- Complete standard library
- Documentation and tutorials
- Bare metal support (if needed — this may stay optional)

**Why this is last:** The ecosystem depends on the language being stable. Don't build a package manager for a language whose type system might change.

---

## The Performance Boundary

### Where Kō is C-competitive (no asterisk)

Tree-shaped ownership. Single-owner data. The compiler eliminates RC entirely.

```ko
# This is zero-cost — no allocation, no RC
fn sum_list xs =
  match xs
    Cons x rest -> x + sum_list rest
    Nil -> 0

# This is zero-cost — inlined, stack-allocated
fn add_pair (a, b) = a + b
```

For these patterns, Kō is within 10% of C. Often identical after LLVM optimization.

### Where Kō has overhead (explicit escape hatch)

Graph-shaped data. Shared ownership. Cycles.

```ko
# This uses Rc — reference counting overhead
let shared = Rc.make node
let a = Rc.get shared
let b = Rc.get shared
# RC increment on get, decrement on drop
```

For these patterns, Kō is still fast (RC is fast), but not zero-cost. The overhead is explicit and visible in the types. This is the honest boundary.

### The Marketing Statement

"Kō is within 10% of C for tree-shaped programs. For shared/graph data, it uses explicit reference counting — still fast, still predictable, but not zero-cost."

This is true, honest, and marketable. Underselling now costs nothing. Overselling costs credibility the first time someone benchmarks a graph traversal.

---

## The Promise

Kō promises to be:

- **Small**: learnable in a weekend (spec ~50 pages)
- **Simple**: no magic, no hidden behavior
- **Practical**: compiles to real code
- **Functional**: immutable by default
- **Linear**: zero-cost ownership for tree data
- **Expressive**: ADTs + pattern matching
- **Fast**: within 10% of C for tree-shaped programs
- **Clever**: computes what it can at compile time
- **Honest**: clear performance boundary, no hidden overhead

Kō promises NOT to be:

- **Large**: no thousands of keywords, no hundreds of pages
- **Complex**: no monads, no type classes (yet), no borrow scopes
- **Slow**: no interpreter overhead, no GC pauses
- **Unsafe**: no null, no exceptions
- **Magic**: no hidden allocations, no implicit conversions

---

## The Invitation

Kō is small today. It will grow. But it will always be:

- Simple before complex
- Explicit before implicit
- Practical before theoretical
- Human before machine

The future is bright. Linear types and functional pragmatism aren't at odds. We just have to find where we can take our wins and hammer down.

**光** — light. The language should be as light as its name.
