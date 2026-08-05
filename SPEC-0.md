# SPEC-0: Kō Core Calculus

> **Status:** Frozen (Phase 0 deliverable)
> **Date:** 2026-08-01
> **Depends on:** DESIGN-linear-types.md

---

## 1. Purpose

This is the formal core of Kō's type system. It freezes the typing rules that Phase 1 must implement. The borrow arrow (`&τ`) is reserved as a syntax stub — the rule comes in Phase 2.

**What this is:** A minimal calculus that captures "immutable data + linear types + pattern matching" with bidirectional type inference.

**What this is not:** A full language spec. Surface syntax, modules, comptime, error handling — all of that comes later.

**Static typing (non-negotiable):** Kō is statically and fully typed; no runtime type tags, no runtime type checks, no `any`/`dynamic` escape hatch anywhere in the language, including the stdlib. This follows directly from "no runtime" and from linearity being a compile-time proof. It is not a decision — it is a consequence. It is not negotiable.

**Inference strategy (frozen):** Kō uses bidirectional local inference, not global Hindley-Milner. The rules are:

1. **Function signatures: mandatory, fully explicit.** Parameters and return type always written out. No exceptions, including single-expression functions.
2. **Everything inside a function body: inferred.** Propagated from the signature inward (checking mode). Synthesized outward for subexpressions where the signature doesn't constrain them (synthesis mode).
3. **Top-level bindings: mandatory type annotation.** Same reasoning as function signatures — anything that forms a module's public interface should be readable without running inference.

**Why not Hindley-Milner:** HM's global unification assumes unrestricted reuse of type variables across constraints, which does not compose cleanly with linear usage tracking. This is a known hard interaction, not a solved one (see Linear Haskell's friction points). Combining full inference research with linearity-checking research in v1 is out of scope.

**Compiler pipeline (frozen):**

```
parse → monomorphize → bidirectional-typecheck-with-linearity → codegen
```

Generics are fully monomorphized (Rust-style) before the linearity checker runs. By the time Γ-usage checking happens, there are no type variables left to reason about. This is a deliberate trade: it costs compile time and binary size on heavy generic use, but keeps the linearity checker simple and sound. Kō does not support runtime-polymorphic collections; a `List<Node>` used at three call sites compiles to three specialized bodies.

---

## 2. Syntax

### 2.1 Types

```
τ ::= Int                          integer
    | Bool                         boolean
    | String                       string
    | ()                           unit
    | τ → τ                        function (linear in both domains)
    | τ ⊸ τ                        function (linear in domain, linear in codomain)
    | K τ₁ ... τₙ                  ADT constructor application
    | (τ₁ × ... × τₙ)              tuple type
    | &τ                           borrow (STUB — Phase 2)
    | α                            type variable
```

The `⊸` (lollipop) is the linear arrow. `τ → τ` means "the argument may be used any number of times." `τ ⊸ τ` means "the argument must be used exactly once." In practice, `→` subsumes `⊸` when the argument is linear — but the distinction matters for the codegen strategy.

**Decision (frozen):** We use `→` for all function types in the surface syntax. The linear/unrestricted distinction is tracked internally by the type checker, not by syntax. The `⊸` appears only in this spec to explain the semantics. This keeps the surface syntax simple.

### 2.2 Expressions

```
e ::= x                           variable
    | λx. e                        lambda (linear parameter)
    | e₁ e₂                        application
    | let x = e₁ in e₂            let binding (x linear in e₂)
    | let _ = e₁ in e₂            let binding (discard e₁)
    | if e₁ then e₂ else e₃       conditional
    | match e₁ with pᵢ → eᵢ       pattern matching
    | K e₁ ... eₙ                  constructor application
    | (e₁, ..., eₙ)               tuple construction
    | e.i                          tuple field access (0-indexed)
    | ()                           unit value
    | n                            integer literal
    | b                            boolean literal
    | s                            string literal
    | &e                           borrow expression (STUB — Phase 2)
```

### 2.3 Patterns

```
p ::= _                            wildcard (linear, not bound)
    | x                            variable (linear binding)
    | K p₁ ... pₙ                  constructor pattern
    | (p₁, ..., pₙ)               tuple pattern
    | n                            literal pattern
    | b                            boolean literal pattern
```

