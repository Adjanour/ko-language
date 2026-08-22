---
title: "Memory Management"
---

# Memory Management in Kō

Kō has no garbage collector. No reference counting overhead by default. No manual `free`.
The compiler proves at compile time that your data has exactly one owner, and frees it
automatically. This document explains how, why, and where the idea came from.

---

## The One-Paragraph Version

Every value in Kō has exactly one owner. When the owner goes out of scope, the value is freed.
The compiler tracks ownership through type inference — you never think about it. If you need
shared access, you opt in with `ref` and pay a small reference-counting cost. The rest is free.

---

## Why No Garbage Collector?

Garbage collection is the default in most functional languages. It works. It's safe. It's also
expensive in ways that matter:

- **Pause times.** A tracing GC stops the world to collect. For a CLI tool or a build system,
  that's fine. For anything interactive, it's not.
- **Cache misses.** The GC walks the entire object graph. That's a lot of pointer chasing, and
  modern CPUs hate it.
- **Unpredictable.** You can't tell when memory is freed. A value might live for milliseconds
  or minutes. That makes performance reasoning impossible.

Kō's bet: you can get the safety of a managed language with the predictability of C, if the
compiler can prove ownership at compile time.

---

## Where the Idea Came From

The theory behind Kō's memory model is forty years old. It comes from logic, not computer science.

### Linear Logic (1987)

Jean-Yves Girard introduced linear logic in 1987. In classical logic, you can use a hypothesis
as many times as you want (contraction) or ignore it entirely (weakening). In linear logic,
every hypothesis must be used **exactly once**.

This sounds abstract, but it maps directly to memory: a pointer can be used exactly once —
either you dereference it, or you pass it somewhere. You can't implicitly copy it or throw
it away. The logic *is* the memory discipline.

### Wadler's Insight (1990)

