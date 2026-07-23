# Kō Type System in the IR Pipeline

## Current State

Kō's type system is Hindley-Milner with let-polymorphism, implemented in `typecheck.zig` (~1650 lines).

**Type representation:**
```
Type = variable(*TypeVar) | int | float | bool | char | string | unit
     | arrow(from, to) | tuple([]*Type) | con(name, args)
     | record(name, fields) | ref(*Type)

TypeVar = { id: usize, name, instance: ?*Type }
Scheme = { quantified: []usize, body: *Type }
```

Types are heap-allocated individually (`allocator.create(Type)`), no arena, no RC. The `Inferer` owns the type graph.

**Codegen side:** LLVM types are derived from Kō types via `koTypeToLlvm()` — a simple mapping:
- `int` → `i64`, `float` → `double`, `bool` → `i1`, `string` → `i8*`, `unit` → `void`
- `con` → `i64` (tag or pointer), `arrow` → opaque `ptr`
- `tuple` → LLVM struct, `record` → LLVM struct

**The problem:** Type info from the typechecker doesn't flow into codegen except through `expr_type_tags` (a hash map from `*Expr → i64` for the type tag used by `inspect`/`println`). Codegen independently derives what it needs from the AST structure.

---

## Type Flow Through the Pipeline

```
Source
  ↓
Parser → AST (TypeExpr annotations)
  ↓
Typechecker → [Type graph: *Type] ───┐
  ↓                                  │
HIR construction                     ├──→ HIR.ty = TypeId
  ↓                                  │
HIR passes (fusion, etc.)            │   (reference to *Type)
  ↓                                  │
HIR → LIR lowering                   ├──→ LIR.ty = lowered concrete type
  ↓ (monomorphization, resolution)   │
LIR passes (RC opt, etc.)            │   (no type variables)
  ↓                                  │
LIR → LLVM ──────────────────────────┘   (LLVM type mapping)
```

### Two Type Universes

**HIR type universe** — the typechecker's `*Type` graph. Contains type variables, polymorphism, constructor names. This is the "rich" type world where optimizations can inspect source-level types.

**LIR type universe** — a fresh concrete type representation. No type variables. No polymorphism. Everything is resolved to a concrete type. This is the "lowered" type world where memory layout, RC, and codegen decisions are made.

The bridge between them is the HIR → LIR lowering pass, which resolves all type variables and monomorphizes polymorphic definitions.

---

## HIR Type Representation

HIR nodes carry a `TypeId` — an index or pointer into the typechecker's type graph:

```zig
pub const HirExpr = struct {
    id: HirId,
    ty: TypeId,            // references the typechecker's *Type
    kind: HirExprKind,
};
```

Where `TypeId` is defined in the typechecker and can be resolved to a `*Type`:

```zig
pub const TypeId = usize;  // index into Inferer.type_table, or direct *Type pointer
```

The HIR does NOT duplicate the type graph. It references the typechecker's owned types. This means:
- HIR lowering happens after type inference is complete
- The `Inferer` must stay alive for the duration of HIR passes (it already does — `codegen.zig` keeps the `Inferer` alive)
- HIR passes can query the `Inferer` for type information (`resolve`, `typeToString`, etc.)

**Why not duplicate types?** Kō's type system is structurally simpler than GHC's System FC (no GADTs, no type families, no coercions). The `*Type` graph is small and stable after inference. Duplicating it into HIR would add complexity without benefit.

```zig
// Access pattern for HIR passes:
fn isInt(self: *HirPass, expr: HirId) bool {
    const ty = self.inferer.resolve(self.hir.exprs[expr].ty);
    return ty.* == .int;
}
```

### What HIR Passes Need from Types

| Pass | Type query |
|------|------------|
| Constant folding | Is this `int`? Is this `float`? |
| Beta reduction | Is this an `arrow`? What are param types? |
| Fusion | Is this `List a`? Is `map` called on a `List`? |
| Inlining | What is the return type? Are args known? |
| Dead code | (no type query needed) |
| Comptime | Is this expression comptime-evaluable? |

