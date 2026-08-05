# Perceus Analysis: Dup/Drop Insertion for Kō's Map

> **Status:** Analysis Document
> **Date:** 2026-08-02
> **Depends on:** SPEC-0.md, DESIGN-linear-types.md, DESIGN-polymorphism.md

---

## 1. What Perceus Actually Does

Strip the formalism: Koka compiles to C with **explicit reference counting instructions** (`dup`/`drop`) inserted at exact points determined by static analysis. Then runs three optimization passes:

1. **Drop specialization**: If the compiler can prove `rc == 1` at a `drop`, the decrement is dead code — deleted.
2. **Reuse analysis**: If a constructor is being allocated while the old value of the same type is being dropped (and `rc == 1`), the old memory can be reused — in-place mutation.
3. **Reuse specialization**: Eliminates field updates when the old and new values are identical.

The result: on the fast path (single-owner, tree-shaped), **zero allocation, zero reference counting, in-place mutation** — achieved through RC with static elision, not through linear types.

---

## 2. The Application Rule's Borrowing Trick

This is the key insight from Perceus that changes Kō's design:

In the linear calculus, the application rule splits `Γ` into `Γ₁` and `Γ₂`:

```
Γ₁ ⊢ e₁ : τ₁ → τ₂    Γ₂ ⊢ e₂ : τ₁
───────────────────────────────────────
        Γ₁ ⊕ Γ₂ ⊢ e₁ e₂ : τ₂
```

Since `Γ₂` is consumed by `e₂`, the compiler knows those resources are **alive** when deriving `e₁`. Therefore `e₁` can **borrow** `Γ₂` for free — no explicit borrow syntax needed.

**What this means for Kō:** The borrow type `&τ` that we reserved as a Phase 2 stub? Perceus gets a limited form of it **for free** from the existing split rule. No new syntax. No new typing rule. The compiler just knows that `Γ₂` is available during `e₁`'s evaluation.

---

## 3. Concrete Example: `map`

### Source

```ko
fn map (f : a -> b) (xs : List a) -> List b =
  match xs
    Cons h t -> Cons (f h) (map f t)
    Nil -> Nil
```

### Step 1: Dup/Drop Insertion

The compiler walks the AST and inserts `dup(x)` at every use of `x` except the last, and `dec(x)` at the last use.

**Analysis for the Cons arm:**

```
Cons (f h) (map f t)
```

- `f` is used twice: in `f h` and in `map f t` → `dup(f)` before first use
- `h` is used once: in `f h` → no dup needed, `dec(h)` after (but h is consumed by f)
- `t` is used once: in `map f t` → no dup needed, `dec(t)` after (but t is consumed by map)
- `xs` is consumed by match → `dec(xs)` after match (but xs is consumed by Cons)

**After dup/drop insertion:**

```c
// Cons arm
dup(f);                          // f is used twice
let h1 = proj_0(xs);            // extract head
let t1 = proj_1(xs);            // extract tail
dec(xs);                         // xs consumed by match
let r1 = f(h1);                 // f h — f consumed here
let r2 = map(f, t1);            // map f t — f and t1 consumed
let result = ctor_Cons(r1, r2); // build new Cons
dec(f);                          // f's last use
ret(result);
```

### Step 2: Drop Specialization

The compiler analyzes reference counts at each `dec`:

- `dec(xs)`: `xs` was the sole reference (it came from the match scrutinee). `rc(xs) == 1` → **drop eliminated**.
- `dec(f)`: `f` was `dup`'d, so `rc(f)` might be > 1. But after `map(f, t1)`, `f` is consumed. The `dup(f)` at the start means `rc(f)` was 2. After `f(h1)`, `rc(f)` is 1. After `map(f, t1)`, `f` is consumed. The `dec(f)` at the end has `rc(f) == 1` → **drop eliminated**.

**After drop specialization:**

```c
// Cons arm (optimized)
dup(f);
let h1 = proj_0(xs);
let t1 = proj_1(xs);
// dec(xs) eliminated — rc was 1
let r1 = f(h1);
let r2 = map(f, t1);
let result = ctor_Cons(r1, r2);
// dec(f) eliminated — rc was 1
ret(result);
```

### Step 3: Reuse Analysis

The compiler looks for patterns:

```
let result = ctor_Cons(r1, r2);  // allocate new Cons
// ... then drop old Cons (xs)
```

Since `rc(xs) == 1` (proved in Step 2), the old `xs` memory can be **reused** for `result`:

```c
// Cons arm (reuse)
dup(f);
let h1 = proj_0(xs);
let t1 = proj_1(xs);
let r1 = f(h1);
let r2 = map(f, t1);
// Reuse xs's memory for result
set(xs, 0, r1);     // set head field
set(xs, 1, r2);     // set tail field
ret(xs);             // return reused node
```

### Step 4: Final Optimized Code

```c
fn map(f, xs):
  loop:
    case xs of
      Cons(h, t):
        dup(f);
        let r1 = f(h);
        let r2 = map(f, t);
        // In-place mutation — no allocation
        set(xs, 0, r1);
        set(xs, 1, r2);
        ret(xs);
      Nil:
        ret(Nil);
```

