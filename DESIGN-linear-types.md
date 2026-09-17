# Kō Linearity and Use Analysis

> **Status:** Supporting design
> **Date:** 2026-09-17
> **Canonical ownership semantics:** [DESIGN-ownership.md](DESIGN-ownership.md)

This document defines the role of linearity and liveness analysis inside Kō's broader ownership model. If terminology or semantics here conflict with `DESIGN-ownership.md`, the canonical ownership document wins.

---

## 1. Purpose

Kō is an eager functional systems language with immutable source semantics. The compiler uses linearity, liveness, and escape information to decide whether a value is:

- borrowed for observation;
- consumed by an ownership transfer;
- shared with another owning path;
- trivially copied.

Linearity is an analysis mechanism, not the entire language identity. It helps prove when a heap value remains uniquely owned and therefore needs no retain/release traffic.

---

## 2. What the Checker Proves

For each non-copy binding, the checker determines:

1. all direct and transitive uses;
2. which uses borrow, consume, or share;
3. whether any borrow escapes;
4. whether a closure escapes with captured data;
5. the ownership state at every control-flow edge;
6. whether states agree at continuing joins;
7. whether the last use permits consumption or destructive reuse.

The analysis runs on typed HIR. Types are known before ownership use modes are selected.

---

## 3. Linearity Is Not “Exactly One Syntactic Use”

A value can be borrowed repeatedly and remain uniquely owned:

```ko
let n = length xs
let found = contains needle xs
inspect xs
```

These uses do not create additional owners.

A value becomes unavailable after a consuming use:

```ko
let ys = map increment xs
inspect xs  # error when map consumes xs at this call site
```

A value becomes shared when another owning path may retain it:

```ko
let cache2 = insert cache key value
```

Whether `cache` or `value` is borrowed, consumed, or shared depends on the selected contract and later uses.

---

## 4. Pattern Bindings

Pattern matching is not inherently consuming.

For every field binding, analysis records one of:

- copy the field;
- borrow the field;
- move the field out of a consumed aggregate;
- share/retain the field.

A borrowed field cannot escape its owner's lifetime. A moved field is valid only when the aggregate is consumed or the representation supports a safe take operation.

---

## 5. Control Flow

The checker propagates ownership state through the control-flow graph.

At a continuing join:

| Incoming states | Result |
|---|---|
| available + available | available, using the least precise safe state |
| consumed + consumed | consumed |
| consumed + available | ownership error |
| returned + available | available on the continuing path |
| unique + shared | shared |
| known + unknown | unknown for non-copy values |

Loops require a stable ownership state at the back edge. A loop iteration cannot conditionally consume a value needed by the next iteration.

---

## 6. Borrows

Borrows are read-only, temporary, and non-owning.

Initial restrictions:

- no general lifetime parameters;
- no returning a borrowed view unless copied, retained, or moved safely;
- no borrowed data in escaping closures;
- no storing a borrow into a longer-lived aggregate;
- no consuming a value while an overlapping borrow is live.

Multiple immutable borrows may be accepted when their lifetimes and non-retention are proven. This is distinct from creating multiple owners.

---

## 7. Closures

For each capture, the checker records:

```text
CaptureMode = borrow | consume | share | copy
```

Non-escaping closures may borrow. Escaping closures must own or share non-copy captures. Capture modes become explicit closure-environment metadata before LIR lowering.

---

## 8. Diagnostics

Errors must report the ownership story, not only a use count:

- where ownership transferred;
- where a later use conflicts;
- which branch caused disagreement;
- where a borrow escaped;
- why a closure required retention.

The checker should suggest borrowing, consuming later, explicitly cloning/sharing, or restructuring control flow only when that repair is semantically valid.

---

## 9. Output Contract

The checker annotates typed HIR with:

```text
ValueState = unique | shared | immortal | unknown
UseMode    = borrow | consume | share | copy
```

LIR receives these decisions. It does not infer them from AST syntax, pointer values, or runtime tags.

---

## 10. Initial Verification Cases

The minimum suite includes:

- repeated sequential borrows;
- consume followed by use;
- consume on only one continuing branch;
- consume on a returning branch;
- borrowed and moved pattern fields;
- non-escaping borrowed closure capture;
- escaping owned/shared closure capture;
- loop back-edge state agreement;
- copy values used freely;
- unknown ownership falling back to safe sharing.

---

*Linearity tells Kō where uniqueness is proven. The broader ownership model decides how that proof becomes borrowing, transfer, sharing, reference counting, or reuse.*
