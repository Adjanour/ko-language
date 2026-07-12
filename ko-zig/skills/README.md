# Kō AI Skills

Skills that teach AI coding assistants how to write Kō code.

## What's in here

| File | For | What it does |
|------|-----|--------------|
| `SKILL.md` | OpenCode | Full language reference — syntax, patterns, gotchas, builtins |
| `CLAUDE.md` | Claude Code / Copilot | Concise guide for AI assistants |
| `.cursorrules` | Cursor | Quick syntax rules |

## Install for your AI tool

### OpenCode

Copy the skill to your OpenCode skills directory:

```bash
cp -r skills/ko-language ~/.config/opencode/skills/ko-language
```

Or add it to a project:

```bash
mkdir -p .opencode/skills
cp -r skills/ko-language .opencode/skills/ko-language
```

### Claude Code / GitHub Copilot

Copy `CLAUDE.md` to your project root:

```bash
cp skills/ko-language/CLAUDE.md /path/to/your/project/CLAUDE.md
```

### Cursor

Copy `.cursorrules` to your project root:

```bash
cp skills/ko-language/.cursorrules /path/to/your/project/.cursorrules
```

### Other AI tools

Any tool that reads `CLAUDE.md`, `.cursorrules`, or similar instruction files will work. Just copy the appropriate file to your project root.

## What the skills teach

- Kō syntax (no parens, indentation, match arms)
- ADTs and pattern matching
- `comptime` compile-time evaluation
- Named parameters (`~name:value`)
- Built-in functions
- Common gotchas (string concat `++`, refs, constructors uppercase)
- Idiomatic patterns (pipeline, guard matches, accumulator)

## Testing

After installing, ask your AI assistant:

> "Write a Kō function that reverses a linked list"

It should produce correct Kō code with `match`, `Cons`/`Nil`, and recursion.
