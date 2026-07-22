# Kō (光) — Compiler Vision

## The Bet

Most languages make you choose: expressive but slow, or fast but verbose.

Kō rejects the tradeoff. Eager evaluation, reference counting, and LLVM codegen give you functional expressiveness *and* predictable performance. No GC pauses. No thunks. No category theory prerequisite.

The bet: you can have both if you're disciplined about what the compiler does and doesn't do.

## Lessons from the Past

Fifty years of programming language research contains a lot of wisdom — and a lot of dead ends.

### Haskell's Gift and Burden

Haskell proved that purity and type inference could scale to real programs. Lazy evaluation enabled compositional programming that eager languages couldn't easily express.

But laziness makes performance unpredictable. A thunk can hide anywhere. Space leaks are a constant tax. The runtime needs a sophisticated GC that trades latency for throughput. The language is beautiful; the performance profile is anything but.

Kō takes Haskell's type inference and ADTs. It leaves behind laziness, monads as the only effect mechanism, and the heavyweight runtime.

### OCaml's Pragmatism

OCaml showed that a strict functional language with mutations, objects, and a practical module system could build real systems. Its runtime is lighter than GHC's but still has a GC that punts on predictable latency.

Kō takes OCaml's eagerness, ref cells, and practical attitude. It replaces GC with reference counting for deterministic destruction.

### Rust's Insight

Rust proved that zero-cost abstractions and memory safety could coexist without a GC. Its ownership model is brilliant — and expensive to learn. The borrow checker, lifetimes, and unsafe blocks form a system that takes months to internalize.

Kō takes Rust's LLVM backend and mechanical sympathy. It replaces ownership with reference counting — less precise, but dramatically simpler. The tradeoff: predictable performance without the learning cliff.

### What C Got Right

C is successful because it maps directly to the hardware. A C programmer has a mental model of the machine that's almost always correct. The compiler does very little behind your back.

Kō keeps the transparency. If you write `let x = a + b`, you get an `add` instruction (eventually). No hidden allocations. No control flow the compiler inserted without your knowledge.

### What Lisp Understood

Lisp got two things right: (1) the language should be small enough to hold in your head, and (2) powerful abstractions can emerge from simple primitives, not from feature accretion.

Kō's 19 keywords is a deliberate debt to this tradition.

## The Insight: Functional Has a Hardware Story

Functional programming's biggest mistake was treating the hardware as a distraction. Laziness, pervasive GC, heavy runtime systems, and complex effects systems all distance the programmer from what the machine actually does.

But functions alone don't cause slowness. The overhead comes from specific runtime choices:

| Choice | Performance Cost |
|--------|-----------------|
| Lazy evaluation | Thunk allocation, space leaks, unpredictable evaluation order |
| Tracing GC | Pause times, cache misses, object graph traversal |
| Boxing everything | Indirection, allocation for every value |
| Monads for effects | Closure allocation per bind, opaque control flow |
| Type class dispatch | Dictionary passing, prevents inlining across boundaries |
| High-level IR (STG, λ-calculus) | Mismatch with LLVM's SSA form, missed optimization |

Kō systematically avoids each one:

- **Eager evaluation** — no thunks, evaluation order is the source order
- **Reference counting** — deterministic, no pauses, predictable overhead
- **Unboxed scalars** — Int is i64, Float is f64, Bool is i1, no boxing
- **Refs for mutation** — `let r = ref 0; r := 1; !r` — mutation is visible in syntax and type
- **HM inference without type classes** — monomorphic dispatch, full inlining
- **LLVM IR** — SSA from the start, LLVM can optimize naturally

The result: a functional language whose performance you can reason about. The same way you reason about a C or Rust program.

## Mechanical Sympathy in Practice

### 1. Eager Evaluation

```
fn fib n =
  if n <= 1 then n
  else fib (n - 1) + fib (n - 2)
```

When `fib` is called, arguments are evaluated before the function body executes. The call stack maps directly to the CPU stack. No thunks, no suspensions, no forcing.

If you can't tell where evaluation happens, neither can the programmer.

### 2. Reference Counting

Every heap-allocated object carries a refcount. When the count drops to zero, the object is freed immediately. No sweep phase, no mark phase, no stop-the-world.

The cost: inc/dec on every pointer copy and function return.

The benefit: free (and predictable) within 2x of Rust's ownership, with no borrow checker.

Reference counting works especially well for functional languages because:
- Most data is tree-shaped (no cycles in practice)
- Immutable values are shared, not copied — RC enables safe structural sharing
- Allocation is sequential (bump allocator per object)
- Deallocation is immediate (not deferred to a GC epoch)

### 3. Tagged Unions

ADTs compile to tagged unions, not boxed objects:

```
type Maybe a = Just a | Nothing
```

becomes (in LLVM IR):

```
%Just = i64          # tag + payload packed into register
%Nothing = i64       # tag only
```

No heap allocation for zero-arg constructors. Single-arg constructors are pass-through. Multi-arg constructors are heap-allocated structs with explicit RC.

Pattern matching compiles to integer comparison, not RTTI or reflection.

### 4. LLVM IR

The compiler generates LLVM IR as its lowest representation. LLVM handles register allocation, instruction selection, and machine code generation.

The key constraint: the IR must be LLVM-friendly. SSA form, explicit control flow, flat memory model. This means the compiler must lower functional abstractions (closures, pattern matching, tail calls) *before* reaching LLVM IR, not within it.

