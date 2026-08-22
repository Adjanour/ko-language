# The Kō Compiler Pipeline

How ko goes from source code to running program. This covers the
architecture, key data structures, and how to inspect each stage.

---

## Overview

```
Source (.ko)
    |
    v
  Parser          (ko-zig/src/parser.zig)
    |
    v
  AST
    |
    v
  HIR Lowering    (ko-zig/src/hir_lower.zig)
    |
    v
  HIR             (High-level IR)
    |
    v
  Linearity Check (ko-zig/src/linearity.zig)
    |
    v
  Type Check      (ko-zig/src/sema.zig)
    |
    v
  LIR Lowering    (ko-zig/src/lir_lower.zig)
    |
    v
  LIR             (Low-level IR, LLVM-like SSA)
    |
    v
  LLVM Codegen    (ko-zig/src/codegen.zig)
    |
    v
  Native Binary   (via LLVM 22)
```

---

## 1. Parser

**File:** `ko-zig/src/parser.zig`

Parses source text into an AST (Abstract Syntax Tree). The parser is
hand-written (no parser generator). It handles:

- Function definitions (`fn name params = body`)
- Let bindings (`let name = value`)
- Expressions (if/match/lambda/application)
- Type definitions (`type Name = ...`)
- Imports (`import std.List`)

**Inspect with:** `ko --check file.ko` (parse + type-check, no codegen)

---

## 2. AST to HIR

**File:** `ko-zig/src/hir_lower.zig`

The AST is lowered to HIR (High-level IR), which is a more compact,
name-resolved representation. Key transformations:

- Name resolution (binding variables to their definitions)
- Operator desugaring (`a + b` becomes `primop add [a, b]`)
- Pattern compilation (match arms become decision trees)

---

## 3. Linearity Check

**File:** `ko-zig/src/linearity.zig`

Walks the HIR and verifies that linear variables are consumed exactly once.
Classifies every variable use as either **consume** (ownership transfers) or
**borrow** (read-only, can be reused).

Produces three warnings (never errors in v0.3.x):

- `linear variable used twice`
- `linear variable used after consumption`
- `linear variable never used`

**Disable with:** `ko --skip-linearity file.ko`

See [linearity-and-ownership.md](linearity-and-ownership.md) for details.

---

## 4. Type Check (Sema)

**File:** `ko-zig/src/sema.zig`

The semantic analysis pass. Verifies:

- Type correctness (every expression has a consistent type)
- Pattern exhaustiveness (currently not enforced)
- Constructor argument types
- Record field types

**Produces:** type errors (`type mismatch: expected X, got Y`)

---

## 5. LIR Lowering

**File:** `ko-zig/src/lir_lower.zig`

HIR is lowered to LIR (Low-level IR), a simpler representation close to
LLVM IR. Key transformations:

- ADT values become tagged unions (raw pointer + tag)
- Pattern matching becomes switch/branch sequences
- Closures become struct allocations
- `ref` becomes heap allocation with reference counting

**Produces:** LIR functions as text (SSA-like, with `bb0:`, `br`, `ret`)

---

## 6. LLVM Codegen

**File:** `ko-zig/src/codegen.zig`

LIR is translated to LLVM IR and compiled to native code via LLVM 22.
The codegen handles:

- Function prologue/epilogue
- Stack allocation for locals
- Heap allocation for `ref` cells
- LLVM optimizations (via `opt -passes='default<O2>'`)

**Inspect with:**
- `ko --dump-ir file.ko` -- print LLVM IR to stdout
- `ko --emit-ir out.ll file.ko` -- write LLVM IR to file
- `ko --emit-obj file.ko` -- compile to object file
- `ko --emit-exe file.ko` -- compile to native executable

---

## 7. Runtime

Ko programs link against a small runtime that provides:

- Memory allocation (`malloc`/`free`)
- Reference counting for `ref` cells
- String operations
- IO syscalls
- The `panic` function

The runtime is compiled into the binary -- no external dependencies.

---

## Inspecting the pipeline

### See LLVM IR

```bash
ko --dump-ir myfile.ko           # print to stdout
ko --emit-ir myfile.ll myfile.ko # write to file
```

### See optimized IR

```bash
ko --emit-ir myfile.ll myfile.ko
opt -passes='default<O2>' myfile.ll -o myfile_opt.ll
```

### See CFG (control flow graph)

```bash
ko --emit-ir myfile.ll myfile.ko
opt -passes='dot' myfile.ll      # produces .dot files
dot -Tsvg myfile.dot -o myfile.svg  # render (needs graphviz)
```

### Godbolt Compiler Explorer

1. Run `ko --emit-ir fact.ll fact.ko`
2. Open [godbolt.org](https://godbolt.org)
3. Set language to "LLVM opt"
4. Paste the `.ll` content
5. Set flags to `-passes='default<O2>'`

---

## Known pipeline gaps (v0.3.x)

- **No dead code elimination** at the ko level (LLVM handles it)
- **No cross-module optimization** (single-file compilation only)
- **Constant folding** is partial (works for int arithmetic, some unary ops)
- **`IO.*` builtins** are JIT-compiled separately (not via LIR pipeline)
- **`Result.map`** segfaults at runtime (codegen bug)
- **`Int.fromString`** fails at LIR lowering (ArityMismatch)
- **Top-level `let`** bindings are not codegen'd (must be inside `fn main`)
