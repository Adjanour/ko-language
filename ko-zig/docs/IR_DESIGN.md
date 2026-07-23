# Kō IR Design — HIR and LIR

## Pipeline

```
Source → AST → HIR → [HIR passes] → LIR → [LIR passes] → LLVM IR
```

Two IRs between AST and LLVM, each with a specific purpose:

| IR | Form | Purpose |
|----|------|---------|
| **HIR** | Functional tree (ANF) | Type-safe transformations: fusion, closure analysis, inlining, pattern analysis |
| **LIR** | Control-flow graph (SSA) | Machine-oriented optimization: RC motion, pattern lowering, monomorphization |

## In-Memory Model

Both HIR and LIR exist **only in memory** during compilation — they are Zig structs (`std.ArrayList(HirExpr)`, `std.ArrayList(BasicBlock)`) with no text serialization in the pipeline. No disk I/O, no IR parsing, no string formatting. Everything is pointers and arrays.

```
Source → AST → HIR (memory) → LIR (memory) → LLVM IR (memory) → Machine Code
```

Debug dump flags (`--dump-ir`, `--emit-ir=file.ir`) are optional developer tools that run a pretty-printer over the in-memory IR after compilation. The compiler never reads IR text back in.

This matches the model used by Clang, Rustc, Zig, GCC, and LLVM itself — text IR is for debugging, not for pipeline communication.

## Why Two IRs?

One IR (like Rust's single `MIR` or GHC's `Core`) would be simpler but would conflate functional and machine concerns:

- **Fusion** needs to recognize `List.map f (List.map g xs)` as a functional pattern. In a CFG, this pattern is lost — it's already lowered to loops and allocs.
- **RC motion** needs basic blocks and dominance information. In a functional tree, control flow is implicit in conditionals.
- **Pattern matching** is best compiled at the boundary: analyze patterns in tree form (HIR), emit optimal decision trees into CFG form (LIR).

The split is the same proven pattern used by Rust (HIR/THIR → MIR), GHC (Core → STG), and Swift (SILGen → Canonical SIL).

---

---

## HIR — High-Level IR

### Design Principles