### 2.4 Type Definitions

```
type K₁ τ₁ ... τₖ = C₁ of τ₁₁ × ... × τ₁ₘ₁
                    | C₂ of τ₂₁ × ... × τ₂ₘ₂
                    | ...
                    | Cₙ of τₙ₁ × ... × τₙₘₙ
```

Each constructor `Cᵢ` has arity `mᵢ`. A nullary constructor (arity 0) is a tagged value. A constructor with fields is a tagged tuple.

---

## 3. Typing Rules

### 3.1 Literals

```
Γ ⊢ n : Int
Γ ⊢ b : Bool
Γ ⊢ s : String
Γ ⊢ () : ()
```

Literals don't consume anything. They're unrestricted.

### 3.2 Variable

```
Γ(x) = τ    x is linear in Γ
─────────────────────────────────
        Γ ⊢ x : τ
```

**The linearity constraint:** After this judgment, `x` is marked as consumed. It cannot appear free in `Γ` again.

```
Γ(x) = τ    x is unrestricted in Γ
────────────────────────────────────
        Γ ⊢ x : τ
```

Unrestricted variables can be used multiple times. Built-in operations (`+`, `==`, etc.) consume their arguments but the result is a new value.

### 3.3 Lambda

```
Γ, x:τ₁ ⊢ e : τ₂
───────────────────
Γ ⊢ λx. e : τ₁ → τ₂
```

`x` is linear in the body `e`. It must appear exactly once (or be discarded with `_`).

### 3.4 Application

```
Γ ⊢ e₁ : τ₁ → τ₂    Γ ⊢ e₂ : τ₁
───────────────────────────────────
        Γ ⊢ e₁ e₂ : τ₂
```

`e₂` is consumed by the application. `e₁` is also consumed (functions are linear too).

**Important:** This is the key difference from unrestricted systems. In an unrestricted system, `e₂` could be used again after the call. In Kō, `e₂` is gone. The function takes ownership.

### 3.5 Let Binding

```
Γ ⊢ e₁ : τ₁    Γ, x:τ₁ ⊢ e₂ : τ₂
────────────────────────────────────
    Γ ⊢ let x = e₁ in e₂ : τ₂
```

`e₁` is evaluated, bound to `x`, and `x` is linear in `e₂`. `x` must appear exactly once in `e₂`.

**Discard binding:**

```
Γ ⊢ e₁ : τ₁    Γ ⊢ e₂ : τ₂
─────────────────────────────
Γ ⊢ let _ = e₁ in e₂ : τ₂
```

`e₁` is evaluated and discarded. No binding is created.

### 3.6 If-Then-Else

```
Γ ⊢ e₁ : Bool    Γ ⊢ e₂ : τ    Γ ⊢ e₃ : τ
─────────────────────────────────────────────
    Γ ⊢ if e₁ then e₂ else e₃ : τ
```

