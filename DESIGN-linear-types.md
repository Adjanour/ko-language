# Kō Linear Types: The Design Center

> **Status:** Design Draft
> **Date:** 2026-08-02
> **Depends on:** VISION.md, DESIGN-memory-runtime.md, DESIGN-polymorphism.md

---

## 1. The Thesis

"Immutable by default" + "no GC" only coexist if the type system proves single-ownership at compile time.

Kō isn't a language project with a memory-management feature. It's a **linear-type-system project with a language attached.** Everything else — the ADTs, the pattern matching, the comptime, the I/O — exists to make linear types ergonomic in practice.

This document defines the ownership model that makes Kō's performance claim honest: zero-cost tree ownership, explicit `ref` for shared data.

---

## 2. The Problem

Today, Kō uses reference counting for all heap data. This works but has three costs:

1. **Hidden overhead**: Every `Cons x rest` increments RC on `x` and `rest`. The programmer can't see it.
2. **No optimization**: The compiler can't eliminate RC because it doesn't know if a value is shared.
3. **Cycles**: RC can't handle cycles. This is a known limitation with no fix.

Linear types solve all three:

1. **Visible ownership**: The type system tracks who owns what. No hidden increments.
2. **Eliminable RC**: If the compiler knows you're the only owner, it eliminates the RC entirely.
3. **Cycles via ref**: Shared data uses explicit `ref` — a separate, clearly-marked kind.

---

## 3. The Rules

### 3.1 Values Are Linear by Default

Every heap-allocated value has exactly one owner. The compiler tracks this.

```ko
let xs = Cons 1 (Cons 2 Nil)   # xs owns the list
let total = sum xs               # xs is consumed — ownership transfers to sum
# xs is gone. The compiler proves it. No RC needed.
```

If you try to use `xs` after consuming it:

```ko
let xs = Cons 1 (Cons 2 Nil)
let total = sum xs
println xs          # ERROR: xs is consumed, cannot use again
```

This is the core guarantee. It's enforced at compile time.

### 3.2 Consumption via Pattern Matching

Pattern matching consumes values. This is the primary consumption mechanism.

```ko
fn sum xs =
  match xs
    Cons x rest -> x + sum rest   # xs consumed, x and rest are new values
    Nil -> 0
```

`Cons x rest` destructures `xs`. After the match, `xs` is gone. `x` and `rest` are new linear values.

### 3.3 Consumption via Function Application

Function arguments are consumed. The caller gives ownership to the callee.

```ko
fn length xs =
  match xs
    Cons _ rest -> 1 + length rest
    Nil -> 0

let n = length myList   # myList is consumed
# myList is gone
```

This is safe because `length` only reads `xs` — it doesn't escape. But the type system doesn't know that. It conservatively assumes all function calls consume.

### 3.4 Rebuild Pattern

To "modify" a linear value, destructure it and reconstruct:

```ko
fn update_name person =
  match person
    Person { name, age } ->
      Person { name = "New " ++ name, age = age }
      # old person consumed, new one built
```

The old `person` is gone. The new `Person` is a fresh allocation. The type system proves the old one was consumed.

### 3.5 Non-Linear Use (ref)

When you need shared access, use `ref`:

```ko
# ref is a linear value that wraps shared data
let shared = ref (Cons 1 (Cons 2 Nil))   # shared owns the RC'd list

let a = !shared    # a borrows the value (RC incremented)
let b = !shared    # b also borrows (RC incremented)

# a and b go out of scope → RC decremented
# When RC reaches 0, memory freed
```

`ref` is **not** a magic escape hatch. It's a separate type with clear semantics:

- `ref expr` creates a shared value (RC = 1)
- `!expr` borrows (RC incremented, decremented when borrow ends)
- `!expr` returns a borrowed reference, not an owned value
- The borrow is temporary — it doesn't outlive the `ref`

### 3.6 What ref Gives You

| Operation | Linear (default) | ref (shared) |
|-----------|-----------------|-------------|
| Create | `Cons 1 Nil` | `ref (Cons 1 Nil)` |
| Read | Direct (owned) | `!x` (dereference) |
| Modify | Rebuild (destructive) | Not allowed (read-only borrow) |
| Destroy | Automatic (scope exit) | RC decrement (when all borrows end) |
| Cost | Zero (no RC) | RC increment/decrement per borrow |
| Cycles | Not possible | Possible (with Weak) |

### 3.7 What ref Does NOT Give You

- **Mutation through ref**: `!x` returns a borrowed, read-only view. To modify, you must `ref` a new value.
- **Escape from ref**: Borrowed values from `!x` don't escape the borrow scope.
- **Zero cost**: RC has overhead. It's explicit and visible, but not zero.