1. **Functional tree, not CFG.** Expressions nest. No basic blocks, no phi nodes. Control flow is implicit in `if`/`match`/`let`.
2. **ANF discipline.** Every non-atomic subexpression is bound to a name via `let`. Arguments to functions, constructors, and primops are always atomic (variables or literals).
3. **Typed.** Every HIR node carries its type (inferred by the existing typechecker). This enables a `lint` pass (like GHC's Core Lint) that verifies transformations preserve types.
4. **Explicit closures.** Closures are separate nodes with free-variable lists. Not yet lowered to environment structs.
5. **Explicit pattern matching.** `match` nodes retain the full pattern structure (nested patterns, guards). Decision trees are not yet compiled.
6. **Source locations on every node.** For error messages and debugging.

### Data Structures

```zig
pub const HirId = usize;

pub const HirExpr = struct {
    id: HirId,
    ty: TypeId,         // resolved type from inference
    span: SourceSpan,
    kind: HirExprKind,
};

pub const HirExprKind = union(enum) {
    // Literals
    int: i64,
    float: f64,
    bool: bool,
    char: u8,
    string: []const u8,

    // Variables
    var: LocalVarId,    // local binding
    global: []const u8, // top-level name

    // Functions
    lambda: struct {
        params: []const LocalVarId,
        body: HirId,
        captures: []const LocalVarId,  // free variables
    },
    apply: struct {
        func: HirId,
        arg: HirId,
    },

    // Bindings (ANF: every non-atomic is let-bound)
    let: struct {
        name: LocalVarId,
        value: HirId,
        body: HirId,
    },
    let_rec: struct {
        bindings: []const struct { name: LocalVarId, value: HirId },
        body: HirId,
    },

    // Control flow
    if_: struct {
        cond: HirId,
        then: HirId,
        else_: HirId,
    },
    match: struct {
        scrutinee: HirId,
        arms: []const MatchArm,
    },

    // Records and tuples
    record: struct {
        fields: []const struct { name: []const u8, value: HirId },
    },
    record_access: struct {
        record: HirId,
        field: []const u8,
    },
    tuple: struct {
        elements: []const HirId,
    },

    // Constructors
    constructor: struct {
        type_name: []const u8,
        ctor_name: []const u8,
        args: []const HirId,
    },

    // References
    ref: HirId,         // ref expr
    deref: HirId,       // !expr
    assign: struct {    // target := value
        target: HirId,
        value: HirId,
    },

    // Comptime
    comptime_expr: HirId,

    // Primitives
    primop: struct {
        op: PrimOp,
        args: []const HirId,
    },
};

pub const MatchArm = struct {
    pattern: Pattern,
    guard: ?HirId,
    body: HirId,
};

pub const Pattern = union(enum) {
    wildcard,
    bind: LocalVarId,
    literal: Literal,
    constructor: struct {
        type_name: []const u8,
        ctor_name: []const u8,
        args: []const Pattern,
    },
    record: struct {
        fields: []const struct { name: []const u8, pattern: Pattern },
        rest: bool,  // ..
    },
    tuple: []const Pattern,
};

// Primitive operations (maps to LLVM instructions)
pub const PrimOp = enum {
    add, sub, mul, div, rem,
    eq, neq, lt, le, gt, ge,
    and_, or_, not_,
    concat,        // string append
    ptrtoint,
    inttoptr,
    bitcast,
};
```

### Key Design Decisions

**Why ANF and not CPS?** ANF is simpler — no continuation variables, no administrative redexes. All the benefits of named intermediate computations without the complexity. CPS's advantage (β-reduction on all calls) is less relevant for Kō because:
- Kō is eager (call-by-value), so the β/βv distinction doesn't apply
- Kō has no first-class control effects (exceptions, coroutines)
- ANF is closed under the transformations we need (inlining, constant folding, dead code elimination)

If we need explicit join points for tail-call optimization, we can add them to LIR (where they naturally become back-edges in the CFG).

**Why typed?** GHC's Core Lint has been invaluable for catching optimizer bugs. A typed HIR means:
- Every pass can run a type checker after transformation
- The type checker serves as an oracle: "is this transformation sound?"
- Type information in HIR enables better optimizations (e.g., knowing a value is `Int` enables unboxing decisions)

**Why explicit captures on lambdas?** Flambda2's separate closure representation shows this is valuable for closure analysis. At HIR level, we record which free variables a lambda captures. This enables:
- Deciding whether to flatten or heap-allocate closures
- Identifying thunk-like closures (no captures, no arguments)
- Measuring closure cost during inlining decisions

### HIR Passes (in order)

1. **AST → HIR lowering** (desugaring)
   - `for` loops → recursive functions (none in Kō yet, but future)
   - `::` (cons) → `Cons` constructor call
   - Comptime annotations → evaluation or deferred to compile-time world
   - ANF conversion: introduce `let` bindings for every non-atomic subexpression
   - Name resolution: resolve all identifiers to `LocalVarId` or global name
   - Type annotation: attach type info from typechecker inference

2. **HIR optimization passes**
   - **Constant folding + propagation**: Evaluate `1 + 2` → `3` at HIR level
   - **Beta reduction**: Inline known functions when beneficial. Change `(\x -> e) v` → `e[x := v]` in HIR.
   - **Dead code elimination**: Remove unused `let` bindings
   - **Fusion**: Rewrite `map f (map g xs)` → `map (\x -> f (g x)) xs` at HIR level (requires function identity tracking)
   - **Comptime evaluation**: Evaluate `comptime` expressions, splice results
   - **Closure analysis**: Mark closures for flat vs heap representation

3. **HIR → LIR lowering**
   - Pattern match compilation (Maranget matrix algorithm)
   - Closure conversion (closures → structs + function pointers)
   - Lambda lifting (nested functions → top-level)
   - CFG construction: introduce basic blocks, phi nodes
   - ANF → SSA conversion (trivial: each `let` binding is already an SSA assignment)

---

---

## LIR — Low-Level IR

### Design Principles

1. **Control-flow graph.** Basic blocks with terminators. No nested expressions.
2. **SSA form.** Every value is defined exactly once. Phi nodes merge values at control-flow joins.
3. **Explicit memory.** Every allocation (`alloc`), load (`load`), store (`store`), and RC operation (`incref`, `decref`) is an explicit instruction.
4. **No closures.** All closures have been converted to structs + function pointers by the HIR→LIR lowering step.
5. **No pattern matching.** All `match` expressions have been compiled to `switch` + conditional branches.
6. **All types explicit.** No type variables — monomorphization happens before or during LIR (configurable).

### Data Structures

```zig
pub const LocalId = usize;
pub const BlockId = usize;

pub const LirFn = struct {
    name: []const u8,
    params: []const LocalId,
    return_type: LirType,
    blocks: []const BasicBlock,
    locals: []const LirType,    // type of each local
};

pub const BasicBlock = struct {
    id: BlockId,
    params: []const LocalId,     // block arguments (SSA phi)
    body: []const LirStmt,
    terminator: LirTerminator,
};

pub const LirStmt = union(enum) {
    assign: struct {
        dest: LocalId,
        value: LirValue,
    },
    store: struct {
        dest: LocalId,    // pointer
        value: LocalId,
    },
};

pub const LirValue = union(enum) {
    // Constants
    int: i64,
    float: f64,
    bool: bool,
    char: u8,
    string: struct { ptr: []const u8, len: usize },

    // Variables
    local: LocalId,

    // Memory operations
    alloc: LirType,                  // heap allocate
    load: LocalId,                    // load from pointer
    alloc_stack: LirType,            // stack allocate

    // RC operations
    incref: LocalId,
    decref: LocalId,
    is_unique: LocalId,              // refcount == 1?

    // Function operations
    call: struct {
        func: LocalId,
        args: []const LocalId,
        fn_type: LirFnType,
    },
    make_closure: struct {           // closure after conversion
        fn_name: []const u8,
        captures: []const LocalId,
    },

    // Aggregate operations
    extract_value: struct {
        aggregate: LocalId,
        index: usize,
        ty: LirType,
    },
    insert_value: struct {
        aggregate: LocalId,
        index: usize,
        value: LocalId,
        ty: LirType,
    },

    // Pointer arithmetic
    get_element_ptr: struct {
        ptr: LocalId,
        indices: []const LocalId,
        elem_type: LirType,
    },

    // Conversions
    ptrtoint: LocalId,
    inttoptr: struct { val: LocalId, ty: LirType },

    // Primops
    primop: struct {
        op: PrimOp,
        args: []const LocalId,
    },
};

pub const LirTerminator = union(enum) {
    br: BlockId,
    cond_br: struct { cond: LocalId, then: BlockId, else_: BlockId },
    switch: struct {
        val: LocalId,
        cases: []const struct { tag: i64, target: BlockId },
        default: BlockId,
    },
    ret: LocalId,
    unreachable,
    tail_call: struct {              // tail call (reuses current frame)
        func: LocalId,
        args: []const LocalId,
        fn_type: LirFnType,
    },
};

pub const LirType = union(enum) {
    int,             // i64
    float,           // double
    bool,
    char,
    string,          // { ptr: i8*, len: i64 }
    unit,            // void
    ptr: *const LirType,
    struct_: []const LirType,
    array: struct { elem: *const LirType, len: usize },
    function: LirFnType,
    opaque,          // unknown (for generics before monomorphization)
};

pub const LirFnType = struct {
    params: []const LirType,
    returns: LirType,
};
```

### LIR Passes (in order)

1. **LIR construction** (from HIR → LIR lowering, which includes):
   - Pattern match compilation (Maranget matrix → switch + branches)
   - Closure conversion (closures → `make_closure` instructions)
   - Lambda lifting (nested functions → top-level `LirFn`)
   - Explicit memory: every allocation becomes `alloc`, every field access becomes `get_element_ptr` + `load`/`store`
   - CFG construction with basic blocks and phi nodes

2. **Mandatory passes** (always run, like Swift's mandatory SIL passes):
   - **Critical edge splitting**: Ensure no block with multiple successors flows into a block with multiple predecessors (required for safe phi placement)
   - **Dead block elimination**: Remove unreachable blocks
   - **Verification**: Check LIR invariants (SSA, well-typed locals, proper terminators)

3. **Optimization passes** (run at `-O1` and above):
   - **Perceus-style RC optimization**:
     - Precise RC insertion: place `incref`/`decref` at last uses using liveness analysis
     - Drop specialization: specialize `decref` by constructor type (inline field decrefs)
     - Dup/drop fusion: cancel adjacent `incref`/`decref` pairs
     - Reuse analysis (FBIP): when `match` pattern pairs with output constructor and scrutinee has refcount 1, reuse the allocation in-place
   - **Memory promotion**: heap `alloc` → stack `alloc_stack` for non-escaping values
   - **Constant propagation**: propagate constants through SSA
   - **Dead code elimination**: remove unused locals and dead blocks
   - **Tail call optimization**: detect self-tail-calls → back-edge in CFG; mutual tail calls → trampoline

4. **LIR → LLVM IR lowering**
   - Two-pass: declare functions, then emit bodies
   - Each `BasicBlock` → LLVM basic block
   - Each `LirValue` → LLVM instruction sequence
   - Each `LirTerminator` → LLVM terminator (`br`, `switch`, `ret`, `unreachable`)
   - RC operations → LLVM calls to `ko_incref`/`ko_decref` (later: LLVM intrinsics for Perceus)
   - Types → LLVM types

---

---

## Key Design Differences from Existing Compiler

### Current (AST → LLVM IR)

The existing codegen (`codegen.zig`, ~3453 lines) processes the AST directly:

```zig
pub fn codegenExpr(self: *Codegen, expr: *const ast.Expr) !types.LLVMValueRef {
    switch (expr.*) {
        .int_literal => |val| { ... },
        .string_literal => |val| { ... },
        .fn_call => |call| { ... },
        .match => |m| { ... },
        // ... 30+ cases, all producing LLVM IR directly
    }
}
```

**Problems:**
- LLVM IR is generated inline, making per-function analysis impossible
- RC operations are inserted ad-hoc (`trackHeapAlloc`, `emitIncref`, `markConsumed`)
- Pattern matching is a linear chain of `icmp` + `br` (naive)
- No intermediate representation for cross-function optimization
- Every optimization must be implemented as LLVM IR pattern matching (brittle)

### New (AST → HIR → LIR → LLVM IR)

The codegen splits into three phases:

1. **`hir.zig`** — AST → HIR lowering (relatively straightforward: pattern match on AST, produce HIR)
2. **`lir.zig`** — HIR → LIR lowering (the complex one: pattern match matrix, closure conversion, CFG construction)
3. **`codegen.zig`** — LIR → LLVM IR (simplified: each LIR construct maps to LLVM)

Existing `codegen.zig` shrinks from ~3453 lines to ~800 lines of LIR → LLVM translation. The complexity moves to `lir.zig` (pattern compilation, closure conversion) and new optimization passes.

### What Changes Where

| Concern | Current | New |
|---------|---------|-----|
| AST types | `ast.zig` | Unchanged (still input) |
| HIR types | — | New file: `hir.zig` (~300 lines) |
| LIR types | — | New file: `lir.zig` (~400 lines) |
| AST → HIR | — | New file: `hir_lower.zig` (~500 lines) |
| HIR passes | — | New files: `hir_fusion.zig`, `hir_comptime.zig`, etc. |
| HIR → LIR | — | New file: `lir_lower.zig` (~1000 lines) |
| LIR passes | — | New files: `lir_rc.zig` (Perceus), `lir_pattern.zig`, etc. |
| LIR → LLVM | `codegen.zig` | Rewritten `codegen.zig` (~800 lines) |
| Type info | `typecheck.zig` | HIR carries `TypeId`; typechecker still drives inference |
| RC | Ad-hoc in codegen | Explicit LIR instructions + Perceus pass |

### Migration Strategy

**Phase 1: Prove the pipeline (this branch)**
1. Define HIR and LIR data structures in `hir.zig` and `lir.zig`
2. Implement AST → HIR lowering for all expression forms
3. Implement HIR → LLVM IR codegen (skip LIR initially — prove HIR works)
4. Verify all existing tests pass with HIR path
5. Switch default from AST → LLVM to AST → HIR → LLVM

**Phase 2: Add LIR**
1. Implement HIR → LIR lowering (basic: each HIR node → LIR sequence)
2. Implement LIR → LLVM IR codegen
3. Verify tests pass with AST → HIR → LIR → LLVM

**Phase 3: Optimize**
1. Pattern match matrix compilation (Maranget) in LIR lowering
2. Perceus RC optimization as LIR pass
3. Fusion as HIR pass
4. Inlining as HIR pass

---

---

## References

- Rustc dev-guide: HIR → THIR → MIR pipeline
- GHC: Core → STG → Cmm pipeline (System FC, Core Lint, Simplifier)
- Swift: SILGen → Raw SIL → Canonical SIL → IRGen (OSSA, ARC optimization)
- Flanagan et al. 1993: "The Essence of Compiling with Continuations" (ANF)
- Appel 1992: "Compiling with Continuations" (CPS)
- Maranget 2008: "Compiling Pattern Matching to Good Decision Trees"
- Reinking et al. 2021: "Perceus: Garbage Free Reference Counting with Reuse"
- Peyton Jones 1992: "Implementing lazy functional languages on stock hardware: the Spineless Tagless G-machine" (STG)