`e₁` is consumed. `e₂` and `e₃` must have the same type. The branches are independent — variables consumed in `e₂` are not consumed in `e₃` (they're in different branches).

**Linearity in branches:** The compiler tracks consumption separately for each branch. A variable consumed in the `then` branch and a variable consumed in the `else` branch are both considered consumed by the `if` expression (the join point).

### 3.7 Pattern Matching

```
Γ ⊢ e : K τ₁ ... τₖ    Γ, x₁:τ₁, ..., xₖ:τₖ ⊢ eᵢ : τ    (for each arm)
─────────────────────────────────────────────────────────────────────────────
              Γ ⊢ match e with K₁ x₁...xₖ → e₁ | ... | Kₙ xₙ...xₖ → eₙ : τ
```

**The scrutinee `e` is consumed.** After the match, the original value is gone. The matched variables (`x₁`, ..., `xₖ`) are new linear bindings.

**Exhaustiveness:** The pattern must cover all constructors of the type. The compiler checks this at compile time.

**Linearity in arms:** Each arm is independent. Variables consumed in one arm are not consumed in another.

### 3.8 Constructor Application

```
Γ ⊢ e₁ : τ₁    ...    Γ ⊢ eₖ : τₖ
────────────────────────────────────
Γ ⊢ K e₁ ... eₖ : K τ₁ ... τₖ
```

Each argument `eᵢ` is consumed by the constructor. The resulting value is a new linear value of type `K τ₁ ... τₖ`.

### 3.9 Tuple Construction

```
Γ ⊢ e₁ : τ₁    ...    Γ ⊢ eₙ : τₙ
─────────────────────────────────────
Γ ⊢ (e₁, ..., eₙ) : (τ₁ × ... × τₙ)
```

Each element is consumed. The tuple is a new linear value.

### 3.10 Tuple Field Access

```
Γ ⊢ e : (τ₁ × ... × τₙ)
──────────────────────────
    Γ ⊢ e.i : τᵢ₊₁
```

**The tuple is consumed by field access.** This is the linear choice: you can't read a field without taking ownership. To read multiple fields, destructure with a pattern match.

```
match tup with (a, b, c) → ...
```

This consumes `tup` and binds `a`, `b`, `c` as linear values.

### 3.11 Unit

```
Γ ⊢ () : ()
```

Unit is unrestricted. It can be used any number of times.

### 3.12 Borrow (STUB)

```
Γ ⊢ e : τ
──────────
Γ ⊢ &e : &τ
```

**Phase 2:** The full rule will be:

```
Γ ⊢ e : τ    Γ, x:τ → Γ' : e' : τ'    Γ'(x) = τ    (x not consumed in e')
─────────────────────────────────────────────────────────────────────────────
        Γ ⊢ let x = &e in e' : τ'
```

Where `&e` creates a borrow: `e` is not consumed, `x` is a read-only reference with scope limited to `e'`.

**Phase 0 stub:** Reserve the syntax `&e` and `&τ`. The compiler should reject borrow expressions with a "not yet implemented" error.

### 3.13 Bidirectional Type Inference

The 12 rules above are in "one-directional" form (Γ ⊢ e : τ). The actual implementation uses **bidirectional type inference** with two judgment forms:

- **⇒ (Synthesis):** Given an expression, produce its type. `Γ ⊢ e ⇒ τ`
- **⇐ (Checking):** Given an expression and an expected type, check that the expression has that type. `Γ ⊢ e ⇐ τ`

**Why bidirectional:** It allows type information to flow in both directions — from the signature inward (checking) and from the expression outward (synthesis). This eliminates most type annotations while keeping inference local (no global unification).

**The key rules:**

#### Variable (Synthesis)

```
Γ(x) = τ
────────────────
Γ ⊢ x ⇒ τ
```

Synthesize: look up `x` in the context, return its type.

#### Application (Synthesis)

```
Γ ⊢ e₁ ⇒ τ₁ → τ₂    Γ ⊢ e₂ ⇐ τ₁
────────────────────────────────────
        Γ ⊢ e₁ e₂ ⇒ τ₂
```

Synthesize the function type, check the argument against the domain. This is the rule that makes bidirectional work: the function's type drives the argument's checking.

#### Lambda (Checking)

```
Γ, x:τ₁ ⊢ e ⇐ τ₂
───────────────────
Γ ⊢ (λx. e) ⇐ τ₁ → τ₂
```

Check: push the expected type into the body. `x` gets type `τ₁`, body is checked against `τ₂`.

#### Let (Synthesis)

```
Γ ⊢ e₁ ⇒ τ₁    Γ, x:τ₁ ⊢ e₂ ⇒ τ₂
─────────────────────────────────────
    Γ ⊢ let x = e₁ in e₂ ⇒ τ₂
```

Synthesize `e₁`'s type, bind `x`, synthesize `e₂`'s type.

#### Let with Annotation (Checking)

```
Γ ⊢ e₁ ⇐ τ₁    Γ, x:τ₁ ⊢ e₂ ⇐ τ₂
─────────────────────────────────────
Γ ⊢ (let x : τ₁ = e₁ in e₂) ⇐ τ₂
```

Check: the annotation drives both sides.

#### If (Checking)

```
Γ ⊢ e₁ ⇒ Bool    Γ ⊢ e₂ ⇐ τ    Γ ⊢ e₃ ⇐ τ
──────────────────────────────────────────────
    Γ ⊢ if e₁ then e₂ else e₃ ⇐ τ
```

Check: synthesize the condition (must be Bool), check both branches against the expected type.

#### Literal (Synthesis)

```
Γ ⊢ n ⇒ Int
Γ ⊢ b ⇒ Bool
Γ ⊢ s ⇒ String
Γ ⊢ () ⇒ ()
```

Synthesize: literals have known types.

#### Constructor (Synthesis)

```
Γ ⊢ K : τ₁ → ... → τₖ → K τ₁ ... τₖ    Γ ⊢ e₁ ⇐ τ₁    ...    Γ ⊢ eₖ ⇐ τₖ
──────────────────────────────────────────────────────────────────────────────────
                        Γ ⊢ K e₁ ... eₖ ⇒ K τ₁ ... τₖ
```

Synthesize: look up the constructor's type, check each argument against the expected type.

#### Tuple (Synthesis)

```
Γ ⊢ e₁ ⇒ τ₁    ...    Γ ⊢ eₙ ⇒ τₙ
─────────────────────────────────────
Γ ⊢ (e₁, ..., eₙ) ⇒ (τ₁ × ... × τₙ)
```

Synthesize: each element's type is synthesized.

#### Field Access (Checking)

```
Γ ⊢ e ⇐ (τ₁ × ... × τₙ)
──────────────────────────
    Γ ⊢ e.i ⇐ τᵢ₊₁
```

Check: the expected type constrains which field is accessed.

#### Pattern Match (Synthesis)

```
Γ ⊢ e ⇒ K τ₁ ... τₖ
Γ, x₁:τ₁, ..., xₖ:τₖ ⊢ eᵢ ⇒ τ    (for each arm)
─────────────────────────────────────────────────────
Γ ⊢ match e with K₁ x₁...xₖ → e₁ | ... | Kₙ xₙ...xₖ → eₙ ⇒ τ
```

Synthesize: the scrutinee's type determines the pattern variables, each arm synthesizes the result type.

**How bidirectional interacts with linearity:**

The linearity check runs as a separate pass AFTER type inference. The bidirectional pass produces a typed AST with all types filled in. The linearity pass then walks the typed AST and checks use counts. This two-pass approach keeps the concerns separate:

1. **Bidirectional pass:** Determines types. No linearity checking.
2. **Linearity pass:** Checks use counts. No type inference.

The monomorphization pass runs BEFORE both: it instantiates generic functions to concrete types, so the bidirectional pass never sees type variables from generic definitions.

---

## 4. Linearity Rules

### 4.1 What Is Linear?

A binding is **linear** if it appears exactly once in the body where it's in scope.

```
fn id (x : a) -> a = x             # x appears once — linear ✓
fn bad (x : a) -> a = x + x        # x appears twice — NOT linear ✗
fn ignore (x : a) -> Int = 42       # x appears zero times — NOT linear ✗
fn discard (x : a) -> Int = let _ = x in 42   # x is discarded — linear ✓
```

### 4.2 What Is Unrestricted?

Some bindings are unrestricted (can be used any number of times):

- **Type variables** (in polymorphic functions): `fn id x = x` — `x` is polymorphic, so it's unrestricted within the body
- **Built-in operations**: `+`, `==`, etc. — these are functions that consume their arguments, but the result is a new value
- **Unit `()`**: Always unrestricted

**Decision (frozen):** In Phase 0, all function parameters are linear. Polymorphism adds unrestricted variables (the `forall` introduces unrestricted quantification). This matches Austral's model.

### 4.3 The Linearity Check

The linearity check runs as a **separate pass** after type inference. It walks the typed AST and checks use counts.

1. When a binding is introduced (`let x = ...`, `λx.`, pattern match), initialize use count to 0.
2. When a binding is used (variable reference), increment use count.
3. When a binding is discarded (`let _ = ...`, `_` in pattern), mark as discarded.
4. At scope exit, check:
   - If use count == 1: linear ✓
   - If use count == 0 and not discarded: error ("unused variable")
   - If use count > 1: error ("variable used more than once")
   - If discarded: ok

### 4.4 Exceptions to Linearity

1. **Polymorphic functions**: `fn id x = x` — `x` has type `∀a. a → a`, so it's unrestricted. The linearity check is deferred to the call site.

2. **Built-in functions**: `Int.add`, `String.append`, etc. — these consume their arguments but are not user-defined. The linearity rules are built into the codegen.

3. **Pattern wildcards**: `_` doesn't create a binding. It's always ok.

### 4.5 Compiler Pipeline

```
parse → monomorphize → bidirectional-typecheck → linearity-check → codegen
```

1. **Parse:** Source code → AST (with type variables from generic definitions)
2. **Monomorphize:** Instantiate generic functions to concrete types. No type variables remain.
3. **Bidirectional typecheck:** Determine types for all expressions. No linearity checking.
4. **Linearity check:** Walk typed AST, check use counts. No type inference.
5. **Codegen:** Generate LLVM IR from fully-typed, linearity-checked AST.

This pipeline order is frozen. It constrains the compiler's architecture: the type checker assumes no generics are present (they've been monomorphized away).

