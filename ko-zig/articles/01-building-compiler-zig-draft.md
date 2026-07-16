# Why I Built Kō

I've been thinking about programming languages for a long time. Not in an academic way — in the way you think about a tool you use every day and wonder why it doesn't quite fit your hand. I've used Haskell and loved its elegance but gotten lost in monads. I've used Rust and respected its safety but fought the borrow checker like it was personally offended by my code. I've used OCaml and admired its elegance but drowned in module declarations. I've used Python and enjoyed its simplicity but watched helplessly as a recursive function that should take milliseconds took seconds.

About a month ago, I decided to stop complaining and build something.

Kō is what I built. It's a minimal, eager, purely functional language that compiles to native machine code via LLVM. It has pattern matching, Hindley-Milner type inference, reference counting, and a 5,000-line compiler written in Zig. It compiles to LLVM IR, which LLVM turns into x86 assembly. No interpreter, no virtual machine, no garbage collector.

The name means "light" in Japanese. The language is lightweight, illuminating, and fast. Or at least that's the idea.

---

The world doesn't need another programming language. There are hundreds of them. Thousands, if you count the ones people build in their spare time and never tell anyone about. And you're right — the world doesn't need another language. But I needed one.

Here's the thing about programming languages: they're all tradeoffs. Haskell gives you purity and powerful types but takes laziness and monads. Rust gives you safety and performance but takes ownership and lifetimes. OCaml gives you elegance and modules but takes ceremony and complexity. Python gives you simplicity but takes speed. Every language is a negotiation between what you get and what you give up.

I kept thinking there was a negotiation nobody had made yet. What if you could get Haskell's type inference, OCaml's pattern matching, and Rust's native compilation, but without the complexity of any of them? What if you could have purity by default but mutation when you need it, without monads? What if you could have safety without a borrow checker? What if you could have fast code without a garbage collector?

These aren't new ideas. OCaml made most of these tradeoffs thirty years ago. Kō is essentially a simpler OCaml with better error messages and native code compilation via LLVM. But nobody had built it in Zig, and nobody had made the specific set of tradeoffs I wanted.

So I built it.

---

The list was short, and I knew what I wanted before I started.

Pattern matching as the only control flow. No while loops, no for loops, no switch statements. Just match and if (which is sugar for match on Bool). I'd been writing functional code for years, and I realized I never needed anything else. Case analysis is sufficient. Every time I reached for a loop, I could have used recursion or a higher-order function instead. Pattern matching makes this natural — you're just saying "if the data looks like this, do this; if it looks like that, do that."

Hindley-Milner type inference. The kind that Algorithm W gives you. The kind where you write `fn add x y = x + y` and the compiler figures out it's `Int -> Int -> Int` without you saying a word. The kind that Haskell and OCaml use. I wanted type inference that finds principal types — the most general type that works — and explains clearly when something goes wrong.

Eager evaluation. No laziness, no thunks, no space leaks. When you write `let x = expensive_computation`, it evaluates immediately. You know exactly when things happen. This is a deliberate choice — laziness enables infinite data structures but causes unpredictable performance. I wanted predictable performance.

References for mutation. Pure by default, mutable when you need it. `let r = ref 0` creates a mutable reference. `r := !r + 1` reads and writes it. No monads, no do-notation, no effect tracking. Just refs. This is the OCaml approach, and it works beautifully. You get purity for reasoning and mutation for pragmatism.

Reference counting. No garbage collector. No stop-the-world pauses. Deterministic memory management. You know exactly when memory is freed. The tradeoff is that circular references leak, but for the kinds of programs I write, that's acceptable.

Native code via LLVM. Not an interpreter. Not a bytecode VM. Real machine code. The kind that runs as fast as C. LLVM does the hard work of optimization and code generation, and I get to focus on the language.

That was it. That was the language. It's not a research language. It's not trying to advance the state of the art. It's trying to be useful.

---

