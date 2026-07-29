# LIR Pipeline — Test Gaps

## Golden Test Suite (`src/tests_ko/`)

42 `.ko` files organized by category, all parse + typecheck + run under the
old codegen pipeline. 40 of 42 pass under `--use-lir`.

| Category | Files | LIR OK | LIR FAIL |
|---|---|---|---|
| syntax_ | 23 | 23 | 0 |
| pattern_ | 2 | 2 | 0 |
| type_ | 3 | 3 | 0 |
| fn_ | 5 | 5 | 0 |
| module_ | 2 | 0 | 2 |
| comptime_ | 5 | 5 | 0 |
| builtin_ | 2 | 2 | 0 |

## Passing (40)

syntax_application, syntax_arithmetic, syntax_block, syntax_bool,
syntax_comment, syntax_comparison, syntax_cons, syntax_fn, syntax_fn_block,
syntax_hyphenated, syntax_if, syntax_let, syntax_literal, syntax_logical,
syntax_nested, syntax_pipe, syntax_precedence, syntax_record, syntax_string,
syntax_unary, syntax_tuple_let, syntax_minimal¹, syntax_tuple²

pattern_match, pattern_wildcard

type_sum³, type_sum_params³, type_record³

fn_lambda, fn_lambda_wildcard, fn_closure, fn_partial, fn_curry

comptime_expr, comptime_fn, comptime_list, comptime_match, comptime_string

builtin_math, builtin_result

¹ `fn main = 1` — return value not printed (by design, requires explicit println)
² Tuple prints correctly: `(1, 2, 3)`
³ Record prints correctly: `Point { 3, 4 }`. Constructor display via let-bound variables uses raw pointers (element-level type tags lost at LLVM IR level)

## Failing (2)

### 1. Module & Import System (`module_def`, `module_import`)
```
lir_lower: undefined constructor 'Math'
lir_lower: undefined global 'abs'
```
The LIR pipeline has no module/import resolution:
- `module_def.ko` defines a local `module Math ...` — LIR doesn't register
  module-scoped names
- `module_import.ko` uses `import std.Math.{abs}` — LIR doesn't process
  import statements at all

### 2. Display / Pretty-Printing (minor, pre-existing)
- **`type_sum`**: prints `[42, 177]` instead of `Ok 42, Err 177` (let-bound constructors lose name at LLVM IR level)
- **`type_sum_params`**: prints `[1, 2]` instead of `Some 1, None` (same issue)

## Fixed

### Tuple Destructuring Let (`syntax_tuple_let`) — Fixed 2026-07-28
Desugared `let (x, y) = value in body` to `match value | (x, y) → body` in
`hir_lower.zig`. The existing LIR match infrastructure handles tuple patterns.

### Builtin Result Type Clash (`builtin_result`) — Fixed 2026-07-28
The segfault was caused by the user-defined `type Result a b = Ok a | Err b`
conflicting with the built-in `Result` constructors. The fix was a side effect
of the tuple destructuring desugaring — the `let` with a pattern now goes through
the match path, which correctly resolves constructor tags.

### Builtin Int.* (`builtin_math`) — Fixed 2026-07-28
The `SigSpec` entries in `lir_lower.zig` were already in place. The LIR_GAPS.md
was stale — `Int.pow`, `Int.gcd`, etc. work correctly under `--use-lir`.

### Tuple/Record/Constructor Display — Fixed 2026-07-28
- Added `arity` parameter (5th arg) to `inspect`, `println_with_tag`, `print_with_tag`
- `lowerStdPrint` now computes arity from type info (tuple len, constructor args, record fields)
- Fixed `LLVMArrayType` GEP element type (resolved 119 test crashes)
- Record display: added `variable_types` lookup for record names and arity
- All 245/245 tests pass; 40/42 .ko files pass under `--use-lir`
