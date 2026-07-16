# Kō: A Language That Bets on Simplicity

There's a certain kind of programmer who looks at Haskell and thinks, "This is beautiful, but I could never use it in production." Not because Haskell is bad — it's magnificent — but because the learning curve is a cliff face, the error messages read like poetry written by someone who hates you, and the moment you need to do something impure, you're deep in monad transformers wondering where your life went wrong.

I've been that programmer. And I've been the opposite kind too — the one who looks at C and thinks, "This is powerful, but I could never trust myself with it." Not because C is bad either — it's magnificent too — but because a single wrong pointer dereference corrupts your data silently, a buffer overflow becomes a security vulnerability, and the compiler shrugs at type errors that should have been caught at compile time.

For years I bounced between these poles. Functional languages gave me safety but took simplicity. Systems languages gave me performance but took safety. I wanted something in the middle. Something that felt like OCaml but compiled to native code. Something that had pattern matching and type inference but didn't require a PhD to understand. Something that let me write pure code by default but gave me refs when I needed mutation, without making me feel like I was breaking the rules.

That's what Kō is. It's not trying to be the best language. It's trying to be a language that does the right things well and gets out of your way.

---

Every language is a set of bets. You bet that certain features are worth the complexity they add. You bet that certain tradeoffs are acceptable. You bet that your users will want what you're offering more than what you're taking away.

Haskell bets that purity is worth the cost of monads. Rust bets that safety is worth the cost of ownership. OCaml bets that modules are worth the ceremony. Python bets that simplicity is worth the speed. Every language makes these bets, and every language lives with the consequences.

Kō makes a different set of bets. It bets that pattern matching is enough for control flow — you don't need while loops, for loops, or switch statements. It bets that eager evaluation is worth the loss of infinite data structures. It bets that references are a simpler mutation story than monads or ownership. It bets that reference counting is acceptable for most programs. It bets that a small, predictable language is more useful than a large, powerful one.

These are not obviously correct bets. Laziness is genuinely useful. Monads are genuinely elegant. Ownership is genuinely safe. Module systems are genuinely powerful. Every feature Kō leaves out is a feature someone loves. The question isn't whether these features are good — they are. The question is whether the complexity they add is worth the benefit they provide.

Kō's answer is no. Not for the kind of programming I do.

---

The hypothesis behind Kō is simple: can 50 features do 80% of what 200 features do, with 50% of the complexity?

This isn't a new hypothesis. It's the OCaml hypothesis, simplified. OCaml made most of these tradeoffs thirty years ago. It's eager, has pattern matching, has references, has a powerful type system with inference, and compiles to native code. Kō is essentially OCaml without the module system, without the object system, and with better error messages.

But OCaml has its own complexity. The module system is powerful but verbose. The object system exists but nobody uses it. The error messages are functional but not friendly. Kō takes the parts of OCaml that work and leaves the parts that don't. It's not a better OCaml — it's a simpler one.

The bet is that simplicity has value. That a language you can hold in your head is more useful than a language you can't. That a compiler you can read in a weekend is more valuable than one you can't. That predictable performance is worth more than peak performance. That a small ecosystem you can know completely is better than a large ecosystem you can only know partially.

These are aesthetic bets as much as technical ones. But aesthetics matter in programming languages. The languages we love are the ones that feel right — that match how we think, that get out of our way, that let us focus on the problem instead of the tool.

---

Kō deliberately leaves out a lot.

No type classes. Haskell's type classes are powerful, but they add significant complexity. Kō uses function dispatch instead. If you want to overload an operator, you define a function. If you want polymorphic behavior, you pass a function as an argument. It's less elegant than type classes, but it's simpler, and for the programs I write, it's sufficient.

No monads. Haskell's monads are elegant, but they're confusing. The IO monad, the State monad, the Reader monad — each is powerful, each has a learning curve. Kō uses references instead. `let r = ref 0; r := !r + 1` is clearer than `modify (+1)` in the State monad. It's less pure, but it's more pragmatic.

No ownership. Rust's ownership system is brilliant, but it's steep. The borrow checker fights you until you learn to think like it does. Kō uses reference counting. `let y = x` just works — no borrowing, no lifetimes, no compile-time fights. It's less safe, but it's more predictable.

No lazy evaluation. Haskell's laziness enables infinite data structures, but it causes space leaks and unpredictable performance. Kō is eager. When you write `let x = expensive_computation`, it evaluates immediately. You know exactly when things happen.

No modules. OCaml's module system is powerful, but it's verbose. `module Foo = struct ... end` everywhere. Kō uses flat imports. `import std.math.{add}` just works. It's less organized, but it's less ceremony.

These omissions are deliberate. They're not oversights or limitations — they're design decisions. Each one trades power for simplicity. Each one makes the language smaller and more predictable. Each one makes it easier to hold the whole thing in your head.

---

What Kō keeps is what matters.

Pattern matching. The only control flow. No while, no for, no switch. Just match and if. This is the ML philosophy: case analysis is sufficient. If you can match on the shape of your data and do different things for each shape, you don't need anything else. It's surprisingly powerful once you stop reaching for loops.

