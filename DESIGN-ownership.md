# Kō Ownership Model

> **Status:** Canonical design
> **Date:** 2026-09-17
> **Authority:** This document is the source of truth for ownership terminology, inference, specialization, and runtime memory operations.
> **Related:** `DESIGN-linear-types.md`, `DESIGN-memory-runtime.md`, `DESIGN-polymorphism.md`, `DESIGN-perceus-analysis.md`

---

## 1. Language Promise

> **Kō is a small, eager functional systems language that uses ownership information to compile high-level immutable programs into predictable native code.**

A programmer chooses Kō for functional programming with fewer lifetime annotations, predictable memory behaviour, and native compilation.

Kō's ownership model exists to preserve a clean functional surface while producing explainable machine behaviour:

- immutable values and transformations are the normal programming model;
- the compiler infers ordinary borrowing, consumption, and sharing;
- uniquely owned data may be destructively reused when the old value is no longer observable;
- reference counting is the safe fallback for genuine or conservatively unknown sharing;
- ownership decisions are inspectable and do not change program semantics.

The implementation principle is:

> **Static ownership first; reference counting where necessary; reuse when provably safe.**

---

## 2. Two Different Axes

Ownership state and parameter use are not one four-way enumeration.

### 2.1 Value states

A non-copy runtime value has an ownership state:

| State | Meaning |
|---|---|
| `unique` | Exactly one owning path is known. |
| `shared` | More than one owning path may retain the value. |
| `immortal` | Static data requires no lifetime management. |
| `unknown` | The compiler cannot prove a more precise state. |

“Owned” is the general responsibility to keep a value alive and eventually release it. `unique` is the important optimizable state.

### 2.2 Use modes

A function parameter, closure capture, field insertion, or other operation uses a value in one of these modes:

| Mode | Meaning |
|---|---|
| `borrow` | Observe temporarily without transferring or retaining ownership. |
| `consume` | Transfer ownership; the source binding is unavailable afterward. |
| `share` | Permit retention beyond the immediate operation. |
| `copy` | Duplicate a trivially copyable value. |

A unique value may be borrowed many times sequentially and remain unique. It becomes shared only when another owning path may retain it.

---

## 3. Core Laws

1. Every non-copy runtime value has an owner.
2. A unique value has exactly one owning path.
3. Borrowing does not transfer ownership.
4. A borrow cannot escape the owner's lifetime.
5. Consuming transfers ownership and invalidates the source binding.
6. Sharing permits retention and may introduce reference counting.
7. Multiple temporary borrows do not make a value shared.
8. Ownership states must agree at each continuing control-flow join.
9. Destructive reuse is allowed only when uniqueness and non-observability are proven.
10. Ownership optimizations cannot change observable program behaviour.
11. When proof is insufficient, the compiler chooses the safe conservative path.
12. Better future analyses may remove memory-management operations but may not change source semantics.

---

## 4. Copy Values

Copy values bypass ownership machinery. The initial copy set is:

- `Int`
- `Float`
- `Bool`
- `Char`
- `Unit`
- aggregates whose complete representation is recursively copyable and whose ABI permits value copying

Examples:

```text
Copy(Int) = true
Copy((Int, Bool)) = true
Copy(String) = false
Copy((Int, String)) = false
```

`Copy` begins as a compiler-known property. It may later become a language-level constraint, but the ownership implementation must not wait for typeclasses.

---

## 5. Inference at Call Sites

Ordinary source code does not need routine ownership annotations.

### 5.1 Borrowing for observation

```ko
fn main =
  let xs = Cons 1 (Cons 2 Nil)
  let n = length xs
  inspect xs
  inspect n
```

Because `xs` is used after the call, the call to `length` borrows it:

```text
length(xs: borrow List Int) -> Int
```

No retain is needed merely because a value is observed more than once.

### 5.2 Consumption for transformation

```ko
fn main =
  let xs = Cons 1 (Cons 2 Nil)
  let ys = map increment xs
  inspect ys
```

There is no later use of `xs`. The compiler may select:

```text
map(f: borrow, xs: consume List Int) -> List Int
```

If `xs` is unique, the implementation may reuse its nodes. The source semantics remain an immutable transformation.

### 5.3 Sharing for retention

```ko
let cache = remember value
```

If `remember` retains `value` after returning, the call uses `share`. A unique value transitions to shared ownership or transfers into a new shared structure according to the callee's contract.

Sharing is about an additional owning path, not about the number of reads.

---

## 6. Borrows Do Not Escape by Default

The first ownership model does not support general lifetime-parameterized references.

A borrow may be used only within the dynamic and lexical extent accepted by ownership analysis. It may not be stored in:

- a return value that can outlive the owner;
- a global;
- a retained heap object;
- an escaping closure;
- a mutable cell whose lifetime is wider than the borrow.

When a function extracts data from a borrowed aggregate, it must do one of the following:

1. copy the result when it is `Copy`;
2. retain/share an independently managed heap value;
3. consume the aggregate and move the field out;
4. reject the program when none is safe.

This restriction removes most lifetime annotations from ordinary programs. Explicit lifetime-bearing views can be considered later if real programs require them.

