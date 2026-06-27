# Kō Language Charter

## Abstract

Kō is a small, eager, statically-typed functional language.
It aims to stay predictable: one obvious way to apply functions, one obvious way to model state, and one obvious way to understand control flow.

## 1. Purpose

Kō exists to make practical programs easier to reason about.
It should be pleasant to write, simple to parse, and straightforward to compile to native code.

## 2. Philosophy

Kō is a small, eager ML with explicit mutation via refs, exhaustive pattern matching over algebraic data types, and no parentheses for function calls.

Each clause matters:

- **Small**: the language should resist feature drift.
- **Eager**: evaluation should stay predictable.
- **Explicit mutation via refs**: mutation must be visible at the type and syntax level.
- **Exhaustive pattern matching over ADTs**: unhandled cases should be compiler errors.
- **No parentheses for function calls**: curried application is a first-class part of the surface language.

## 3. Semantics Before Syntax

These are the commitments syntax must obey.

- **Mutation is explicit and total**. Ordinary bindings do not change. State lives in refs.
- **Effects are unrestricted for now**. `println` is an ordinary function, not an `IO` action.
- **Pattern matches are exhaustive or they do not compile**.
- **Recursion is the default control structure**. Kō does not center loops.
- **Application is implicit**. Calls should read as `add 1 2`, not `add(1, 2)`.

## 4. Data Model

Kō should treat algebraic data and named-field records as the two primary shapes of data.

### Sum Types

Use sum types for closed sets of alternatives:

```ko
type Expr =
  Num Int
  | Var String
  | Add Expr Expr
  | Let String Expr Expr
```

### Records

Use records for named-field product types:

```ko
type Binding = {
  name : String,
  value : Int
}
```

### Layout Is A Storage Choice

- The data type itself should stay pure and structural.
- Array-of-structs vs struct-of-arrays belongs to the container or storage wrapper, not the type definition.
- Layout specialization should be a comptime decision over a closed record type.

### Pattern Matching

- Constructor patterns match sum types.
- Record patterns match named fields.
- Partial record patterns must be explicit with `..`.

Example:

```ko
Binding { name, .. } => ...
```

## 5. Grammar Proposal

This is the intended direction for the parser and future grammar docs.

```ebnf
type_def        = "type" IDENT { LOWER_IDENT } "=" ( record_body | variant_body ) ;

record_body     = "{" field_decl { "," field_decl } "}" ;
field_decl      = LOWER_IDENT ":" type_expr ;

variant_body    = type_alt { "|" type_alt } ;
type_alt        = CONSTRUCTOR { type_atom } ;

record_literal  = CONSTRUCTOR "{" field_init { "," field_init } "}" ;
field_init      = LOWER_IDENT "=" expr ;

pat_record      = CONSTRUCTOR "{" pat_field { "," pat_field } [ "," ".." ] "}" ;
pat_field       = LOWER_IDENT [ "=" pattern ] ;
```

The rule is simple:

- `type Expr = ...` defines a sum type.
- `type Binding = { ... }` defines a record.
- `Expr { ... }` constructs a record value.
- `Expr { ... }` in a pattern destructures a record value.
- `..` means intentionally ignore the remaining fields.

## 6. What Kō Is For

Kō is aimed at:

- CLI tools
- compilers and transpilers
- data transforms
- build and automation tooling
- small-to-medium systems programs

## 7. What Kō Is Not

Kō is deliberately not:

- an object-oriented language
- a feature kitchen sink
- a syntax zoo
- a language with many interchangeable ways to express the same idea
- a system that requires the typechecker to guess too much

## 8. Design Principles

1. Prefer the simplest syntax that reads well.
2. Keep the core small and explicit.
3. Add syntax only when it clearly improves everyday code.
4. Preserve predictable parsing and type checking.
5. Favor one canonical way to express a concept.
6. Keep the language easy to compile to native code.

## 9. Current Syntax Freeze

The parser port should treat these as stable:

- `_` as wildcard token
- hyphenated identifiers
- decimal, hex, binary, and octal numerics
- `#` comments and indentation-sensitive blocks
- named args as `~name:expr`
- `pub` before `fn`, `type`, `let`, `module`
- `|>` as pipe

## 10. Near-Term Roadmap

### v0.3.x (current)

- Parser, typechecker, and codegen complete (Zig)
- Hindley-Milner type inference with let-polymorphism
- LLVM IR codegen via kassane/llvm-zig bindings
- JIT execution and AOT compilation
- Reference counting for heap-allocated objects
- Partial application (currying)
- Module definitions with pub visibility

### v0.4.0

- File-based imports
- General recursion safety (stack overflow prevention)
- Closure codegen for multi-param lambdas
- Full decref for intermediate variables

### v0.5.0

- Standard library
- Better compiler diagnostics
- Codegen and runtime hardening

## 11. Decision Rule

Keep a feature if it:

- reduces ambiguity
- improves readability
- lowers implementation complexity
- fits the functional core

Reject or defer a feature if it:

- adds overlapping syntax
- creates hidden control flow
- makes errors harder to explain
- forces the typechecker to infer too much