---

## 5. Semantics

### 5.1 Evaluation Strategy

**Strict (eager):** Arguments are evaluated before application.

```
let x = (1 + 2) in x * 3    # 1+2 evaluated first, then 3*3
```

### 5.2 Substitution

The core reduction rule is β-reduction:

```
(λx. e) v  →  e[v/x]
```

Where `e[v/x]` substitutes `v` for all (linear) occurrences of `x` in `e`.

### 5.3 Match Reduction

```
match K v₁ ... vₖ with ... | K x₁ ... xₖ → e | ... → e[v₁/x₁, ..., vₖ/xₖ]
```

The matched constructor's arguments are substituted into the arm body.

---

## 6. Examples

### 6.1 Identity (Linear)

```ko
fn id (x : a) -> a = x
# Type: ∀a. a → a
# x is linear: used exactly once
# Signature mandatory, body inferred
```

**Type check (bidirectional):**
```
Γ = x: a
Γ ⊢ x ⇒ a                              (variable, synthesis)
────────────────────────────────────
Γ ⊢ (λx. x) ⇐ a → a                   (lambda, checking — pushed from signature)
```

### 6.2 Map (Linear Recursive)

```ko
fn map (f : a -> b) (xs : List a) -> List b =
  match xs
    Cons x rest -> Cons (f x) (map f rest)
    Nil -> Nil
```

