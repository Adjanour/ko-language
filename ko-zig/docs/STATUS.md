# Kō Compiler — Status & Active Bugs

**Last updated**: 2026-07-21  
**Tests**: 78/78 passing (commit 02dc4dc)

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

---

## Other Known Issues

- **Imported type propagation**: Types from imported modules show as type variables in the main inferer (not started).

## Next Steps

1. Multi-arg lambda closures — lambdas (`\x y -> ...`) don't get PA wrappers, only global `fn` definitions do
2. Pattern matching on more types — records, tuples, nested patterns
3. Import system hardening — circular import detection, type info propagation from imported modules