---

## 4. The Type System Rules

### 4.1 Ownership Tracking

The type system tracks ownership through three mechanisms:

1. **Pattern matching**: Consumes the scrutinee, binds new linear values
2. **Function application**: Consumes arguments, produces new values
3. **Let binding**: Binds a name to a linear value (ownership transfers)

```ko
# Let binding: xs owns the list
let xs = Cons 1 Nil

# Pattern match: xs consumed, x and rest are new
match xs
  Cons x rest -> ...
  Nil -> ...

# Function call: xs consumed, result is new
let n = length xs
```

### 4.2 Borrowing (Read-Only Access)

Sometimes you need to read a value without consuming it. Kō supports borrowing via pattern matching:

```ko
# Pattern match that only reads — the value is not consumed
fn first xs =
  match xs
    Cons x _ -> x    # x is extracted, but xs is not consumed
    Nil -> 0
```

Wait — this conflicts with rule 3.2 (pattern matching consumes). We need a distinction.

**The distinction**: A pattern match that extracts values but doesn't consume the scrutinee is a **borrowing match**. The compiler tracks this differently:

- **Consuming match**: `match xs Cons x rest -> ...` — `xs` is consumed
- **Borrowing match**: The same syntax, but the compiler infers whether `xs` is used after the match. If it is, the match is borrowing.

This is **inference**, not syntax. The programmer doesn't annotate "I'm borrowing." The compiler figures it out.

```ko
fn sum_and_length xs =
  match xs
    Cons x rest -> (x + sum_and_length rest, 1 + length rest)
    Nil -> (0, 0)
```

Here, `xs` is used in both arms (`sum_and_length rest` and `length rest`). The compiler infers that the match is borrowing — `xs` is not consumed, `rest` is a borrow of the tail.

### 4.3 The Borrowing Rules

1. A value can be borrowed at most once at a time (no aliasing)
2. A borrow is temporary — it doesn't escape the scope
3. While borrowed, the value cannot be consumed or modified
4. When the borrow ends, the value is available again

These rules are checked at compile time. Violations are type errors.

### 4.4 ref as Escape Hatch

When borrowing isn't enough (you need multiple readers, or the data forms a graph), use `ref`:

```ko
# Tree with parent pointers — needs ref
type Tree a = Node (ref (Tree a)) a (ref (Tree a)) | Leaf

# Create
let leaf = ref Leaf
let tree = Node leaf 42 leaf   # leaf shared between left and right

# Read
match tree
  Node left val right ->
    let l = !left    # borrow left
    let r = !right   # borrow right
    val + tree_value l + tree_value r
```

`ref` is designed into the type system from day one. It's not a stdlib afterthought.

---

## 5. The Codegen Strategy

### 5.1 Linear Values: Zero-Cost

For linear values, the compiler eliminates RC:

```ko
# Source
let xs = Cons 1 (Cons 2 Nil)
let total = sum xs

# Generated code (after optimization):
# No RC increments. No RC decrements. The list is stack-allocated or inlined.
# sum consumes xs, and the compiler reuses the memory directly.
```

How:
1. The type checker marks `xs` as linear
2. The code generator sees `xs` is consumed by `sum`
3. No RC operations are generated
4. LLVM optimizes: stack allocation, inlining, dead code elimination

### 5.2 ref Values: Explicit RC

For `ref` values, the compiler generates RC operations:

```ko
# Source
let shared = ref (Cons 1 Nil)
let a = !shared
let b = !shared

# Generated code:
shared_ptr = ko_alloc(sizeof(RcHeader) + sizeof(Cons))
shared_ptr.rc = 1

a_ptr = shared_ptr         # borrow (no RC increment — a is a borrow, not an owned copy)
b_ptr = shared_ptr         # borrow (same)

# At scope end:
# a and b are borrows — no decrement
# shared_ptr.rc decremented when shared goes out of scope
```

The key insight: `!x` returns a **borrow**, not an **owned copy**. No RC increment for borrows. RC only increments on `ref` and when a value is stored in a parent structure (consumed by a constructor).

### 5.3 The Codegen Checklist

| Value kind | Allocation | RC ops | Optimization |
|-----------|-----------|--------|-------------|
| Linear (tree) | Stack/inline | None | Full (LLVM eliminates) |
| Linear (heap) | `ko_alloc` | None | Full |
| ref (shared) | `ko_alloc` | Increment/decrement | None (explicit) |
| ref (borrowed) | None (pointer) | None | None |

---

## 6. Ownership-Aware Monomorphization

