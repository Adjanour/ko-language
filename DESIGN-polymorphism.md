# Kō Polymorphism and Ownership-Aware Specialization

> **Status:** Supporting design
> **Date:** 2026-09-17
> **Canonical ownership semantics:** [DESIGN-ownership.md](DESIGN-ownership.md)
> **Tracked by:** issue #47

This document defines how type polymorphism and ownership patterns produce concrete code. The canonical ownership document controls ownership terminology and laws.

---

## 1. Decision

Kō uses demand-driven compile-time specialization for generic functions.

Specialization occurs **after type inference**, not before it. The compiler must know concrete types, representations, liveness, escape behaviour, and ownership-relevant call patterns before it can construct the correct specialization key.

Canonical pipeline:

```text
parse
  → type inference and checking
  → typed HIR
  → liveness / escape / ownership analysis
  → specialization worklist
  → ownership-explicit LIR
  → LLVM IR
```

---

## 2. Why Specialize

Concrete specialization provides:

- unboxed concrete representations;
- direct calls and inlining opportunities;
- representation-specific pattern matching;
- ownership-specific retain/release behaviour;
- allocation reuse when inputs are uniquely consumed;
- stable native ABIs for generated functions.

Kō may later share identical machine bodies, but semantic specialization is defined first.

---

## 3. Signatures

Public generic APIs require explicit type signatures once the syntax is stabilized. Private definitions may be inferred.

Examples:

```ko
pub fn id (x : a) -> a = x
pub fn map (f : a -> b) (xs : List a) -> List b = ...
```

Ownership contracts may be inferred initially and serialized in module metadata. Future explicit `borrow`, `consume`, or `share` syntax is governed by `DESIGN-ownership.md`.

---

## 4. Canonical Specialization Key

```text
SpecializationKey {
  definition_id
  concrete_type_arguments
  representation_arguments
  relevant_parameter_modes
  relevant_capture_modes
  target_abi
}
```

Requirements:

- deterministic and hashable;
- independent of source memory addresses and traversal order;
- stable for the same package/module identity and ABI;
- ownership modes included only when they change LIR or ABI;
- suitable for persistent caching.

Two requests with identical canonical keys reuse one specialization.

---

## 5. Ownership-Relevant Variants

The same source type may need different bodies:

```text
map<Int, Int, xs=consume>  → may reuse nodes
map<Int, Int, xs=borrow>   → preserves the original list
```

Different call sites may share a body:

```text
length<List Int, xs=borrow>
length<List Int, xs=borrow>
```

If borrow and consume lower to identical LIR for a function, the compiler may canonicalize them to one implementation. It must not generate ownership variants merely because the analysis vocabulary permits them.

---

## 6. Worklist

1. Typecheck generic definitions once.
2. Seed requests from concrete entry points, exports, and required runtime boundaries.
3. At each call, resolve concrete types and representations.
4. Compute only behaviour-relevant ownership and capture modes.
5. Canonicalize the request.
6. Reuse an existing or in-progress key when present.
7. Otherwise reserve its stable symbol before lowering.
8. Lower the typed HIR body under that contract.
9. Enqueue newly discovered requests.
10. Continue until no requests remain.

Reservation before lowering supports direct recursion.

---

## 7. Recursive Termination

A recursive request that repeats the same canonical key is normal recursion.

The compiler rejects specialization expansion when recursive calls continually grow the key, such as structurally larger type arguments or ownership forms that never reach a fixed point.

Mutually recursive groups reserve their in-progress keys before any member finishes lowering.

Diagnostics show:

- the generic definition;
- the concrete call chain;
- each changing specialization key;
- the point where expansion was rejected.

A numeric limit may protect the compiler but is not the semantic definition of termination.

---

## 8. Symbols and Modules

A symbol is derived from:

- stable package/module identity;
- stable definition identity;
- canonical type and representation arguments;
- relevant ownership modes;
- ABI version.

Readable fragments are optional. Linkage uniqueness uses a stable hash.

Diagnostics always map back to the generic source definition and instantiation chain.

---

## 9. Runtime Polymorphism and Typeclasses

The first specialization milestone does not require runtime polymorphism, vtables, or boxing.

Typeclasses are a later design. They may lower through specialization, dictionaries, or a restricted hybrid, but their design must not retroactively force monomorphization to occur before type inference.

---

## 10. Compile-Time and Binary-Size Controls

Required measurements:

- number of requested and emitted specializations;
- cache hit rate;
- per-definition code-size contribution;
- compile time spent in analysis and lowering;
- variants split only by ownership;
- identical LIR bodies eligible for folding.

Mitigations may include lazy instantiation, persistent caching, identical-body folding, and representation sharing.

---

## 11. First End-to-End Proof

Use one recursive ADT transformation such as `map`.

Required cases:

1. `List Int → List Int`, borrowed input;
2. `List Int → List Int`, uniquely consumed input;
3. the same borrowed request at multiple call sites;
4. shared or unknown input using safe RC;
5. recursive calls reusing the in-progress key.

The borrowed and consumed versions must produce the same observable list. The consumed version may demonstrate node reuse and reduced allocation/RC traffic.

---

## 12. Non-Goals

- specializing before type inference;
- cloning generic ASTs without typed context;
- one variant for every theoretical ownership state;
- runtime `any` values;
- solving the complete typeclass design;
- using mangled names as user-facing diagnostics.

---

*Types determine what a value is. Ownership analysis determines how this call may use it. Specialization emits concrete code only for distinctions that matter.*