I started with a Python interpreter. It worked, and it was painfully slow. Not "a little slow" — "interpret the AST on every run" slow. A simple recursive function took seconds. I needed a compiler.

I tried Rust first. The borrow checker fought me at every turn. Writing a compiler is inherently about shared mutable state — the typechecker needs to modify the type environment, the codegen needs to modify the LLVM module. Rust's ownership model made this feel like solving a puzzle instead of building a thing. Every time I wanted to share a reference between two compiler passes, I had to fight the language.

Then I tried Zig, and it just clicked. Zig gives you C-level control without the C-level pain. No hidden allocations, no hidden copies, no hidden control flow. You write exactly what you mean, and the compiler doesn't do anything behind your back. The error handling is explicit — try and catch are clear and composable. The allocators are explicit — you choose your allocation strategy and stick with it.

The LLVM bindings saved me months of work. The kassane/llvm-zig package provides thin wrappers around the LLVM C API. I didn't have to write my own bindings or fight with FFI. I just imported the package and used it.

And Zig compiles fast. The compiler itself compiles in seconds. That matters when you're iterating on a compiler — when you change the parser and want to test it immediately, not wait for a two-minute build.

---

Like most compilers, Kō has four stages: lexer, parser, typechecker, and codegen. Each stage is a pure transformation — tokens go in, LLVM IR comes out. Each stage is independently testable. You can debug the parser without worrying about codegen. You can test the typechecker without generating LLVM IR.

The whole thing is about 5,000 lines of Zig. That's small enough to read in a weekend. Large enough to be useful. Small enough to hold in your head.

The lexer tokenizes the source code, handling significant whitespace and INDENT/DEDENT tokens. The parser builds an AST using recursive descent. The typechecker runs Algorithm W to infer types. The codegen generates LLVM IR using a two-pass approach — declare all functions first, then generate their bodies.

Each stage is a clean transformation. There's no magic, no hidden complexity. Just straightforward code that does what it says.

---

Pattern matching was the hardest part of the compiler, and the most satisfying to get right.

Consider this Kō code:

```ko
type List a = Cons a (List a) | Nil

fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0
```

The compiler must extract the tag from `xs`, compare it to each constructor, bind variables in the body, and merge results from all arms. The strategy is a comparison chain — one basic block per match arm, each block comparing the tag and branching to the body or the next comparison, with a phi node merging results at the end.

It's simple. It's efficient. It works. And getting it right felt like solving a puzzle that had been sitting in front of me for years.

Kō has no garbage collector. Everything is LLVM IR. Every heap object has a reference count header — an 8-byte integer that tracks how many references exist. When you create an object, the count is 1. When you share it, the count goes up. When you're done, the count goes down. When it reaches zero, the memory is freed.

The compiler generates this code directly. No runtime, no GC pauses, no stop-the-world. Just LLVM IR that manages memory. The tradeoff is that circular references leak, but for the kinds of programs I write, that's acceptable.

Multi-param functions return closures when partially applied. When you write `let add5 = add 5` on a function `add` that takes two arguments, it returns a closure that remembers the 5 and waits for the second argument. The closure struct holds the function pointer, the total arity, the applied count, and the pre-applied values.

The representation uses bit-0 tagging. Raw function pointers have bit 0 = 0 (they're aligned, so the bit is always zero). Closures have bit 0 = 1 (they're heap-allocated, so the bit is always one). When calling a function value, you check bit 0. If it's zero, it's a direct call. If it's one, you unpack the closure and call the wrapper function.

It's clever. It's simple. It works.

`println` works on any type at runtime. You can print an integer, a float, a boolean, a string, a list, a record — anything. The typechecker passes a type tag as an extra argument, and the codegen uses LLVM's switch instruction to dispatch on the tag. Each case prints the value in the appropriate format.

No type classes. No overloading. Just a type tag and a switch. It's the simplest possible approach, and it works beautifully.

---

