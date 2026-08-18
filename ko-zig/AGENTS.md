# AGENTS.md — Kō Compiler (ko-zig/)

## Quick Reference

| Topic | Where |
|-------|-------|
| Zig 0.17 API, allocators, I/O, testing | `~/.agents/skills/zig-017/SKILL.md` |
| LLVM codegen, opaque pointers, RC, AOT/JIT | `~/.agents/skills/systems-engineering/SKILL.md` |
| Kō syntax, tokens, design decisions, stdlib | `~/.agents/skills/ko-language/SKILL.md` |
| Source file structure, parser patterns, tests | `src/AGENTS.md` |
| Vision & north star | `VISION.md` |
| Design center: linear types | `DESIGN-linear-types.md` |
| Language charter | `LANGUAGE_CHARTER.md` |
| Runtime independence roadmap | `DESIGN-runtime-independence.md` |

## Workflow

Research → Design → Implement → Test. Apply to ALL changes: features, bugs, architecture.

```bash
zig build test --summary all  # Run tests (always use --summary all)
```

## Design Center

Kō is a **linear-type-system project with a language attached.** Immutable by default + no GC only coexist if the type system proves single-ownership at compile time.

- Tree-shaped ownership: C-competitive (zero-cost, no RC)
- Shared/graph ownership: explicit `Rc` (fast, but not zero-cost)

## Legacy Codegen

`codegen.zig` is **frozen**. All new work goes through LIR pipeline (`codegen_lir.zig`).

## Key Files

- `build.zig` / `build.zig.zon` — build config
- `src/main.zig` — entry point
- `src/ast.zig` — canonical AST types
- `src/codegen_lir.zig` — active codegen pipeline
- `src/stdlib_codegen.zig` — LLVM IR for all stdlib functions
- `src/tests.zig` — all tests
- `src/tests_ko/` — .ko test programs

## Language Quick Reference

- Sum types: `type Expr = Cons Expr (List Expr) | Nil`
- Records: `type Binding = { name: String, value: Int }`
- Functions: `fn add (x : Int) (y : Int) -> Int = x + y`
- Pipe: `x |> f |> g`
- Match: `match x = Cons h t -> ... | Nil -> ...`
- Ref: `ref expr` (create), `!expr` (deref), `ref T` (type)
- Assignment: `x := expr`
- Comments: `# this is a comment`
