# Article 1: Building a Compiler in Zig: From Python to Native Code

## Target Audience
Systems programmers, language enthusiasts, developers curious about compilers.

## Tone
Personal, honest, practical. Not academic — this is a journey, not a paper.

## Word Count
3,000-4,000 words

## Structure

### Hook (200 words)
- Open with the result: a 5,000-line compiler that compiles a functional language to native machine code
- Show a simple Kō program and its output
- Contrast with where we started: a Python interpreter that was 10x slower

### The Problem: Why Build a Language? (400 words)
- Existing languages are too complex (Haskell's monads, Rust's ownership, OCaml's modules)
- Hypothesis: Can 50 features do 80% of what 200 features do?
- The design constraints: eager, functional, refs, pattern matching, HM inference
- What we deliberately left out (and why)

### Why Zig? (500 words)
- Started in Python — too slow, too dynamic
- Tried Rust — ownership got in the way of writing a compiler (ironic)
- Zig hit the sweet spot: C-level control, no hidden allocations, explicit error handling
- The LLVM bindings story: kassane/llvm-zig saved months of work
- Zig 0.17 API changes we had to adapt to (DebugAllocator, Io pattern, Args)

### The Architecture: Four Stages (600 words)
- Lexer → Parser → Typechecker → Codegen
- Each stage is a pure transformation: tokens → AST → typed AST → LLVM IR
- Why this architecture (it's the standard, and there's a reason it's standard)
- The files: lexer.zig, parser.zig, typecheck.zig, codegen.zig, stdlib_codegen.zig
- Total: ~5,000 lines of Zig

### The Hard Parts (800 words)

#### Significant Whitespace
- Kō uses indentation like Python
- Tracking INDENT/DEDENT tokens is harder than it looks
- The offside rule and its edge cases
- How we handle inline comments vs standalone comments

#### Pattern Matching Compilation
- Matching on sum types requires tag comparison
- The comparison chain: entry → cmp[0] → (match? → body, no match → cmp[1]) → ...
- Phi nodes for merging results
- Nested patterns: destructuring during comparison
- This was the hardest part of the compiler

#### Reference Counting in LLVM IR
- No GC, no runtime — everything is LLVM IR
- Tracking heap allocations per function scope
- Ownership-based decref: skip decref for consumed values
- The emitIncref pattern: when a value is stored in a parent structure
- The scope_heap_values gotcha: must store ptrtoint, not raw pointer

#### Partial Application (Currying)
- Multi-param functions return closures when partially applied
- Closure struct: { fn_ptr, total_arity, applied_count, applied_args[] }
- Bit-0 tagging: raw function pointers have bit 0 = 0, closures have bit 0 = 1
- Wrapper functions that unpack and call the original

### What We Built (600 words)
- The standard library: 25+ List operations, Math, String, Int, Float, Bool
- Built-in polymorphic I/O: println works on any type at runtime
- Compile-time evaluation: comptime for constant folding
- LSP server: hover, completion, diagnostics — without LLVM dependency
- VS Code extension: syntax highlighting and language support
- REPL: interactive development with type inference

### Lessons Learned (400 words)
- The grammar is the contract — if the parser drifts from the grammar, fix the grammar
- @embedFile is already null-terminated — don't append \x00
- LLVM 22 has bugs — we work around them, we don't fight them
- The two-pass codegen pattern: declare first, then generate bodies
- Scope-based cleanup: defer is your friend in Zig

### What's Next (300 words)
- Fixing the remaining bugs (multi-line closures, True/False in lambdas)
- Complete stdlib (String operations, Array, Set, Map)
- Package manager and test framework
- Concurrency and effects (the hard problems)
- Self-hosting: rewriting the compiler in Kō

### Closing (200 words)
- The project is small enough to understand completely
- Every design decision is documented in THEORY.md
- The compiler is 5,000 lines — you can read it in a weekend
- In a world of complexity, Kō chooses simplicity
- Link to the GitHub repo

---

## Key Code Snippets to Include

1. A simple Kō program (fibonacci, list operations)
2. The lexer token types
3. The parser's pattern matching
4. The typechecker's unification
5. The codegen's comparison chain for match
6. The RC tracking pattern
7. The closure struct layout

## Images/Diagrams
1. Compiler pipeline diagram
2. Pattern matching control flow graph
3. Memory layout (RC header + user data)
4. Closure struct layout
5. Bit-0 tagging diagram

## Publishing Platforms
- Personal blog
- Hacker News
- Reddit (r/programming, r/Compilers, r/Zig)
- Dev.to
- Medium (cross-post)