---

## 7. Pattern Matching

Pattern matching does not always consume and does not always borrow. Its mode follows the scrutinee's use and the ownership of bound fields.

A consuming match may move fields out of a unique value:

```ko
match xs
  Cons x rest => consume_both x rest
  Nil => ()
```

A borrowing match creates non-escaping views of fields:

```ko
let n = length xs
inspect xs
```

The HIR must record whether each pattern binding is copied, borrowed, moved, or shared. LIR lowering must not rediscover this decision from syntax.

---

## 8. Control Flow

Ownership analysis is path-sensitive.

At a continuing control-flow join:

| Incoming states | Result |
|---|---|
| available + available | available, with the least precise safe ownership state |
| consumed + consumed | consumed |
| consumed + available | error |
| returned + available | available on the continuing path |
| shared + unique | shared |
| unknown + any non-copy state | unknown unless a stronger proof exists |

Example:

```ko
let result =
  if condition then consume_value x
  else inspect x

inspect x
```

This is invalid because `x` is consumed on only one path that reaches the later use.

A consuming branch that returns does not poison the continuing path:

```ko
if condition then
  return consume_value x
else
  inspect x

inspect x
```

---

## 9. Closures

Each closure capture has its own use mode and resulting stored state.

A non-escaping closure may borrow:

```ko
let total = with_each xs (\x -> inspect x)
```

An escaping closure must own or share its captures:

```ko
fn make_greeter prefix =
  \name -> String.append prefix name
```

If `make_greeter` consumes `prefix`, the closure owns it. If the caller retains `prefix`, the closure capture shares it and the compiler inserts the necessary retain.

The closure environment metadata must distinguish:

```text
Capture { field, type, use_mode, stored_state }
```

Borrowed captures are permitted only when escape analysis proves that the closure cannot outlive the borrowed owner.

---

## 10. Public Ownership Contracts

Private functions normally use inferred contracts. Public APIs need stable contracts for separate compilation and human understanding.

The semantic contract supports:

- `borrow`: the caller retains ownership;
- `consume`: ownership transfers to the callee;
- `share`: the callee may retain the argument;
- `copy`: applicable to copy values.

Possible future syntax:

```ko
pub fn length (borrow xs : List a) -> Int
pub fn map f (consume xs : List a) -> List b
pub fn cache (share value : a) -> Cache a
```

The syntax is not frozen by this document. The semantics are.

Until explicit syntax is implemented, the compiler may infer and serialize public ownership contracts in module metadata. Changing an exported contract is an API change.

---

## 11. Compiler Pipeline

Ownership-aware specialization cannot occur before type inference because concrete types and use information are both inputs.

The canonical order is:

```text
source
  → parse
  → type inference and checking
  → typed HIR
  → liveness and use analysis
  → escape and capture analysis
  → ownership contracts and call patterns
  → specialization worklist
  → ownership-explicit LIR
  → retain/release/reuse insertion
  → LLVM IR
```

### 11.1 Typed HIR responsibility

Typed HIR answers:

- the type and representation class of every value;
- all uses of each binding;
- control-flow successors;
- closure capture sets;
- whether a call is direct, generic, or indirect.

Ownership analysis annotates typed HIR with:

```text
ValueState = unique | shared | immortal | unknown
UseMode    = borrow | consume | share | copy
```

### 11.2 LIR responsibility

LIR receives ownership decisions explicitly. Conceptually it supports operations or annotations equivalent to:

```text
borrow value
move value
retain value
release value
share value
reuse allocation
```

The exact instruction encoding is an implementation detail. The invariant is that LIR lowering never guesses ownership from AST syntax or pointer shape.

---

## 12. Ownership-Aware Specialization

A function is specialized by concrete types and only those ownership distinctions that change generated behaviour.

A canonical key is:

```text
SpecializationKey {
  definition_id
  concrete_type_arguments
  representation_arguments
  relevant_parameter_modes
  relevant_capture_modes
  target_abi
}
```

The key must be deterministic and hashable. Source locations and compiler allocation addresses must never participate.

### 12.1 When ownership belongs in the key

Create distinct specializations when ownership changes:

- whether an input may be destructively reused;
- whether retain/release operations are required;
- closure environment layout;
- ABI or concrete representation;
- move versus borrow behaviour in generated code.

Reuse one specialization when ownership annotations erase to identical LIR.

### 12.2 Examples

Same type, different code:

```text
map<Int, Int, xs=consume>  → may reuse list nodes
map<Int, Int, xs=borrow>   → must preserve the input list
```

Different call sites, same code:

```text
length<List Int, xs=borrow>
length<List Int, xs=borrow>
```

Both calls share one specialization.

Shared fallback:

```text
remember<String, value=share>
```

The specialization retains the string if another owning path remains live.

### 12.3 Worklist algorithm

1. Typecheck generic definitions without cloning them.
2. Begin from concrete entry points and exported instantiation requests.
3. For each call, compute concrete types, representations, and relevant ownership modes.
4. Canonicalize them into a `SpecializationKey`.
5. If the key already exists or is in progress, reuse its symbol.
6. Otherwise reserve the symbol before lowering the body.
7. Analyze/lower the body under the requested contract.
8. Enqueue newly discovered specialization requests.
9. Continue until the worklist is empty.

