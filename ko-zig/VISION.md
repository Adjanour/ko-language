# Kō (光) — Vision Statement

## What is Kō?

Kō is a **minimal, eager, purely functional language** that compiles to native machine code via LLVM. It proves that simplicity is sufficient.

## The Hypothesis

> Can a language with **50 features** do **80% of what a language with 200 features** can do, with **50% of the complexity**?

Kō tests this by combining:
- **Haskell's type inference** (HM with let-polymorphism)
- **OCaml's evaluation model** (eager, refs for mutation)
- **Rust's compilation target** (native code via LLVM)

While deliberately omitting:
- Type classes (use function dispatch instead)
- Monads (use refs instead)
- Ownership (use reference counting instead)
- Lazy evaluation (use eager evaluation instead)

## Design Principles

1. **Simplicity over power** — Every feature must earn its place
2. **Predictable performance** — No hidden costs, no GC pauses
3. **Good error messages** — Explain *why* a type error occurred
4. **Practical purity** — Pure by default, mutation when needed
5. **Minimal surface area** — The spec fits on a single page

## Target Audience

- **Systems programmers** who need mutation without unsafe blocks
- **Web developers** who want functional programming without monads
- **Educators** who need a clear, understandable language
- **Haskell refugees** who want HM inference without laziness

## Success Metric

A Kō program should be:
- **Shorter** than an equivalent OCaml program (no module ceremony)
- **Simpler** than an equivalent Haskell program (no monads, no type classes)
- **Safer** than an equivalent C program (no null, no buffer overflows)
- **Faster** than an equivalent Python program (native code, no interpreter)

## The Name

**光 (Kō)** means "light" in Japanese. The language is:
- **Lightweight** — small spec, small implementation
- **Illuminating** — clear error messages, explicit behavior
- **Fast** — eager evaluation, LLVM optimization

## Current State

Kō is at **v0.2.0-alpha** with:
- Full HM type inference
- Sum types, records, pattern matching
- Reference counting (no GC)
- Compile-time evaluation
- LSP server, VS Code extension, REPL
- 78 tests, 24 examples

## The Road Ahead

1. **v0.3.0** — Fix bugs, add runtime tests, improve error messages
2. **v0.4.0** — Complete stdlib (String, Array, Set, Map), add guards
3. **v0.5.0** — Package manager, test framework, documentation
4. **v1.0.0** — Concurrency, effects, FFI, optimization
5. **v2.0.0** — Self-hosting, web backend, mobile support

## The Ultimate Goal

**Self-hosting.** Rewrite the Kō compiler in Kō. This proves the language is expressive enough to implement itself.

## Philosophy

> In a world of complexity, Kō chooses simplicity.

Kō doesn't try to be everything to everyone. It tries to be:
- **Simple enough** to understand completely
- **Powerful enough** to be useful
- **Predictable enough** to be reliable

The language is small enough that you can hold the entire thing in your head. The compiler is small enough that you can understand the entire implementation. The ecosystem is small enough that you can know every package.

**That's the vision.** Not a language that does everything, but a language that does the right things well.
