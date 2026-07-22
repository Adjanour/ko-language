# Kō Compiler — Research & Emergent Capabilities

Research conducted July 2026. Primary sources: Rustc dev-guide, Swift SIL docs, GHC commentary, OCaml Flambda2 publications, Lisp Machine architecture specs, Mesa/Cedar papers, Deutsch-Schiffman Smalltalk.

---

## 1. Modern Compilers: What They Do and Why

### 1.1 Rust — HIR → THIR → MIR → LLVM

Rust's pipeline: AST → HIR → THIR → MIR → LLVM IR.

Three IRs, each with a specific purpose:

| IR | Purpose | Key property |
|----|---------|-------------|
| **HIR** | Desugared AST, ready for type checking | Close to source, loops/`for` desugared |
| **THIR** | Typed-HIR, after type checking | Fully typed, implicit derefs explicit, method calls resolved |
| **MIR** | Control-flow graph, borrow checking, optimization | Basic blocks, no nested expressions, all types explicit, CFG form |

**Key techniques:**

- **MIR is generic.** Optimizations run before monomorphization, catching patterns that would be invisible after. Example: `simplify_try` pattern (`?` operator lowering) is visible in MIR but opaque in LLVM IR.
- **Query system for incremental compilation.** Every MIR pass is a query. Results cached on disk. Only recompiles changed dependencies. Cache key = source hash + dependency hashes.
- **Stealing for memory efficiency.** Intermediate MIR is `Steal<Body>` — stolen by the next phase, cloned only when needed. Panics if you access stolen data.
- **MIR passes are composable.** ~40 passes in `mir_drops_elaborated_and_const_checked` and `optimized_mir`. Each implements `MirPass` trait. Added/removed independently.

**Relevant to Kō:**