### What HIR Does NOT Need from Types

- Type variable IDs (these are internal to unification)
- Unification state (occurs check, instance chains)
- Fresh variable generation
- The generalization/instantiation machinery

These are type *inference* concerns, not type *usage* concerns. By the time HIR is constructed, inference is done.

---

## LIR Type Representation

LIR has its own independent type universe — completely separate from the typechecker's `*Type`:

```zig
pub const LirType = union(enum) {
    int,                    // i64
    float,                  // double
    bool,                   // i1
    char,                   // i8
    string,                 // { ptr, len }
    unit,                   // void
    ptr: *const LirType,    // pointer to T
    struct_: []const LirType,
    array: struct { elem: *const LirType, len: usize },
    function: LirFnType,
};
```

Key properties:

1. **No type variables.** Every `LirType` is concrete. Polymorphism has been resolved by monomorphization at the HIR→LIR boundary.

2. **No constructor names.** Sum types are lowered to either:
   - `int` (for zero-arg constructors — just the tag)
   - `struct_({int, T, U, ...})` (for constructors with payload — tag + fields)
   The constructor name is gone; only the layout matters.

3. **No record/tuple distinction.** Both become `struct_` with field types. Field names are resolved to indices by the HIR→LIR lowering pass.

4. **Functions are `function`.** The `LirFnType` carries parameter and return types, enabling LLVM function type construction without additional lookup.

5. **Pointers are explicit.** `ptr(T)` means a pointer to a heap-allocated T. Stack pointers are locals (not `ptr` type).

### Monomorphization at the HIR→LIR Boundary

When a polymorphic function is lowered from HIR to LIR, each instantiation produces a separate monomorphized copy:

```ko
# Source
fn id x = x
let a = id 42       # id @ Int
let b = id "hello"  # id @ String
```

HIR (typed, references *Type):
```
id: ∀a. a → a
id_inst1: Int → Int     # fresh TypeId for each instantiation
id_inst2: String → String
```

LIR (concrete types only):
```
id_int(param: int) → int
id_string(param: string) → string
```

The monomorphization cache (see §3.2 of `RESEARCH.md`) avoids redundant compilation: the same `(function_name, [concrete_types])` pair returns the same LIR function.

### Type Lowering Rules

| HIR type (*Type) | LIR type |
|------------------|----------|
| `int` | `int` |
| `float` | `float` |
| `bool` | `bool` |
| `char` | `char` |
| `string` | `string` |
| `unit` | `unit` |
| `arrow(a, b)` | `function([a'], b')` where a',b' are lowered |
| `tuple([a, b, c])` | `struct_([a', b', c'])` |
| `con("List", [a])` where a is resolved to Int | `int` (List is sum type, all values fit in i64 or struct pointer) |
| `con("Maybe", [a])` where a is resolved | `int` with tag+payload layout |
| `record("Point", [x: Int, y: Int])` | `struct_([int, int])` |
| `ref(a)` | `ptr(a')` |

### Why Separate LIR Types?

1. **LLVM affinity.** LIR types map directly to LLVM types. No indirection, no name resolution, no constructor lookup.

2. **RC optimization needs concrete types.** Perceus drop specialization needs to know the constructor layout (fields to decref). With constructor names gone, the layout is explicit.

3. **Memory promotion.** Deciding whether to use `alloc_stack` vs `alloc` depends on the concrete size and whether the type contains RC-managed pointers. This is straightforward with `LirType` but requires traversing the `*Type` graph otherwise.

4. **Pattern match lowering.** After pattern match compilation, we need to know field offsets and sizes. `LirType` struct layouts provide this directly.

---

## Type Representation in LIR Instructions

LIR instructions use `LirType` for all type annotations:

```zig
alloc: LirType,              // "allocate space for this type on heap"
alloc_stack: LirType,         // "allocate space for this type on stack"
load: LocalId,                // load from pointer; type comes from local's declaration
get_element_ptr: {
    ptr: LocalId,
    indices: []const LocalId,
    elem_type: LirType,       // the element type being accessed
},
```