Reserving before lowering permits ordinary recursive calls to refer to the specialization being built.

### 12.4 Termination

The compiler rejects unbounded specialization growth.

It must detect:

- recursive calls whose canonical key repeats: valid recursion;
- recursive calls whose type or ownership key grows structurally without reaching a fixed point: specialization expansion;
- mutually recursive groups: reserve the complete strongly connected request set before lowering.

A configurable diagnostic limit may protect compilation, but it is not the semantic termination rule. The diagnostic must show the chain of specialization requests.

### 12.5 Symbols and modules

A specialized symbol is derived from:

- stable module/package identity;
- stable definition identity;
- canonicalized type/representation arguments;
- relevant ownership modes;
- ABI version.

Human-readable names may include short type/mode fragments, but linkage uniqueness uses a stable hash of the canonical key.

Diagnostics always point back to the generic definition and concrete call chain, not only the mangled symbol.

---

## 13. Runtime Strategy

The runtime strategy is ordered by available proof:

| Proof | Action |
|---|---|
| copy value | copy bits according to ABI |
| immortal value | no lifetime operation |
| unique + consumed | move; optionally reuse allocation |
| unique + borrowed | temporary alias; no retain |
| shared | retain/release according to owning paths |
| unknown | conservatively retain/release |
| ownership transfer into aggregate | move or retain as required by the source state |

Reference counting is not Kō's language identity. It is the predictable fallback when static ownership cannot remove dynamic sharing.

The initial runtime may attach RC headers to all heap objects while analysis matures. This is acceptable if LIR makes the operations explicit and optimization can safely remove unnecessary pairs.

Cycles are not solved by ordinary RC. The initial language should prevent or document unsupported strong cycles; weak references or a cycle strategy require a separate design.

---

## 14. Mutation and `ref`

The existing `ref` expression/type represents explicit indirection or mutation. It is not synonymous with “shared ownership.”

These are separate questions:

1. Is a value unique or shared?
2. Is access immutable or mutable?
3. Is a value stored behind an explicit reference cell?

A `ref T` may itself be unique or shared. Mutation through a shared reference requires a separate aliasing rule and is outside the first ownership milestone.

This distinction prevents the ownership model from forcing users to wrap every shared immutable value in a source-level `ref`.

---

## 15. Diagnostics and Explainability

Ownership errors must name:

- the binding;
- the consuming or sharing use;
- the later conflicting use;
- the relevant control-flow path;
- a useful repair when one exists.

Example:

```text
error: 'xs' is used after ownership was transferred
  8 | let ys = map increment xs
                             -- ownership transferred here
  9 | inspect xs
              -- used again here
help: borrow 'xs', clone it explicitly, or stop using it after the call
```

Kō should eventually expose an ownership explanation command:

```text
ko explain ownership program.ko
```

Example output:

```text
map<Int, Int>
  f: borrowed
  xs: consumed
  result: unique
  list nodes: reused
  allocations: 0
  retains/releases: 0
```

---

## 16. Non-Goals for the First Milestone

- general lifetime parameters;
- arbitrary escaping borrowed references;
- implicit mutable aliasing;
- cycle collection;
- ownership expressed as LLVM heuristics;
- specializing every function for every theoretical ownership state;
- requiring ownership annotations on ordinary private functions;
- promising zero allocations or zero RC without measurement.

---

## 17. Implementation Sequence

1. **Correct LIR ownership inventory** — issue #45.
2. **Balanced release insertion** — issue #46.
3. **Typed-HIR ownership annotations and control-flow joins.**
4. **Closure escape and capture-mode analysis.**
5. **Canonical specialization key and worklist** — issue #47.
6. **Consume/borrow specializations for one recursive ADT function.**
7. **Allocation reuse for one proven-unique transformation.**
8. **Ownership explanation output.**
9. **Public ownership contract syntax, only after inferred semantics are stable.**

The first end-to-end proof should use one function such as `map`:

- borrowed input preserves the original list;
- consumed unique input may reuse nodes;
- shared/unknown input remains correct through explicit RC;
- all variants produce the same observable result.

---

## 18. Decision Summary

| Question | Decision |
|---|---|
| Default programming model | Immutable, functional values |
| Ordinary ownership syntax | Inferred |
| Value states | unique, shared, immortal, unknown |
| Use modes | borrow, consume, share, copy |
| Borrow escape | Forbidden by default |
| Sharing implementation | Static proof first, RC fallback |
| Mutation | Separate from ownership; explicit `ref` is not “shared” |
| Ownership analysis boundary | Typed HIR |
| Ownership-explicit boundary | LIR |
| Specialization | Concrete types plus behaviour-changing ownership patterns |
| Safety fallback | Conservative retain/release |
| Semantic guarantee | Optimizations never change observable behaviour |

---

*Kō values are uniquely owned when possible, borrowed for observation, consumed for transformation, and reference-counted only when genuinely shared or conservatively unknown.*
