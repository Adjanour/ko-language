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

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
