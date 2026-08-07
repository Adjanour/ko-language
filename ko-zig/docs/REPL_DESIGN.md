# REPL Design

## Purpose

The REPL is Kō's primary interface. It's not a debugging tool — it's where people learn, explore, and build. The UX *is* the language's first impression.

Core goals:
- **Incremental composition** — definitions persist, the session IS the program
- **Instant feedback** — see results, types, and errors immediately
- **Discovery** — learn the language and stdlib by typing into it
- **Resilience** — errors return to the prompt, never crash

## Architecture

### One Persistent LLVM Module

The REPL maintains a single LLVM module for the entire session. It grows as definitions are added — never rebuilt.

- **Definitions** (`fn`, `type`, `let`) → compiled as permanent LLVM functions, added to the module
- **Expressions** → wrapped in a temporary `__repl_eval_N` function, JIT'd, executed, discarded
- **The module persists** — each definition extends it, nothing is thrown away
- **Type environment persists** — `inferProgram` is incremental (definitions added to existing env)

### Two-Tier Evaluation

| Input type | What happens |
|------------|-------------|
| **Definition** (`fn`, `type`, `let`) | Parse → typecheck → codegen → add to persistent module |
| **Expression** | Typecheck against current env → wrap in temp function → codegen → JIT → execute → discard wrapper |
| **Command** (`:type`, `:env`) | No codegen — query the persistent type environment |

### Source Accumulation

Definitions are stored as source text in `accumulated_source`. On each eval, the full source is replayed for the parser and typechecker, but only the *new* codegen'd function is added to the LLVM module.

This avoids re-codegenning old definitions while keeping the type environment consistent.

### Error Recovery

Runtime panics (division by zero, stack overflow, assertion failure) must NOT kill the REPL process.

Implementation: `setjmp`/`longjmp` or a signal handler (`SIGABRT`) that catches the abort and returns control to the REPL loop. The Zig `std.c.abort()` call in `ko_panic` should be intercepted.

Parse errors and type errors are already recoverable (Zig errors).

## UX Principles

### 1. Show, Don't Tell

Result appears on the next line. No prefix, no decoration.

```
ko> 2 + 3
5
```

Not:
```
ko> 2 + 3
The result is: 5
=> 5
```

### 2. Definitions Confirm with Types

When you define something, acknowledge it with its type signature:

```
ko> fn add x y = x + y
add : Int -> Int -> Int

ko> type Point = { x: Int, y: Int }

ko> let p = Point { x = 1, y = 2 }
```

Type definitions show the name. Let bindings show name and type.

### 3. Errors Point at the Problem

Errors include source location and a visual pointer:

```
ko> add "hello" 3
Type error: expected Int, got String
  add "hello" 3
      ^^^^^^^
```

Not:
```
Error: TypeMismatch
```

### 4. Multi-Line is Invisible

No special syntax. The REPL *knows* when a definition needs a body:

```
ko> fn fib n =
...   if n < 2 then n
...   else fib (n-1) + fib (n-2)
fib : Int -> Int
```

Detection: a line ending with `=` or an opening bracket `(` `{` `[` that isn't closed signals more input is needed.

### 5. Tab Completion Teaches

Type `Str` + Tab, see `String.length`, `String.append`, etc. Discover the stdlib by exploring.

Completion sources:
- Keywords (`fn`, `let`, `if`, `then`, `else`, `match`, `type`, `import`)
- Builtins (`println`, `print`, `inspect`, `Int.toString`, `String.length`, ...)
- User-defined names from the current session

### 6. `:type` is Seamless

Query the type of anything without evaluating it:

```
ko> :type add
Int -> Int -> Int

ko> :type 2 + 3
Int

ko> :type if True then 1 else 2
Int
```

### 7. Side Effects Print Inline

`println` and `print` show their output during evaluation. The result is printed after:

```
ko> println (fib 10)
55
```

Not:
```
ko> println (fib 10)
55
()
```

(`println` returns Unit — don't print the Unit result.)

### 8. `:env` Shows Everything

List all defined names with their types:

```
ko> :env
add : Int -> Int -> Int
p : { x: Int, y: Int }
fib : Int -> Int
```

## Commands

| Command | Aliases | Behavior |
|---------|---------|----------|
| `:quit` | `:q`, `:exit` | Exit the REPL |
| `:help` | `:h` | Show available commands |
| `:type <expr>` | `:t <expr>` | Show the type of an expression without evaluating it |
| `:env` | | Show all defined names and their types |
| `:reset` | | Clear all definitions, start fresh |
| `:history` | | Show numbered input history |
| `:load <file>` | | Load and evaluate a `.ko` file |

## Multi-Line Input

The REPL tracks two signals for multi-line input:

1. **Unclosed brackets** — `(`, `{`, `[` increase depth; `)`, `}`, `]` decrease. Non-zero depth means more input.
2. **Trailing `=`** — a line ending with `=` signals a definition body follows.

When more input is needed, the prompt changes from `ko> ` to `... `.

```
ko> fn add x y =
...   x + y
add : Int -> Int -> Int
```

## Result Formatting

| Type | Format |
|------|--------|
| Int | `42` |
| Float | `3.14` |
| Bool | `True` / `False` |
| Char | `'a'` |
| String | `"hello"` |
| Unit | (nothing — don't print `()`) |
| Constructor | `None` / `Some 42` / `Cons 1 (Cons 2 Nil)` |
| Record | `{ x = 1, y = 2 }` |
| Function | `<fn>` |
| List | `[1, 2, 3]` |

## Persistence Model

### What persists across iterations

- All definitions (fn, type, let) — in `accumulated_source` and the LLVM module
- Type environment — the inferer's global env
- Input history — for up/down arrow navigation

### What is ephemeral

- Expression evaluations — the `__repl_eval_N` wrapper is discarded after execution
- Parser, inferer, codegen — created fresh per eval (but seeded from persistent state)
- LLVM execution engine — created fresh per eval, but the module persists

### Reset behavior

`:reset` clears `accumulated_source`, resets the LLVM module to empty, and resets `eval_counter`. The session starts over.

## Implementation Notes

### Let-to-Fn Conversion

`let name = value` is stored as-is in `accumulated_source` but internally treated as `fn name = value` for codegen compatibility. This is because Kō's codegen requires function definitions to have LLVM function declarations.

### Definition Detection

`isDefinition()` checks if input starts with `fn`, `type`, `let`, `module`, `pub`, `import`, or `package`. Falls back to scanning for `=` at parenthesis depth 0 that isn't part of `!=`, `<=`, `>=`, `==`.

### Tab Completion

Searches:
1. Keywords (hardcoded list)
2. Builtins (from `inferer.global` — `println`, `String.length`, etc.)
3. User-defined names (from `accumulated_source` — parses `fn name` and `let name` patterns)

Single match: auto-complete. Multiple matches: show candidates.

### History

File-backed at `/tmp/.ko_history_{uid}`. Loaded on startup, saved on exit. Up/down arrow keys navigate. History is per-user, not per-project.
