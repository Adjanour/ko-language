# Implementation Plan — Middle End

## Strategy

Replace the current AST→LLVM IR codegen with AST→HIR→LIR→LLVM IR, **one file at a time, keeping tests passing at every step.** No big bang rewrites.

The plan uses a parallel pipeline approach: the old `codegen.zig` stays as the default until the new path covers every expression form. A `--use-hir` flag gates the new path during development.

---

## Phase 0 — Scaffolding (1 session)

**Goal:** New files compile but are empty. Tests still pass (no behavior change).

Files to create:
- `src/hir.zig` — `pub const HirId = usize;` placeholder
- `src/lir.zig` — `pub const LirId = usize;` placeholder

Files to modify:
- `build.zig` — add `hir.zig` and `lir.zig` to the root module source files

**Verify:** `zig build test --summary all` — 155/155 pass.

---

## Phase 1 — HIR Data Structures (1 session)

**Goal:** Complete HIR type definitions. No logic yet.

Files to modify:
- `src/hir.zig` — define full `HirExpr`, `HirExprKind`, `Pattern`, `MatchArm`, `PrimOp`

Key decisions to implement:
- `HirId` = `usize` index into a flat `HirExpr` array (like Rust's `HirId`)
- `ty: TypeId` references the typechecker's `*Type` via an index into `Inferer`'s type table
- ANF discipline: every `HirExprKind` is either atomic (literal, variable) or a let-binding
- Closures carry explicit capture lists
- Pattern matching is structural (nested patterns preserved, not yet compiled)
- All nodes carry `span: SourceSpan`

**Verify:** `zig build test` — 155/155 pass. Add a test in `tests.zig` that creates HIR nodes directly and checks structural invariants.

---

## Phase 2 — LIR Data Structures (1 session)

**Goal:** Complete LIR type definitions.

Files to modify:
- `src/lir.zig` — define `LirFn`, `BasicBlock`, `LirStmt`, `LirValue`, `LirTerminator`, `LirType`

Key decisions:
- `BasicBlock.params` for block arguments (SSA phi via basic block args, not explicit phi nodes)
- `LirType` is completely independent from the typechecker's `*Type` — no type variables, no constructor names
- RC operations are explicit: `incref`, `decref`, `is_unique`
- Functions are separate from closures: `call` takes a function, `make_closure` creates closure objects

**Verify:** `zig build test` — 155/155 pass. Add structural tests.

---

## Phase 3 — AST → HIR Lowering (2-3 sessions)

**Goal:** Convert any parsed + typechecked AST program to HIR.

Files to create:
- `src/hir_lower.zig` — `HirLower` struct

Files to modify:
- `src/tests.zig` — add HIR lowering tests

Implementation order (each sub-step ends with tests passing):

### 3a — Literals and identifiers
- `HirLower.lowerExpr` for `int_literal`, `float_literal`, `bool_literal`, `char_literal`, `string_literal`, `unit_literal`, `identifier`
- Straightforward 1:1 mapping from AST to HIR

### 3b — Binary and unary ops
- `ast.BinaryOp` → `HirExprKind.primop`
- Let-binding for non-atomic operands (ANF)
- Test with `fn main = 1 + 2` — verify HIR has let-bindings

### 3c — Let expressions and blocks
- `ast.LetBinding` → `HirExprKind.let` / `let_rec`
- Flatten `ast.Block` items into nested lets

### 3d — If/then/else
- `ast.If` → `HirExprKind.if_`

### 3e — Function calls and lambdas
- `ast.FnCall` → `HirExprKind.apply` (with let-binding for non-atomic args)
- `ast.Lambda` → `HirExprKind.lambda` (with capture list computation)
- Lambda bodies are lowered recursively

### 3f — Constructors, tuples, records
- `ast.Constructor` → `HirExprKind.constructor`
- `ast.Tuple` → `HirExprKind.tuple`
- `ast.Record` → `HirExprKind.record`
- `ast.FieldAccess` → `HirExprKind.record_access`

### 3g — Match expressions
- `ast.Match` → `HirExprKind.match`
- Patterns lowered structurally (not yet compiled to decision trees)
- Guard expressions attached to match arms

### 3h — Refs and comptime
- `ast.Ref` → `HirExprKind.ref`
- `ast.Deref` → `HirExprKind.deref`
- `ast.Assign` → `HirExprKind.assign`
- `ast.ComptimeExpr` → `HirExprKind.comptime_expr`
- `ast.FnDef.is_comptime` → captured in HIR function metadata

### 3i — Top-level definitions
- `HirLower.lowerProgram` — iterate `ast.Definition` items
- `fn_def` → store as HIR function
- `type_def` → store type info for constructor lowering
- `let_binding` → lower to HIR let (rewrap as function for codegen)

**Milestone:** `HirLower.lowerProgram()` produces complete HIR for any valid Kō program. Test: parse + typecheck + lower all 47 `.ko` test files, verify no crashes.

**Verify:** `zig build test` — 155/155 pass (old codegen path still active). New HIR lowering tests use side-by-side assertions (lower to HIR, check structural properties).

---

## Phase 4 — HIR → LLVM Codegen (3-4 sessions) — **DEFERRED**

> **Status (2026-07-23): deferred, likely unnecessary.** Decided after the
> Perceus research (see `docs/PERCEUS.md`): Phase 4's hard parts — closure
> codegen (4g), naive match (4i), ad-hoc RC (4l) — would all be deleted and
> redone by the LIR lowering in Phase 5 (closure conversion, match
> compilation, and RC are LIR-level concerns). The risk Phase 4 was meant to
> retire (no end-to-end validation of the new pipeline) is instead covered
> by differential testing against the legacy AST→LLVM path, which stays the
> default until Phase 5 lands. If Phase 5 hits trouble, Phase 4 can be
> revived as a fallback milestone. The sub-steps below are preserved for
> that reason.

**Goal:** Replace the AST→LLVM path with HIR→LLVM. Tests pass with both paths.

Files to create:
- `src/codegen_hir.zig` — `CodegenHir` struct, HIR→LLVM codegen

Files to modify:
- `src/main.zig` — add `--use-hir` flag
- `src/tests.zig` — add HIR codegen runtime tests

Implementation order:

### 4a — Codegen skeleton
- `CodegenHir` struct mirrors `Codegen` from existing `codegen.zig`
- Same LLVM context, module, builder, JIT/AOT integration
- `codegenProgram` entry point — reuses existing module declaration, JIT, AOT infrastructure
- For now, fall back to `codegen.zig` for anything not yet handled

### 4b — Literals
- `HirExprKind.int` → `LLVMConstInt(i64_type, val, true)`
- `HirExprKind.float` → `LLVMConstReal(double_type, val)`
- `HirExprKind.bool` → `LLVMConstInt(i1_type, val, false)`
- `HirExprKind.char` → `LLVMConstInt(i8_type, val, false)`
- `HirExprKind.string` → global `[N x i8]` constant + GEP
- `HirExprKind.unit` → `LLVMConstInt(i64_type, 0, 0)` (unit is 0)

### 4c — Variables and let bindings
- `HirExprKind.var(id)` → lookup in local scope (like existing `named_values`)
- `HirExprKind.let(name, value, body)` → emit value, store in scope, emit body
- `HirExprKind.let_rec` → emit all values first (forward declarations), then body

### 4d — Primops (binary/unary)
- Each `PrimOp` → corresponding LLVM instruction (`add` → `BuildAdd`, `eq` → `BuildICmp`, etc.)
- String `concat` → special case: call `ko_string_append`

### 4e — If/then/else
- Create `then_bb`, `else_bb`, `merge_bb`
- Conditional branch, phi node for result
- Identical pattern to existing `codegenIf` in `codegen.zig`

### 4f — Function calls and application
- `HirExprKind.apply(func, arg)` → build LLVM call instruction
- Direct calls (known function) vs indirect calls (function value)
- Partial application detection (arity check)
- Reuse existing partial application logic from `codegen.zig`

### 4g — Closures
- `HirExprKind.lambda(params, body, captures)` → create LLVM function + closure struct
- Lambda lifting: generate top-level function, allocate closure struct with captures
- Reuse existing closure codegen from `codegen.zig`

### 4h — Constructors, tuples, records
- Translate HIR constructor → LLVM tagged struct
- Zero-arg constructors: return tag as i64
- Multi-arg constructors: allocate, store tag + args, return ptrtoint
- Same representation as existing codegen

### 4i — Pattern matching (naive)
- `HirExprKind.match` → linear chain of icmp + cond_br + phi
- Same naive algorithm as existing `codegenMatch` in `codegen.zig`
- Optimal decision trees come later (Phase 6)

### 4j — Refs and assignments
- `ref expr` → alloca + store
- `!expr` → load
- `:=` → store

### 4k — Comptime
- `comptime_expr` → try comptime eval in `CompileTimeWorld`, splice result
- Same logic as existing comptime integration in `codegen.zig`

### 4l — RC management
- Track heap allocations (same pattern as `scope_heap_values`, `markConsumed`)
- Insert `ko_incref`/`ko_decref` calls
- Same ownership model as existing codegen
- Perceus optimization comes in Phase 7

### 4m — Switch default to HIR path
- `--use-hir` becomes default, `--legacy-codegen` for old path
- All 155 tests pass with HIR path

**Milestone:** `ko --run` works for all 47 `.ko` test files through the HIR path. Output matches the legacy path.

**Verify:** `zig build test --summary all` — 155/155 pass. New runtime tests run through HIR path.

---

## Phase 5 — LIR → LLVM Codegen (2 sessions)

**Goal:** HIR → LIR → LLVM IR pipeline works. Tests pass.

Files to create:
- `src/codegen_lir.zig` — `CodegenLir` struct, LIR→LLVM codegen ✅ **(5a done, 2026-07-23)**
- `src/lir_lower.zig` — HIR → LIR lowering (5b; was missing from this list)

Files to modify:
- `src/main.zig` — `--use-lir` flag for the full pipeline

> **5a status:** `src/codegen_lir.zig` complete with 9 JIT-executed tests
> (191/191 total suite green). Covers the full mapping table below plus:
> block params → phi nodes, runtime reuse of `StdlibCodegen` output, and
> inline `is_unique` over the RC header. Three LIR extensions were required
> (all in `lir.zig`): terminators carry block arguments (`BrTarget{target,
> args}` — MLIR-style; `BasicBlock.params` was previously unbindable),
> `LirValue.fn_ref` (materialize top-level functions for direct calls), and
> `LirStmt.effect` (side-effect-only ops like `decref`). One real algorithm
> fell out: LLVM phis can't hold two entries for the same predecessor with
> different values, so duplicate edges to parameterized blocks are split
> lazily through trampoline blocks (critical-edge splitting) inside
> `codegen_lir`. Per-function LLVM verification runs on every emitted LIR
> function. Pre-existing issue found: some `StdlibCodegen` functions emit
> invalid IR (bad GEP indices, mid-block terminators) — invisible to the
> legacy path because it never verifies and MCJIT compiles lazily; tracked
> for a separate fix.

### 5a — LIR → LLVM for basic LIR
Each `LirStmt` and `LirTerminator` maps to LLVM instructions:
| LIR | LLVM |
|-----|------|
| `alloc(T)` | `call ko_alloc(sizeof(T))` + bitcast |
| `alloc_stack(T)` | `alloca T` |
| `load(src)` | `BuildLoad2(elem_type, src, name)` |
| `store(dest, val)` | `BuildStore(val, dest)` |
| `incref(ptr)` | `call ko_incref(ptr)` |
| `decref(ptr)` | `call ko_decref(ptr)` |
| `call(func, args)` | `BuildCall2(fn_type, func, args)` |
| `br(block)` | `BuildBr(block)` |
| `cond_br(cond, t, f)` | `BuildCondBr(cond, t, f)` |
| `switch(val, cases, default)` | `BuildSwitch(val, default, count)` |
| `ret(val)` | `BuildRet(val)` |
| `tail_call(func, args)` | `BuildCall` with `musttail` |

### 5b — Wire HIR→LIR→LLVM
- `main.zig` calls `hir_lower` → `lir_lower` → `codegen_lir`
- No LIR optimizations yet (straight lowering)

### 5c — Verify output matches HIR→LLVM path
- Run all tests through LIR path, compare LLVM IR output
- Same semantics, same results

**Milestone:** `ko --use-lir file.ko` produces correct output for all test files.

**Verify:** `zig build test` — 155/155 pass.

---

## Phase 6 — Pattern Match Compilation (2 sessions)

**Goal:** Match expressions compile to optimal decision trees instead of linear chains.

Files to create:
- `src/lir_pattern.zig` — Maranget matrix algorithm
  - Pattern matrix construction from HIR match arms
  - Column selection with heuristics (q → b → a composition)
  - Specialization and default decomposition
  - DAG sharing via hash consing
  - `LirSwitch` with dense tag dispatch

Files to modify:
- `src/lir_lower.zig` — call pattern match compiler instead of naive lowering
- `src/tests.zig` — add pattern match compilation tests

**Milestone:** `match (x, y, z) | (_, F, T) => 1 | (F, T, _) => 2 | ...` compiles to optimal decision tree, not linear chain.

**Verify:** Codegen tests verify decision tree shape (not just correctness). Runtime tests verify same behavior as naive matching.

---

## Phase 7 — Perceus RC (3 sessions) — **restructured: runs on HIR**

> **Restructured 2026-07-23** after the Perceus paper deep-dive. The
> algorithm is syntax-directed over a functional ANF calculus — Kō's HIR,
> not the CFG-based LIR. Insertion, drop specialization, and reuse pairing
> all happen on HIR (where match arms and constructor allocations are still
> syntactically paired); LIR just transports the explicit ops. The full
> implementable spec is **`docs/PERCEUS.md`** (algorithm rules, runtime
> pseudocode, Kō mappings). The original LIR-liveness design (`lir_rc.zig`)
> is abandoned.

**Goal:** precise (garbage-free) reference counting with drop specialization and FBIP reuse.

Files to create:
- `src/hir_rc.zig` — Perceus insertion pass on HIR (paper Figure 8 rules
  with borrowed/owned environments), run as the last HIR pass

Files to modify:
- `src/hir.zig` — new node kinds: `dup`, `drop` (7a), `drop_reuse` + `ConstructorExpr.reuse` token (7c)
- `src/lir_lower.zig` — lower explicit HIR RC nodes 1:1 to LIR ops; no ad-hoc RC insertion
- `src/lir.zig` — 7c only: `drop_reuse`, `alloc_reuse` ops
- `src/codegen_lir.zig` — 7c only: lower `drop_reuse` / `alloc_reuse`
- `src/stdlib_codegen.zig` — 7c only: `ko_drop_reuse` runtime function

### 7a — dup/drop insertion (Figure 8) (1 session)
- `Δ | Γ ⊢s e ⇝ e′` over HIR: `svar/svar-dup/sapp/slam/sbind/smatch/scon`
- v1: all function parameters owned; borrowed params deferred
- **Golden tests:** exact-placement assertions on hand-derived examples (`map` from the paper)

### 7b — drop specialization + dup push-down/fusion (1 session)
- Inline `drop` specialized by constructor (only when children are used in the branch)
- Push dups into branches; cancel adjacent dup/drop pairs
- **Test:** `map` fast path has zero RC ops under `is-unique`

### 7c — reuse analysis (FBIP) (1 session)
- Pair matched constructors with same-branch constructor allocations; `drop_reuse` + `Ctor@ru`
- Reuse specialization only when ≥1 field unchanged
- **Milestone:** `List.map` in a tight loop shows zero alloc/free per iteration.

**Verify:** Memory tracing tests (capture `ko_alloc`/`ko_decref` calls, verify elimination). Golden-derivation tests for placement. Runtime tests verify same results.

---

## Phase 8 — HIR Optimization Passes (ongoing)

**Goal:** HIR-level optimizations that can't be done at LIR.

Files to create:
- `src/hir_fusion.zig` — list fusion (map/map, map/filter, stream fusion)
- `src/hir_inline.zig` — beta reduction + inlining heuristic
- `src/hir_comptime.zig` — comptime evaluation as HIR pass
- `src/hir_dce.zig` — dead code elimination at HIR level
- `src/hir_pass.zig` — pass manager (order, fixpoint iteration)

**Order:**
1. Dead code elimination (easiest, biggest payoff)
2. Constant folding + propagation
3. Comptime evaluation as a pass
4. Beta reduction (inline trivial lambdas)
5. Fusion (requires function identity tracking)
6. Inlining (heuristic-based)

---

## Summary

| Phase | What | New Files | Sessions |
|-------|------|-----------|----------|
| 0 | Scaffolding | `hir.zig`, `lir.zig` | 1 |
| 1 | HIR data structures | `hir.zig` | 1 |
| 2 | LIR data structures | `lir.zig` | 1 |
| 3 | AST → HIR lowering | `hir_lower.zig` | 3 |
| 4 | HIR → LLVM codegen | `codegen_hir.zig` | ~~4~~ **deferred** |
| 5 | LIR → LLVM codegen | `codegen_lir.zig` ✅ 5a | 2 |
| 6 | Pattern match compilation | `lir_pattern.zig` | 2 |
| 7 | Perceus RC on HIR (7a/7b/7c) | `hir_rc.zig` | 3 |
| 8 | HIR optimization passes | `hir_fusion.zig` etc. | ongoing |

**Total: ~17 sessions to full pipeline.**

Each phase ends with `zig build test --summary all` — 155/155 pass.
