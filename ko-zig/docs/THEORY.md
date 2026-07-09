# Kō — Theoretical Foundations

The complete intellectual lineage of the Kō language, with references to the original research.

---

## 1. Lambda Calculus — The Foundation

Everything starts here. The lambda calculus (Church 1930s-1940s) is a formal system for expressing computation via function abstraction and application. It is the theoretical backbone of all functional programming languages.

- **Alonzo Church** (1936) — "An Unsolvable Problem of Elementary Number Theory" — introduced the lambda calculus as a foundation for mathematics and computation.
- **Stephen Kleene** (1936) — developed the theory of recursive functions, closely related.
- **Church–Rosser Theorem** — guarantees that evaluation order doesn't affect the final result (confluence property).

**What Kō inherits:** Kō is a lambda calculus extended with eagerness, algebraic data types, and references. The core evaluation model (function abstraction → application → reduction) is lambda calculus.

**Key papers:**
- Church, A. (1936). "An Unsolvable Problem of Elementary Number Theory." *American Journal of Mathematics*, 58(2), 345–363. [JSTOR](https://www.jstor.org/stable/2371051)
- Selinger, P. (2007). "Lecture Notes on the Lambda Calculus." [PDF](https://www.mathstat.dal.ca/~selinger/papers/lambdanotes.pdf) — Excellent modern reference covering Church-Rosser, typed lambda calculus, Curry-Howard.

---

## 2. Curry–Howard Correspondence — Proofs as Programs

The deepest connection in computer science: propositions are types, proofs are programs, proof simplification is program evaluation.

- **Haskell Curry** (1934) — observed that types of combinators correspond to propositions in implicational logic.
- **William Howard** (1969, published 1980) — made the full correspondence explicit: natural deduction ↔ simply typed lambda calculus.

| Logic | Type System | Programming |
|-------|------------|-------------|
| Implication (A ⊃ B) | Function type (A → B) | Function |
| Conjunction (A ∧ B) | Product type (A × B) | Record/Pair |
| Disjunction (A ∨ B) | Sum type (A + B) | Variant/Match |
| True (⊤) | Unit type (1) | () |
| False (⊥) | Void type (0) | — |

**What Kō inherits:** Kō's type system is a direct expression of Curry-Howard. Every type in Kō is a proposition, every value is a proof, and pattern matching is proof case analysis.

**Key papers:**
- Curry, H.B. & Feys, R. (1958). *Combinatory Logic*, Vol. 1. North-Holland.
- Howard, W.A. (1980). "The Formulae-as-Types Notion of Construction." In *To H.B. Curry: Essays on Combinatory Logic, Lambda Calculus and Formalism*, pp. 479–490. [PDF](https://homepages.inf.ed.ac.uk/wadler/papers/propositions-as-types/propositions-as-types.pdf) (Wadler's exposition)
- Wadler, P. (2015). "Propositions as Types." *Communications of the ACM*, 58(12), 75–84. [PDF](https://homepages.inf.ed.ac.uk/wadler/papers/propositions-as-types/propositions-as-types.pdf)
- Pfenning, F. (2001). "Proofs as Programs." [PDF](https://plv.mpi-sws.org/plerg/papers/pfenning-proofs-progs-2up.pdf)
- Harper, R. (2016). *Practical Foundations for Programming Languages*. Cambridge University Press. [Online](https://www.cs.cmu.edu/~rwh/pfpl/)

---

## 3. Hindley-Milner Type Inference — Letting the Compiler Figure It Out

The type system Kō uses. Hindley-Milner (HM) finds the most general type for every expression without requiring type annotations.

### The Key Insight: Algorithm W

Given an expression, generate constraints on type variables, then use unification to solve them. The result is the **principal type** — the most general type compatible with the constraints.

### Let-Polymorphism

The `let` (or `fn`) binding introduces polymorphism:

```
let id = λx. x in (id 3, id True)
```

`id` has type `∀α. α → α`, meaning it can be used at different types at each call site. This is the key difference between `let id = ... in ...` and `(λid. ...) (λx. x)`.

### Generalization and Instantiation

- **Generalization** (at `let`/`fn`): close over free type variables → `∀α. α → α`
- **Instantiation** (at use site): open the `∀` → `α → α` where `α` is fresh

**What Kō inherits:** Kō uses HM with let-polymorphism. The typechecker implements Algorithm W (with some modifications for error messages). Type inference is fully automatic — no annotations required (though Kō supports them for readability).

**Key papers:**
- Hindley, J.R. (1969). "The Principal Type-Scheme of an Object in Combinatory Logic." *Transactions of the American Mathematical Society*, 146, 29–60. [PDF](https://www.cs.tufts.edu/~nr/cs257/archive/roger-hindley/principal-type-scheme.pdf) | [DOI](https://doi.org/10.1090/S0002-9947-1969-0249428-5)
- Milner, R. (1978). "A Theory of Type Polymorphism in Programming." *Journal of Computer and System Sciences*, 17(3), 348–375. [PDF](https://homepages.inf.ed.ac.uk/wadler/papers/papers-we-love/milner-type-polymorphism.pdf) | [DOI](https://doi.org/10.1016/0022-0000(78)90014-4)
- Damas, L. & Milner, R. (1982). "Principal Type-Schemes for Functional Programs." *Proceedings of the 9th ACM SIGPLAN-SIGACT Symposium on Principles of Programming Languages (POPL)*, pp. 207–212. [PDF](https://homes.cs.washington.edu/~mernst/teaching/6.883/readings/p207-damas.pdf) | [DOI](https://doi.org/10.1145/582153.582176)
- Pierce, B.C. (2002). *Types and Programming Languages*. MIT Press. — Chapter 22 covers HM in depth.
- Wikipedia — [Hindley–Milner type system](https://en.wikipedia.org/wiki/Hindley%E2%80%93Milner_type_system)

---

## 4. Unification — Solving Type Equations

Robinson's unification algorithm (1965) is the engine behind HM type inference. Given two types, find a substitution that makes them equal.

### The Algorithm

1. Take two terms (types)
2. Find the "disagreement set" — the first place they differ
3. If one side is a variable, substitute it for the other
4. If both are function types, unify their components
5. If both are different constructors, fail (type error)

### Most General Unifier (MGU)

The substitution found is the **most general** — any other unifier can be obtained by composing it with another substitution. This ensures type inference finds principal types.

**What Kō inherits:** The typechecker uses unification at its core. Every `=` comparison, every function application, every pattern match drives unification constraints.

**Key papers:**
- Robinson, J.A. (1965). "A Machine-Oriented Logic Based on the Resolution Principle." *Journal of the ACM*, 12(1), 23–41. [DOI](https://doi.org/10.1145/321250.321253) | [PDF](https://www.cs.tufts.edu/~nr/cs257/archive/john-alan-robinson/resolution.pdf)
- Robinson, J.A. (1984). "Computational Logic: The Unification Computation." [PDF](https://aitopics.org/download/classics:E35191E8) — Robinson's own later exposition.

---

## 5. Algebraic Data Types and Pattern Matching

### Sum Types (ADTs)

Sum types model "this value is one of these variants." They correspond to logical disjunction (A ∨ B) under Curry-Howard.

```
type Expr =
  | Num Int
  | Add Expr Expr
  | Mul Expr Expr
```

Each variant is a constructor. `Num 42` is a value of type `Expr`. This is the same idea as tagged unions, but with compile-time safety.

### Pattern Matching

Pattern matching is a form of **case analysis** with **destructuring**. It compiles to a decision tree or backtracking automaton.

### Compilation Strategy

Two main approaches:

1. **Decision Trees** (Augustsson 1985, Maranget 2008) — each test branches to exactly one path; no backtracking; code may be duplicated. O(n) tests in the worst case, but each subterm is tested at most once.

2. **Backtracking Automata** (Cardelli 1984, Le Fessant & Maranget 2001) — linear code; may re-test subterms; uses jumps for backtracking. More compact code, but potentially slower.

Kō uses **decision trees** (the simpler approach for its match expressions). The match compiler in `codegen.zig` generates a linear chain of comparison blocks, which is a degenerate form of decision tree.

**What Kō inherits:** Kō's sum types and pattern matching follow the ML tradition. The compiler generates sequential tests (cmp → branch → body) which is the simplest form of decision tree compilation.

**Key papers:**
- Augustsson, L. (1985). "Compiling Pattern Matching." In *Proceedings of the Second Conference on Functional Programming Languages and Computer Architecture (FPCA)*, LNCS vol. 201, pp. 368–381. Springer. [DOI](https://doi.org/10.1007/3-540-15975-4_48) | [PDF](https://www.cs.tufts.edu/~nr/pubs/match.pdf) (Ramsey's collection)
- Maranget, L. (2008). "Compiling Pattern Matching to Good Decision Trees." *Proceedings of the ACM Workshop on ML*, pp. 1–12. [PDF](http://moscova.inria.fr/~maranget/papers/ml05e-maranget.pdf) | [DOI](https://doi.org/10.1145/1411304.1411311)
- Le Fessant, F. & Maranget, L. (2001). "Optimizing Pattern Matching." *Proceedings of the Sixth ACM SIGPLAN International Conference on Functional Programming (ICFP)*, pp. 26–37. [DOI](https://doi.org/10.1145/507635.507641) | [PDF](http://pauillac.inria.fr/~maranget/papers/opat/)
- Wadler, P. (1987). "Views: A Way for Pattern Matching to Cohabit with Data Abstraction." *Proceedings of the 14th ACM SIGPLAN-SIGACT Symposium on Principles of Programming Languages (POPL)*, pp. 307–313. [DOI](https://doi.org/10.1145/41625.41653) | [PDF](https://www.cs.tufts.edu/~nr/cs257/archive/phil-wadler/views.pdf)
- Wadler, P. & Barrett, G. (1987). "Derivation of a Pattern-Matching Compiler." [PDF](https://homepages.inf.ed.ac.uk/wadler/papers/pattern/pattern.pdf)
- Jones, S.L.P. (1987). *The Implementation of Functional Programming Languages*. Prentice-Hall. [Online](https://simon.peytonjones.org/assets/pdfs/slpj-book-1987-2up-searchable.pdf) — Chapter 5 covers pattern matching compilation.

---

## 6. Closure Conversion and Lambda Lifting

When a lambda captures variables from its enclosing scope, the compiler must make those variables available at runtime. Two strategies:

### Closure Conversion (Appel 1992)

Transform each lambda into a function that takes an explicit **environment** (closure record) as an extra argument. The closure record holds:
1. A pointer to the function code
2. The captured variables

This is what Kō does. A partial application creates a closure struct: `{ fn_ptr, arity, applied_count, applied_args[] }`.

### Lambda Lifting (Hughes 1984, Johnsson 1985)

Hoist all functions to the top level. Free variables become additional parameters. Each function call passes the captured variables explicitly.

This is an alternative to closure conversion. It avoids heap allocation for closures but may pass unnecessary arguments.

### The Difference

| Aspect | Closure Conversion | Lambda Lifting |
|--------|-------------------|----------------|
| Where closures live | Heap-allocated records | Extra parameters |
| Free variables | Loaded from closure record | Passed as arguments |
| Nested functions | Preserved | Eliminated |
| Partial application | Natural | Requires thunks |

**What Kō inherits:** Kō uses **closure conversion**. Lambdas become anonymous LLVM functions, and partial application creates heap-allocated closure structs with the `{ fn_ptr, arity, count, args[] }` layout.

**Key papers:**
- Appel, A.W. (1992). *Compiling with Continuations*. Cambridge University Press. [PDF](https://www.ccs.neu.edu/home/shivers/cs6983/papers/Appel,%20Andrew%20~%20Compiling%20with%20Continuations.pdf) — Chapter 10 covers closure conversion.
- Appel, A.W. & Jim, T. (1989). "Continuation-Passing, Closure-Passing Style." *Proceedings of the 16th ACM SIGPLAN-SIGACT Symposium on Principles of Programming Languages (POPL)*, pp. 293–302. [PDF](https://www.cs.princeton.edu/~appel/papers/cpcps.pdf)
- Shao, Z. & Appel, A.W. (1994). "Efficient and Safe-for-Space Closure Conversion." *ACM Transactions on Programming Languages and Systems*, 17(1), 26–54. [PDF](https://www.classes.cs.uchicago.edu/archive/2011/spring/22620-1/papers/closure-conversion.pdf)
- Paraskevopoulou, Z. & Appel, A.W. (2015). "Closure Conversion Is Safe for Space." [PDF](https://www.cs.princeton.edu/~appel/papers/safe-closure.pdf)
- Hughes, J. (1984). "The Design and Implementation of Functional Programming Languages." Ph.D. thesis, University of Glasgow. — Introduced lambda lifting.
- Johnsson, T. (1985). "Lambda Lifting: Transforming Programs to Recursive Equations." In *Proceedings of the Conference on Functional Programming Languages and Computer Architecture*, pp. 190–203. Springer. [PDF](https://ia601204.us.archive.org/10/items/nonzen-cs-papers-bucket0/SHA256E-s202812--8877d0b4507bc5c238fd7ea2bab007bfaef604200e3fddad4d349fae3bed75f5.pdf)
- Peyton Jones, S.L. (1987). *The Implementation of Functional Programming Languages*. Prentice-Hall. [Online](https://simon.peytonjones.org/assets/pdfs/slpj-book-1987-2up-searchable.pdf) — Chapter 14 covers lambda lifting.
- Matt Might. "Closure Conversion: How to Compile Lambda." [Article](https://matt.might.net/articles/closure-conversion/)

---

## 7. Reference Counting — Memory Without a GC

Reference counting is the oldest automatic memory management technique. Each object tracks how many pointers point to it. When the count reaches zero, the object is unreachable and can be freed.

### Collins (1960)

George Collins published the first practical reference counting algorithm. Unlike McCarthy's tracing collector (mark-sweep, also 1960), reference counting is **incremental** — cleanup happens immediately when a pointer is destroyed, not in a separate pause.

### Key Properties

- **Deterministic** — no GC pauses; cleanup is immediate
- **Incremental** — work is spread across the program's execution
- **Cannot collect cycles** — circular references (A → B → A) keep each other alive
- **Overhead** — every pointer mutation requires increment/decrement

### Deferred Reference Counting

An optimization: don't track stack pointers (they're always live). Only decrement on heap-to-heap pointer changes. This reduces overhead significantly while preserving the key property: heap objects with RC=0 are freed immediately.

### Kō's Approach

Kō uses **scope-based decref**:
1. Track all heap allocations in a scope (`scope_heap_values`)
2. On scope exit, decref all tracked values (except the return value)
3. RC=0 → immediate free

This is a simplified form of deferred reference counting. It doesn't handle cycles (Kō has no cyclic data structures), and it's sufficient for the language's needs.

**What Kō inherits:** Kō's `ko_alloc`/`ko_incref`/`ko_decref` system is a direct implementation of Collins-style reference counting, with scope-based decref as the optimization.

**Key papers:**
- Collins, G.E. (1960). "A Method for Overlapping and Erasure of Lists." *Communications of the ACM*, 3(12), 687–691. [DOI](https://doi.org/10.1145/367487.367501) — The original reference counting paper.
- McCarthy, J. (1960). "Recursive Functions of Symbolic Expressions and Their Computation by Machine, Part I." *Communications of the ACM*, 3(4), 184–195. [DOI](https://doi.org/10.1145/367157.367164) — The mark-sweep GC paper (reference point).
- Wilson, P.R. (1994). "Uniprocessor Garbage Collection Techniques." *Proceedings of the International Workshop on Memory Management*, LNCS vol. 742, pp. 1–42. [PDF](https://flint.cs.yale.edu/cs421/papers/Wilson-GC.pdf) — Comprehensive survey of RC vs tracing methods.
- Jones, R. & Lins, R. (1996). *Garbage Collection: Algorithms for Automatic Dynamic Memory Management*. Wiley. — The definitive textbook on GC.
- Shahriyar, R., Blackburn, S.M., & Frampton, D. (2013). "Micro-benchmarks for Determining the Need for Precise Tracing GCs." [PDF](https://www.cs.utexas.edu/users/mckinley/papers/rcix-oopsla-2013.pdf) — Modern analysis of RC vs tracing.

---

## 8. SSA Form and LLVM IR

### Static Single Assignment (SSA)

A program representation where every variable is assigned exactly once. This simplifies dataflow analysis and enables powerful optimizations.

**Key properties:**
- Each variable has a single definition point
- φ (phi) nodes merge values from different control flow paths
- Enables constant propagation, dead code elimination, register allocation

### LLVM

LLVM uses SSA form internally. When Kō generates LLVM IR, it's writing SSA instructions. The phi nodes in Kō's if-expressions and match expressions are direct applications of SSA theory.

**What Kō inherits:** Kō generates LLVM IR (which is SSA form). The phi nodes in `codegenIf` and `codegenMatch` are SSA phi instructions. LLVM's optimizer then applies standard SSA optimizations to Kō's generated code.

**Key papers:**
- Cytron, R., Ferrante, J., Rosen, B.K., Wegman, M.N., & Zadeck, F.K. (1991). "Efficiently Computing Static Single Assignment Form and the Control Dependence Graph." *ACM Transactions on Programming Languages and Systems*, 13(4), 451–490. [DOI](https://doi.org/10.1145/115372.115320) | [PDF](https://faculty.cc.gatech.edu/~harrold/6340/cs6340_fall2009/Readings/cytron91oct.pdf) — The foundational SSA paper.
- Cytron, R., Ferrante, J., Rosen, B.K., Wegman, M.N., & Zadeck, F.K. (1989). "An Efficient Method of Computing Static Single Assignment Form." *Proceedings of the 16th ACM SIGPLAN-SIGACT Symposium on Principles of Programming Languages (POPL)*, pp. 25–35. [DOI](https://doi.org/10.1145/75277.75280) — Earlier conference version.
- LLVM Project — [LLVM Language Reference Manual](https://llvm.org/docs/LangRef.html) — The specification of the IR Kō generates.

---

## 9. Evaluation Strategies

### Eager vs Lazy Evaluation

| Strategy | When arguments are evaluated | Used by |
|----------|----------------------------|---------|
| **Eager** (strict) | Before function call | C, Java, OCaml, Kō |
| **Lazy** (non-strict) | When needed | Haskell, Miranda |

Kō is **eager** — arguments are evaluated before the function is called. This means:
- No thunks or lazy evaluation overhead
- Stack overflow is possible (not in Haskell)
- Simpler mental model

### Call-by-Value vs Call-by-Name

Kō uses **call-by-value**: arguments are evaluated exactly once, before the function call. This is the standard for imperative and most functional languages.

**What Kō inherits:** Kō's eagerness is a deliberate design choice. It simplifies reasoning, debugging, and codegen (no thunking overhead). The tradeoff is that Kō can't express infinite data structures or short-circuit `and`/`or` without explicit control flow.

**Key papers:**
- Plotkin, G.D. (1975). "Call-by-Name, Call-by-Value and the Lambda-Calculus." *Theoretical Computer Science*, 1(2), 125–159. [DOI](https://doi.org/10.1016/0304-3975(75)90017-1) — The foundational paper on evaluation strategies.
- Abramsky, S. (1991). "Abstract Interpretation, Logical Relations and Canonical Forms." *Bulletin of the European Association for Theoretical Computer Science*, 44, 132–152.

---

## 10. Indentation-Based Syntax

Kō uses indentation-based syntax (like Python, Haskell, and Miranda) rather than braces. This is a syntactic choice, not a semantic one, but it has roots in language design research.

### Offside Rule

The "offside rule" (Peyton Jones 1987) formalizes indentation-based parsing: a token can only appear to the right of the leftmost token of the previous line's context.

**Key papers:**
- Peyton Jones, S.L. (1987). *The Implementation of Functional Programming Languages*. Prentice-Hall. [Online](https://simon.peytonjones.org/assets/pdfs/slpj-book-1987-2up-searchable.pdf) — Chapter 9 defines the offside rule.
- Lindley, C. & Wadler, P. (1985). "Indentation Sensitivity in Functional Programming Languages." *Technical Report CSR-165-85*, University of Edinburgh.

---

## 11. Type Soundness — The Guarantee

The **type soundness theorem** (also called the "progress and preservation" theorem) guarantees that well-typed programs don't "go wrong."

### Progress

If a program is well-typed, it's either a value or it can take a step (reduce further). No well-typed program gets stuck.

### Preservation

If a well-typed program takes a step, the result is still well-typed.

Together, these guarantee: **a well-typed Kō program will never encounter a type error at runtime.** Types are checked at compile time and erased before execution.

**What Kō inherits:** The type soundness theorem is the foundation of Kō's type system. It's proved (in principle) by the standard Hindley-Milner metatheory. The W algorithm's soundness and completeness (Damas-Milner 1982) ensure that Kō's typechecker is correct.

**Key papers:**
- Wright, A.K. & Felleisen, M. (1994). "A Syntactic Approach to Type Soundness." *Information and Computation*, 115(1), 38–94. [DOI](https://doi.org/10.1006/inco.1994.1093) — The modern "progress + preservation" formulation.
- Milner, R. (1978). "A Theory of Type Polymorphism in Programming." — Proves semantic soundness for HM.
- Pierce, B.C. (2002). *Types and Programming Languages*. MIT Press. — Chapter 8 proves type soundness for the simply-typed lambda calculus.

---

## 12. The Full Pipeline: Source → Machine Code

Kō's compilation pipeline follows the standard functional language compilation strategy:

```
Source Code
    ↓ [Lexer]
Token Stream
    ↓ [Parser]
Abstract Syntax Tree (AST)
    ↓ [Typechecker]
Typed AST (with inferred types)
    ↓ [Codegen]
LLVM IR (SSA form)
    ↓ [LLVM Optimizer]
Optimized LLVM IR
    ↓ [LLVM Backend]
Machine Code (.o or in-memory)
    ↓ [Linker]
Executable
```

### How Kō's Pipeline Maps to Theory

| Pipeline Stage | Kō Implementation | Theoretical Basis |
|----------------|-------------------|-------------------|
| Lexing | `src/lexer.zig` | Regular expressions, DFAs |
| Parsing | `src/parser.zig` | Recursive descent, PEG grammars |
| Type Inference | `src/typecheck.zig` | Hindley-Milner (Algorithm W) |
| Unification | `src/typecheck.zig` | Robinson (1965) |
| Pattern Compilation | `src/codegen.zig` | Augustsson (1985), linear decision trees |
| Closure Conversion | `src/codegen.zig` | Appel (1992) |
| Code Generation | `src/codegen.zig` | SSA form (Cytron 1991), LLVM IR |
| Memory Management | `ko_runtime.c` | Reference counting (Collins 1960) |

---

## 13. What Makes Kō "Weird" (on purpose)

Kō is deliberately minimalist. The design choices are research hypotheses:

1. **Eager + functional + refs** — Can we get the benefits of purity (reasoning, type safety) with the pragmatism of mutation (performance, I/O)? OCaml says yes. Kō tests whether a simpler version works.

2. **Pattern matching as the only control flow** — No `while`, no `for`, no `switch`. Just `match` and `if` (which is sugar for match on Bool). This is the ML philosophy: case analysis is sufficient.

3. **HM inference with good error messages** — The open problem. Type inference finds principal types, but explaining *why* a type error occurred is hard. Kō's `ErrorContext` is a step toward this.

4. **No type classes, no effects, no GADTs** — Kō keeps the type system simple. The hypothesis: a small, predictable type system with good inference is more useful than a large, complex one.

5. **LLVM as the backend** — Instead of writing a custom compiler, Kō leverages LLVM's optimizer and code generator. This gives Kō industrial-strength optimization for free.

---

## 14. Comparison with Related Languages

| Language | Type System | Evaluation | Pattern Matching | References | Year |
|----------|------------|------------|-----------------|------------|------|
| ML (1973) | HM | Eager | Yes | No (refs in SML) | 1973 |
| Haskell (1990) | HM + type classes | Lazy | Yes | No (monads) | 1990 |
| OCaml (1996) | HM + row polymorphism | Eager | Yes | Yes | 1996 |
| Elm (2012) | HM | Eager | Yes | No | 2012 |
| Rust (2015) | HM + ownership | Eager | Yes | No (ownership) | 2015 |
| **Kō** | HM | Eager | Yes | **Yes** | 2026 |

Kō is closest to OCaml with a simpler type system and no side effects beyond refs. The key differentiator: Kō is a testbed for exploring whether a minimal functional language with refs and pattern matching is sufficient for systems programming.

---

## References (BibTeX)

```bibtex
@article{Hindley1969,
  author  = {J. R. Hindley},
  title   = {The Principal Type-Scheme of an Object in Combinatory Logic},
  journal = {Transactions of the American Mathematical Society},
  volume  = {146},
  pages   = {29--60},
  year    = {1969},
  doi     = {10.1090/S0002-9947-1969-0249428-5}
}

@article{Milner1978,
  author  = {Robin Milner},
  title   = {A Theory of Type Polymorphism in Programming},
  journal = {Journal of Computer and System Sciences},
  volume  = {17},
  number  = {3},
  pages   = {348--375},
  year    = {1978},
  doi     = {10.1016/0022-0000(78)90014-4}
}

@inproceedings{DamasMilner1982,
  author    = {Luis Damas and Robin Milner},
  title     = {Principal Type-Schemes for Functional Programs},
  booktitle = {Proceedings of the 9th ACM SIGPLAN-SIGACT Symposium on Principles of Programming Languages (POPL)},
  pages     = {207--212},
  year      = {1982},
  doi       = {10.1145/582153.582176}
}

@article{Robinson1965,
  author  = {John A. Robinson},
  title   = {A Machine-Oriented Logic Based on the Resolution Principle},
  journal = {Journal of the ACM},
  volume  = {12},
  number  = {1},
  pages   = {23--41},
  year    = {1965},
  doi     = {10.1145/321250.321253}
}

@inproceedings{Augustsson1985,
  author    = {Lennart Augustsson},
  title     = {Compiling Pattern Matching},
  booktitle = {Proceedings of the Second Conference on Functional Programming Languages and Computer Architecture (FPCA)},
  series    = {LNCS},
  volume    = {201},
  pages     = {368--381},
  year      = {1985},
  publisher = {Springer-Verlag},
  doi       = {10.1007/3-540-15975-4_48}
}

@inproceedings{Maranget2008,
  author    = {Luc Maranget},
  title     = {Compiling Pattern Matching to Good Decision Trees},
  booktitle = {Proceedings of the ACM Workshop on ML},
  pages     = {1--12},
  year      = {2008},
  doi       = {10.1145/1411304.1411311}
}

@inproceedings{LeFessantMaranget2001,
  author    = {Fabrice Le Fessant and Luc Maranget},
  title     = {Optimizing Pattern Matching},
  booktitle = {Proceedings of the Sixth ACM SIGPLAN International Conference on Functional Programming (ICFP)},
  pages     = {26--37},
  year      = {2001},
  doi       = {10.1145/507635.507641}
}

@book{Appel1992,
  author    = {Andrew W. Appel},
  title     = {Compiling with Continuations},
  publisher = {Cambridge University Press},
  year      = {1992}
}

@article{ShaoAppel1994,
  author  = {Zhong Shao and Andrew W. Appel},
  title   = {Efficient and Safe-for-Space Closure Conversion},
  journal = {ACM Transactions on Programming Languages and Systems},
  volume  = {17},
  number  = {1},
  pages   = {26--54},
  year    = {1994},
  doi     = {10.1145/174721.174724}
}

@inproceedings{Johnsson1985,
  author    = {Thomas Johnsson},
  title     = {Lambda Lifting: Transforming Programs to Recursive Equations},
  booktitle = {Proceedings of the Conference on Functional Programming Languages and Computer Architecture},
  pages     = {190--203},
  year      = {1985},
  publisher = {Springer-Verlag}
}

@article{Collins1960,
  author  = {George E. Collins},
  title   = {A Method for Overlapping and Erasure of Lists},
  journal = {Communications of the ACM},
  volume  = {3},
  number  = {12},
  pages   = {687--691},
  year    = {1960},
  doi     = {10.1145/367487.367501}
}

@article{Cytron1991,
  author  = {Ron K. Cytron and Jeanne Ferrante and Barry K. Rosen and Mark N. Wegman and F. Kenneth Zadeck},
  title   = {Efficiently Computing Static Single Assignment Form and the Control Dependence Graph},
  journal = {ACM Transactions on Programming Languages and Systems},
  volume  = {13},
  number  = {4},
  pages   = {451--490},
  year    = {1991},
  doi     = {10.1145/115372.115320}
}

@inproceedings{Wadler1987,
  author    = {Philip Wadler},
  title     = {Views: A Way for Pattern Matching to Cohabit with Data Abstraction},
  booktitle = {Proceedings of the 14th ACM SIGPLAN-SIGACT Symposium on Principles of Programming Languages (POPL)},
  pages     = {307--313},
  year      = {1987},
  doi       = {10.1145/41625.41653}
}

@article{WrightFelleisen1994,
  author  = {Andrew K. Wright and Matthias Felleisen},
  title   = {A Syntactic Approach to Type Soundness},
  journal = {Information and Computation},
  volume  = {115},
  number  = {1},
  pages   = {38--94},
  year    = {1994},
  doi     = {10.1006/inco.1994.1093}
}

@book{PeytonJones1987,
  author    = {Simon Peyton Jones},
  title     = {The Implementation of Functional Programming Languages},
  publisher = {Prentice-Hall},
  year      = {1987},
  url       = {https://simon.peytonjones.org/assets/pdfs/slpj-book-1987-2up-searchable.pdf}
}

@book{Pierce2002,
  author    = {Benjamin C. Pierce},
  title     = {Types and Programming Languages},
  publisher = {MIT Press},
  year      = {2002}
}

@article{Plotkin1975,
  author  = {Gordon D. Plotkin},
  title   = {Call-by-Name, Call-by-Value and the Lambda-Calculus},
  journal = {Theoretical Computer Science},
  volume  = {1},
  number  = {2},
  pages   = {125--159},
  year    = {1975},
  doi     = {10.1016/0304-3975(75)90017-1}
}
```