Hindley-Milner type inference. Algorithm W. The kind that finds principal types without annotations. You write `fn add x y = x + y` and the compiler figures out it's `Int -> Int -> Int`. You write `fn map f xs = match xs | Cons x rest => Cons (f x) (map f rest) | Nil => Nil` and the compiler figures out it's `(a -> b) -> List a -> List b`. No type annotations needed. The inference just works.

References for mutation. Pure by default, mutable when you need it. `let r = ref 0` creates a mutable reference. `r := !r + 1` reads and writes it. No monads, no do-notation, no effect tracking. You get purity for reasoning and mutation for pragmatism. The OCaml approach, and it works beautifully.

Reference counting. No garbage collector. No stop-the-world pauses. Deterministic memory management. You know exactly when memory is freed. The tradeoff is circular references, but for most programs, that's acceptable.

Native code via LLVM. Not an interpreter. Not a bytecode VM. Real machine code. LLVM does the hard work of optimization and code generation, and Kō gets to focus on the language.

These features form a coherent whole. They reinforce each other. Pattern matching works well with eager evaluation. Type inference works well with references. Reference counting works well with eager evaluation. Each feature makes the others more useful.

---

The result is a language that feels different from the ones you're used to.

In Haskell, you'd write:

```haskell
sumList :: [Int] -> Int
sumList [] = 0
sumList (x:xs) = x + sumList xs
```

In OCaml, you'd write:

```ocaml
let rec sum_list xs = match xs with
  | [] -> 0
  | x :: xs -> x + sum_list xs
```

In Kō, you'd write:

```ko
fn sum xs =
  match xs
    | Cons x rest => x + sum rest
    | Nil => 0
```

The Kō version is simpler. No type annotations. No `rec` keyword (mutual recursion is inferred). No `[]` syntax — just constructors. The pattern matching is the same idea, but the ceremony is less.

This is what simplicity looks like. Not fewer features — fewer things you have to think about. Not less power — less overhead. Not a toy language — a language that trusts you to know what you're doing.

---

Kō has limitations. I'm not going to pretend it doesn't.

Circular references leak with reference counting. Infinite data structures don't work with eager evaluation. No type classes means less ad-hoc polymorphism. No modules means less organization for large projects. No async means no concurrent I/O without blocking.

These are real limitations. They matter for some programs. But they don't matter for the programs I write. CLI tools. Data processing scripts. Small utilities. Teaching examples. For these, Kō's limitations are irrelevant, and its simplicity is a feature.

The question isn't whether Kō is perfect. It isn't. The question is whether it's useful. Whether it makes some kinds of programming easier. Whether the simplicity is worth the tradeoffs.

For me, the answer is yes. For you, it might be no. That's fine. Languages are tools, and different tools work for different people.

---

What I'm most excited about is what Kō proves.

It proves that a small language can be useful. That you don't need 200 features to write real programs. That pattern matching, type inference, eager evaluation, and reference counting are enough for most things. That simplicity has value.

It proves that a compiler can be small. 5,000 lines. That's small enough to read in a weekend. Small enough to understand completely. Small enough to modify without fear. In a world of million-line compilers, that feels valuable.

It proves that Zig is a good language for writing compilers. C-level control without C-level pain. Explicit error handling. Fast compilation. Good LLVM bindings. Zig isn't the obvious choice for a compiler, but it works.

It proves that reference counting can work without a garbage collector. That you can have functional programming without GC pauses. That deterministic memory management is possible. The tradeoff is circular references, but for most programs, that's acceptable.

These proofs aren't new. OCaml proved most of them thirty years ago. But Kō proves them in a different way — with a different set of tradeoffs, in a different language, for a different audience. And sometimes the best way to prove something is to build it yourself.

---

Kō isn't finished. There are bugs to fix — multi-line closures capturing free variables, True/False inside lambdas, float binary operations, imported type propagation. There's stdlib to complete — String operations, Array type, Set and Map types. There's ecosystem to build — package manager, test framework, documentation generator.

And there are hard problems ahead. Concurrency — green threads, channels, STM. Effect system — optional, composable effects. Type classes — lightweight, opt-in. Self-hosting — rewriting the compiler in Kō.

These are the problems that will determine whether Kō is a toy or a tool. Whether it's a weekend project or a language people actually use. Whether the bet on simplicity pays off.

I don't know the answers yet. But I'm excited to find out.

---

If you've ever looked at a programming language and thought, "This is too complicated," Kō might be for you. If you've ever wished for a language that just does pattern matching, type inference, and native code without extra ceremony, Kō might be for you. If you've ever wanted to read a compiler and understand every line, Kō might be for you.

Or it might not be. That's fine. The world needs complex languages too. But if you're curious, the source code is on GitHub. The design rationale is in `docs/THEORY.md`. The implementation guide is in `AGENTS.md`. Take a look. Tell me what you think.

I built this because I wanted to understand something. I'm still learning.

---

*Kō (光) means "light" in Japanese. The language is lightweight, illuminating, and fast.*
