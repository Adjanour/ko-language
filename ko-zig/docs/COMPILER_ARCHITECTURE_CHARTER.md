# Kō Compiler Architecture

## Purpose

Kō is a small functional language that produces native code. The compiler should keep the language simple for users while making runtime work explicit inside the compiler.

The main goals are:

- functional source code with type inference, ADTs, pattern matching, and
  immutable values by default;
- native output through LLVM;
- predictable allocation and memory-management behavior;
- ownership analysis that can reduce reference-counting work without forcing
  users to write lifetime annotations.

## Current pipeline

The default path in `src/main.zig` is:

```text
source
  → lexer and parser
  → AST
  → module graph resolution and type-discovery pass
  → type-directed monomorphization with syntax fallback for generated bodies
  → final type checking
  → HIR lowering
  → linearity warnings
  → HIR optimization
  → LIR lowering
  → LLVM IR
  → JIT, object file, or executable
```

The discovery pass establishes checked program facts before specialization. The specializer uses inferred call-site types for source expressions and retains syntax inference only for generated clone bodies, which have not been independently typechecked yet.

The old `AST → LLVM` path is still used when LIR lowering does not support a program. It is frozen. New compiler work must go through HIR, LIR, and `codegen_lir.zig`.

## Target pipeline

The desired order is:

```text
source
  → parse
  → load modules and resolve names
  → infer and check types
  → typed HIR
  → monomorphize from inferred types
  → ownership analysis
  → HIR optimization
  → LIR
  → LLVM IR
  → JIT or native output
```

The difference is important: later stages should use checked facts, not infer them again from syntax.

## Stage responsibilities

| Stage | Input | Output | Responsibility |
| --- | --- | --- | --- |
| Parser | Source text | AST | Parse syntax, keep locations, report syntax errors. |
| Resolver | AST and imports | Resolved program | Load modules, build scopes, bind names. |
| Typechecker | Resolved program | Typed program | Infer and check types. Report type errors. |
| HIR | Typed program | Typed HIR | Represent functions, closures, matches, and evaluation order in a form suitable for analysis. |
| Monomorphizer | Typed HIR | Concrete function instances | Create specializations from actual call-site types. |
| Ownership analysis | Typed HIR | Ownership facts | Decide conservatively whether values are owned, borrowed, or shared. |
| Optimizer | Typed HIR | Simplified typed HIR | Perform safe functional optimizations. |
| LIR lowering | Typed HIR | LIR | Make control flow, allocation, layouts, and RC operations explicit. |
| LLVM codegen | LIR | LLVM IR | Produce valid LLVM IR for JIT or AOT output. |

## Ownership model

Ownership analysis is an implementation feature. It should improve generated code without making ordinary Kō programming difficult.

Use these meanings:

| Fact | Meaning | Lowering consequence |
| --- | --- | --- |
| `Owned` | There is one consuming owner. | The compiler may move or reuse it and may omit RC operations when proven safe. |
| `Borrowed` | The current code reads it but does not own it. | No release occurs here. |
| `Shared` | More than one owner may use it. | Use the RC representation and normal retain/release rules. |

If the analysis is unsure, it must choose `Shared`. Incorrect RC removal is a correctness bug.

The current linearity checker stays advisory. It warns users about likely ownership mistakes, then later becomes input to ownership lowering. It should not become a source-level borrow-checker.

## Representation contract

The compiler needs one shared definition of value representation. It must define how the following values are stored and passed:

- scalar values;
- ADTs and constructors;
- records;
- strings;
- closures and their environments;
- references;
- heap objects and RC headers;
- function parameters and return values.

Do not keep constructor tags, record layouts, or ownership conventions in separate copies inside the typechecker, LIR lowerer, and LLVM code generator. One representation module or plan must own that information.

## Work order

### 1. Finish the LIR path

- Keep a list of language features supported by LIR lowering.
- For every feature supported by both backends, run the same integration test
  through both paths and compare observable output.
- Print or otherwise record when the compiler falls back to the legacy path.
- Add LIR support feature by feature until the fallback is no longer needed.

### 2. Make typed HIR the source of truth

- Move checked type and resolved-name information from AST-pointer maps into
  HIR nodes or HIR side tables owned by the HIR layer.
- Separate module and name resolution from typechecking.
- Keep source spans available after lowering for diagnostics and LSP work.

### 3. Move monomorphization after typechecking

- Use inferred call-site types, not only annotations and argument syntax.
- Key each specialization by function identity plus normalized concrete types.
- Process specializations with a worklist until no new instance is needed.
- Test recursive, higher-order, imported, and polymorphic-data calls.

### 4. Use ownership facts in LIR

- Define ownership transfer for calls, constructors, pattern matching, and
  closure captures.
- Attach conservative facts to typed HIR.
- Lower them to explicit move, retain, release, and reuse operations in LIR.
- Add focused tests for every rule that removes an RC operation.

### 5. Delete the legacy backend

Remove `codegen.zig` only after:

- every supported feature lowers through LIR;
- JIT and AOT use LIR only;
- integration tests cover previous fallback cases;
- `--use-legacy` is no longer needed for supported programs.

## Rules for compiler changes

For each change, document:

1. the stage that owns the problem;
2. the input and output invariant for that stage;
3. the type, ownership, or representation facts added or changed;
4. how diagnostics keep their source location;
5. the unit and integration tests that prove the change.

If a change needs the same fact in several places, create a shared contract instead of copying the fact.