Every local variable in LIR has a declared type:

```zig
pub const LirFn = struct {
    locals: []const LirType,   // type of each local (indexed by LocalId)
    // ...
};
```

This means the LLVM codegen pass is purely mechanical: `local[i]` → `alloca(type_i)`, `get_element_ptr` → `GEP` with the known type, etc. No type queries, no typechecker dependency.

---

## Unboxing Decisions

Kō's current approach (all values are `i64` or `i8*`) is simple but wasteful for some types:

| Type | Current | Optimal |
|------|---------|---------|
| `Int` | `i64` | `i64` (already optimal) |
| `Float` | `double` bitcast to `i64` | `double` (no bitcast) |
| `Bool` | `i64` | `i1` (spills to i8 on ARM) |
| `Char` | `i8` passed as `i64` | `i8` |
| `(Int, Int)` | `{i64, i64}` | `{i64, i64}` (already a struct) |
| `Maybe Int` | `i64` (0=Nothing, 1=Just payload) | `{i1, i64}` packed |

**In the HIR/LIR pipeline:** Unboxing becomes a type-driven lowering decision. The HIR type tells us "this is `Maybe Int`". The LIR lowering pass decides the concrete representation — packed `{i1, i64}` or opaque `i64` — based on a cost model.

The decision happens once at the HIR→LIR boundary. LIR never sees "Maybe Int" as a concept, only the concrete layout.

---

## Type Identity at Runtime

Kō uses a type tag for `inspect`/`println` (the `expr_type_tags` map in the current codegen). In the new pipeline, type tags are assigned at the HIR→LIR boundary:

- Each concrete type (after monomorphization) gets a unique type ID
- The ID flows into LIR as a constant
- LIR passes can use it for debug info, `inspect`, etc.
- LLVM codegen emits the ID alongside values that need runtime type inspection

This replaces the current ad-hoc `expr_type_tags` map with a systematic type ID assignment tied to the concrete type universe.

---

## Key Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| HIR types | References to `*Type` (typechecker-owned) | No duplication; typechecker is source of truth |
| LIR types | Independent concrete `LirType` | LLVM affinity, explicit layout, no variable resolution |
| Monomorphization | At HIR→LIR boundary | Matches Rust's approach (monomorphize at MIR level) |
| Unboxing | Type-driven decision at lowering | Once, at the right abstraction boundary |
| Runtime type tags | Systematic assignment at lowering | Replaces ad-hoc `expr_type_tags` map |
| Type inference scope | AST → HIR only | HIR passes use resolved types; LIR has no type variables |

```

## Interaction with Key Features

### Comptime

Comptime evaluation works at the HIR level (before lowering to LIR). The HIR type universe supports this naturally:
- `comptime fn power n = ...` has type `Int → Int` in the typechecker
- The comptime evaluator works on HIR nodes (or a HIR subset)
- Results are spliced into HIR as constants

### Generics (v0.4)

When generics arrive:
- The typechecker already handles them (`Scheme.quantified` = type parameters)
- HIR carries the polymorphic types (with type variables)
- The HIR→LIR lowering pass monomorphizes: each `(fn_id, [concrete_types])` pair produces a separate LIR function
- The monomorphization cache prevents redundant work

### Refs

`ref T` is a special case:
- HIR type: `ref(Int)` — the typechecker tracks ref-ness
- LIR type: `ptr(int)` — lowered to a pointer
- The `ref`/`!`/`:=` operations are explicit HIR nodes, lowered to `alloc_stack`/`load`/`store` in LIR
- RC is NOT affected by refs (refs don't own the value they point to — they borrow)

### Type Errors in HIR Passes

Since HIR is typed, HIR passes can produce type errors:
- Fusion: "Cannot fuse map on non-List type"
- Inlining: "Function type mismatch during specialization"
- Comptime: "Comptime evaluation failed: type mismatch"

These errors use the source location carried by every HIR node.