**No allocation. No reference counting. In-place mutation.** Same result as linear types, achieved through RC with static elision.

---

## 4. Comparison: Linear Types vs Perceus

### For `map` (tree-shaped, single-owner)

| Aspect | Linear Types | Perceus |
|--------|-------------|---------|
| RC operations | None (compiler proves single-owner) | Inserted, then deleted by optimization |
| Allocation | None (compiler reuses memory) | None (reuse analysis reuses memory) |
| Mutation | In-place (compiler proven safe) | In-place (rc==1 check at runtime, or proven at compile time) |
| Result | Tight loop, zero overhead | Tight loop, zero overhead |

**Same generated code. Different path to get there.**

### For shared data (graph-shaped)

| Aspect | Linear Types (Rc<T>) | Perceus |
|--------|---------------------|---------|
| Sharing mechanism | Explicit `Rc` type, manual | Automatic, `rc > 1` |
| RC operations | Explicit increment/decrement | Automatic, inserted by compiler |
| Programmer burden | Must choose `Rc` up front | None — sharing is native |
| Performance | RC overhead (visible in types) | RC overhead (invisible, but present) |

**Perceus is strictly better here.** Sharing is native, not an escape hatch.

### For borrowing (read without consuming)

| Aspect | Linear Types (Phase 2 `&τ`) | Perceus |
|--------|---------------------------|---------|
| Syntax | `&e` (explicit) | None (free from application rule) |
| Mechanism | Separate typing rule | Context split in application rule |
| Scope | Lexically scoped | Lexically scoped |

**Perceus gets borrowing for free.** No new syntax needed.

---

## 5. What This Means for Kō

### The Honest Assessment

The "compile-time proof vs runtime check" dichotomy **nearly disappears at the generated-code level** if the elision passes are good enough. Both approaches converge on:
- In-place mutation for tree-shaped data
- Zero runtime bookkeeping on the fast path
- RC overhead for shared data

### Where Perceus Wins

1. **Sharing is native**: No `Rc<T>` bolt-on. Sharing is just `rc > 1`.
2. **Borrowing is free**: No `&τ` syntax needed. The application rule gives it for free.
3. **Simpler mental model**: No linear/unrestricted distinction. No ownership tracking. Just "the compiler optimizes RC."
4. **Proven benchmarks**: Koka achieves "within 10% of C" on real workloads (rbtree benchmark).

### Where Linear Types Win

1. **No runtime**: No RC fields, no dup/drop instructions, no `isShared` checks. The proof is static.
2. **Bare metal**: No allocator dependency for RC. Linear values need no runtime support.
3. **Predictability**: No "the optimizer might miss this." The type system guarantees it.
4. **Smaller binaries**: No RC code generated for linear values.

### The Decision for Kō

**The question is not "which is better in theory?" but "which is better for Kō's goals?"**

Kō's goals:
1. Functional by default ✓ (both)
2. No GC ✓ (both)
3. Small spec ✓ (Perceus is simpler — no linear/unrestricted distinction)
4. C-competitive ✓ (both achieve this)
5. Bare metal ← **This is where they differ**

If Kō wants bare metal / no-libc support, linear types win (no RC runtime needed). If Kō doesn't need bare metal, Perceus is simpler and strictly better for sharing.

---

## 6. The Combined Approach

The analysis shows that linear types and Perceus RC are not mutually exclusive. Kō can combine both:

1. **Linear by default**: Values are consumed after use, no RC needed
2. **Explicit `ref` for sharing**: When sharing is needed, use `ref` (explicit opt-in)
3. **Ownership-aware monomorphization**: The compiler creates specialized versions for each ownership pattern

This gives the best of both worlds:
- Zero-cost for tree-shaped data (linear types)
- Correct RC for shared data (Perceus-style)
- No runtime overhead for either

See DESIGN-polymorphism.md for the full analysis.

### Phase 1 Revised Exit Criterion

1. **Functional test**: CLI example (args → read → split → filter → print), profile against C.
2. **Compile-time test**: Monomorphization on generic program.
3. **Ownership-aware monomorphization test**: Verify that linear and ref versions are generated correctly.
4. **Compare**: Both must be within striking distance of C. If one is significantly better, that's the path forward.

### What This Gives You

- **Hard data** on which approach actually performs better for Kō's use cases
- **No premature commitment** to an approach that might not be the best
- **A clear decision point** at the end of Phase 1, based on numbers, not theory

---

## 7. The Key Insight (One-Sentence Version)

"Perceus shows that reference counting with static elision converges on the same generated code as linear types for tree-shaped data, while being strictly better for shared data — because sharing is native, not an escape hatch. Kō combines both: linear by default, explicit `ref` for sharing, with ownership-aware monomorphization to generate specialized code for each pattern."

---

*This analysis settles the linear vs RC debate: use both, with ownership-aware monomorphization.*