### 6.1 The Innovation

Instead of monomorphizing only for types, Kō monomorphizes for **ownership patterns**. Functions that consume their arguments differently get different specializations.

This is unique to Kō — no other language does ownership-aware monomorphization.

### 6.2 How It Works

Given:
```ko
pub fn process (x : List Int) : Int = match xs
  | Cons x rest -> x + process rest
  | Nil -> 0
```

After ownership-aware monomorphization:
```ko
# Linear version (x is consumed, no RC)
fn process__linear (x : List Int) : Int = match xs
  | Cons x rest -> x + process__linear rest
  | Nil -> 0

# ref version (x is shared, RC overhead)
fn process__ref (x : ref (List Int)) : Int = match !x
  | Cons x rest -> x + process__ref (ref rest)
  | Nil -> 0
```

The caller chooses which version to call based on whether they own or share the data.

### 6.3 When It Helps

**Tree-shaped data (linear wins):**
```ko
let xs = Cons 1 (Cons 2 Nil)  # linear, no RC
let total = process xs          # calls process__linear, zero-cost
```

**Shared data (ref wins):**
```ko
let xs = Cons 1 (Cons 2 Nil)
let shared = ref xs             # ref, explicit
let total = process shared      # calls process__ref, RC overhead
```

### 6.4 The Tradeoff

Ownership-aware monomorphization increases compile time and binary size (more specializations). But it gives:
- Zero-cost for tree-shaped data (the common case)
- Correct RC for shared data (the uncommon case)
- No runtime overhead for either

See DESIGN-polymorphism.md for the full analysis.

---

## 7. The Spec Growth

### 6.1 Current Spec Size

The current spec is small — a few dozen pages. It covers:
- Lexical structure
- Expressions
- Types
- Pattern matching
- ADTs
- Modules

### 6.2 What Linear Types Add

Linear types add:
- Ownership rules (who owns what, when)
- Borrowing rules (when can you read without owning)
- ref rules (when to use ref, how borrows work)
- Consumption analysis (which matches consume, which borrow)
- The rebuild pattern (destructure → modify → reconstruct)

This adds approximately 20-30 pages to the spec. Total: ~50 pages.

### 6.3 The Trade

**Old promise**: "Learnable in a day."
**New promise**: "Learnable in a weekend."

This is the explicit trade: we sacrifice "a day" to get "weekend" in exchange for zero-cost tree ownership. The core language is still small. The complexity is in the ownership rules, not in features.

**Austral comparison**: Austral's spec is ~50 pages. Kō's spec will be similar. Austral is known as the smallest linear-types language. Kō aims to match that.

---

## 8. The Honest Boundary

### 7.1 Tree-Shaped Ownership (Zero-Cost)

```ko
# Linked list — linear, zero-cost
fn sum_list xs =
  match xs
    Cons x rest -> x + sum_list rest
    Nil -> 0

# Binary tree — linear, zero-cost
fn tree_sum tree =
  match tree
    Leaf -> 0
    Node left val right -> tree_sum left + val + tree_sum right
```

For these patterns: **within 10% of C.** No asterisk.

The compiler eliminates RC. The data is stack-allocated or inlined. LLVM optimizes aggressively.

### 7.2 Graph-Shaped Ownership (RC Overhead)

```ko
# Graph with shared nodes — ref, not zero-cost
type Graph a = Node (List (ref (Graph a))) a

# Shared cache — ref, not zero-cost
let cache = ref (Map.empty)
let a = !cache
let b = !cache
```

For these patterns: **still fast, but not zero-cost.** The overhead is RC increment/decrement per borrow.

### 7.3 The Marketing Statement

"Kō is within 10% of C for tree-shaped programs. For shared/graph data, it uses explicit reference counting — still fast, still predictable, but not zero-cost."

This is true, honest, and marketable. Underselling now costs nothing. Overselling costs credibility the first time someone benchmarks a graph traversal.

---

## 9. Implementation Roadmap

### Phase 1: Type System (v0.3.0)

**Goal:** Linear type checker. Prove or disprove the thesis.

1. **Ownership tracking**: Extend the typechecker to track linear values
2. **Consumption analysis**: Determine which matches consume, which borrow
3. **Borrow checking**: Ensure borrows don't escape, don't alias
4. **ref type**: Implement `ref` as a built-in type with `ref`/`!`
5. **Error messages**: "Value consumed here, used here" / "Borrow conflicts with..."

**Verification**: Write test programs that exercise linear patterns. The compiler must reject invalid programs and accept valid ones.

### Phase 2: Codegen (v0.3.0)