**Type check (bidirectional, Cons arm):**
```
Γ = f: a → b, xs: List a, x: a, rest: List a
Γ ⊢ f ⇒ a → b                          (variable, synthesis)
Γ ⊢ x ⇒ a                              (variable, synthesis)
Γ ⊢ f x ⇒ b                            (application, synthesis)
Γ ⊢ map ⇒ (a → b) → List a → List b   (variable, synthesis)
Γ ⊢ f ⇐ a → b                          (application, checking — domain of map)
Γ ⊢ rest ⇐ List a                      (application, checking — domain of map)
Γ ⊢ map f rest ⇒ List b                (application, synthesis)
Γ ⊢ Cons ⇒ b → List b → List b         (constructor, synthesis)
Γ ⊢ f x ⇐ b                            (constructor, checking)
Γ ⊢ map f rest ⇐ List b                (constructor, checking)
Γ ⊢ Cons (f x) (map f rest) ⇒ List b   (constructor, synthesis)
```

**Linearity check (separate pass):**
- `f`: used twice (in `f x` and `map f rest`) — **NOT LINEAR** → deferred to polymorphic unrestricted
- `x`: used once — linear ✓
- `rest`: used once — linear ✓
- `xs`: consumed by match — linear ✓

### 6.3 The Key Insight: Why Cons(f h, map f t) Doesn't Need RC

Consider:
```ko
fn map (f : a -> b) (xs : List a) -> List b =
  match xs
    Cons h t -> Cons (f h) (map f t)
    Nil -> Nil
```

**In an RC system:** Every `Cons` allocation increments RC on `f` and the list elements. `map f t` shares `f` with the recursive call. `Cons (f h) (map f t)` shares the new `Cons` node. All of this is hidden overhead.

**In a linear system:** `f` is unrestricted (polymorphic). `h` and `t` are linear — consumed exactly once. `Cons (f h) (map f t)` creates a new `Cons` node with ownership of `f h` and `map f t`. No sharing. No RC. The compiler knows:

1. `h` is consumed by `f h` — done, no decref needed
2. `t` is consumed by `map f t` — done, no decref needed
3. The new `Cons` node owns its children — no sharing, no RC
4. The result is a new list with the same shape — no aliasing

