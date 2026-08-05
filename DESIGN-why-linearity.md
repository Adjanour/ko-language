# Why Compile-Time Linearity Over Runtime Refcounting

> **Status:** Frozen (Phase 0 deliverable)
> **Date:** 2026-08-01

---

## The Question

Every systems programmer will ask: "Roc does runtime refcount elision. Why are you doing compile-time linearity instead?"

This document answers that question crisply.

---

## The Short Answer

Runtime refcount elision (Roc's approach) optimizes the common case at runtime. Compile-time linearity (Kō's approach) eliminates the cost entirely at compile time. They solve the same problem with different tradeoffs:

| | Runtime Elision (Roc) | Compile-Time Linearity (Kō) |
|---|---|---|
| **When optimization happens** | Runtime (JIT/AOT) | Compile time |
| **Cost when it works** | RC increment/decrement | Zero (none generated) |
| **Cost when it doesn't fall back** | Full RC overhead | Zero (compiler proved no RC needed) |
| **Complexity** | Runtime counter checks | Type system rules |
| **Guarantee** | Probabilistic (may miss) | Absolute (proof or error) |

---

## Why Kō Chooses Compile-Time

### 1. Predictability Over Optimization

Roc's runtime elision is clever: it checks reference counts at runtime and skips increment/decrement when the count is 1 (meaning no other reference exists). This works well for Roc's use case (pure functional, no mutation).

But it has a cost: **every RC operation pays a branch.** Even when the elision works, there's a branch prediction cost. When it doesn't work (shared data, graphs), you pay full RC overhead.

Kō's approach: **no branches, no checks, no overhead.** The compiler proves at compile time that a value is single-owner. No RC operations are generated. Period. The cost is zero, not "almost zero."

### 2. Absolute Guarantee vs Probabilistic Optimization

Roc's elision can miss. If the JIT doesn't inline a function, or if the optimizer can't see through a callback, the RC operations remain. This is fine for Roc (their benchmarks show it works well in practice), but it means the performance depends on the optimizer's ability to see the full call graph.

Kō's linearity is a **compile-time proof.** If the type checker accepts the program, RC is eliminated. If it can't prove linearity, it rejects the program (or falls back to Rc). There's no "the optimizer might not see this" — it's a type system guarantee.

### 3. No Runtime Counter

Roc's elision requires a runtime reference counter on every heap object. The counter itself is a cost: 8 bytes per object, cache line pollution, atomic operations for thread safety.

Kō's linear values have **no counter at all.** The compiler knows they're single-owner. No counter means:
- 8 bytes less per object
- No cache line pollution
- No atomic operations
- No branch prediction overhead

### 4. Simpler Mental Model

Roc's programmer thinks: "The runtime will optimize this. I don't need to worry about it."

Kō's programmer thinks: "The compiler proved this is linear. I can see it in the types. No hidden cost."

The second model is more honest. It doesn't rely on "trust the optimizer." It says: "Here's the proof. Here's the cost. You can see it."

---

## When Runtime Elision Wins

Runtime elision has one advantage: **it works without type system changes.** Roc added elision to an existing RC system. Kō adds linearity to the type system, which requires programmer buy-in.

For Roc's use case (pure functional, no mutation), runtime elision is probably sufficient. The common case (single-owner) is optimized, and the uncommon case (shared) falls back to RC.

For Kō's use case (systems programming, performance-critical), the absolute guarantee matters more. Systems programmers want to know: "Is this zero-cost, or is it 'almost zero-cost'?" Kō answers: "It's zero-cost. The compiler proved it."

---

## The Performance Delta

| Pattern | Runtime Elision (Roc) | Compile-Time Linearity (Kō) |
|---------|----------------------|----------------------------|
| Single-owner tree | RC branch (optimized away in common case) | Zero (no RC generated) |
| Shared graph | Full RC | Full Rc (explicit) |
| Mixed | RC branch on single-owner, full RC on shared | Zero on linear, Rc on shared |

The key difference: Kō's single-owner case is **provably zero-cost.** Roc's is "probably zero-cost if the optimizer sees it."

---

## The Cost

The cost of compile-time linearity is the type system rules. The programmer must:
1. Understand linear vs unrestricted variables
2. Ensure each linear variable is used exactly once
3. Use `Rc` explicitly for shared data

This is the same cost Rust pays (ownership, borrowing). Kō's version is simpler (no lifetimes, no borrow scopes — just linear/unrestricted and Rc). But it's still a cost.

**The trade:** Kō trades "trust the optimizer" for "prove it at compile time." For systems programmers, this trade is worth it.

---

## The One-Sentence Answer

"Runtime refcount elision optimizes the common case at runtime with a branch. Compile-time linearity eliminates the cost entirely at compile time with a type system proof. We choose the absolute guarantee over the probabilistic optimization."

---

## Why Not Hindley-Milner

Kō does not use global HM-style inference. Reason: HM's global unification assumes unrestricted reuse of type variables across constraints, which does not compose cleanly with linear usage tracking. This is a known hard interaction, not a solved one (see Linear Haskell's friction points). Combining full inference research with linearity-checking research in v1 is out of scope.

Instead, Kō uses **bidirectional local inference**: function signatures are mandatory and fully explicit; everything inside a function body is inferred locally (checking mode from the signature inward, synthesis mode outward for unconstrained subexpressions). This keeps inference local, predictable, and compatible with linear usage tracking.

**The sentence that stops future contributors from "improving" into HM territory:** "HM's global unification assumes unrestricted reuse of type variables across constraints, which does not compose cleanly with linear usage tracking." If someone proposes adding HM inference, they must first solve this interaction — and that's a research project, not a engineering task.

---

*This document is frozen. It answers the question "why not runtime elision?" If a systems programmer asks, point them here.*