**Goal:** Linear values get zero-cost codegen.

1. **No RC for linear values**: Track linear values in codegen, skip RC ops
2. **RC for Rc values**: Generate increment/decrement for Rc operations
3. **Stack allocation**: Linear values that fit on stack → no heap allocation
4. **LLVM optimization**: Let LLVM eliminate dead RC ops, inline functions, etc.

**Verification**: Compare generated IR for linear vs Rc programs. Linear programs must have zero RC operations.

### Phase 3: Stdlib (v0.4.0)

**Goal:** Stdlib uses linear types. Array, Map, String all have linear ownership.

1. **Array**: Linear by default. `Array.get` returns a borrow. `Array.set` consumes and rebuilds.
2. **Map**: Linear by default. `Map.get` returns a borrow. `Map.set` consumes and rebuilds.
3. **String**: Linear by default. `String.append` consumes and rebuilds.
4. **ref**: First-class in stdlib. `ref`, `!`, `ref_mut` (for unique access).

### Phase 4: Polish (v0.5.0)

**Goal:** Ergonomic linear types.

1. **Inference improvements**: Better borrowing inference for common patterns
2. **Error messages**: Clear, actionable error messages for ownership violations
3. **Documentation**: Examples, tutorials, migration guide from RC to linear
4. **Performance benchmarks**: Prove the "10% of C" claim with real programs

### Phase 1 Exit Criterion (Go/No-Go)

1. **Functional test:** Compile the CLI example (args → read file → split lines → filter → print), run it, and profile it against a handwritten C equivalent. If the naive "no refcount, no GC" in-place-mutation scheme is within striking distance of C on a tree-shaped workload (a few times slower is fine at this stage, orders-of-magnitude is not), the thesis holds and you proceed. If it's orders of magnitude off, stop and figure out why before writing another line.

2. **Compile-time test:** Compile a moderately generic program (the CLI example, but with `map`/`filter` used at 3-4 different concrete types). If monomorphization makes a trivial CLI tool take multiple seconds to compile, that's a signal worth catching in Phase 1, not after the stdlib is built on top of it.

3. **Dual implementation test:** Implement the tree insertion benchmark under both:
   - (a) Linear types (current design — compile-time proof, no RC)
   - (b) Perceus-style RC with static elision (runtime RC, optimized away)
   
   Both must be within striking distance of C. If one is significantly better, that's the path forward. If they're comparable, linear types win on the "no runtime" claim. If Perceus is significantly better, reconsider the approach.

If any test fails, stop. Don't paper over it with "we'll optimize later."

---

## 10. The Sequencing (Corrected)

The previous roadmap listed goals that looked parallel but are actually sequential.

**Phase 1 (v0.3.0-v0.4.0)**: Prove the thesis — linear types on Linux/x86-64. This is the existential risk. If linear types don't work for Kō's use cases, nothing else matters.

**Phase 2 (v0.5.0)**: Widen the platform — macOS, Windows, cross-compilation. This is backend labor. Any competent systems team can do it once the frontend is right.

**Phase 3 (v1.0.0)**: Ecosystem — package manager, self-hosting, docs. This depends on the language being stable.

Do not parallelize these. Phase 1 proves the type system works. Phase 2 widens it. Phase 3 builds on it.

---

## 11. What This Means for the Existing Code

### The Current RC System

The current `ko_incref`/`ko_decref` system works but is unoptimized:
- Every heap allocation gets RC
- RC is incremented on every store to a parent
- RC is decremented on scope exit
- No cycle detection

### The Transition

Linear types don't replace RC — they **eliminate it** for linear values:

- Linear values: No RC at all. The compiler proves they're single-owner.
- ref values: Explicit RC. The programmer chooses ref when sharing is needed.

The existing RC system becomes the fallback for ref values only. Linear values get zero-cost.

### Migration

Existing programs that use only linear patterns (most programs) will see zero RC operations after the transition. Programs that need sharing will use ref explicitly.

No breaking changes. The syntax is the same. The types are the same. The only change is the compiler's analysis: it now knows which values are linear and eliminates RC for them.

---

## 12. The Vision

Kō's vision is: **functional pragmatism + mechanical sympathy.**

Linear types are the mechanism that makes this vision real:

- **Functional pragmatism**: Immutable data, pattern matching, ADTs — but with zero-cost ownership.
- **Mechanical sympathy**: The compiler knows who owns what, and eliminates overhead.

The vision isn't "linear types as a feature." The vision is "linear types as the design center." Everything else is implementation.

---

*The future is bright. Linear types and functional pragmatism aren't at odds. We just have to find where we can take our wins and hammer down.*
