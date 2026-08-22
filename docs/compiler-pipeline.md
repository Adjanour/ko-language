# The Kō Compiler Pipeline

How source code becomes a running program.

---

## Overview

```
Source (.ko)
    |
    v
  Parser            (ko-zig/src/parser.zig)
    |
    v
  AST
    |
    v
  HIR Lowering      (ko-zig/src/hir_lower.zig)
    |
    v
  HIR
    |
    v
  Linearity Check   (ko-zig/src/linearity.zig)
    |
    v
  Type Check        (ko-zig/src/sema.zig)
    |
    v
  LIR Lowering      (ko-zig/src/lir_lower.zig)
    |
    v
  LIR
    |
    v
  LLVM Codegen      (ko-zig/src/codegen.zig)
    |
    v
  Native Binary     (via LLVM 22)
```

---

## Parser

Hand-written recursive descent parser. Produces an AST from source text.
Handles function definitions, let bindings, expressions, type definitions,
and imports.

```bash
ko --check file.ko   # parse + type-check, no codegen
```

## HIR Lowering

AST is lowered to HIR (High-level IR) -- a compact, name-resolved
representation. Handles name resolution, operator desugaring, and
pattern compilation.

## Linearity Check

Walks the HIR and verifies that linear variables are consumed exactly once.
Produces three warnings (never errors):

- `linear variable used twice`
- `linear variable used after consumption`
- `linear variable never used`

Disable with `ko --skip-linearity file.ko`.

See [Linearity and Ownership](linearity-and-ownership) for details.

## Type Check

Verifies type correctness, pattern exhaustiveness (currently not enforced),
constructor argument types, and record field types.

## LIR Lowering

HIR is lowered to LIR (Low-level IR) -- a simpler representation close to
LLVM IR. ADTs become tagged unions, pattern matching becomes switch/branch
sequences, closures become struct allocations, and `ref` becomes heap
allocation with reference counting.

## LLVM Codegen

LIR is translated to LLVM IR and compiled to native code via LLVM 22.

```bash
ko --dump-ir file.ko           # print LLVM IR to stdout
ko --emit-ir out.ll file.ko    # write LLVM IR to file
ko --emit-obj file.ko          # compile to object file
ko --emit-exe file.ko          # compile to native executable
```

## Runtime

Ko programs link against a small runtime providing memory allocation,
reference counting, string operations, IO syscalls, and `panic`. The
runtime is compiled into the binary -- no external dependencies.

---

## Inspecting the Pipeline

### Optimized IR

```bash
ko --emit-ir myfile.ll myfile.ko
opt -passes='default<O2>' myfile.ll -o myfile_opt.ll
```

### Control Flow Graph

```bash
ko --emit-ir myfile.ll myfile.ko
opt -passes='dot' myfile.ll
dot -Tsvg myfile.dot -o myfile.svg
```

### Godbolt Compiler Explorer

1. `ko --emit-ir fact.ll fact.ko`
2. Open [godbolt.org](https://godbolt.org)
3. Set language to "LLVM opt", flags to `-passes='default<O2>'`
4. Paste the `.ll` content

---

## Known Gaps (v0.3.x)

- No dead code elimination at the ko level (LLVM handles it).
- No cross-module optimization (single-file compilation only).
- Constant folding is partial (int arithmetic, some unary ops).
- `IO.*` builtins are JIT-compiled separately (not via LIR pipeline).
- `Result.map` segfaults at runtime.
- `Int.fromString` fails at LIR lowering.
- Top-level `let` bindings are not codegen'd.
