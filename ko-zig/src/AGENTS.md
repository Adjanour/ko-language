# Source Code Patterns

## Workflow: Research → Design → Implement

Before implementing any feature or fix:

1. Explain the problem
2. Research how other languages solve it (OCaml, Haskell, Rust, Zig)
3. Finalize design decisions — choose an approach, document why
4. Identify implementation options and tradeoffs
5. Implement
6. Test with `zig build test --summary all`

## File Structure

```
src/
├── main.zig           # Entry point
├── lexer.zig          # Tokenizer
├── parser.zig         # Recursive descent parser
├── ast.zig            # AST node types (canonical definitions)
├── errors.zig         # Error types
├── typecheck.zig      # Bidirectional type inference
├── linearity.zig      # Linearity checker (HIR pass)
├── codegen.zig        # LLVM IR generation (FROZEN — legacy)
├── codegen_lir.zig    # LIR pipeline (active development)
├── stdlib.zig         # Zig stdlib implementations
├── stdlib_codegen.zig # LLVM IR generation for ALL stdlib functions
├── comptime.zig       # Compile-time evaluator
├── module_loader.zig  # File-based module imports
├── prettyprint.zig    # Type-directed value pretty-printing
├── repl.zig           # REPL implementation
├── lsp.zig            # LSP server
├── lir.zig            # LIR IR types
├── lir_lower.zig      # HIR → LIR lowering
├── lir_dump.zig       # LIR IR printer
├── hir.zig            # HIR types
├── hir_lower.zig      # AST → HIR lowering
├── hir_fold.zig       # Constant folding
├── hir_beta.zig       # Beta reduction
├── hir_dce.zig        # Dead code elimination
├── hir_let_simpl.zig  # Let simplification
├── hir_known_match.zig # Known constructor match
├── hir_check.zig      # HIR validation
├── hir_dump.zig       # HIR printer
├── diagnostics.zig    # Error diagnostics
├── monomorphize.zig   # Monomorphization
├── linenoise.zig      # Line editing for REPL
├── llvm/              # kassane/llvm-zig bindings source
├── tests.zig          # All tests
├── tests_ko/          # .ko test programs
└── examples/          # Example programs
```

## Module Dependencies

```
main.zig → parser.zig → lexer.zig → ast.zig
         → typecheck.zig → parser.zig (re-exports ast types)
         → linearity.zig → hir.zig, hir_lower.zig, diagnostics.zig
         → codegen.zig → parser.zig, typecheck.zig, stdlib.zig, llvm/
```

- `ast.zig` is the single source of truth for all AST types
- `parser.zig` re-exports ast types for backward compatibility

## Legacy Codegen — FROZEN

`codegen.zig` is frozen. No new features, fixes, or changes. All new work goes through the LIR pipeline (`codegen_lir.zig`).

- Legacy: `AST → LLVM IR` (single pass)
- LIR: `AST → HIR → LIR → LLVM IR` (multi-pass, the future)

## Test Pyramid

When testing compiler features, write tests in this order:

1. **Lexer test**: tokenize input, verify token sequence
2. **Parser test**: parse input, verify AST structure
3. **Typechecker test**: typecheck parsed AST, verify no errors
4. **Codegen test**: generate LLVM IR, verify output
5. **Integration test**: `ko` the program, verify output

Never skip stages. A test that only does codegen without verifying parsing is fragile.

## Adding Test Programs

1. Write `.ko` file in `src/tests_ko/`
2. Add trailing newline if missing
3. Add `@embedFile` entry to parser test in `tests.zig`
4. Run `zig build test` — must parse successfully

## Parser Gotchas

- `parse_block` called from two contexts: `parse_fn_def` (let terminates) and `parse_let_expr_in_block` (let is nested). Use `allow_let_in_body` flag.
- `fn_body_stops` must NOT include `keyword_let` — would consume subsequent top-level bindings
- `isInlineComment()` distinguishes standalone comment lines (break blocks) from inline comments (skip transparently)
- Grammar is documentation, parser is truth. Fix drift early.

## Common Pitfalls

1. Imported constructors show raw values in `println`
2. No circular import detection
3. `@embedFile` is already sentinel-terminated — don't append `\x00`
4. Float bitcast needed before passing to C functions
5. Allocas for conditional allocations must go before entry block terminator
6. `LLVMAddIncoming` requires `LLVMBasicBlockRef`, not `LLVMIBasicBlockRef`