### 5. The IR Pipeline

```
Source
  → AST (parser output, syntax-oriented)
  → HIR (functional IR: Lambda, Match, LetRec, Apply)
  → LIR (imperative IR: blocks, branches, loads, stores)
  → LLVM IR (SSA, phi nodes, explicit memory)
```

Each stage strips away one layer of abstraction:

- **HIR**: still knows about functions as values, pattern matching as a construct, closures as captures. Optimizations here are functional: inline small functions, beta-reduce, constant fold.
- **LIR**: closures are structs, pattern matching is a decision tree, tail calls are loops or explicit trampolines. Optimizations here are imperative: dead code elimination, constant propagation, loop invariant code motion.
- **LLVM IR**: final lowering. LLVM does the rest.

## Minimum Viable Magic

The right amount of magic saves the programmer work. The wrong amount makes behavior unpredictable.

### What the compiler does for you

- **Type inference** — you rarely write types. The compiler figures them out and checks them.
- **Memory management** — RC is automatic. You don't `free` or think about lifetimes.
- **Pattern match exhaustiveness** — the compiler checks you handled all cases.
- **Compile-time evaluation** — `comptime` expressions run during compilation.

### What the compiler does NOT do

- **No implicit allocations** — if something allocates, it's visible in the type or the code.
- **No hidden evaluation** — evaluation order follows source order.
- **No type class dispatch** — calls resolve to concrete functions.
- **No implicit conversions** — what you write is what you get.
- **No magic syntax** — every syntax form has a direct semantic meaning.

The goal: a programmer can read a Kō function and predict, within a factor of 2, what the generated machine code looks like.

## The Compact Language

Kō has 19 keywords, 20 operators, and about 22 expression types. The grammar fits on a page.

This is not a limitation. It's an affordance:

- **Learnable** — an afternoon to learn, a week to master
- **Portable** — every implementation (Python, Zig, future self-hosted) targets the same surface
- **Forkable** — the spec is small enough that a motivated person could implement it from scratch
- **Auditable** — a security review covers the whole language, not just "the unsafe parts"

The library does the rest. `String.split`, `Array.map`, `Math.sqrt` — these are not language features. They're library functions, written in Kō, that the compiler can recognize and optimize.

## The Pipeline

```
Source Code
  │
  ├── 1. Lexer  (text → tokens)
  │     └── Indentation tracking, comment stripping
  │
  ├── 2. Parser  (tokens → AST)
  │     └── Recursive descent, error recovery
  │
  ├── 3. Name Resolution  (AST → scoped AST)
  │     └── Module imports, scope nesting, symbol resolution
  │
  ├── 4. Type Inference  (AST → typed AST)
  │     └── HM with let-polymorphism, unification, exhaustiveness
  │
  ├── 5. Lower to HIR  (AST → HIR)
  │     └── Desugar pattern matching, desugar let, flatten
  │
  ├── 6. HIR Optimizer
  │     └── Inline, const fold, DCE, simplify
  │
  ├── 7. Lower to LIR  (HIR → LIR)
  │     └── Closure conversion, pattern match compilation,
  │         lambda lifting, tail call analysis, monomorphization
  │
  ├── 8. LIR Optimizer
  │     └── Block layout, constant propagation, dead block removal
  │
  └── 9. LLVM IR Generation  (LIR → LLVM IR)
        └── Two-pass: declare functions, then emit bodies
              │
              ├── ORC JIT  (development)
              └── AOT Codegen (production)
                    └── Object file → Linker → Executable
```

Each IR exists because the next one can't represent what the current one understands:

- **AST** understands `match x | Just v => f v | Nothing => 0`
- **HIR** understands the same, but with desugared patterns and explicit scoping
- **LIR** understands conditional branches, phi nodes, and explicit loads/stores — `match` is gone
- **LLVM IR** understands registers, stack slots, and function calls — closures are gone

## What This Enables

### Fast iteration

Compile times stay low because the language is simple. No trait resolution, no elaborate monomorphization, no complex type-level computation (outside explicit `comptime`).

### Predictable deployment

Static linking produces a single binary. No runtime to install, no VM version to manage, no GC to tune.

### Accessible systems programming

A web developer who knows Python can learn Kō in a day and write a CLI tool that compiles to a 200KB native binary. No borrow checker to fight, no monads to compose.

### Clear mental model

```
if condition then a else b    →  compare, branch
match x | A => ... | B => ... →  tag compare, jump table or chain
let x = f y                   →  call f, store result in SSA register
ref x, !r, r := v            →  stack/heap alloc, load, store
```

Every language construct has a straightforward translation to machine operations.

## What We're Not Building

- **Not a research language.** No dependent types, linear types, or effect systems (yet).
- **Not a systems language.** No manual memory management, no `unsafe`, no inline assembly.
- **Not a cloud language.** No distributed runtime, no actor model, no hot code reloading.
- **Not a general-purpose language for everything.** Kō is for CLI tools, compilers, data transforms, build tooling, and small-to-medium programs.

## The Verdict We're Waiting For

Can a language with 19 keywords, eager evaluation, and reference counting compete with Rust for systems programming, with Haskell for expressiveness, and with Go for simplicity?

Probably not on any single axis. But the intersection — fast, simple, functional, native — is empty right now.

Kō fills that space.
