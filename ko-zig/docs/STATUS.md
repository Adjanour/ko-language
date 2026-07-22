# Kō Compiler — Status & Active Bugs

**Last updated**: 2026-07-22  
**Tests**: 155/155 passing (commit TBD)

---

## Completed Work (this session)

1. **Multi-line closures**: Parser `parse_block` got `consume_dedent` param; lambda bodies use `false`. `collectFreeVars` propagates let-bound names across block items. `codegenLambda` saves/restores `scope_heap_values`.
2. **True/False in lambdas**: Swapped codegen tags (True=1/False=0 to match printing convention). Pre-registered constructors + globals in `Inferer.init`.
3. **Float binary ops**: Added Float paths in `inferBinary`. Added `floatPredicate`, bitcast round-trip, LLVM float operations (`FAdd`/`FSub`/`FMul`/`FDiv`/`FRem`/`FCmp`) in `codegenBinaryOp`.
4. **String.split**: Full implementation — Zig runtime (`stdlib.zig`), LLVM declaration (`stdlib_codegen.zig`), type registration, codegen + JIT mapping.
5. **Beginner tutorial**: `docs/TUTORIAL.md` (15 sections).
6. **Release builds**: `ko` (5.8M) and `ko-lsp` (5.2M) with `-Doptimize=ReleaseFast`.
7. **Partial application calling convention**: Extracted `codegenApplyIndirect` for single-arg bit-0 dispatch. Added `codegenApplyIndirectWithArity` for multi-arg calls. Fixed closure path: mask off bit 0, use i8 GEP, call wrapper with all args at once. Added arity propagation for let-bound partial applications. Added over-application support.
8. **Nested lambda captures / over-application**: When `argc > arity`, call with first `arity` args, then apply remaining args one at a time via `codegenApplyIndirect`.
9. **Runtime correctness tests**: Added 28 JIT-executed tests covering literals, arithmetic, if/else, negation, function calls, recursion, mutual recursion, sum types, sum type payloads, recursive Nat, nested pattern matching, pattern matching with computation, refs/mutation, swap, lambdas, closures, higher-order functions, partial application, let bindings, nested let, complex expressions, list length, fibonacci, factorial, String.length, pipe operator, if/else computation, nested Succ Zero patterns.
10. **Codegen test fixes**: Fixed pre-existing orphaned tests in `codegen.zig` (LLVM type cast issues, IR assertion format, memory leaks). Fixed JIT double-free by setting `module_owned_by_jit`.
11. **Runtime correctness tests (40 more)**: Added 40 example-based and edge-case runtime tests (list sugar, multi-line strings, tuple field access, nested constructors in lists, string arithmetic, etc.). Total 155/155 tests passing.
12. **Inspect list sugar in JIT**: `builtin_inspect_tag` now checks "Nil"→`[]` and "Cons"→recursive list display, matching LLVM IR stdlib behavior.
13. **Error message improvements**: Added `note` and `help` fields to `ErrorContext`. Added `reportNote`/`reportHelp` functions. Added `printSourceLine` for source code display with column pointer. Added `findSimilarName` with Levenshtein distance for "did you mean?" suggestions. Improved occurs check message ("this type occurs in" → "this type infinite type"). Added "these types are not compatible" note on type mismatches.

---

## Other Known Issues

- **Imported type propagation**: Types from imported modules show as type variables in the main inferer (not started).

## Next Steps

1. Multi-arg lambda closures — lambdas (`\x y -> ...`) don't get PA wrappers, only global `fn` definitions do
2. Import system hardening — circular import detection, type info propagation from imported modules
