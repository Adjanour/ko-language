---
title: "Kō Design Documents"
---

# Kō Design Documents

## Compile-Time AST Construction Helpers

> **Status:** Design Draft  
> **Date:** 2026-07-12  
> **Research:** Zig comptime, MetaOCaml, Template Haskell, Lisp macros

### Problem

Kō's comptime evaluator can compute values at compile time, but can't:

1. **Construct AST nodes**: no way to build code programmatically
2. **Manipulate code**: no way to transform or generate code at compile time
3. **Write macros**: no way to define new syntax or code transformations
4. **Domain-specific languages**: can't embed DSLs that compile to efficient code

### Proposed Design: `code` Keyword

```ko
# Quote an expression as code
let ast = code (1 + 2)

# Quote with variables (antiquotation)
let x = code (42)
let ast = code (x + 1)  # ast = (42 + 1)

# Manipulate code at compile time
comptime fn double_code ast =
  code (ast + ast)

let result = double_code (code (3))  # result = (3 + 3)

# Build AST programmatically
comptime fn make_add left right =
  code (left + right)

let sum = make_add (code (1)) (code (2))  # sum = (1 + 2)
```

### Comptime AST Constructor Functions

```ko
comptime fn lit value = Code.literal value
comptime fn var name = Code.identifier name
comptime fn app func arg = Code.application func arg
comptime fn lam param body = Code.lambda param body
comptime fn let name value body = Code.let name value body
comptime fn ifte cond then else_ = Code.if_then_else cond then else_
comptime fn binop op left right = Code.binary_op op left right
comptime fn block exprs = Code.block exprs
comptime fn ctor name args = Code.constructor name args
comptime fn tuple elems = Code.tuple elems
comptime fn record fields = Code.record fields

# Code manipulation
comptime fn code_size ast = Code.size ast
comptime fn code_subst ast name replacement = Code.substitute ast name replacement

# Code evaluation
comptime fn eval code = Code.eval code
comptime fn type_of code = Code.type_of code
```

### Comparison with Existing Features

| Feature | `comptime expr` | `code expr` | `stage expr` |
|---------|-----------------|-------------|--------------|
| Evaluation time | Compile time | Compile time | Compile time |
| Result type | ComptimeValue | CodeNode | Runtime type |
| Splicing | Scalar only | To CodeNode | To LLVM IR |
| Manipulation | Limited | Full AST | Via comptime |
| Use case | Constants | Macros, DSLs | Code generation |

### Implementation Plan

- **Phase 1**: Add `code: *CodeNode` to ComptimeValue, implement `CodeNode` structure, handle `code expr` in comptime evaluator, add code constructors and evaluation
- **Phase 2**: Substitution, code inspection, code transformation (map/fold over AST)
- **Phase 3**: Integration with `stage` for LLVM IR emission, type checking of constructed code

---

## Error Handling

> **Status:** Design Draft
> **Date:** 2026-07-27
> **Research:** Rust panic/Result split, Roc's total stdlib, OCaml's `Division_by_zero`, Koka's `exn` effect

### The Two Buckets

| | Recoverable (`Result`) | Unrecoverable (`panic`) |
|---|---|---|
| Meaning | Expected failure a caller should handle | Broken invariant / programmer error |
| Examples | `String.to_int` on bad input, file not found, `div`/`mod` by zero, safe list `at`/index | empty-list `head`/`tail` on the panicking variants, stack overflow, `assert` failure |
| Mechanism | Already exists: `Result`, `?`, `map`/`fold`/`and_then` | Generalize the stack-overflow path into a real `panic(msg)` |
| Rule of thumb | Failure a well-formed program can hit from real input | Failure that means the program itself has a bug |

Division by zero belongs in the `Result` bucket (Roc's answer), because a divisor coming from user input isn't a programmer error. If that's judged too heavy, the fallback is OCaml's answer: keep the signature, but panic with a message instead of trapping.

### `panic` as a General Mechanism

Generalize the stack-overflow path into `panic : String -> a`: print to stderr, exit nonzero, no unwinding. Every other panic site (head/tail on empty, assert failure, out-of-bounds indexing) calls through this one mechanism.

### Naming

```ko
Result.unwrap    : Result a b -> a        # panics on Err
Result.unwrapOr  : a -> Result a b -> a   # supplies a default
```

### Implementation Plan

- **Phase 1**: Generalize stack-overflow panic into `panic(msg)` builtin; guard div/mod codegen with zero check; rename `ko_result_unwrap` → `ko_result_unwrap_or`, add real panicking `unwrap`; fix `head`/`tail` in `List.ko` to panic on `Nil`
- **Phase 2**: Decide Maybe-returning vs panicking for `head`/`tail` and indexing
- **Phase 3**: Source location in panic messages; implement `assert`/`assert_eq`/`test`

---

## Staged Compilation

> **Status:** Design Draft  
> **Date:** 2026-07-12  
> **Research:** MacoCaml (OCaml), Template Haskell, MetaML, Zig comptime

### Problem

Kō's `comptime` evaluates expressions at compile time and splices scalar results into LLVM IR. But it can't:

1. **Generate code**: comptime can't produce runtime functions or complex data structures
2. **Partial evaluation**: can't specialize functions for known inputs at compile time
3. **Zero-cost abstractions**: can't eliminate runtime overhead of generic code
4. **Domain-specific languages**: can't embed DSLs that compile to efficient native code

### Proposed Design: `stage` Keyword

```ko
# Stage an expression for compile-time evaluation
let optimized = stage (fibonacci 10)

# Stage with lambda for partial evaluation
# Known args evaluated at compile time, unknown args become runtime parameters
let fast_add = stage (\x y -> x + y) where x = 5

# Stage a function definition for specialization
comptime fn specialized_sort xs =
  match xs
    [] -> []
    pivot :: rest ->
      let smaller = stage (filter (\x -> x < pivot) rest)
      let larger = stage (filter (\x -> x >= pivot) rest)
      (specialized_sort smaller) ++ [pivot] ++ (specialized_sort larger)
```

### Semantics

1. `stage expr` evaluates `expr` at compile time
2. If `expr` reduces to a value, that value is spliced into the LLVM IR
3. If `expr` contains free variables, it becomes a lambda with those variables as parameters
4. `stage` is compile-time only: can't appear in runtime expressions

### Comparison with Existing `comptime`

| Feature | `comptime expr` | `stage expr` |
|---------|-----------------|--------------|
| Evaluation time | Compile time | Compile time |
| Result type | ComptimeValue | Runtime type |
| Splicing | Scalar only | Any type |
| Free variables | Error | Lambda |
| Side effects | Allowed | Restricted |
| Use case | Constants, simple computations | Code generation, specialization |

### Implementation Plan

- **Phase 1**: Add `stage` keyword to parser, `StageExpr` AST node, type as type of body, codegen evaluates at compile time and splices
- **Phase 2**: Extend comptime evaluator for free variables, generate lambdas for staged expressions with free vars, partial application specialization
- **Phase 3**: Staged pattern matching, staged recursion unrolling, staged generic specialization
