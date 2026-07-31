# Contributing to Kō

Thanks for your interest in contributing! Kō is an early-stage language — there's a lot of work to do and every contribution helps.

## Getting started

### Prerequisites

- **Zig 0.17** (0.17-dev): `snap install zig --classic --channel=latest/edge`
- **LLVM 22**: `sudo apt install llvm-22-dev zlib1g-dev` (Linux) or `brew install llvm@22` (macOS)

### Build

```bash
cd ko-zig
zig build                # Build compiler + LSP
zig build test --summary all  # Run all 78 tests
```

### Try it

```bash
echo 'fn main = println "Hello, Kō!"' > hello.ko
./zig-out/bin/ko hello.ko
```

## Project structure

```
ko-zig/src/
├── lexer.zig           # Tokenizer (~872 lines)
├── parser.zig          # Recursive descent parser (~1316 lines)
├── typecheck.zig       # Hindley-Milner type inference (~1495 lines)
├── codegen.zig         # LLVM IR generation (~3060 lines)
├── comptime.zig        # Compile-time evaluation (~740 lines)
├── ast.zig             # AST node types
├── errors.zig          # Error types
├── stdlib.zig          # Zig runtime implementations
├── stdlib_codegen.zig  # LLVM IR stdlib generation
├── module_loader.zig   # File-based module imports
├── lsp.zig             # LSP server (separate binary)
├── repl.zig            # REPL implementation
├── prettyprint.zig     # Type-directed value display
├── tests.zig           # All tests
└── tests_ko/           # .ko test programs (53 files)
```

## How to contribute

### Good first issues