The standard library is written in Kō itself. List has 25+ operations — head, tail, length, map, filter, fold, zip, reverse, append, and more. Math has abs, gcd, lcm, factorial, pow, isqrt. String has length and append, with more coming. Int has even, odd, clamp, sign. Bool has not.

Some functions are built into the compiler, no import needed. `println`, `print`, and `inspect` are polymorphic — they work on any type. `Int.toString`, `Int.abs`, `Int.pow`, `Int.gcd` are all there. `Float.sqrt`, `Float.sin`, `Float.cos`, `Float.log` are there too. `String.length` and `String.append` are built in. `Result.is_ok`, `Result.map`, `Result.unwrap` are there. And the `?` operator for Result propagation.

Compile-time evaluation is built in. You can write `comptime fn factorial n = if n == 0 then 1 else n * factorial (n - 1)` and have it evaluated at compile time. The comptime evaluator supports arithmetic, if-then-else, let bindings, function calls, match expressions, lists, tuples, and constructors.

The LSP server provides hover, completion, and diagnostics. It's written in Zig with raw syscalls — no LLVM dependency, no standard library I/O. Just raw Linux syscalls for reading and writing.

The REPL lets you interact with the type inference engine. You can define functions, evaluate expressions, and check types. Each expression is wrapped in a unique function, so the typechecker can infer types correctly.

---

I learned a lot building this. Some of it was technical, some of it was about the process of building something.

The grammar is the contract. I learned this the hard way. The parser was built incrementally to make individual tests pass, not to faithfully implement the grammar. This caused months of bugs. The rule now: if a test passes but violates the grammar, the test is wrong. Fix the grammar first, then fix the parser.

@embedFile is already null-terminated. In Zig, `@embedFile("path")` returns a null-terminated string. I appended an extra null byte and spent hours debugging a double-null that the tokenizer misread as premature EOF. The lesson: know your tools.

LLVM has bugs. Two bugs in LLVM 22 prevent AOT optimization. Both are fixed in LLVM main. For now, AOT uses unoptimized code. I work around the bugs, I don't fight them. The lesson: your dependencies will have bugs, and you need to work with them, not against them.

Scope-based cleanup changes everything. Zig's `defer` is your friend. Every resource allocation has a corresponding `defer` that cleans up. You never forget to clean up. The compiler won't let you. This makes memory management predictable and prevents leaks.

Small projects teach you more than big ones. Kō is 5,000 lines. That's small enough to understand completely. Every design decision is documented. Every line of code has a purpose. Building something small and complete teaches you more than building something large and sprawling.

---

I'm fixing the remaining bugs — multi-line closures capturing free variables, True/False inside lambdas, float binary operations, imported type propagation. I'm completing the stdlib — String operations, Array type, Set and Map types. I'm building the ecosystem — package manager, test framework, documentation generator.

And I'm thinking about the hard problems. Concurrency — green threads, channels, STM. Effect system — optional, composable effects. Type classes — lightweight, opt-in. Self-hosting — rewriting the compiler in Kō.

These are the problems that interest me now. Not because they're easy, but because they're hard. And because the answers will determine whether Kō is useful or just interesting.

---

Kō is small enough to understand completely. The compiler is 5,000 lines. The design rationale is documented. The implementation guide explains every decision. You can read the whole thing in a weekend.

In a world of complexity, that feels valuable. Not because simplicity is always better than complexity, but because understanding is always better than ignorance. When you understand your tools completely, you can use them more effectively. When you understand your language completely, you can write better code.

Kō doesn't try to do everything. It tries to do the right things well. Pattern matching, type inference, eager evaluation, reference counting, native code. That's it. If you've ever wished for a language that just does these things without extra ceremony, maybe this is it.

The source code is on GitHub. The design rationale is in `docs/THEORY.md`. The implementation guide is in `AGENTS.md`. Take a look. Tell me what you think. Tell me what you'd do differently.

I built this because I wanted to understand something. I'm still learning.

---

*Kō (光) means "light" in Japanese.*
