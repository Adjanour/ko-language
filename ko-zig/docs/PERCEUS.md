# Perceus RC — Implementable Specification for Kō

Distilled from **"Perceus: Garbage Free Reference Counting with Reuse"** (Reinking, Xie, de Moura, Leijen — PLDI'21) and its extended tech report **MSR-TR-2020-42**. Local copies: `/tmp/perceus/perceus-{pldi21,tr}.{pdf,txt}`.

This is the implementation spec for Phase 7 (hir_rc). `docs/RESEARCH.md` §3.1.1 has the high-level motivation; this document has the algorithm.

---

## 1. Where Perceus runs: HIR, not LIR

The paper's algorithm is **syntax-directed over a functional core calculus** (λ₁: `val x = e₁; e₂`, structural `match`, closures) with *explicit control flow* (all effects compiled to data flow). That is exactly Kō's **HIR** (ANF + structural match) — not the CFG-based LIR.

Two consequences:

1. **RC insertion, drop specialization, and reuse analysis are HIR passes** (`src/hir_rc.zig`), run *last* in the HIR pipeline (after fold/DCE/inline), so no dead code receives RC ops.
2. **LIR's job is transport**: HIR emits explicit `dup` / `drop` / `drop_reuse` / `Ctor@ru` nodes; `lir_lower` maps them 1:1 to LIR `incref` / `decref` / `is_unique` (already in `lir.zig`) plus `drop_reuse` / `alloc_reuse` (added in 7c); `codegen_lir` lowers them to runtime calls. The original plan (liveness-driven insertion on the LIR CFG) is abandoned: on a CFG, branch-level drops and pattern↔constructor reuse pairing must be reconstructed via dataflow after match compilation has scattered the branches — strictly harder for no benefit.

## 2. The pipeline (paper Figure 1, `map` example)

Seven transformations. Input: HIR. Output: HIR with explicit RC + reuse.

```
(a) source              match(xs) { Cons(x,xx) -> Cons(f(x), map(xx,f)) ; Nil -> Nil }

(b) dup/drop insertion  Cons: dup(x); dup(xx); drop(xs); Cons(dup(f)(x), map(xx,f))
    (§2.2, Fig. 8)      Nil:  drop(xs); drop(f); Nil

(c) drop specialization Cons: dup(x); dup(xx);
    (§2.3)                  if is-unique(xs) then { drop(x); drop(xx); free(xs) }
                            else decref(xs)
(d) dup push-down       Cons: if is-unique(xs) then free(xs)
    + dup/drop fusion           else { dup(x); dup(xx); decref(xs) }

(e) reuse token insert  Cons: val ru = drop-reuse(xs); Cons@ru(dup(f)(x), map(xx,f))
(f) drop-reuse spec.    Cons: val ru = if is-unique(xs) then { drop(x); drop(xx); &xs }
    (§2.4)                            else { decref(xs); NULL }
(g) push-down + fusion  Cons: val ru = if is-unique(xs) then &xs
                                        else { dup(x); dup(xx); decref(xs); NULL }
```

After (g) the fast path has **zero RC ops and zero alloc/free** — the matched cell is overwritten in place. This is FBIP: functional but in-place.

## 3. Insertion algorithm (paper Figure 8 — implement this)

Judgement `Δ | Γ ⊢s e ⇝ e′`: translate `e` to `e′` under **borrowed** env `Δ` and **owned** env `Γ` (both multisets of variables).

Invariants (maintain by construction):
1. `Δ ∩ Γ = ∅`
2. `Γ ⊆ fv(e)`
3. `fv(e) ⊆ Δ ∪ Γ`
4. multiplicity of each member of `Δ`, `Γ` is 1

| Rule | Shape | Action |
|------|-------|--------|
| `svar` | `Δ | x ⊢s x` | owned var consumed directly |
| `svar-dup` | `Δ, x | ∅ ⊢s x` | borrowed var → `dup x; x` |
| `sapp` | `Δ | Γ ⊢s e₁ e₂` | split deterministically: `Γ₂ = Γ ∩ fv(e₂)` goes to `e₂`, rest to `e₁` — **dups pushed to leaves (as late as possible)** |
| `slam` / `slam-d` | `λx. e` | closure owns exactly `fv(λx.e)`; borrowed frees `Δ₁ = ys − Γ` get `dup Δ₁` at closure creation; unused param → `drop x` at body start |
| `sbind` / `sbind-d` | `val x = e₁; e₂` | `x ∈ fv(e₂)`: normal; `x ∉ fv(e₂)`: `drop x` immediately after binding |
| `smatch` | `match x { pᵢ → eᵢ }` | per branch: owned set `Γᵢ = (Γ, bv(pᵢ)) ∩ fv(eᵢ)`; **drop all other owned vars `Γᵢ′ = (Γ, bv(pᵢ)) − Γᵢ` at branch start** — this is what makes drops *early* |
| `scon` | `C v₁ … vₙ` | split `Γ` across fields right-to-left: `Γᵢ = (Γ − Γᵢ₊₁ − …) ∩ fv(vᵢ)` |

Design principles: *dup as late as possible; drop as early as possible (right after a binding / at branch start).*

Kō v1 simplification: **all function parameters owned** (callee drops). Borrowed-parameter inference (Lean's "Counting Immutable Beans" extension) is a later optimization; `svar-dup` already covers borrows once introduced.

## 4. Runtime primitives → Kō runtime mapping

| Perceus | Semantics | Kō v1 lowering |
|---------|-----------|----------------|
| `dup(x)` | incref; **returns x** (usable as expression) | `ko_incref` (already returns the ptr ✓) |
| `drop(x)` | `if is-unique(x) { drop children; free(x) } else decref(x)` | drop specialization emits the branch; fallback `ko_decref` |
| `is-unique(x)` | `rc(x) == 1` | **inlined**: `load i64 (gep i8 x, -8) == 1` (RC header is 8 bytes before the user ptr — see `stdlib_codegen.codegenKoAlloc`; `codegen_lir.codegenIsUnique` already emits this) |
| `drop-reuse(x)` | `if is-unique(x) { drop children; &x } else { decref(x); NULL }` | 7c: new LIR `drop_reuse` op + `ko_drop_reuse` runtime fn |
| `C@ru(v…)` | `if ru ≠ NULL { ru->fᵢ := vᵢ; ru } else malloc-C(v…)` | 7c: new LIR `alloc_reuse` op (reuse token or fresh `ko_alloc`) |

Fast-path shape (paper §2.7.2): one inlined test `if (rc <= 1) slow_path else rc--` covers both free-needed and (future) thread-shared cases. Thread-shared objects get *negative* RCs (sticky at 2³⁰) — Kō is single-threaded in v1; the `rc <= 1` test shape keeps the door open.

## 5. Specialization passes

**Drop specialization (7b).** After insertion, inline `drop(x)` at sites where the constructor is statically known (match branches): specialize on the constructor; only specialize *if the children are used* in the branch (never in branches like `Nil`). Then push `dup`s down into branches and apply **dup/drop fusion** (cancel adjacent `dup(x); …; drop(x)` pairs). Result: fast path does no RC at all when the scrutinee is unique.

**Reuse analysis (7c).** Pair each matched constructor with a same-size-class constructor allocation *in the same branch* (`Cons(x,xx) -> Cons(…)`). Replace `drop(xs)` with `val ru = drop-reuse(xs)` and the allocation with `Cons@ru(…)`. On HIR this pairing is syntactic — do it before match compilation moves to LIR.

**Reuse specialization (7c).** Only emit `C@ru` when **≥1 field stays unchanged** between pattern and allocation (red-black tree case: reuse node, assign only the changed child). If all fields are overwritten (like `map`), plain `alloc_reuse` already wins — skip field-wise specialization.

## 6. Kō implementation phases

- **7a — `src/hir_rc.zig`: insertion (Figure 8).** New HIR node kinds: `dup`, `drop`. Pass runs last in the HIR pipeline. Golden tests: exact-placement assertions against hand-derived examples (the `map` pipeline above is the reference derivation).
- **7b — drop specialization + dup push-down/fusion.** HIR→HIR rewrite implementing §2.3. Tests: `map` fast path contains no `dup`/`drop` under `is-unique`.
- **7c — reuse analysis + LIR/runtime support.** HIR: `drop_reuse` node, `ConstructorExpr.reuse: ?LocalVarId`. LIR: `drop_reuse: LocalId`, `alloc_reuse: { token: LocalId, ty: LirType }` ops. Runtime: `ko_drop_reuse`. Milestone (unchanged): `List.map` in a tight loop → zero alloc/free per iteration, verified by memory tracing.

## 7. Test strategy

1. **Golden derivations** — hand-derive Figure-8 translations for small HIR programs; assert exact dup/drop placement (incl. `smatch` branch-start drops and `sbind-d` unused-binding drops).
2. **Memory tracing** — count `ko_alloc`/`ko_decref` calls at runtime (JIT); reuse tests assert the count drops to zero per loop iteration.
3. **Leak freedom** — debug allocator / allocation counting on every runtime test through the new path.
4. **Differential** — same program output through legacy AST→LLVM and HIR→LIR→LLVM paths for all `.ko` test files.

## 8. Caveats and non-goals (v1)

- **Cycles**: Kō is immutable + inductive types (same as Koka) — no cycles from data. Explicit `ref` cells can create cycles in principle; accepted limitation (same as Koka), no cycle collector in v1.
- **Concurrency**: negative-RC / atomic ops deferred (single-threaded runtime).
- **Exceptions/control effects**: Kō has none — control flow is already explicit, which is *why* Perceus applies cleanly.
- **Benchmark expectation** (paper §4): "no-opt" Koka is >2× slower than optimized on rbtree — the specializations (7b/7c), not the baseline insertion (7a), deliver the performance.