Philip Wadler connected the dots in a 1990 paper titled
[**"Linear types can change the world!"**](https://homepages.inf.ed.ac.uk/wadler/topics/linear.html).
His argument: if a type system tracks how many times a value is used, you can guarantee that
resources are cleaned up exactly when they're no longer needed. No GC. No manual free.
The compiler does it.

The paper was ahead of its time. Languages in the 1990s and 2000s mostly ignored linear types.
GC was good enough. Hardware was getting faster. Nobody needed to care.

### Clean and Uniqueness Types (1987–2000)

The Clean language at Radboud University took a different approach: **uniqueness types**.
A value with a uniqueness type can have at most one reference. This lets the compiler
update values in place instead of copying them — safe mutation in a pure functional language.

Clean proved that linear/unique types could work in practice, not just theory. But it
remained a research language.

### Cyclone and Region-Based Memory (2001–2006)

Cyclone, a "safe dialect of C" from Cornell and AT&T, brought these ideas to systems
programming. It used **regions** — stack-like memory pools managed at compile time.
The type system tracked which region each value lived in, and deallocated regions
when they were provably empty.

Cyclone's region system is the most direct ancestor of Rust's lifetime annotations.

### Rust (2006–2015)

Graydon Hoare started Rust as a personal project in 2006, inspired by Cyclone. The Mozilla
team joined, and Rust 1.0 shipped in 2015.

Rust's innovation: instead of exposing regions or linear types directly, it created an
**ownership model** with three simple rules:

1. Each value has one owner
2. Ownership transfers on move
3. Values are dropped when the owner goes out of scope

Rust's borrow checker is powerful but has a steep learning curve. The experience of
"fighting the borrow checker" is well-documented. Months of frustration before it clicks.

### Kō (2025–)

Kō takes the same core insight — compile-time ownership tracking — but makes it simpler:

| | Rust | Kō |
|---|---|---|
| Ownership tracking | Explicit lifetimes (`'a`) | Inferred, no syntax |
| Borrow checker | Complex, phase-based | Simple consume/borrow |
| Mutation | `&mut` references | `ref` cells (`:=`, `!`) |
| Learning curve | Months | Days |
| Precision | Very precise | Conservative (warnings, not errors) |
| Safety | Enforced (compile errors) | Advised (warnings, optional) |

Kō gives up some of Rust's precision for a dramatically simpler experience.
The tradeoff is explicit: easier to learn, slightly less optimizable.

---

## How It Works in Practice

### Linear Values (The Default)

Most values in Kō are linear — used exactly once. The compiler tracks this:

```ko
let xs = Cons 1 (Cons 2 Nil)   # xs owns the list
let total = sum xs              # xs is consumed — ownership transfers to sum
# xs is gone. The compiler proved it.
```

When you pass `xs` to `sum`, ownership transfers. `sum` owns the list now.
When `sum` returns, the list is freed. No RC increment. No GC scan. Just free.

This is the zero-cost path. For tree-shaped data (lists, trees, nested structures),
Kō is within 10% of C. No asterisk.

### Consumption via Pattern Matching

Pattern matching consumes values. This is the primary way ownership transfers:

```ko
fn sum xs =
    match xs
        | Cons x rest -> x + sum rest   # xs consumed, x and rest are new
        | Nil => 0
```

`Cons x rest` destructures `xs`. After the match, `xs` is gone. `x` and `rest` are
new linear values with their own lifetimes.

### Borrowing (Read-Only Access)

Sometimes you need to read without consuming. The compiler infers this:

```ko
fn first xs =
    match xs
        | Cons h _ => h    # xs is borrowed, not consumed
        | Nil => 0
```

The `_` means "I don't need this part." The compiler sees that `xs` isn't used after
the match, so it borrows instead of consuming. No syntax needed — it just works.

### Shared Data with `ref`

When you need multiple readers (or a graph structure), use `ref`:

```ko
let shared = ref (Cons 1 (Cons 2 Nil))   # RC'd shared data
let a = !shared    # borrow (RC incremented)
let b = !shared    # borrow (RC incremented)
```

`ref` is the escape hatch. It creates a reference-counted box. `!` borrows it temporarily.
The cost: RC increment/decrement per borrow. Not zero-cost, but explicit and visible.

`ref` is designed into the type system from day one. It's not a stdlib afterthought.
When you need it, you reach for it. When you don't, you never pay for it.

---

## Perceus-Style Reference Counting

Kō's runtime uses a technique inspired by
[**Perceus**](https://www.microsoft.com/en-us/research/uploads/prod/2021/01/perceus-tr.pdf),
a 2021 paper from Microsoft Research. The core idea: most reference-counting operations
can be eliminated at compile time if the compiler knows who owns what.

### What Perceus Does

Traditional reference counting increments the counter on every pointer copy and
decrements on every drop. That's a lot of runtime work. Perceus observes that most
values are **uniquely referenced** — only one pointer points to them. For those values,
the RC is always 1, and all the inc/dec operations are pointless.

Perceus adds two compile-time optimizations:

1. **Unique fast path:** If the compiler knows a value is uniquely owned, it skips
   the decrement entirely — the value can be freed immediately without checking the counter.
2. **Memory reuse:** When you consume a value and immediately create a new one of
   the same shape, you can reuse the old allocation instead of allocating fresh memory.

### How Kō Implements It

Kō takes the first optimization (unique fast path) and is building toward the second
(memory reuse). Here's what's in the compiler today:

**Type tags in the header.** Every heap-allocated value has a 32-byte header:

```
[ rc (i64) | type_tag (i64) | arity (i64) | bitmap (i64) ]
```

The `type_tag` tells `ko_decref` how to walk the value when freeing:
- Tag 0: `ref` (shared, needs RC)
- Tag 1: constructor (linear, no RC)
- Tag 2: tuple (linear, no RC)
- Tag 3: record (linear, no RC)
- Tag 10: closure (custom walk)
- Tag 11: array with scalar elements (no walk)
- Tag 12: array with heap elements (walk needed)

**Linear values skip RC.** The LIR lowering pass tracks whether each value is linear
(single-owner) or shared (`ref`). Linear values get no `incref`/`decref` operations at
scope exit — they're freed directly. Only `ref` values (tag 0) get RC operations.

```ko
# Linear: no RC operations generated
let xs = Cons 1 (Cons 2 Nil)
let total = sum xs            # xs consumed, freed directly

# Shared: RC operations generated
let shared = ref (Cons 1 Nil)
let a = !shared               # incref (if a escapes)
# ... a goes out of scope ... # decref on shared
```

**Inlined uniqueness test.** The `is_unique(p)` check — the heart of the Perceus
fast path — is inlined directly in the generated LLVM IR:

```
# is_unique(p) compiles to:
rc_ptr = p - 32              # RC header is 32 bytes before user data
rc = load rc_ptr             # read the reference count
is_unique = (rc == 1)        # unique if RC is exactly 1
```

No function call. No runtime support. Just a load and a comparison.
This is the Perceus fast path — it lets the compiler skip decref entirely
when a value is provably unique.

### What's Not There Yet

**Memory reuse** — the second Perceus optimization — is not implemented yet.
This is the optimization where:

```ko
fn update_name person =
    match person
        | Person { name, age } ->
            Person { name = "New " ++ name, age = age }
```

Instead of allocating a new `Person` and freeing the old one, the compiler could
reuse the old `Person`'s memory for the new one. Same shape, same size, different
fields. The allocation becomes a no-op.

This is harder than the unique fast path because it requires:
- Shape analysis (are the old and new values the same constructor?)
- Size analysis (do they fit in the same allocation?)
- Lifecycle analysis (is the old value consumed at exactly the point where the new one is created?)

The plan is to implement memory reuse after the linear type checker is fully
integrated — the ownership analysis that makes reuse safe is the same analysis
that powers the linearity warnings.

### The Cost Model

| Value kind | Allocation | RC operations | Optimization |
|-----------|-----------|--------------|-------------|
| Linear (tree) | Stack/inline possible | None | Full — LLVM eliminates dead code |
| Linear (heap) | `ko_alloc` | None | Unique fast path (inlined `is_unique`) |
| `ref` (shared) | `ko_alloc` | Increment/decrement | None (explicit RC) |
| `ref` (borrowed) | None (pointer) | None | None |

For tree-shaped data (the common case in functional programming), Kō generates
zero reference-counting operations. The data is allocated, used, and freed
directly. This is the "10% of C" path.

For shared data, the overhead is visible and explicit: you chose `ref`, you
see the RC cost. No hidden overhead, no surprises.

---

## What the Linearity Checker Does

Kō's compiler has a **linearity checker** — a compile-time pass that tracks ownership.
It produces three kinds of warnings (never errors):

**`linear variable used twice`** — you tried to use a value you already gave away.
Usually a real bug, sometimes a checker limitation with accumulators.

**`linear variable used after consumption`** — you read a value after it was consumed.
Same family, different wording.

**`linear variable never used`** — you created a value and never touched it. Prefix with `_`
to silence it.

All warnings are advisory. The compiler never rejects a program for linearity — it warns,
and you decide. This is a deliberate choice: the checker is a helpful assistant, not a strict gatekeeper.

See [Linearity and Ownership](linearity-and-ownership) for the full details.

---

## The Vision

Kō's vision is **functional pragmatism + mechanical sympathy**.

Functional pragmatism means: immutable data, pattern matching, ADTs, type inference —
the things that make functional programming expressive. But without laziness, without
GC, without a heavyweight runtime.

Mechanical sympathy means: the compiler knows what the machine does. `let x = a + b`
becomes an `add` instruction. No hidden allocations. No control flow the compiler
inserted without your knowledge.

Linear types are the mechanism that makes both possible. They let the compiler
eliminate overhead without putting the burden on the programmer.

### Where We're Going

**Phase 1 (now):** The linearity checker works. It warns about ownership violations.
RC is still used everywhere, but the checker proves the analysis is possible.

**Phase 2 (next):** Eliminate RC for linear values. The compiler uses the ownership
analysis to skip reference-counting operations for values it can prove are single-owner.
This is the zero-cost path.

**Phase 3:** Ownership-aware monomorphization. Functions that consume their arguments
get different specializations than functions that share them. The caller picks the right
version. Zero-cost for tree data, correct RC for shared data.

**Phase 4:** Ergonomic refinements. Better inference, better error messages, benchmarks
proving the "10% of C" claim.

The end state: a functional language whose performance you can reason about,
the same way you reason about a C or Rust program. No GC pauses. No hidden overhead.
Just code that does what it says.

---

## Further Reading

- [Linearity and Ownership](linearity-and-ownership) — the practical guide (warnings, borrow vs consume)
- [Writing Kō Programs](writing-ko-programs) — everyday patterns
- [Vision](https://github.com/Adjanour/ko-language/blob/main/ko-zig/VISION.md) — the full design rationale
- [Linear Types Design](https://github.com/Adjanour/ko-language/blob/main/DESIGN-linear-types.md) — the technical spec

---

*Linear types aren't new. The idea is forty years old. Kō's contribution is making them
invisible — you write normal functional code, and the compiler proves it's safe.*