**Why no RC check?** Because the compiler proved at compile time that `h` and `t` are consumed exactly once. There's no aliasing. There's no sharing. The only reference to each node is the one in the `Cons` constructor. When the function returns, that reference is the caller's. No decref.

**Compare to Rust:** Rust's borrow checker would say `h` and `t` are moved into `Cons`. Same proof. Same zero-cost. Kō's linear types are the same mechanism, just with different syntax and a simpler surface.

**Compare to C:** In C, you'd `malloc` each `Cons` node, manually track pointers, and `free` when done. Kō's compiler does this automatically — but only because it proved linearity at compile time.

### 6.4 Filter (Linear Recursive)

```ko
fn filter (f : a -> Bool) (xs : List a) -> List a =
  match xs
    Cons x rest ->
      if f x then Cons x (filter f rest)
      else filter f rest
    Nil -> Nil
```

**Linearity check:**
- `f`: used in `f x` — linear ✓ (used once)
- `x`: used in `f x` and `Cons x ...` — **NOT LINEAR** → unrestricted (polymorphic)
- `rest`: used in `filter f rest` — linear ✓

### 6.5 Fold (Linear Recursive)

```ko
fn fold (f : b -> a -> b) (acc : b) (xs : List a) -> b =
  match xs
    Cons x rest -> fold f (f acc x) rest
    Nil -> acc
```

**Linearity check:**
- `f`: used in `f acc x` — linear ✓ (used once)
- `acc`: used in `f acc x` — linear ✓ (used once)
- `xs`: consumed by match — linear ✓
- `x`: used in `f acc x` — linear ✓
- `rest`: used in `fold f ... rest` — linear ✓

### 6.6 Five Example Programs (Bidirectional Inference Verification)

These five programs confirm that bidirectional inference with mandatory signatures works without unexpected annotations.

**1. CLI Example (args → read → split → filter → print):**
```ko
fn main -> () =
  let lines = read_file "input.txt" in
  let filtered = filter (\x -> not (isEmpty x)) (split lines "\n") in
  println filtered
```
No local annotations needed. The signature on `main` drives everything.

**2. Binary Tree (ADT + recursion):**
```ko
type Tree = Node (Tree × Int × Tree) | Leaf

fn tree_sum (t : Tree) -> Int =
  match t
    Node (l, v, r) -> v + tree_sum l + tree_sum r
    Leaf -> 0
```
One annotation on `tree_sum`. Pattern variables inferred.

**3. Generic Map (polymorphism):**
```ko
fn map_list (f : a -> b) (xs : List a) -> List b =
  match xs
    Cons x rest -> Cons (f x) (map_list f rest)
    Nil -> Nil
```
One annotation on `map_list`. `f`, `x`, `rest` inferred.

**4. IO + Error Handling:**
```ko
fn read_config -> String =
  match readFile "config.ko"
    Ok contents -> contents
    Err e -> panic (to_string e)
```
One annotation on `read_config`. `contents`, `e` inferred.

**5. Tuple Destructuring:**
```ko
fn swap (pair : a × b) -> b × a =
  match pair
    (x, y) -> (y, x)
```
One annotation on `swap`. `x`, `y` inferred.

**Verification:** Across all five programs, zero unexpected local annotations. Every annotation is on a top-level function signature (mandatory). This confirms the bidirectional inference story is pleasant.

### 6.3 The Key Insight: Why Cons(f h, map f t) Doesn't Need RC

Consider:
```ko
fn map f xs =
  match xs
    Cons h t -> Cons (f h) (map f t)
    Nil -> Nil
```

**In an RC system:** Every `Cons` allocation increments RC on `f` and the list elements. `map f t` shares `f` with the recursive call. `Cons (f h) (map f t)` shares the new `Cons` node. All of this is hidden overhead.

**In a linear system:** `f` is unrestricted (polymorphic). `h` and `t` are linear — consumed exactly once. `Cons (f h) (map f t)` creates a new `Cons` node with ownership of `f h` and `map f t`. No sharing. No RC. The compiler knows:

1. `h` is consumed by `f h` — done, no decref needed
2. `t` is consumed by `map f t` — done, no decref needed
3. The new `Cons` node owns its children — no sharing, no RC
4. The result is a new list with the same shape — no aliasing

