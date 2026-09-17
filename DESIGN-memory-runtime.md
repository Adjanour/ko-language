# Kō Memory and Runtime Contract

> **Status:** Supporting design and implementation contract
> **Date:** 2026-09-17
> **Canonical ownership semantics:** [DESIGN-ownership.md](DESIGN-ownership.md)

This document describes how canonical ownership decisions become runtime behaviour. If ownership terminology here conflicts with `DESIGN-ownership.md`, the canonical document wins.

---

## 1. Boundary

Typed HIR determines value types and ownership use patterns. Ownership-explicit LIR decides where values move, retain, release, or become eligible for reuse. The runtime implements the remaining dynamic operations.

The runtime must not infer language ownership from pointer magnitude, incidental AST form, or undocumented conventions.

---

## 2. Current Implementation

Kō currently uses a largely uniform `i64`-or-pointer representation and reference-counted heap allocations. Important implementation details include:

- primitive values are unboxed where the active lowering permits;
- heap objects carry runtime headers;
- constructors, tuples, records, strings, closures, arrays, maps, sets, and partial applications have representation-specific layouts;
- zero-argument constructors may be immediate tags;
- closure/function values use tagged representation conventions;
- the active code-generation path is AST → HIR → LIR → LLVM IR;
- legacy `codegen.zig` is frozen.

The current compiler still has incomplete tracking and cleanup for some intermediate tuples, records, closures, and aggregate paths. Issues #45 and #46 track the immediate correctness work.

---

## 3. Runtime Actions

The compiler may request these conceptual actions:

| Action | Meaning |
|---|---|
| `move` | Transfer an owning value without changing its dynamic owner count. |
| `borrow` | Create a temporary non-owning alias; no retain. |
| `retain` | Create or preserve another owning path. |
| `release` | End an owning path; destroy recursively when the count reaches zero. |
| `reuse` | Reinitialize unique, dead storage for a semantically new immutable value. |
| `copy` | Duplicate a compiler-known copy value according to the ABI. |

These may be LIR instructions, annotations consumed during lowering, or calls after optimization. Their semantics are fixed even if encoding changes.

---

## 4. Heap Object Requirements

Every heap representation must define:

- allocation size and alignment;
- ownership header, when dynamically shared;
- concrete type/representation identifier;
- child-field layout;
- which child fields own heap values;
- destruction procedure;
- closure capture or aggregate field metadata;
- whether allocation reuse is legal;
- whether the value may be immortal.

Pointer-shape heuristics are not sufficient for recursive destruction.

---

## 5. Reference Counting

Reference counting is Kō's safe dynamic-sharing fallback.

Rules:

1. A borrow never increments a reference count.
2. Moving a unique owner does not increment a reference count.
3. Creating an additional owning path retains the value.
4. Ending an owning path releases it.
5. Reaching zero recursively releases owned children according to representation metadata.
6. Immortal objects ignore retain/release.
7. Unknown non-copy ownership is treated conservatively.
8. Compiler optimizations may remove balanced operations only when semantics are preserved.

The initial implementation may keep RC headers on all heap objects while static analysis improves. “Unique” can therefore mean “dynamically one owner and statically proven not to require additional RC traffic,” not necessarily a different physical allocation layout.

---

## 6. Strings and Aggregates

Heap strings must have a stable owned representation with length and destruction behaviour. String literals may be immortal.

Constructors, tuples, records, and collections must expose enough metadata to destroy owned children correctly. The compiler knows concrete field types after specialization and should prefer representation-specific destructors over conservative pointer guessing.

Generic containers receive specialized element ownership/destruction behaviour when concrete types are known.

---

## 7. Closures and Partial Applications

Closure environments contain capture metadata derived from typed-HIR ownership analysis:

```text
Capture { representation, stored_state, destructor }
```

- copied captures need no RC;
- moved captures are owned by the closure;
- shared captures are retained on environment creation;
- borrowed captures are allowed only for proven non-escaping closures and do not become stored owning fields.

Partial applications follow the same contract for applied arguments.

---

## 8. Reuse

Destructive reuse is permitted when:

- the allocation is uniquely owned;
- its previous value is dead on all continuing paths;
- no borrow or shared alias can observe it;
- layout and alignment are compatible, or reallocation occurs;
- child fields that are not transferred are released correctly.

Reuse is an optimization of immutable semantics. Programs cannot observe whether storage was reused.

---

## 9. Cycles

Ordinary reference counting does not collect strong cycles.

The first milestone does not introduce an automatic cycle collector. Kō must either:

- prevent creation of unsupported strong cycles through its ownership/mutation rules; or
- document the leak boundary for explicit shared mutable graphs.

Weak references and cycle collection require a separate design and must not be implied by ordinary `ref` syntax.

---

## 10. Allocation Strategy

Correctness precedes allocation optimization.

Permitted future strategies include:

- stack promotion for proven non-escaping values;
- arenas for region-compatible temporaries;
- pools for uniform nodes;
- allocation reuse for unique transformations;
- specialized layouts for concrete generic types.

These strategies do not change ownership semantics.

---

## 11. Required Instrumentation

Tests need runtime instrumentation for:

- allocations and frees;
- retains and releases;
- live-object counts by representation;
- destructor recursion;
- reuse events;
- double-release and invalid-object detection in debug builds.

An ownership explanation view should connect these runtime facts to the HIR/LIR decisions that caused them.

---

## 12. Immediate Implementation Sequence

1. Inventory every heap-producing LIR instruction (#45).
2. Define representation-specific ownership/destruction metadata.
3. Emit balanced cleanup on all control-flow exits (#46).
4. Cover strings, tuples, records, closures, partial applications, lists, and Result paths.
5. Add leak/double-release instrumentation.
6. Only then add reuse and RC-elision optimizations.

---

*The runtime performs only the ownership work that static proof could not safely remove.*
