# Kō Performance Claim (Pre-Committed)

> **Status:** Frozen (Phase 0 deliverable)
> **Date:** 2026-08-01
> **Depends on:** DESIGN-linear-types.md, DESIGN-why-linearity.md

---

## The Claim

> **Kō is within 10% of C for tree-shaped ownership patterns. Shared/graph-shaped data uses explicit `Rc<T>` with reference-counting overhead.**

This sentence is frozen. It will not be softened under pressure to look impressive. When the benchmarks exist, the numbers will replace the words "within 10%."

---

## What "Tree-Shaped Ownership" Means

A tree-shaped program is one where:
- Data flows in one direction (parent → child)
- Each value has exactly one owner
- No cycles, no shared mutable state

Examples:
- Linked list processing (`map`, `filter`, `fold`)
- Tree traversal (binary trees, ASTs)
- String processing (concat, split, join)
- CLI argument processing (args → filter → print)

These are the most common patterns in functional programming. Kō's linear types prove single-ownership at compile time and eliminate all reference counting for these patterns.

---

## The Monomorphization Tradeoff

Kō monomorphizes generics (Rust-style): a `List<Node>` used at three call sites compiles to three specialized bodies. This costs compile time and binary size on heavy generic use, but keeps the linearity checker simple and sound.

**The tradeoff, stated explicitly:** Kō does not support runtime-polymorphic collections. This is a documented design choice, not a surprise regression. A `List<Node>` used at three call sites compiles to three specialized bodies. If someone's binary balloons from heavy generic use, that's the monomorphization tradeoff — known, documented, and accepted.

---

## What "Shared/Graph-Shaped" Means

A graph-shaped program is one where:
- Data is shared between multiple owners
- Cycles exist (parent ↔ child)
- Shared mutable state is needed

Examples:
- Caches (shared across functions)
- Parent pointers in trees
- Graph algorithms (BFS, DFS)
- Shared configuration

For these patterns, Kō uses explicit `Rc<T>` — reference-counted shared ownership. The overhead is visible in the types. It's not zero-cost, but it's fast and predictable.

---

## The Honest Footnote

The "within 10% of C" claim applies only to tree-shaped ownership. For shared/graph-shaped data, the overhead is RC increment/decrement per borrow. This is fast (RC is fast), but not zero-cost.

**The footnote will read:**

> "Within 10% of C" applies to tree-shaped ownership patterns where the compiler can prove single ownership at compile time. For shared/graph-shaped data, Kō uses explicit reference counting (`Rc<T>`), which has reference-counting overhead. The overhead is predictable and visible in the types.

---

## Why This Claim Is Defensible

1. **Linear types eliminate RC for trees:** The compiler proves single-ownership. No RC operations are generated. The cost is zero.
2. **LLVM optimizes aggressively:** With no RC overhead, LLVM can inline, unroll, and vectorize freely.
3. **The mental model matches C:** "Own the data, use it, done." Same as C's malloc/use/free — but with compile-time proof instead of manual tracking.
4. **The shared case is honest:** Rc has overhead. It's fast, but it's not zero. We don't hide this.

---

## When the Numbers Exist

Replace "within 10% of C" with the actual benchmark delta:

> "Kō is within **X%** of C for tree-shaped ownership patterns (benchmarked on [specific workload]). Shared/graph-shaped data uses explicit `Rc<T>` with reference-counting overhead (benchmarked at **Y%** of C equivalent)."

The specific workloads will be:
- **Tree-shaped:** List processing (map/filter/fold on 1M elements), binary tree traversal
- **Graph-shaped:** Shared cache lookup, parent pointer traversal

---

## What We Will NOT Say

- "Zero-cost abstractions" (unless the benchmark proves it)
- "As fast as C" (without qualification)
- "No overhead" (Rc has overhead, and we say so)
- "Optimized by the runtime" (the compiler proves it, not the runtime)

---

*This claim is frozen. It is honest, defensible, and pre-committed. When the numbers exist, they replace the words.*
