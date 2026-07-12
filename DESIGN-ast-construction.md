# Compile-Time AST Construction Helpers for Kō

> **Status:** Design Draft  
> **Date:** 2026-07-12  
> **Research:** Zig comptime, MetaOCaml, Template Haskell, Lisp macros

---

## Problem

Kō's comptime evaluator can compute values at compile time, but can't:

1. **Construct AST nodes** — no way to build code programmatically
2. **Manipulate code** — no way to transform or generate code at compile time
3. **Write macros** — no way to define new syntax or code transformations
4. **Domain-specific languages** — can't embed DSLs that compile to efficient code

## Research Summary

### Zig comptime
- **No AST manipulation**: comptime can only evaluate existing code, not construct new code
- **Type reflection**: can inspect types at compile time
- **Generic functions**: comptime parameters enable type-generic code
- **Limitation**: can't generate code that doesn't exist in the source

### MetaOCaml
- **Quotations**: `.{ e .}` wraps code as a value at compile time
- **Splicing**: `.(e)` evaluates code and splices result
- **Code constructors**: `.~` for antiquotation (insert code into quotations)
- **Key insight**: code is first-class values that can be manipulated

### Template Haskell
- **Quasi-quoters**: `[| e |]` creates code values
- **Splices**: `$(e)` evaluates code and inserts result
- **Code constructors**: `varE`, `appE`, `lamE` etc. for building AST
- **Key insight**: AST construction via combinators

### Lisp
- **S-expressions**: code IS data, can be manipulated directly
- **Macros**: transform code at compile time
- **Key insight**: homoiconicity — code and data share representation

## Design Goals

1. **Build on existing comptime** — extend ComptimeValue to represent code
2. **Simple API** — combinators for common AST operations
3. **Type-safe** — constructed code must be well-typed
4. **Practical** — solve real problems (macros, DSLs, code generation)
5. **No phase-crossing bugs** — compile-time code construction can't leak to runtime

## Proposed Design: Comptime AST Constructors

### New ComptimeValue Variant: `code`

```zig
// In ComptimeValue union:
code: *CodeNode,  // AST node for code construction

pub const CodeNode = struct {
    tag: CodeTag,
    data: union(enum) {
        literal: ComptimeValue,
        identifier: []const u8,
        application: struct { func: *CodeNode, arg: *CodeNode },
        lambda: struct { param: []const u8, body: *CodeNode },
        let: struct { name: []const u8, value: *CodeNode, body: *CodeNode },
        if_then_else: struct { cond: *CodeNode, then: *CodeNode, else_: *CodeNode },
        match: struct { scrutinee: *CodeNode, arms: []MatchArm },
        binary_op: struct { op: []const u8, left: *CodeNode, right: *CodeNode },
        unary_op: struct { op: []const u8, operand: *CodeNode },
        block: struct { exprs: []*CodeNode },
        constructor: struct { name: []const u8, args: []*CodeNode },
        tuple: struct { elems: []*CodeNode },
        record: struct { fields: []RecordField },
    },
};
```

### Syntax: `code` Keyword

```ko
# Quote an expression as code
let ast = code (1 + 2)

# Quote with variables (antiquotation)
let x = code (42)
let ast = code (x + 1)  # ast = (42 + 1)

# Quote a function
let add_ast = code (\x -> x + 1)

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
# Built-in AST constructors (available in comptime)
comptime fn lit value = Code.literal value
comptime fn var name = Code.identifier name
comptime fn app func arg = Code.application func arg
comptime fn lam param body = Code.lambda param body
comptime fn let name value body = Code.let name value body
comptime fn ifte cond then else_ = Code.if_then_else cond then else_
comptime fn binop op left right = Code.binary_op op left right
comptime fn unaryop op operand = Code.unary_op op operand
comptime fn block exprs = Code.block exprs
comptime fn ctor name args = Code.constructor name args
comptime fn tuple elems = Code.tuple elems
comptime fn record fields = Code.record fields

# Code manipulation
comptime fn code_size ast = Code.size ast
comptime fn code_children ast = Code.children ast
comptime fn code_subst ast name replacement = Code.substitute ast name replacement

# Code evaluation
comptime fn eval code = Code.eval code
comptime fn type_of code = Code.type_of code
```

### Examples