**Why no RC check?** Because the compiler proved at compile time that `h` and `t` are consumed exactly once. There's no aliasing. There's no sharing. The only reference to each node is the one in the `Cons` constructor. When the function returns, that reference is the caller's. No decref.

**Compare to Rust:** Rust's borrow checker would say `h` and `t` are moved into `Cons`. Same proof. Same zero-cost. Kō's linear types are the same mechanism, just with different syntax and a simpler surface.

**Compare to C:** In C, you'd `malloc` each `Cons` node, manually track pointers, and `free` when done. Kō's compiler does this automatically — but only because it proved linearity at compile time.

---

## 7. What Phase 2 Adds

### 7.1 The Borrow Arrow (`&τ`)

**Syntax:** `&e` creates a borrow. `&τ` is the borrow type.

**Rule (Phase 2):**

```
Γ ⊢ e : τ    Γ, x:&τ ⊢ e' : τ'    x not consumed in e'
─────────────────────────────────────────────────────────────
        Γ ⊢ let x = &e in e' : τ'
```

Where:
- `e` is **not consumed** — it remains available after the borrow
- `x` is a **read-only reference** — it can be used to read `e`'s fields, but not to consume `e`
- `x`'s scope is limited to `e'` — the borrow ends when `e'` finishes
- `x` cannot be stored in a data structure (it's a local borrow)

**Example (Phase 2):**
```ko
fn first xs =
  match xs
    Cons h _ -> h    # h is borrowed, not consumed
    Nil -> 0

# With borrow:
fn first_pair pair =
  let a = &pair.0 in   # borrow first element
  let b = &pair.1 in   # borrow second element
  a + b                # a and b used, pair still available
```

### 7.2 Rc<T> (Phase 2)

**Syntax:** `Rc.make`, `Rc.get`, `Rc.get_mut`

**Type:** `Rc` is a stdlib type, not a language primitive. It wraps a linear value in reference-counted storage.

```ko
type Rc a = Rc *    # opaque, reference-counted

fn Rc.make : ∀a. a → Rc a
fn Rc.get : ∀a. Rc a → &a
fn Rc.get_mut : ∀a. Rc a → a    # consumes the Rc, returns the value
```

**Codegen:** `Rc.make` allocates with RC=1. `Rc.get` increments RC (borrow). `Rc.get_mut` decrements RC and returns the value (consume).

---

## 9. Summary of Frozen Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Static typing | Fully static, no dynamic escape | Consequence of "no runtime" + linearity |
| Inference strategy | Bidirectional local (not HM) | HM doesn't compose with linearity |
| Function signatures | Mandatory, fully explicit | Public interface must be readable |
| Top-level annotations | Mandatory | Same as function signatures |
| Function syntax | `(param : Type) -> ReturnType`, linearity tracked internally | Keeps surface syntax clean |
| Pattern matching | Consumes scrutinee | Linear by default |
| Tuple field access | Consumes tuple | Linear by default (destructure to read multiple fields) |
| Let binding | Linear (must use once) | Core invariant |
| Lambda parameter | Linear (must use once in body) | Core invariant |
| Polymorphic functions | Unrestricted parameters | Enables `map`, `fold`, etc. |
| Generics | Monomorphize, Rust-style | No polymorphic linearity in v1 |
| Pipeline | parse → monomorphize → bidirectional-typecheck → linearity-check → codegen | Frozen architecture |
| `_` pattern | Discards value | Standard |
| Borrow syntax | `&e` / `&τ` | Reserved, not implemented |
| Rc<T> | Stdlib type, not primitive | Keeps core calculus minimal |
| Spec size ceiling | ~50 pages (including borrow rules) | Explicit commitment |
| Linear types vs Perceus | **Deferred to Phase 1** | Implement both, compare benchmarks, decide based on numbers |

---

## 10. Exit Criterion (Phase 0)

1. You can explain, without notes, why `Cons (f h) (map f t)` doesn't need a refcount check.
2. You have five example programs (CLI, ADT, generics, IO, tuples) that type-check under bidirectional inference with zero unexpected annotations.
3. The pipeline is frozen: `parse → monomorphize → bidirectional-typecheck → linearity-check → codegen`.

---

*This calculus is the foundation. Everything else — surface syntax, modules, comptime, error handling — builds on top of it.*
