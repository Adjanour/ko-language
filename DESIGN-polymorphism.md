# Kō Polymorphism: Monomorphization and Ownership-Aware Compilation

> **Status:** Design Draft
> **Date:** 2026-08-02
> **Depends on:** SPEC-0.md, DESIGN-linear-types.md, DESIGN-perceus-analysis.md

---

## 1. The Decision

Kō uses **compile-time monomorphization** (Rust-style). All generics are fully instantiated to concrete types before typechecking and linearity checking. By the time the linearity checker runs, there are no type variables left.

This is a deliberate trade: it costs compile time and binary size on heavy generic use, but keeps the linearity checker simple and sound. Kō does not support runtime-polymorphic collections; a `List<Node>` used at three call sites compiles to three specialized bodies.

---

## 2. Why Monomorphization

### 2.1 The Alternatives

| Strategy | How it works | Tradeoff |
|----------|-------------|----------|
| **Monomorphization** | One copy per concrete type | Code bloat, zero runtime overhead |
| **Type erasure** | One copy, types deleted at runtime | Runtime type checks needed, can't specialize |
| **Dictionary passing** | One copy, type info passed as dict | Indirect call overhead, boxing |
| **Runtime polymorphism** | Vtable dispatch at runtime | Boxing, indirect calls, can't prove linearity |

### 2.2 Why Not the Others