Look for issues tagged `good first issue` on the [issue tracker](https://github.com/Adjanour/ko-language/issues). These are scoped, well-defined tasks that don't require deep compiler knowledge.

### Areas that need help

| Area | Difficulty | Issues |
|------|-----------|--------|
| **Tokenizer fixes** | Easy | Blank-line scoping in `scan_indent` |
| **Standard library** | Easy-Medium | New `.ko` files in `std/` (Set, Map, Maybe, etc.) |
| **Error messages** | Medium | Better type error messages with source location |
| **Codegen bugs** | Medium | `list_ops.ko` hangs, multi-line closure errors |
| **Documentation** | Easy | Examples, tutorials, language guide |
| **Tree-sitter grammar** | Medium | Update grammar for new syntax |
| **Tests** | Easy | More test cases for edge cases |

### Workflow

1. **Fork** the repo and create a branch
2. **Make your change** — keep commits focused
3. **Run tests**: `zig build test --summary all`
4. **Test manually**: try your change on example programs
5. **Open a PR** with a clear description of what changed and why

### Code style

- Follow existing patterns in the file you're editing
- Zig 0.17 APIs only (see `AGENTS.md` for gotchas)
- No unnecessary comments — code should be self-documenting
- All `.ko` test files must parse successfully before they can test typechecking/codegen

### Adding a test

1. Create `src/tests_ko/NN_name.ko` with a trailing newline
2. Add the `@embedFile` entry in `tests.zig`
3. Verify it parses: `./zig-out/bin/ko src/tests_ko/NN_name.ko` should show "Parsed: N definitions"
4. Run `zig build test --summary all`

### Commit messages

Keep them short and descriptive:
- `fix: blank-line scoping in scan_indent`
- `feat: add List.sort built-in`
- `docs: update examples for ? operator`

## Reporting bugs

Open an issue with:
1. What you expected to happen
2. What actually happened
3. A minimal `.ko` file that reproduces the issue
4. Your OS and Zig/LLVM versions

## Questions?

Open a discussion on GitHub or check the existing docs:
- `GRAMMAR.md` — formal grammar
- `LANGUAGE_CHARTER.md` — design principles
- `ROADMAP.md` — what's planned
- `AGENTS.md` — developer guide (compiler internals)

## Architecture Reference: How LLVM Works

### The Pipeline

```
Frontend            Middle end (LLVM)              Backend (LLVM)
(yours)              (LLVM IR + passes)              (target codegen)
Source → AST   →     LLVM IR → optimized IR   →     machine code / object file
```

Every language that targets LLVM writes its own frontend down to LLVM IR, and LLVM's optimizer and every backend target work on that IR without knowing or caring what source language produced it. Kō's frontend is everything before `codegen.zig`/`codegen_lir.zig` — lexer, parser, typechecker, HIR, and LIR.

### LLVM IR and SSA

LLVM IR is typed, register-based, in Static Single Assignment (SSA) form — every virtual register is assigned exactly once. Where control flow merges, `phi` instructions pick the right incoming value. This is *why* the HIR→LIR split exists: Kō source has constructs SSA has no notion of — pattern matching, closures, tail-recursive functions — all must be lowered into branches, phi nodes, and explicit loads/stores before reaching LLVM.

### Object Model

```
LLVMContextRef                    (owns all types/constants; one per compilation unit)
  └─ LLVMModuleRef                (a translation unit — roughly, one Kō program)
       └─ LLVMValueRef (function)  (one Kō `fn`)
            └─ LLVMBasicBlockRef   (a straight-line run of instructions)
                 └─ instructions   (built via LLVMBuildXxx calls)
```

### Types

LLVM has a real type system (`i1`, `i64`, `float`, `ptr`, function types, struct types, arrays) but it's much coarser than Kō's. Kō collapses its rich type system: `Int` is `i64`, `Bool` is `i1`, zero-arg constructors and small sum types are packed into a raw `i64` tag, multi-arg constructors become heap-allocated structs behind a `ptr` with an RC header. LLVM never sees `type Maybe a = Just a | Nothing` — it sees an `i64` and a `ptr`.

### The Optimizer

A **pass** is a self-contained transformation over the IR — constant folding, dead code elimination, inlining, etc. Kō currently runs `.LLVMCodeGenLevelNone` unconditionally due to an LLVM 22 bug: `CodeGenPrepare` infinite loop with bitcast+phi patterns (fixed in LLVM 23, [PR #186468](https://github.com/llvm/llvm-project/pull/186468)).

### JIT vs AOT

- **JIT** (`codegen.zig:2967-3003`): MCJIT compiles the whole module to machine code in memory and hands back a function pointer. Powers the REPL and `ko run`.
- **AOT** (`codegen.zig:3011-3082`, `main.zig:426-475`): Emit object file via `LLVMTargetMachineEmitToMemoryBuffer`, then shell out to the system linker (`ld`) for the final executable.

### The Dependency

Kō uses [kassane/llvm-zig](https://github.com/kassane/llvm-zig) — third-party Zig bindings over LLVM's C API. This is why Kō needs LLVM 22 specifically and can't build against whatever LLVM a distro packages.

### LLVM-C API Cheat Sheet

| Call | Purpose | Location |
|---|---|---|
| `LLVMContextCreate` | One context per compile; owns types/constants | `codegen.zig:84` |
| `LLVMModuleCreateWithNameInContext` | One module per Kō program | `codegen.zig:85` |
| `LLVMCreateBuilderInContext` | Cursor used to append instructions | `codegen.zig:97` |
| `LLVMBuild*` (Add, Call2, Br, Load2, ICmp, Phi, ...) | Emit one SSA instruction | throughout `codegen.zig`/`codegen_lir.zig` |
| `LLVMLinkInMCJIT` + `LLVMCreateJITCompilerForModule` | JIT compile to memory | `codegen.zig:2977-2988` |
| `LLVMGetFunctionAddress` | Resolve symbol to function pointer | `codegen.zig:2998` |
| `LLVMGetDefaultTargetTriple` / `LLVMGetTargetFromTriple` | Identify host target | `codegen.zig:3021-3029` |
| `LLVMCreateTargetMachine` | Configure codegen for target | `codegen.zig:3038-3046` |
| `LLVMTargetMachineEmitToMemoryBuffer` | IR → machine code object file in memory | `codegen.zig:3067` |
| `LLVMVerifyModule` / `LLVMPrintModuleToString` | Sanity-check and dump IR | scattered in `tests.zig` |

### Where the Middle End Fits

The HIR/LIR pipeline is *upstream* of LLVM. Its entire reason for existing is everything above: LLVM IR is SSA, flat, and has no patience for closures, nested pattern matches, or anything that isn't already a branch and a phi node. `codegen_lir.zig` is the point where Kō's own IR stops and LLVM's begins.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