```ko
# Macro: generate a function from a name and body
comptime fn make_fn name body =
  code (fn name = body)

let my_fn = make_fn (code "my_function") (code (42))
# Expands to: fn my_function = 42

# Macro: generate a chain of function calls
comptime fn chain fns =
  match fns
    [] -> code (() )
    fn :: rest ->
      let rest_ast = chain rest
      code (fn rest_ast)

let pipeline = chain [code inc, code double, code negate]
# Expands to: inc (double (negate ()))

# Macro: generate a pattern match from cases
comptime fn make_match scrutinee cases =
  code (match scrutinee cases)

let result = make_match (code x) [
  (code (Cons h t), code (h + 1)),
  (code Nil, code 0)
]
# Expands to: match x of Cons h t -> h + 1; Nil -> 0

# Macro: unroll a loop at compile time
comptime fn unroll n body =
  if n == 0 then code ()
  else
    let rest = unroll (n - 1) body
    code (body; rest)

let stmts = unroll 3 (code (println "hello"))
# Expands to: println "hello"; println "hello"; println "hello"
```

### Integration with `stage`

```ko
# Stage evaluates code at compile time
let x = stage (1 + 2)  # x = 3

# Code constructors build AST at compile time
comptime fn build_ast n =
  if n == 0 then code 0
  else code (1 + (build_ast (n - 1)))

# Stage the constructed code
let sum = stage (build_ast 3)  # sum = 1 + (1 + (1 + 0)) = 3

# Combine: build specialized function at compile time
comptime fn specialize sort_fn xs =
  let ast = sort_fn xs
  code (\xs -> ast)

let fast_sort = stage (specialize sort [3, 1, 4, 1, 5])
# Generates: \xs -> specialized sort for [3, 1, 4, 1, 5]
```

## Implementation Plan

### Phase 1: Basic Code Values (Minimal)

1. **ComptimeValue**: Add `code: *CodeNode` variant
2. **CodeNode**: Implement AST node structure
3. **Comptime evaluator**: Handle `code expr` by constructing CodeNode
4. **Code constructors**: Add built-in functions (lit, var, app, lam, etc.)
5. **Code evaluation**: Add `eval` to convert CodeNode back to ComptimeValue

### Phase 2: Code Manipulation

1. **Substitution**: Implement alpha-renaming and capture-avoiding substitution
2. **Code inspection**: Add size, children, free variables functions
3. **Code transformation**: Add map, fold over AST nodes

### Phase 3: Code Splicing

1. **Integration with stage**: Stage evaluates CodeNode to LLVM IR
2. **Code to LLVM**: Convert CodeNode to LLVM instructions
3. **Type checking**: Validate constructed code is well-typed

## Open Questions

1. Should `code` be `code` or `ast` or `quote`?
2. How to handle code construction errors (ill-typed AST)?
3. Should code constructors be functions or syntax?
4. How to handle alpha-renaming and capture-avoiding substitution?
5. Should constructed code be cached for performance?
6. How to prevent infinite code construction (macro expansion loops)?

## Comparison with Existing Features

| Feature | `comptime expr` | `code expr` | `stage expr` |
|---------|-----------------|-------------|--------------|
| Evaluation time | Compile time | Compile time | Compile time |
| Result type | ComptimeValue | CodeNode | Runtime type |
| Splicing | Scalar only | To CodeNode | To LLVM IR |
| Manipulation | Limited | Full AST | Via comptime |
| Use case | Constants | Macros, DSLs | Code generation |

## Risk Assessment

- **Low risk**: Extends existing comptime infrastructure
- **Medium risk**: AST manipulation is complex
- **High risk**: Phase-crossing bugs if code values leak to runtime

## Next Steps

1. Get user feedback on syntax
2. Implement Phase 1 (basic code values)
3. Test with simple macros
4. Iterate on design based on experience

---

## Appendix: Design Alternatives Considered

### Alternative 1: Homoiconicity (Lisp-style)

**Pros**: Simple, powerful, well-understood  
**Cons**: Kō is not S-expression based, would require major syntax changes

### Alternative 2: Quasi-quotations (MetaOCaml-style)

**Pros**: Elegant, well-studied  
**Cons**: Complex parsing, hard to get right

### Alternative 3: Combinator-based (Template Haskell-style)

**Pros**: Type-safe, explicit  
**Cons**: Verbose, harder to read

### Decision: Combinator-based

**Why**: 
- Fits Kō's functional style
- Explicit is better than implicit
- Type-safe by construction
- Builds on existing comptime infrastructure
