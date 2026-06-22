# Changelog

## v0.2.1 — 2026-06-19

### Bug Fixes

- **Parser `let` interleaving** — `let` bindings now execute at their correct position, not hoisted to the top of the block
- **User-defined `Nil`/`Cons` codegen** — constructors defined via `type` no longer conflict with built-in list constructors
- **Deferred let init ordering** — removed broken deferred mechanism, let bindings emit inline

### Standard Library

- **New I/O**: `eprint`, `eprintln` (stderr output)
- **Filesystem**: `mkdir`, `rm`, `cp`, `mv`, `readdir`
- **File metadata**: `file_size`, `file_modified`
- **Path operations**: `path_join`, `path_dirname`, `path_basename`
- **JSON**: `json_parse`, `json_stringify`

### Docs

- SPEC.md updated with all new standard library functions
- LSP hover docs now show parameters and usage examples for all builtins

## v0.2.0 — 2026-06-19

### Language

- **Multi-line `if`/`else`** — then/else branches support multi-expression blocks
- **Negative argument literals** — `fn f x = ...` / `add 5 -60` works as expected
- **Multi-line input** — lines ending with `\` continue on the next line (REPL)
- **`import` statements** — relative imports with circular import detection

### Standard Library (stdlib)

- String: `split`, `join`, `replace`, `trim`, `starts_with`, `ends_with`, `contains`, `repeat`
- Math: `abs`, `min`, `max`, `clamp`, `floor`, `ceil`, `pow`, `sqrt`
- Conversion: `to_string`, `to_int`, `to_float`
- Type checking: `is_int`, `is_float`, `is_string`, `is_bool`, `is_char`, `is_function`

### Built-in Functions

- `char_at` — extract character at index from string
- `ord` / `chr` — convert between characters and integers
- `panic` — runtime error with message
- `args_get` — command-line argument access

### REPL (v0.2.0)

- Stateful definitions persist across evaluations
- Bare expressions auto-print
- Commands: `:help`, `:list`, `:reset`, `:types`, `:q`, `:import`
- Multi-line input with `\` continuation
- Error recovery — bad definitions don't corrupt state

### Compiler

- Nuitka standalone build with `runtime.h` bundled
- Symlink at `~/.local/bin/ko`
- `to_string` handles `Char` type correctly
- Fixed escape sequence handling in `escape_c_string` / `escape_c_char`
- Built-in list type (`Nil`/`Cons`) with tag collision avoidance
- Removed extra `}` in `runtime.h` (`ko_sleep`)

### LSP Server

- `initialize` response, `shutdown` tracking
- Parse error locations in diagnostics
- `didClose` handler
- `textDocument/documentSymbol` — functions, types, lets
- `textDocument/completion` — builtins, keywords, user definitions
- `textDocument/hover` — types and documentation
- Cross-file `textDocument/definition` support

### VS Code Extension

- v0.2.0 — clean release with LSP-powered features
- Removed local completion/symbol providers (LSP handles them)
- Kept folding provider

### Tests

- 234 tests passing

## v0.1.0 — Initial

- Core compiler: lexer, parser, HM type inference, C codegen
- Pattern matching with exhaustive checking
- References, closures, recursion
- Tree-sitter grammar
- VS Code extension with syntax highlighting
- Example programs