- HIR → LIR pipeline concept (we need this)
- Generic MIR optimizations before monomorphization (we'll have generics in v0.4)
- The composable pass approach

### 1.2 GHC — Core → STG → Cmm

GHC's pipeline: Haskell → Core → STG → Cmm → codegen.

| IR | Purpose |
|----|---------|
| **Core** (System FC) | Typed lambda calculus. All Haskell desugars to this. All optimizations happen here. |
| **STG** | ANF form. Explicit allocation (let = allocate). Explicit evaluation (case = evaluate). |
| **Cmm** | Low-level imperative language with explicit stack. Three backends: C, NCG, LLVM. |

**Key technique: Core is typed.**

GHC's Core is System FC — an explicitly typed lambda calculus. Every binder has a type, every transformation must maintain type correctness. The Core type checker (`Lint`) runs as a consistency check on the compiler itself. This has been a *huge win*:

1. Catches optimization bugs (treating Int as function → Lint rejects)
2. Sanity check for new features (if it desugars to Core, it's syntactic sugar; if it needs Core extension, think harder)
3. Independent audit of the type inference engine

**Key technique: The Simplifier.**

GHC's main optimization engine is a single pass (the Simplifier) run repeatedly to fixpoint. It applies ~20 transformations in a unified framework: inlining, beta reduction, let-floating, case-of-known-constructor, case-of-case, etc. The Simplifier is simpler than many individual optimization passes because transformations compose through the same IR.

**Key technique: Strictness analysis + worker/wrapper.**

GHC identifies strict functions and generates a *worker* (unboxed types, tight loop) + *wrapper* (normal type interface). The worker uses unboxed `Int#` instead of boxed `Int`, eliminating thunk allocation for strict computations. This is how Haskell gets C-like performance for numeric code.

**Key technique: Rewrite rules (`{-# RULES #-}`).**

Library authors annotate functions with rewrite rules:
```haskell
{-# RULES "map/map" forall f g xs. map f (map g xs) = map (f.g) xs #-}
```
The simplifier applies these during optimization. This lets library authors extend GHC with domain-specific optimizations without changing the compiler.

**Relevant to Kō:**

- Core being typed is a compelling argument for Kō's HIR to be typed. It catches bugs and enables a `lint` pass.
- The simplifier model (one pass, many transformations, run to fixpoint) is simpler than N independent passes.
- Rewrite rules for stdlib — Kō's `List.map` could have fusion rules.
- Strictness analysis is less critical for Kō (eager by default, no thunks), but the same technique applies to unboxing.

### 1.3 Swift — SIL: SSA with Language Semantics

Swift's pipeline: AST → SILGen → Raw SIL → [mandatory passes] → Canonical SIL → [optimization passes] → IRGen → LLVM IR.

**Key insight: SIL is SSA-form but retains high-level language info.**

LLVM IR loses: type parameters (generics), class hierarchies, protocol conformances, reference counting semantics, array bounds semantics. SIL keeps all of this.

Loss of this info means LLVM can't optimize generics, devirtualize, or remove redundant RC operations. Swift's optimizer fills this gap.

**Key technique: Mandatory passes → optimization passes (two phases).**

- **Mandatory passes** (always run, even at `-Onone`): Mandatory inlining (transparent functions), memory promotion (box→stack, stack→SSA), constant folding + overflow diagnostics, return analysis, definitive initialization, critical edge splitting. These produce *canonical SIL* — the baseline.
- **Optimization passes** (optional, `-O`): Generic specialization, devirtualization, performance inlining, ARC optimization, memory promotion, high-level domain-specific optimizations (Array, String).

**Key technique: ARC optimization.**

Reference counting is *visible in SIL*. Every `retain`/`release` is an instruction. The optimizer:
1. **Retain sinking**: move retains down (closer to use, shorter lifetime)
2. **Release hoisting**: move releases up (earlier deallocation)
3. **ARC sequence optimization**: remove retain/release pairs that cancel
4. **Eliminate retains preceding program termination points**: leaking at end of program is fine

This is a critical precedent for Kō. Kō's RC operations are *already visible in LLVM IR*, but with a HIR/LIR pipeline, they could be optimized at the LIR level before lowering to LLVM.

**Key technique: `@_semantics` annotations for stdlib.**

Swift's standard library annotates functions with semantic tags:
```
@_semantics("array.check_subscript") func checkSubscript(_ index: Int) { ... }
@_semantics("array.get_element") func getElement(_ index: Int) -> Element { ... }
```

The optimizer recognizes these as atomic operations. It can reorder, eliminate, or specialize them. This lets the optimizer understand high-level container semantics without hardcoding them in the compiler.

**Key technique: Generic specialization + devirtualization.**

- **Generic specialization**: If `foo<Int>(x)` is called, generate `foo_int(x)`, monomorphize the body, optimize. This is monomorphization at the SIL level, before LLVM.
- **Devirtualization**: For class methods, look up the actual type, replace indirect `class_method` with direct `function_ref @concrete_func`. Without this, LLVM sees a load+indirect call and can't optimize.

**Relevant to Kō:**

- RC optimization is the single biggest win Kō can adopt from Swift. Move retains/releases, cancel pairs. This is architectural — it requires HIR/LIR so RC operations are explicit.
- `@_semantics` pattern for stdlib. Kō's `List.map` could be annotated as a fold, enabling fusion.
- Two-phase pass pipeline (mandatory + optional) is cleaner than a flat list of passes.

### 1.4 OCaml Flambda2 — CPS as IR

OCaml's pipeline: Lambda → Flambda2 (CPS) → Simplify → Cmm → codegen.

**Key insight: CPS = control-flow graph = named continuations.**

Flambda2 represents the program in CPS (continuation-passing style). Every control point is named. There are no nested expressions — everything is in ANF-like form. The CPS form is *second-class*: continuations are control-flow constructs in the IR, not first-class values.

**Why CPS for functional languages?**

1. **Exceptions are double-barrelled**. Every function has two continuations: normal return and exception. `try/with` and `raise` map directly to continuation calls.
2. **Control flow is explicit**. Inlining, dead code elimination, and code motion all benefit from having named control points.
3. **Tail recursion is natural**. A tail call is just a continuation jump. `loopify` transforms self-tail-calls into local jumps (loops).

**Key technique: Single-pass simplifier (downward + upward).**

The Simplify pass works in three stages:
1. **Downward traversal** (dominator order): Collect information in an abstract domain (type approximations, known values, etc.). Build equations and constraints.
2. **Fixpoint calculations**: Specific optimizations that need iteration (e.g., dependency analysis for dead bindings).
3. **Upward traversal**: Rebuild the term with optimizations applied. Delete dead bindings, inline continuations used once, rewrite primitives.

This is elegant: one pass, lots of optimizations, unified framework.

**Key technique: Separate closure representation.**

In Flambda2, closures are separate from code. `set_of_closures` defines a group of mutually recursive functions with their shared environment. `Project_closure` selects one function from the set. `Project_var` extracts a captured variable from the closure. This separation enables:
- Measuring closure cost during inlining decisions
- Specializing closures (when a captured variable is known)
- Moving within a set of closures (avoiding keeping entire set alive)

**Relevant to Kō:**

- Kō's closure conversion is already a pass in the current compiler (lambda lifting). Flambda2's separate closure representation is a more principled version of the same idea.
- CPS-based IR is overkill for Kō (we don't have first-class control effects). But the downward/upward simplifier pattern is valuable.
- Loopification: Kō's tail-recursive functions could compile to LLVM loops.

---

## 2. Older Compilers: Wisdom Worth Preserving

### 2.1 Lisp Machines: Tagged Architecture

The Lisp Machine (MIT CADR, Symbolics 3600, TI Explorer, etc.) was a processor designed specifically for Lisp. Every word had a type tag (typically 6-8 bits in a 40-bit word).

**Techniques:**

- **Parallel tag checking.** The ALU and tag logic ran in parallel. Type checking was free in the common case — the tag was checked *while* the operation executed. On tag mismatch, a trap fired and the slow path handled it.
- **CDR-coding.** Lists stored in two forms: normal (two-word cons) and compact (contiguous words with CDR-code bits). The CDR-code specified whether the next word was the CDR (cdr-next), the list end (cdr-nil), or a pointer to the CDR (cdr-normal). This halved storage for most lists.
- **Forwarding pointers.** When GC moved an object, the old location held an invisible forwarding pointer. Existing references continued to work. This enabled incremental/relocating GC.

**Relevance to Kō:**
- Tagged sum types in Kō already use a compact representation (tag + payload). This is the same idea as CDR-coding. Extending this: a single-arg `Just` could be a tagged pointer (no heap allocation).
- Zero-arg constructors as raw tag values (already done in Kō). This is the Lisp Machine's unboxed fixnum.

### 2.2 Mesa/Cedar: Interfaces as Contracts

Mesa (late 1970s) pioneered *DEFINITIONS modules* — separate interface specifications with strict type checking across module boundaries.

**Techniques:**

- **Type-safe separate compilation.** The compiler generated a unique timestamp for each interface. Importers and exporters matched timestamps. Mismatches were caught at bind time, not runtime.
- **Binder-level type checking.** The binder (linker) checked interface compatibility, not just the compiler. This prevented version skew from causing subtle bugs.
- **Custom instruction set for code density.** Mesa's Alto instruction set was designed based on empirical entropy analysis of Mesa programs. The instruction set minimized code size, which was more important than speed on small machines.
- **Procedure-oriented model for concurrency.** Mesa adopted monitors and condition variables as the standard concurrency model. This influenced Java, C#, and Go.

**Relevance to Kō:**
- Timestamped interfaces for module versioning. This could prevent Kō's "interface mismatch" bugs.
- Code density is relevant for Kō's AOT binaries. LLVM's `-Os` is a reasonable default.
- Monitors/condition variables could be a concurrency model for Kō (simpler than actors, more structured than raw threads).

### 2.3 Smalltalk-80 (Deutsch-Schiffman): Dynamic Optimization

The Deutsch-Schiffman Smalltalk-80 implementation (1984) was the first "modern" virtual machine. It pioneered techniques that became standard in JIT compilers.

**Techniques:**

- **Dynamic code translation.** v-code (virtual machine bytecode) translated to n-code (native code) on-the-fly, not ahead of time. Translated code was cached.
- **Multiple execution strategies.** Interpreter, simple translator (4× expansion, 1.6× speedup), optimizing translator (5× expansion, 2× speedup). The system could switch between strategies depending on code hotness.
- **Inline caching.** At each message send site, the system cached the last method found. On subsequent calls, checked receiver class against cached class → direct call. Over 90% of sends hit the cache.
- **Dynamic change of representation.** Activation records stored in two forms: machine-oriented (during execution) or Smalltalk object form (when visible to programmer). Transformed between representations as needed.

**Evolution into SELF's adaptive optimization:**

SELF (Urs Hölzle, 1994) extended the Deutsch-Schiffman approach:
- **Polymorphic inline caches (PICs).** For call sites with multiple receiver types, generated a stub with type-case sequence. Also collected concrete type information for the optimizer.
- **Adaptive recompilation.** Fast non-optimizing compiler generated initial code; profiling identified hot spots; optimizing compiler recompiled hot methods. On SPARCstation-2, fewer than 200 pauses exceeded 200ms during 50-minute interaction.
- **Dynamic deoptimization.** Optimized code could be deoptimized back to unoptimized form when optimization invariants were violated (e.g., new class loaded, new receiver type appeared).

**Relevance to Kō:**
- Kō already has JIT and AOT sharing the same frontend. Adding a profiling/inlining tier between JIT and AOT is a natural extension.
- Inline caching is less relevant (Kō has static dispatch). But polymorphic inline caching for dynamic features (if Kō ever gets multimethods or type classes) would follow this pattern.
- The Deutsch-Schiffman lesson: *dynamic translation doesn't have to be slow.* Kō's JIT could cache compiled modules.

---

## 3. Emergent Capabilities from Kō's Design

Kō's specific choices — eager evaluation, reference counting, HM inference without type classes, LLVM backend, HIR/LIR pipeline — create capabilities that don't exist in most languages.

### 3.1 RC Optimization (Like Swift ARC, But Simpler)

Because Kō uses reference counting (not tracing GC), RC operations are explicit in the generated code. Every `ko_alloc`/`ko_incref`/`ko_decref` call is visible.

With a LIR layer, these become LIR instructions:

```
%x = alloc type         # ko_alloc
%x' = incref %x         # ko_incref
decref %x               # ko_decref
```

The optimizer can then:

1. **Eliminate redundant pairs**: `incref x; decref x` → no-op (value not escaping)
2. **Sink retains**: Move `incref` closer to last use (shorter lifetime)
3. **Hoist releases**: Move `decref` closer to allocation (earlier deallocation)
4. **Eliminate retains before program termination**: `incref x; exit()` → `exit()` (leak is fine)
5. **Convert heap→stack**: If a value's lifetime doesn't escape the function, use `alloca` instead of `ko_alloc`

Swift's ARC optimization pass demonstrates that RC optimization is a net win: it eliminates roughly 50-70% of RC operations on average (varies by code).

**Kō advantage vs Swift**: Kō has no class hierarchies, no protocol witnesses, no weakly-held references (yet). The RC graph is simpler, so the analysis is faster and more precise.

---

#### 3.1.1 Perceus: Garbage-Free RC with Reuse Analysis

Perceus (Reinking et al., PLDI 2021) is the algorithm behind Koka's memory management. It starts from a functional core language with *explicit control flow* and emits precise reference counting instructions such that (cycle-free) programs are *garbage free* — only live references are retained. Perceus has four key phases:

**1. Precise RC insertion.** Given a function body with explicit control flow (basic blocks), Perceus inserts `dup` and `drop` operations at every point where a value's reference count changes. A value is `dup`'d when it is used multiple times, and `drop`'d when it goes out of scope. Because control flow is explicit, drops are placed as early as possible (at the last use), not at the end of the scope.

**2. Drop specialization.** After RC insertion, Perceus specializes `drop` operations by constructor. Instead of a generic `drop(x)` that reads the tag and dispatches to field-specific drops, the compiler inlines the drop into each match branch. A `drop` on a `Cons` node becomes:
```
if is-unique(xs) then free(xs)
else { decref(xs.head); decref(xs.tail); free(xs) }
```
Combined with `dup`/`drop` fusion (canceling adjacent `dup`/`drop` pairs), this eliminates almost all RC overhead in the fast path. When `xs` is unique (refcount == 1), the decref chain is entirely bypassed — just `free`.

**3. Reuse analysis (FBIP).** The key innovation: instead of freeing a matched constructor and immediately allocating a new one, Perceus pairs patterns with allocated constructors in each match branch. For `map f (Cons x xs) => Cons (f x) (map f xs)`, the `Cons` pattern is paired with the `Cons` allocation. If the matched object is *not live* (its refcount is 1), the old `Cons` node is reused in-place — no free, no alloc. This is the *functional but in-place* (FBIP) paradigm: purely functional code compiles to in-place mutation when safe.

```
# Reuse analysis pairs patterns to constructors
match xs
  Cons x xs' => Cons@ru (f x) (map f xs')   # reuse token ru from drop-reuse(xs)
```
At runtime: `ru != NULL` → write fields directly into the old node; `ru == NULL` → fall back to fresh allocation.

**4. Reuse specialization.** Even when reuse is possible, not all fields need updating. Reuse specialization tracks which fields of the matched constructor are identical to the output constructor's fields, eliminating redundant writes.

**Why Perceus fits Kō:**

- Kō already has explicit control flow in LLVM IR (basic blocks). The LIR pipeline is a natural place to insert precise RC operations.
- Kō's immutability + RC is the same model Koka uses. Perceus's uniqueness check (is-unique) works because immutable values have no aliasing concerns from mutation.
- FBIP means Kō's `List.map` can compile to a single in-place loop — no allocations, no frees, purely functional source.
- Kō has no effect handlers (unlike Koka), which simplifies the control-flow graph and makes Perceus's analysis easier.

**Relevance to Kō:** Perceus is the most important single technique Kō can adopt. It transforms RC from a cost center into a competitive advantage, enabling functional code that matches or beats imperative C++ on benchmarks like tree insertion (within 10% of `std::map` in Koka's measurements).

### 3.2 Monomorphization Cache for JIT

When generics arrive (v0.4), each generic function instantiation produces a separate compiled version:

```
fn map f xs = ...   # generic

map inc ints        # -> map_inc (specialized for Int)
map show strs       # -> map_show (specialized for String)
```

Without caching, every generic call site re-monomorphizes and re-compiles. With a JIT monomorphization cache:

```
cache[(map_id, [Int])] = compiled_map_inc
cache[(map_id, [String])] = compiled_map_show
```

On cache hit → direct call. On cache miss → monomorphize + compile + cache + call.

This is standard for JIT-compiled generics (e.g., .NET's RyuJIT, Java's C2). But Kō's advantage: the monomorphized functions are *first-class LLVM functions*. They can be optimized across calls, inlined, and LTO'd — unlike JVM bytecode where generics are erased.

**JIT-specific trick**: Lazy monomorphization — don't compile a generic instantiation until it's first called. Large programs can have thousands of generic instantiations, most never used in a given run.

### 3.3 Comptime as Partial Evaluation

Kō's `comptime` evaluates expressions at compile time. With HIR, this becomes more powerful.

Currently, `comptime` evaluates the AST directly (tree-walking interpreter). With HIR:

- HIR nodes carry enough semantic info for safe evaluation
- `comptime` functions are HIR → HIR transformations (partial evaluation)
- The compiler can *specialize* runtime calls using comptime info

Example:
```
comptime fn power n = if n == 0 then 1 else 2 * power (n - 1)

let x = power 10   # comptime: 1024
let y = x + 1      # 1025, all at compile time
```

**Emergent capability**: Staged compilation. `comptime` could generate code at compile time:

```
comptime fn generate_loop n =
  `( fold (+) 0 (range 1 ~n) )`
```

This requires HIR to be representable as data (which it is in HIR form). OCaml's PPX and Template Haskell do similar things, but Kō's advantage: `comptime` uses the same type system and language as runtime code.

### 3.4 Pattern Match Compilation: Matrix-Based Decision Trees

Kō's `match` currently compiles to a naive linear chain of tagged integer comparisons. With a proper pattern match compiler at the HIR→LIR boundary, matching becomes optimal using the *pattern matrix* formulation (Augustsson 1985, Maranget 2008).

#### 3.4.1 The Pattern Matrix

The core data structure is a *pattern matrix* — an m×n grid of patterns representing all match arms, with a corresponding *action vector* of right-hand side expressions:

```
         col1    col2    col3
row 1: [ _,     False,  True  ] → action A1
row 2: [ False, True,   _     ] → action A2
row 3: [ _,     _,      False ] → action A3
row 4: [ _,     _,      True  ] → action A4
```

An *occurrence vector* tracks how to extract each column's value from the scrutinee (e.g., `o1 = x.0`, `o2 = x.1`, `o3 = x.2` for a triple). The compilation algorithm `CC(~o, P → A)` recursively decomposes the matrix:

1. **Empty matrix** (`P` has 0 rows) → `Fail` (inexhaustive match)
2. **First row irrefutable** (all wildcards/variables) → `Success(A1)` (first-match semantics)
3. **Otherwise** → choose a column `i`, examine its head constructor, and *specialize* the matrix for each constructor:

The choice of column is crucial — it determines the shape and efficiency of the resulting decision tree.

#### 3.4.2 Specialization and Defaulting

**Specialization** retains only rows that admit a given constructor, decomposing sub-patterns into new columns:

```
CC(~o, P → A)   where column i has constructors C1, C2
  → Switch(o_i, {
      C1: CC(~o', specialize(P, i, C1) → A),
      C2: CC(~o', specialize(P, i, C2) → A),
      default: CC(~o, default(P, i) → A)
    })
```

**Defaulting** retains rows whose column-i pattern is a wildcard/variable (irrefutable), handling constructors not explicitly listed.

Example from Maranget: matching booleans `(x, y, z)`:

```
match (x, y, z)
  | (_,  F, T) => 1
  | (F,  T, _) => 2
  | (_,  _, F) => 3
  | (_,  _, T) => 4
```

Leftmost-column choice produces a deep tree (worst case: 3 tests per path). Choosing column 2 (the needed column) first produces:

```
if y then
  if x then
    if z then 4 else 3
  else 2
else
  if z then 1 else 3
```

This is the optimal tree: at most 2 tests when `y = false`, and at most 3 when `y = true`.

#### 3.4.3 Maranget's Heuristics

Maranget defines *necessity*: a column is *needed* if every possible decision tree must examine it. This gives a partial order on columns. The column-choice heuristics, ordered by sophistication:

| Heuristic | Score function | Intuition |
|-----------|---------------|-----------|
| **f** (frequency) | Count constructor patterns in column | Prefer columns with many non-wildcard entries |
| **d** (distinguishable) | Count distinguishable constructors | Prefer columns where patterns are spread across constructors |
| **b** (balanced) | Minimize max submatrix size | Keep decision tree balanced |
| **a** (arity) | Prefer columns with low-arity constructors | Cheaper to extract subterms |
| **n** (needed columns) | Count rows where column is needed | Prefer columns that *must* be tested |
| **p** (needed prefix) | Largest prefix of rows where column is needed | Earlier rows matter more (first-match) |
| **q** (constructor prefix) | Approximate p without usefulness computation | Avoid pattern copies from wildcards |

In practice, composing heuristics (e.g., `q → b → a`) yields good decision trees for most real pattern matches. The OCaml compiler uses a refined version of these heuristics.

#### 3.4.4 DAG Sharing (Pettersson)

Naive decision trees can explode exponentially for deep patterns with shared sub-expressions. Pettersson's solution: implement the decision tree as a DAG with *hash consing*. Each `Switch` node is interned by its constructor mapping. Identical subtrees share a single representation. When emitting code, shared subtrees are either duplicated (if small) or extracted as separate functions.

#### 3.4.5 Application to Kō

Kō's sum types are already tagged `i64` with dense constructor tags. This makes the pattern matrix algorithm especially efficient:

- **Tag extraction** is a register operation (no heap dereference for zero-arg constructors)
- **SwitchInst** maps directly to LLVM's `switch` (O(1) dispatch for dense tags)
- **Constructor unpacking**: single-arg constructors are pass-through `i64`; multi-arg constructors are heap structs — the pattern compiler knows the representation and generates different access patterns (no-op vs. GEP)
- **Nested patterns** (`match x | Cons (Cons a b) c => ...`) decompose naturally via specialization: the inner `Cons` becomes a new column in the specialized matrix

**Emergent capability**: Pattern match compilation also enables *usefulness* and *redundancy* checking. If a row's pattern is subsumed by earlier rows, the decision tree will never reach it — the compiler can warn the user. Maranget's algorithm supports this directly: the default matrix for an incomplete signature represents uncovered cases.

**Kō advantage**: Kō's sum types are simpler than OCaml's (no existential type variables in constructors, no GADTs). The pattern matrix algorithm is correspondingly simpler — no need for type-level information during compilation, just constructor tags.

### 3.5 Deforestation and Fusion

Kō's `List.map f (List.map g xs)` allocates an intermediate list. This is the classic functional programming performance trap.

With HIR-level optimization, the compiler can recognize this pattern and fuse:

```
map f (map g xs)  →  map (f ∘ g) xs  →  single pass, no intermediate list
```

GHC does this via rewrite rules (`map/map fusion`). Swift recognizes `array.map { ... }.filter { ... }` at the SIL level.

Kō can do this at the HIR level:

1. HIR retains function identity. `List.map` is still recognizable as `List.map` (not yet lowered to a loop).
2. A fusion pass recognizes `map f (map g xs)` and rewrites to `map (\x -> f (g x)) xs`.
3. The fused `map` then lowers to a single loop in LIR.

**Conditions for fusion in Kō:**
- Functions must be pure (no `ref` access). The type checker knows purity from the type (no `Ref` in the type).
- The intermediate list must not escape (liveness analysis on the HIR).
- Both `map` calls must be *saturated* (all arguments applied).

### 3.6 Tail Call Optimization

Kō is a functional language — tail recursion is the primary iteration mechanism. TCO is critical for performance.

**Current state**: codegen.zig detects tail calls and uses LLVM's `musttail` when possible. But LLVM's `musttail` is limited: same calling convention, tail position, no varargs.

**With LIR**: Tail calls become explicit goto/jump instructions:

```
fn countdown n =
  if n == 0 then 0
  else countdown (n - 1)
```

LIR:
```
bb_entry:
  %n = param
  %cond = icmp eq %n, 0
  br %cond, bb_base, bb_recur

bb_recur:
  %n' = sub %n, 1
  jump bb_entry with %n'        # tail call → back edge

bb_base:
  ret 0
```

This is a loop. LLVM handles this perfectly — no `musttail` needed.

For non-recursive tail calls (mutual tail recursion, tail calls to different functions), LIR can use trampolining: a small loop at the call site that jumps between functions.

**Emergent capability**: *Loopification* (like OCaml Flambda2's `loopify`). A self-tail-call is a loop branch. The function body can be compiled as a loop header, eliminating all call/return overhead.

### 3.7 RC + Immutability = Safe Structural Sharing

Kō's combination of immutability by default and reference counting creates an opportunity most languages don't have.

In Rust, sharing a data structure requires `Rc<T>` or `Arc<T>` — explicit, with runtime overhead. In Haskell, sharing is the default but GC has no destructors. In OCaml, sharing is fine but GC collects cyclically.

In Kō: immutable values can be shared freely. RC handles deallocation. Because values are immutable, a value cannot be freed while another reference holds it. This is safe and automatic.

**Practical consequences:**
- Persistent data structures (functional HashMap, Set) are efficient. Structural sharing doesn't require copy-on-write — RC handles the shared nodes.
- Thread safety: immutable values need no synchronization (read-only). RC updates on the value need atomic ops, but RC on *references to immutable values* doesn't need atomics (you're sharing the read-only pointer).
- Caching: memoized function results can be cached and shared. RC prevents memory leaks from the cache (when cache entries are dropped, the cache value is freed).

---

## 4. What Kō Can Learn From Each System

| System | Technique | Priority | Why for Kō |
|--------|-----------|----------|------------|
| Rust | MIR as CFG with basic blocks | **High** | LIR should be exactly this |
| Rust | Query-based incremental compilation | **Medium** | Separate compilation for v0.6 |
| Rust | Monomorphization at MIR level | **High** | Generics in v0.4 — same pattern |
| GHC | Typed Core with Lint | **Medium** | Type-checking HIR catches compilation bugs |
| GHC | Simplifier (one pass, many transforms) | **Medium** | Simpler than N independent passes |
| GHC | Rewrite rules for library fusion | **Low** (v0.5+) | List fusion, stream fusion |
| GHC | Strictness analysis + worker/wrapper | **Low** | Less relevant (no thunks) but applies to unboxing |
| Swift | ARC optimization (retain sinking, release hoisting) | **High** | Directly applicable to Kō's RC once LIR exists |
| Swift | @_semantics annotations for stdlib | **Medium** | Let compiler optimize stdlib without hardcoding |
| Swift | Two-phase passes (mandatory + optional) | **Medium** | Cleaner pipeline organization |
| OCaml | CPS-based IR | **Low** | Too elaborate for Kō; CFG is sufficient |
| OCaml | Downward/upward simplifier | **Medium** | Elegant pattern for HIR optimization |
| OCaml | Separate closure representation | **High** | Better closure analysis in HIR |
| Koka | Perceus RC (precise RC, drop specialization, reuse analysis) | **Highest** | FBIP: functional but in-place; directly applicable to Kō's RC model |
| OCaml/Maranget | Pattern match matrix compilation with heuristics | **High** | Optimal decision trees for match; usefulness/redundancy checking |
| Lisp | Tagged pointers (spare bits in align) | **Medium** | Single-arg constructors as tagged pointers |
| Mesa | Interface timestamps for module safety | **Low** (v0.5+) | Package management |
| Deutsch-Schiffman | Inline caching for dynamic dispatch | **Low** | Kō has static dispatch (no type classes yet) |
| Hölzle/SELF | Adaptive recompilation | **Low** | Future optimization when profiling exists |

## 5. What Kō Unlocks That Others Don't

Combinations that are unique to Kō:

| Combination | What It Enables | Who Else Does This |
|-------------|-----------------|--------------------|
| **Eager + RC + LLVM** | Predictable performance model, no GC pauses | Closest: Swift (but has class hierarchies + ObjC interop) |
| **HM + no type classes** | Monomorphic dispatch, full inlining | No major language (OCaml has modules, Haskell has type classes) |
| **JIT + AOT same IR** | Fast dev, optimized prod | Julia (same IR), but Kō targets native code, not runtime |
| **Comptime + HM** | Type-safe partial evaluation | Zig (but no type inference at comptime), Terra (Lua + LLVM) |
| **RC + immutable values** | Safe structural sharing, deterministic free | No major language (Swift has let + RC but classes are mutable) |
| **Pattern matching + tagged i64** | Register-efficient sum types | Rust (tagged unions), but at the LLVM level, not language level |
| **Small language + library** | Forkable, auditable, stable spec | Scheme, Lua — but neither compiles to native code |

---

## 6. IR Design Recommendations for Kō

Based on all research, Kō should target this IR pipeline:

```
AST → HIR → [HIR passes] → LIR → [LIR passes] → LLVM IR
```

### HIR (High-Level IR)

Purpose: Functional optimization. Pattern matching, closure analysis, inlining, fusion.

Properties:
- Functional (no control-flow graph)
- Typed (type info available from inference)
- Explicit closures (closure representation, captured variables)
- Explicit pattern matching (decision trees not yet compiled)
- Named expressions (ANF-like: every subexpression is a let binding)
- Source locations on every node (for error messages)

Passes:
1. Name resolution + scope analysis
2. Desugar (comptime calls, let patterns, etc.)
3. Type inference results propagated
4. HIR optimization:
   - Constant folding and propagation
   - Beta reduction (inline known functions)
   - Dead code elimination (HIR level)
   - Fusion (map/map, map/filter, etc.)
   - Comptime evaluation

### LIR (Low-Level IR)

Purpose: Machine-oriented optimization. RC motion, closure lowering, pattern match lowering.

Properties:
- Control-flow graph (basic blocks, terminators, phi nodes)
- Explicit memory operations (alloc, load, store, incref, decref)
- No closures (converted to structs + function pointers)
- No pattern matching (converted to switches + branches)
- No nested expressions (every value is a local)
- All types are lowered (no type variables — monomorphized)

Passes:
1. Closure conversion (closures → structs)
2. Lambda lifting (nested functions → top-level)
3. Pattern match compilation (Maranget matrix algorithm: column selection heuristics, specialization/default, DAG sharing)
4. Tail call analysis (self-recursive → loops, mutual → trampoline)
5. Monomorphization (generic → concrete, with cache)
6. LIR optimization:
   - Perceus-style RC optimization (precise RC insertion, drop specialization by constructor, dup/drop fusion)
   - Reuse analysis (FBIP: pair matched patterns to output constructors, in-place update when unique)
   - Dead block elimination
   - Constant propagation
   - Memory promotion (heap → stack for non-escaping values)
   - Critical edge splitting

### LLVM IR Generation

Purpose: Lower LIR to LLVM IR.

- Two-pass: declare functions, then emit bodies
- Each LIR basic block → LLVM basic block
- Each LIR instruction → LLVM instruction sequence
- RC operations → LLVM calls to `ko_incref`/`ko_decref` (later: LLVM intrinsics)
- Pattern matching results → LLVM switch/phi

---

## 7. Summary: The Kō Advantage

Kō's design choices — not as compromises, but as *deliberate constraints* — create a compiler that is:

1. **Simpler** than GHC, Rust, or Swift (one type system, one evaluation strategy, one memory model)
2. **More predictable** than Haskell (no laziness, no thunks, no GC pauses)
3. **More accessible** than Rust (no borrow checker, no lifetimes, no unsafe)
4. **More optimizable** than most functional languages (eager + RC + monomorphic dispatch open optimization doors that remain closed in lazy or polymorphic settings)

The IR pipeline is the key missing piece. With HIR and LIR inserted between AST and LLVM, Kō can:
- Optimize RC operations with Perceus-style reuse analysis (FBIP: functional code compiles to in-place mutation)
- Fuse list traversals (GHC-level fusion)
- Compile pattern matching via Maranget decision trees (OCaml-level match compilation with usefulness checking)
- Cache monomorphization (Java/C#-level JIT optimization)
- Share everything between JIT and AOT (Julia-level flexibility)

The techniques are all proven. Kō just needs to apply them in the right order.