**Type erasure** doesn't work for Kō because:
- Linear types are a compile-time proof — they can't be erased
- Pattern matching needs to know constructor tags at compile time
- No runtime type checks (Kō's "no runtime" constraint)

**Dictionary passing** doesn't work for Kō because:
- Adds runtime overhead (indirect calls, boxing)
- Contradicts "mechanical sympathy" — the compiler should know everything at compile time
- Makes linearity checking harder (need to track dictionaries)

**Runtime polymorphism** doesn't work for Kō because:
- Requires runtime type tags (Kō has none)
- Requires boxing (Kō avoids this for linear values)
- Can't prove linearity at compile time (the proof would be lost)

### 2.3 Why Monomorphization Wins

Monomorphization is the only strategy that:
1. **Preserves linear types** — no type information is lost
2. **Zero runtime overhead** — all types known at compile time
3. **Enables optimization** — LLVM can inline, specialize, and optimize each copy
4. **Simple to implement** — straightforward AST transformation

---

## 3. How Monomorphization Works

### 3.1 The Pipeline

```
parse → monomorphize → bidirectional-typecheck → linearity-check → codegen
```

1. **Parse**: Source code → AST (with generic function definitions)
2. **Monomorphize**: Instantiate generics to concrete types (no type variables remain)
3. **Bidirectional typecheck**: Determine types for all expressions (no linearity checking)
4. **Linearity check**: Walk typed AST, check use counts (no type inference)
5. **Codegen**: Generate LLVM IR from fully-typed, linearity-checked AST

### 3.2 What Monomorphization Does

Given:
```ko
pub fn map (f : a -> b) (xs : List a) -> List b = match xs
  | Cons x rest -> Cons (f x) (map f rest)
  | Nil -> Nil

fn main =
  let xs = Cons 1 (Cons 2 Nil)
  let ys = map (\x -> toString x) xs   # call site 1
  let zs = map (\x -> x > 0) ys        # call site 2
```

After monomorphization:
```ko
# Specialized for (Int -> String) and List Int
fn map__Int__String (f : Int -> String) (xs : List Int) -> List String = match xs
  | Cons x rest -> Cons (f x) (map__Int__String f rest)
  | Nil -> Nil

# Specialized for (String -> Bool) and List String
fn map__String__Bool (f : String -> Bool) (xs : List String) -> List Bool = match xs
  | Cons x rest -> Cons (f x) (map__String__Bool f rest)
  | Nil -> Nil

fn main =
  let xs = Cons 1 (Cons 2 Nil)
  let ys = map__Int__String (\x -> toString x) xs
  let zs = map__String__Bool (\x -> x > 0) ys
```

### 3.3 What Gets Monomorphized

- **Function definitions** with quantified type variables
- **Constructor applications** with concrete type arguments
- **Pattern matches** on concrete types

What does NOT get monomorphized:
- **Built-in functions** (already concrete)
- **Functions without type variables** (already concrete)
- **Local bindings** (inferred, not polymorphic)

---

## 4. Signature Rules

### 4.1 Public Functions: Signature Mandatory

Public functions form the module's API. Readers must understand the types without running inference.

```ko
pub fn add (a : Int) (b : Int) -> Int = a + b
pub fn id (x : a) -> a = x
pub fn map (f : a -> b) (xs : List a) -> List b = ...
```

### 4.2 Private Functions: Signature Optional

Private functions are implementation details. The compiler infers types from the body.

```ko
# Simple — obviously inferred
fn add a b = a + b           # inferred: Int -> Int -> Int

# Complex — still inferred
fn compose f g x = f (g x)   # inferred: (b -> c) -> (a -> b) -> a -> c

# Partial annotation — check specific types
fn compose (f : b -> c) g x = f (g x)  # f annotated, g and x inferred
```

### 4.3 Recursive Functions: Signature Recommended

Recursive functions benefit from signatures (helps the compiler, documents intent):

```ko
# Recommended (but not required)
fn factorial (n : Int) -> Int = if n == 0 then 1 else n * factorial (n - 1)

# Also works (inferred)
fn factorial n = if n == 0 then 1 else n * factorial (n - 1)
```

### 4.4 The Rule

> Public functions require full type signatures. Private functions may omit signatures — the compiler infers types from the body. Partial annotations are allowed (annotate some params, infer the rest).

---

## 5. Ownership-Aware Monomorphization

### 5.1 The Innovation

Instead of monomorphizing only for types, Kō monomorphizes for **ownership patterns**. Functions that consume their arguments differently get different specializations.

This is unique to Kō — no other language does ownership-aware monomorphization.

### 5.2 How It Works

Given:
```ko
pub fn process (x : List Int) -> Int = match xs
  | Cons x rest -> x + process rest
  | Nil -> 0
```

After ownership-aware monomorphization:
```ko
# Linear version (x is consumed, no RC)
fn process__linear (x : List Int) -> Int = match xs
  | Cons x rest -> x + process__linear rest
  | Nil -> 0

# Rc version (x is shared, RC overhead)
fn process__ref (x : ref (List Int)) -> Int = match !x
  | Cons x rest -> x + process__ref (ref rest)
  | Nil -> 0
```

The caller chooses which version to call based on whether they own or share the data.

### 5.3 When It Helps

**Tree-shaped data (linear wins):**
```ko
let xs = Cons 1 (Cons 2 Nil)  # linear, no RC
let total = process xs          # calls process__linear, zero-cost
```

**Shared data (Rc wins):**
```ko
let xs = Cons 1 (Cons 2 Nil)
let shared = ref xs             # Rc, explicit
let total = process shared      # calls process__ref, RC overhead
```

### 5.4 The Tradeoff

Ownership-aware monomorphization increases compile time and binary size (more specializations). But it gives:
- Zero-cost for tree-shaped data (the common case)
- Correct RC for shared data (the uncommon case)
- No runtime overhead for either

---

## 6. The Rc Type

### 6.1 Syntax

`ref` is the keyword for creating reference-counted values. `ref T` is the type.

```ko
# Linear (default, no annotation needed)
let x : Int = 42
fn consume (x : Int) -> Int = x + 1

# Rc (explicit with ref)
let x : ref Int = ref 42
fn share (x : ref Int) -> ref Int = x

# Dereference (already exists)
let y = !x

# Rc in type definitions
type Shared a = ref a
type Node a = { value : a, next : ref (Node a) }
```

### 6.2 Rules

- `ref expr` creates a reference-counted value
- `ref T` is the type (reference-counted value of type T)
- `!expr` dereferences (already exists)
- Linear is the default; `ref` is explicit opt-in
- Rc values have runtime overhead (RC increment/decrement)

### 6.3 What Rc Gives You

| Operation | Linear (default) | Rc (shared) |
|-----------|-----------------|-------------|
| Create | `Cons 1 Nil` | `ref (Cons 1 Nil)` |
| Read | Direct (owned) | `!x` (dereference) |
| Modify | Rebuild (destructive) | Not allowed (read-only) |
| Destroy | Automatic (scope exit) | RC decrement |
| Cost | Zero (no RC) | RC overhead |
| Cycles | Not possible | Possible (with Weak) |

---

## 7. Compile-Time Cost

### 7.1 The Tradeoff

Monomorphization costs compile time and binary size. The question is: how much?

**Worst case:** A heavily generic program with many concrete types:
```ko
fn map (f : a -> b) (xs : List a) -> List b = ...
fn filter (p : a -> Bool) (xs : List a) -> List a = ...
fn foldl (f : b -> a -> b) (acc : b) (xs : List a) -> b = ...

# If used at 10 concrete types each:
# 10 × 3 = 30 specialized functions
```

**Mitigation:**
1. **Shared code for same-shape types**: `List Int` and `List String` have the same shape — the compiler can share code when operations are identical
2. **Lazy monomorphization**: Only monomorphize when the function is actually called
3. **Caching**: Cache monomorphized versions and reuse across call sites

### 7.2 The Exit Criterion

From DESIGN-linear-types.md:

> Compile a moderately generic program (the CLI example, but with `map`/`filter` used at 3-4 different concrete types). If monomorphization makes a trivial CLI tool take multiple seconds to compile, that's a signal worth catching in Phase 1, not after the stdlib is built on top of it.

---

## 8. Interaction with Linearity

### 8.1 The Key Insight

Monomorphization happens BEFORE linearity checking. By the time we check linearity, all types are concrete.

This means:
1. We can check linearity for each concrete function independently
2. We don't need to worry about type variables affecting linearity
3. The linearity checker is simpler and more predictable

### 8.2 Example

```ko
# Original (polymorphic)
pub fn id (x : a) -> a = x

# After monomorphization
fn id_Int (x : Int) -> Int = x
fn id_String (x : String) -> String = x

# Linearity check: each function independently
# id_Int: x used once → linear ✓
# id_String: x used once → linear ✓
```

### 8.3 Polymorphic Functions Are Unrestricted

From SPEC-0.md:

> In Phase 0, all function parameters are linear. Polymorphism adds unrestricted variables (the `forall` introduces unrestricted quantification).

After monomorphization, this distinction disappears — all parameters are concrete and linear. The linearity checker doesn't need to handle polymorphism.

---

## 9. What Kō Deliberately Leaves Out

1. **Runtime polymorphism**: No vtable dispatch, no boxing, no `any`/`dynamic`
2. **Heterogeneous collections**: No `[Int, "hello", True]` — all elements must be the same type
3. **Type classes**: No ad-hoc polymorphism — use monomorphization instead
4. **Higher-kinded types**: No `Functor`, `Monad` — keep it simple
5. **Polymorphic linearity**: No `forall a. a ⊸ a` — monomorphize first, then check linearity

These are deliberate omissions. They keep the language small, the compiler simple, and the generated code fast.

---

## 10. Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Polymorphism strategy | Monomorphization | Preserves linear types, zero runtime overhead |
| Signature requirement | Mandatory for public, optional for private | API clarity + ergonomics |
| Rc syntax | `ref T` type, `ref expr` creation | Familiar keyword, explicit opt-in |
| Ownership-aware mono | Yes | Zero-cost trees + correct RC for shared data |
| Runtime polymorphism | No | Contradicts "no runtime" and linear types |
| Binary size mitigation | Shared code + caching | Future optimization, acceptable for Phase 1 |

---

*This document defines Kō's polymorphism strategy. It is a deliberate trade: compile-time cost for runtime performance and type system simplicity.*
