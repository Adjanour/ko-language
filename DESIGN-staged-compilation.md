# Staged Compilation Design for Kō

> **Status:** Design Draft  
> **Date:** 2026-07-12  
> **Research:** MacoCaml (OCaml), Template Haskell, MetaML, Zig comptime

---

## Problem

Kō's `comptime` evaluates expressions at compile time and splices scalar results into LLVM IR. But it can't:

1. **Generate code** — comptime can't produce runtime functions or complex data structures
2. **Partial evaluation** — can't specialize functions for known inputs at compile time
3. **Zero-cost abstractions** — can't eliminate runtime overhead of generic code
4. **Domain-specific languages** — can't embed DSLs that compile to efficient native code

## Research Summary

### MacoCaml (OCaml, 2023)
- **Quote-splice model**: `⟨e⟩` (quote) wraps code at level n+1, `$e` (splice) evaluates at level n-1
- **Macros as compile-time bindings**: `mac` keyword defines compile-time functions
- **Top-level splices trigger compile-time code generation**: `$e` at top level evaluates `e` at compile time, inserts result as runtime code
- **Phase distinction**: compile-time heaps discarded after compilation; compile-time computations don't interfere with runtime
- **Key insight**: macros and staging are unified — macros are just compile-time bindings, splices are just phase-crossing annotations

### Template Haskell (Haskell)
- **Staged type class constraints**: `CodeC C` proves constraint C in next stage
- **Splice environments**: instead of level-indexed evaluation, splices are bound to variables
- **Top-level splices**: `$(e)` evaluates `e` at compile time, inserts result as code

### Zig
- **`comptime` blocks**: evaluated at compile time, can use runtime syntax
- **`comptime` function parameters**: generic functions via comptime parameters
- **No explicit staging**: comptime is always at compile time, no runtime code generation
- **Key insight**: simple model, but limited — can't generate code that depends on runtime values

### MetaML
- **Two-level types**: `Code[T]` is a value of type T at the next stage
- **`run` construct**: evaluates staged code at runtime
- **Key insight**: formal foundation for staging, but complex type system

## Design Goals

1. **Build on existing comptime** — don't replace, extend
2. **Simple syntax** — one keyword, clear semantics
3. **Type-safe** — staged code must be well-typed
4. **Practical** — solve real problems (generic specialization, DSL compilation)
5. **No phase-crossing bugs** — compile-time side effects can't leak to runtime

## Proposed Design: `stage` Keyword

### Syntax

```ko
# Stage an expression for compile-time evaluation
# The result is spliced as runtime code
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

# Stage produces code, not values
let code = stage (1 + 2)  # code = 3 (spliced as literal)
let f = stage (\x -> x * 2)  # code = <function> (spliced as function)
```

### Semantics

1. `stage expr` evaluates `expr` at compile time
2. If `expr` reduces to a value, that value is spliced into the LLVM IR
3. If `expr` contains free variables, it becomes a lambda with those variables as parameters
4. `stage` is compile-time only — can't appear in runtime expressions

### Examples

```ko
# Partial evaluation: specialize fib for known input
comptime fn fib n =
  if n == 0 then 0
  else if n == 1 then 1
  else fib (n - 1) + fib (n - 2)

# Stage fib(10) → evaluates to 55 at compile time
let result = stage (fib 10)  # result = 55

# Stage fib(n) where n is unknown → generates specialized function
let fib_specialized = stage (\n -> fib n)  # generates unrolled function

# Generic sort specialized for Int
comptime fn specialized_sort xs =
  match xs
    [] -> []
    pivot :: rest ->
      let smaller = filter (\x -> x < pivot) rest
      let larger = filter (\x -> x >= pivot) rest
      (specialized_sort smaller) ++ [pivot] ++ (specialized_sort larger)

# Stage sort for known list → unrolled at compile time
let sorted = stage (specialized_sort [3, 1, 4, 1, 5])

# Stage sort for unknown list → generates specialized function
let sort_fn = stage (\xs -> specialized_sort xs)
```

## Implementation Plan

### Phase 1: Basic Staging (Minimal)

1. **Parser**: Add `stage` keyword, parse `stage expr`
2. **AST**: Add `StageExpr { body: *Expr }` node
3. **Typechecker**: Type `stage e` as the type of `e`
4. **Codegen**: Evaluate `stage e` at compile time, splice result
   - Scalar result → LLVM constant
   - Lambda result → LLVM function
   - Complex result → error (not yet supported)

### Phase 2: Partial Evaluation

1. **Comptime evaluator**: Extend to handle free variables
2. **Code generation**: Generate lambda for staged expressions with free vars
3. **Specialization**: Stage function applications with partial args

### Phase 3: Advanced Features

1. **Staged pattern matching**: Generate specialized match code
2. **Staged recursion**: Unroll recursive functions at compile time
3. **Staged types**: Generic functions specialized at compile time

## Open Questions

1. Should `stage` be `stage` or `compile` or `eval`?
2. How to handle staged expressions that produce non-scalar values?
3. Should staged code be type-checked before or after evaluation?
4. How to prevent infinite compile-time loops in staged code?
5. Should `stage` support `where` clauses for binding compile-time variables?

## Comparison with Existing `comptime`

| Feature | `comptime expr` | `stage expr` |
|---------|-----------------|--------------|
| Evaluation time | Compile time | Compile time |
| Result type | ComptimeValue | Runtime type |
| Splicing | Scalar only | Any type |
| Free variables | Error | Lambda |
| Side effects | Allowed | Restricted |
| Use case | Constants, simple computations | Code generation, specialization |

## Risk Assessment

- **Low risk**: Extends existing comptime infrastructure
- **Medium risk**: Partial evaluation is complex
- **High risk**: Phase-crossing bugs if side effects leak

## Next Steps

1. Get user feedback on syntax
2. Implement Phase 1 (basic staging)
3. Test with real use cases
4. Iterate on design based on experience
