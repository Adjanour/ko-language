# Kō (光) Language Roadmap & Vision

## Vision

**Kō is a minimal, eager, purely functional language that proves simplicity is sufficient.**

Where Haskell has monads, Kō has refs. Where Rust has ownership, Kō has reference counting. Where OCaml has modules, Kō has flat imports. The hypothesis: a small, predictable language with good inference is more useful than a large, complex one.

**Target audience:** developers who want functional programming without the ceremony—systems programmers who need mutation, web developers who need simplicity, educators who need clarity.

**Success metric:** Can a Kō program do 80% of what an OCaml program can do, with 50% of the complexity?

---

## Core Principles

1. **Simplicity over power** — Every feature must earn its place. If a feature can be implemented in user code, it shouldn't be in the language.

2. **Predictable performance** — Eager evaluation + LLVM = no hidden costs. No laziness, no thunks, no GC pauses.

3. **Good error messages** — Type inference finds the type; the compiler explains *why* it's wrong.

4. **Practical purity** — Pure functions by default, refs when you need mutation. No monads, no do-notation, no effect tracking.

5. **Minimal surface area** — The language spec should fit on a single page. The implementation should be understandable by one person.

---

## Current State (v0.2.0-alpha) — July 2026

### What Works
- Full HM type inference with let-polymorphism
- Sum types, records, tuples, pattern matching
- Lambdas, closures, partial application
- Reference counting with scope-based decref
- Compile-time evaluation (`comptime`)
- Module imports (flat file system)
- LSP server, VS Code extension, REPL
- Multiple compilation modes (JIT, IR, object, executable)

### What's Broken
- LLVM 22 optimization bug (AOT compiles unoptimized)
- Multi-line closures capturing free variables crash
- True/False inside lambdas don't work
- Imported type info doesn't propagate to main module
- Float binary operations not supported by typechecker

### What's Missing
- String operations (split, replace, trim, contains, etc.)
- Collections beyond List (Set, Map, Array)
- Guard expressions in match arms
- Package/module system (hierarchical imports)
- Runtime correctness tests (only parse tests exist)
- Concurrency (async, threads, IO monad)
- Ecosystem (package manager, test framework, docs generator)

---

## Phase 1: Stabilization (v0.3.0)

**Goal:** Fix what's broken. Make the compiler reliable.

**Timeline:** July 2026 — September 2026

### 1.1 Fix Known Bugs
- [ ] Multi-line closure capture (codegen error)
- [ ] True/False inside lambdas
- [ ] Float binary operations in typechecker
- [ ] Imported type propagation
- [ ] `inspect` list sugar for nested types

### 1.2 Runtime Correctness Tests
- [ ] Add output verification tests (compile + run + check stdout)
- [ ] Test all 24 examples programmatically
- [ ] Add edge case tests (empty lists, deep recursion, large numbers)
- [ ] Memory leak detection in test suite

### 1.3 Error Message Quality
- [ ] Type error explanations with context
- [ ] "Expected X, got Y" with source location
- [ ] Suggested fixes for common mistakes
- [ ] Warning system for unused bindings, shadowing

### 1.4 Documentation
- [ ] Language reference (one-page spec)
- [ ] Tutorial for beginners
- [ ] Migration guide from OCaml/Haskell
- [ ] API docs for stdlib

**Exit criteria:** All known bugs fixed, 100+ tests with output verification, clear error messages.

---

## Phase 2: Completeness (v0.4.0)

**Goal:** Fill in the gaps. Make the language usable.

**Timeline:** October 2026 — December 2026

### 2.1 Standard Library Expansion

#### String Operations (built-in, LLVM IR)
- `String.split sep str` → `List String`
- `String.replace old new str` → `String`
- `String.trim str` → `String`
- `String.contains needle str` → `Bool`
- `String.charAt index str` → `Char`
- `String.toUpperCase str` → `String`
- `String.toLowerCase str` → `String`
- `String.substring start len str` → `String`
- `String.indexOf needle str` → `Int` (-1 if not found)
- `String.startsWith prefix str` → `Bool`
- `String.endsWith suffix str` → `Bool`
- `String.fromInt n` → `String`
- `String.toFloat s` → `Result Float String`
- `String.fromFloat f` → `String`

#### Type Conversions
- `Int.fromString s` → `Result Int String`
- `Float.toString f` → `String`
- `Char.toString c` → `String`
- `String.toList s` → `List Char`
- `String.fromList cs` → `String`

#### Collection Types (in std/)
- `type Array a` — mutable array with O(1) index
- `type Set a` — balanced binary tree set
- `type Map k v` — balanced binary tree map
- `type Queue a` — functional queue (amortized O(1))
- `type Stack a` — alias for List

#### Array Operations
- `Array.new size default` → `Array a`
- `Array.get index arr` → `a`
- `Array.set index value arr` → `Array a`
- `Array.length arr` → `Int`
- `Array.map f arr` → `Array b`
- `Array.filter pred arr` → `Array a`
- `Array.foldl f init arr` → `b`
- `Array.fromList list` → `Array a`
- `Array.toList arr` → `List a`

#### Set Operations
- `Set.empty` → `Set a`
- `Set.insert elem set` → `Set a`
- `Set.member elem set` → `Bool`
- `Set.delete elem set` → `Set a`
- `Set.size set` → `Int`
- `Set.toList set` → `List a`
- `Set.fromList list` → `Set a`
- `Set.union s1 s2` → `Set a`
- `Set.intersection s1 s2` → `Set a`
- `Set.difference s1 s2` → `Set a`

#### Map Operations
- `Map.empty` → `Map k v`
- `Map.insert key value map` → `Map k v`
- `Map.get key map` → `Maybe v`
- `Map.delete key map` → `Map k v`
- `Map.size map` → `Int`
- `Map.keys map` → `List k`
- `Map.values map` → `List v`
- `Map.toList map` → `List (k, v)`
- `Map.fromList list` → `Map k v`
- `Map.update key f map` → `Map k v`

### 2.2 Language Features

#### Guard Expressions
```ko
fn abs n =
  match n
    | n when n < 0 => -n
    | n => n

fn classify age =
  match age
    | age when age < 13 => "child"
    | age when age < 18 => "teen"
    | _ => "adult"
```

#### Record Punning in Let
```ko
let { x, y } = point
let { name, .. } = person
```

#### Where Clauses
```ko
fn quadratic a b c x =
  a * x * x + b * x + c
  where
    x2 = x * x
```

#### List Comprehensions (sugar for map/filter)
```ko
let evens = [x | x <- [1..100], x % 2 == 0]
let pairs = [(x, y) | x <- [1..10], y <- [1..10], x < y]
```

### 2.3 Import System Improvements
- [ ] Hierarchical module paths (`import std.collections.List`)
- [ ] Circular import detection with clear error
- [ ] Re-exports (`pub use`)
- [ ] Module-level documentation extraction

### 2.4 Tooling
- [ ] `ko test` — run .ko test files with output verification
- [ ] `ko fmt` — automatic code formatter
- [ ] `ko doc` — generate documentation from doc comments
- [ ] `ko check` — type check without codegen

**Exit criteria:** Complete stdlib, guard expressions, working toolchain.

---

## Phase 3: Ecosystem (v0.5.0)

**Goal:** Build the community. Make Kō accessible.

**Timeline:** January 2027 — March 2027

### 3.1 Package Manager
- [ ] `ko init` — create new project
- [ ] `ko add dep` — add dependency
- [ ] `ko install` — install dependencies
- [ ] `ko publish` — publish package
- [ ] `ko.org` — package registry

### 3.2 Test Framework
```ko
import test.{describe, it, expect}

describe "List operations" $
  it "empty list has length 0" $
    expect (List.length Nil) == 0

  it "cons adds to front" $
    expect (List.length (1 :: Nil)) == 1

  it "map transforms elements" $
    expect (List.map (\x -> x * 2) [1, 2, 3]) == [2, 4, 6]
```

### 3.3 Documentation Generator
- [ ] Extract doc comments from source
- [ ] Generate HTML documentation
- [ ] API reference with types and examples
- [ ] Tutorial integration

### 3.4 Playground
- [ ] Web-based Kō REPL
- [ ] Share code snippets
- [ ] Example gallery

### 3.5 Editor Support
- [ ] Vim/Neovim plugin
- [ ] Emacs mode
- [ ] Sublime Text package
- [ ] IntelliJ plugin

**Exit criteria:** Working package manager, test framework, documentation, editor plugins.

---

## Phase 4: Advanced Features (v1.0.0)

**Goal:** Push the boundaries. Make Kō distinctive.

**Timeline:** April 2027 — September 2027

### 4.1 Concurrency

#### Lightweight Threads (Green Threads)
```ko
fn main =
  let t1 = spawn \ -> heavyComputation ()
  let t2 = spawn \ -> anotherComputation ()
  let r1 = await t1
  let r2 = await t2
  println (r1 + r2)
```

#### Channels
```ko
fn main =
  let ch = Channel.new ()
  spawn \ -> Channel.send ch 42
  let val = Channel.recv ch
  println val
```

#### STM (Software Transactional Memory)
```ko
fn main =
  let counter = TVar.new 0
  atomically $
    let val = TVar.read counter
    TVar.write counter (val + 1)
```

### 4.2 Effect System (Optional)
```ko
# Pure function
fn add x y = x + y

# Effectful function
fn readFile path : IO String =
  let content = IO.perform (ReadFile path)
  content

# Effect tracking
fn main : IO () =
  let content = readFile "hello.txt"
  println content
```

### 4.3 Type Classes (Lightweight)
```ko
class Eq a where
  (==) : a -> a -> Bool
  (!=) : a -> a -> Bool

class Ord a where
  (<) : a -> a -> Bool
  (<=) : a -> a -> Bool
  (>) : a -> a -> Bool
  (>=) : a -> a -> Bool

instance Eq Int where
  (==) = intEq
  (!=) = intNeq

instance Ord Int where
  (<) = intLt
  (<=) = intLe
  (>) = intGt
  (>=) = intGe
```

### 4.4 GADTs (Generalized Algebraic Data Types)
```ko
type Expr a where
  Num : Int -> Expr Int
  Bool : Bool -> Expr Bool
  Add : Expr Int -> Expr Int -> Expr Int
  If : Expr Bool -> Expr a -> Expr a -> Expr a
  Equal : Eq a => Expr a -> Expr a -> Expr Bool
```

### 4.5 Dependent Types (Exploratory)
```ko
# Vector with compile-time length
type Vect : Nat -> Type -> Type where
  Nil : Vect 0 a
  Cons : a -> Vect n a -> Vect (n + 1) a

# Safe head (can't call on empty)
head : Vect (n + 1) a -> a
head (Cons x _) = x
```

### 4.6 Compiler Optimizations
- [ ] LLVM 23 upgrade (fix optimization bug)
- [ ] Whole-program optimization
- [ ] Link-time optimization (LTO)
- [ ] Profile-guided optimization (PGO)
- [ ] Tail call optimization ( guaranteed by pattern matching)

### 4.7 Foreign Function Interface (FFI)
```ko
# Call C functions
import foreign "libc" {
  fn printf : String -> Int
  fn malloc : Int -> Ptr
  fn free : Ptr -> ()
}

# Call Kō from C
export fn add x y = x + y
```

### 4.8 Metaprogramming
```ko
# Compile-time code generation
comptime fn generateMatrix n =
  let rows = [0..n]
  let cols = [0..n]
  let cells = [\i -> \j -> if i == j then 1 else 0 | i <- rows, j <- cols]
  Matrix.new cells

# Quasiquoting
let code = [expr| x + y |]
let result = eval code
```

**Exit criteria:** Concurrency, effects, type classes, FFI, optimization.

---

## Long-term Vision (v2.0+)

### Self-hosting
Rewrite the Kō compiler in Kō. This is the ultimate test of the language's expressiveness.

### Web Backend
Compile Kō to WebAssembly for browser deployment.

### Mobile Support
Compile Kō to iOS/Android via LLVM.

### Distributed Computing
```ko
fn main =
  let nodes = discover "cluster.local"
  let data = distribute nodes [1..1000000]
  let results = map parallel (\x -> expensiveComputation x) data
  let total = sum results
  println total
```

### Formal Verification
```ko
# Prove properties at compile time
prove "factorial is positive" :
  for all n : Int, n >= 0 => factorial n > 0

# Refined types
type PositiveInt = { n : Int | n > 0 }
type NonEmptyList a = { list : List a | length list > 0 }
```

---

## Release Schedule

| Version | Target Date | Focus |
|---------|------------|-------|
| v0.3.0 | September 2026 | Stabilization — fix bugs, add tests |
| v0.4.0 | December 2026 | Completeness — stdlib, guards, tooling |
| v0.5.0 | March 2027 | Ecosystem — packages, tests, docs |
| v1.0.0 | September 2027 | Advanced — concurrency, effects, FFI |
| v2.0.0 | 2028+ | Self-hosting, web, mobile, distributed |

---

## Learning Resources & Research

### Foundational Papers

#### Type Inference & Hindley-Milner
- [Algorithm W (Milner 1978)](https://web.stanford.edu/class/cs242/reading/wand-1980.pdf) — "Polymorphic Type Schemes and Recursive Definitions" — The original Algorithm W paper
- [A Type Inference System for ML (Damás & Milner 1982)](https://doi.org/10.1145/582153.582156) — Complete type inference with let-polymorphism
- [Typing Haskell in Haskell (Jones 1999)](https://doi.org/10.1017/S0956796899003342) — Practical HM implementation in Haskell

#### Unification
- [Unification Algorithms (Robinson 1965)](https://doi.org/10.1145/800157.800165) — "A Machine-Oriented Logic Based on the Resolution Principle" — The foundation of unification
- [A Unification Algorithm for Typed Lambda Calculus (Huet 1975)](https://www.lsi.upc.edu/~roberto/papers/huet-unification.pdf) — Efficient unification algorithm

#### Pattern Matching
- [Compiling Pattern Matching (Augustsson 1985)](https://doi.org/10.1145/318593.318622) — Efficient pattern matching compilation
- [Pattern Matching Compilation (Maranget 2008)](https://hal.archives-ouvertes.fr/hal-01100582) — "Warnings for pattern matching" — Modern pattern matching compilation

#### Memory Management
- [Reference Counting (Collins 1960)](https://doi.org/10.1145/367173.367192) — Original reference counting paper
- [Efficient Reference Counting (Sekiguchi 1997)](https://doi.org/10.1017/S0956796897002624) — Optimizing reference counting for functional languages

#### Closure Conversion
- [Closure Conversion (Appel 1992)](https://doi.org/10.1016/0167-6423(92)90013-3) — "Effective static-graph reuse" — Closure conversion techniques

#### Compiler Construction
- [Modern Compiler Implementation (Appel 1998)](https://www.cs.princeton.edu/~appel/modern/ml/) — "Modern Compiler Implementation in ML" — The bible of compiler construction
- [Engineering a Compiler (Cooper & Torczon 2011)](https://www.elsevier.com/books/engineering-a-compiler/cooper/978-0-12-088473-5) — Modern compiler engineering
- [Compiling with Continuations (Appel 1992)](https://doi.org/10.1017/CBO9780511624728) — Continuation-passing style and closure conversion

#### LLVM
- [LLVM Tutorial](https://llvm.org/docs/tutorial/) — "My First Language Frontend" — Step-by-step LLVM codegen tutorial
- [LLVM Language Reference](https://llvm.org/docs/LangRef.html) — Complete LLVM IR reference
- [Kaleidoscope: Implementing a Language with LLVM](https://llvm.org/docs/tutorial/MyFirstLanguageFrontend/LangImpl01.html) — Building a toy language with LLVM

#### Functional Language Design
- [The Essence of ML (Pierre Weis & Xavier Leroy)](https://caml.inria.fr/ocaml/htmlman/) — OCaml manual — Design decisions in a practical ML
- [Haskell 2010 Report](https://www.haskell.org/onlinereport/haskell2010/) — Haskell language specification
- [The Haskell 98 Report](https://www.haskell.org/onlinereport/haskell98/) — Original Haskell 98 specification

### Books & Tutorials

#### Compiler Construction
- [Crafting Interpreters (Nystrom 2021)](https://craftinginterpreters.com/) — Free online book, excellent for understanding parsing and bytecode compilation
- [Writing An Interpreter In Go (Mihailis 2016)](https://interpreterbook.com/) — Practical interpreter implementation
- [Engineering a Compiler (Cooper & Torczon 2011)](https://www.elsevier.com/books/engineering-a-compiler/cooper/978-0-12-088473-5) — Academic but practical compiler engineering
- [Compilers: Principles, Techniques, and Tools (Aho et al. 2006)](https://doi.org/10.1145/513435.513443) — The Dragon Book — Classic compiler theory

#### Functional Programming
- [Introduction to Functional Programming (Bird 1988)](https://doi.org/10.1007/978-3-662-02413-3) — Classic FP textbook
- [Real World Haskell (O'Sullivan et al. 2008)](https://book.realworldhaskell.org/) — Free online, practical Haskell
- [Learn You a Haskell for Great Good (Lipovaca 2011)](http://learnyouahaskell.com/) — Free online, beginner-friendly Haskell
- [Functional Programming in Scala (Chiusano & Bjarnason 2015)](https://www.manning.com/books/functional-programming-in-scala) — Functional concepts in Scala

#### Zig Programming
- [Zig Documentation](https://ziglang.org/documentation/) — Official Zig docs
- [Zig Learn](https://ziglang.org/learn/) — Official tutorials
- [Zig by Example](https://ziglang.org/learn/) — Practical examples

### Online Resources

#### Language Design
- [Lambda the Ultimate](http://lambda-the-ultimate.org/) — Academic PL research blog
- [Types-FAQ](https://github.com/lysxia/types-faq) — Common type system questions
- [Haskell Wiki](https://wiki.haskell.org/) — Comprehensive Haskell reference
- [OCaml Manual](https://caml.inria.fr/ocaml/htmlman/) — OCaml documentation
- [Rust Reference](https://doc.rust-lang.org/reference/) — Rust language reference

#### LLVM & Code Generation
- [LLVM Tutorial: Kaleidoscope](https://llvm.org/docs/tutorial/MyFirstLanguageFrontend/LangImpl01.html) — Building a language frontend with LLVM
- [LLVM IR Tutorial](https://llvm.org/docs/tutorial/) — Step-by-step LLVM IR generation
- [LLVM Language Reference](https://llvm.org/docs/LangRef.html) — Complete LLVM IR specification
- [Awesome LLVM](https://github.com/AshkanKhd/awesome-llvm) — LLVM resources collection

#### Type Systems
- [Types and Programming Languages (Pierce 2002)](https://www.cis.upenn.edu/~bcpierce/tapl/) — The TAPL book — Definitive type systems reference
- [Advanced Types and Programming Languages (Pierce 2002)](https://www.cis.upenn.edu/~bcpierce/attapl/) — Advanced type systems
- [Introduction to Lambda Calculus (Barendregt & Barendsen 2000)](https://www.cambridge.org/core/books/introduction-to-lambda-calculus/58D340B21C672C40C0E0C79F9F57692C) — Lambda calculus foundations

#### Functional Programming Patterns
- [Functional Design Patterns (Friedman & Wise 1979)](https://doi.org/10.1145/800186.810614) — Original functional programming patterns
- [The Little MLer (Felleisen et al. 1998)](https://mitpress.mit.edu/9780262561143/the-little-mler/) — Teaching functional programming through examples
- [Why Functional Programming Matters (Hughes 1984)](https://doi.org/10.1016/0167-6423(84)90023-7) — Classic paper on FP benefits

#### Reference Counting & Memory Management
- [Efficient Reference Counting in Functional Languages (Sekiguchi 1997)](https://doi.org/10.1017/S0956796897002624)
- [Optimizing Reference Counting (Hudak 1986)](https://doi.org/10.1145/99584.99601)
- [Reference Counting for Functional Languages (DeTreville 1990)](https://doi.org/10.1145/91552.91633)

### Research Groups & Projects

#### Language Research
- [INRIA Gallium](https://gallium.inria.fr/) — OCaml and ML research
- [Glasgow Haskell Compiler](https://www.haskell.org/ghc/) — GHC development and research
- [Rust Language Team](https://www.rust-lang.org/governance/teams/language) — Rust language design
- [Zig Software Foundation](https://ziglang.org/) — Zig development

#### Compiler Research
- [LLVM Project](https://llvm.org/) — LLVM compiler infrastructure
- [MLton](http://mlton.org/) — Whole-program optimizing ML compiler
- [GHC](https://ghc.haskell.org/) — Glasgow Haskell Compiler

### Community

#### Forums & Discussion
- [Haskell Discourse](https://discourse.haskell.org/) — Haskell community forum
- [OCaml Discuss](https://discuss.ocaml.org/) — OCaml community forum
- [Rust Users Forum](https://users.rust-lang.org/) — Rust community forum
- [Zig Programming](https://ziglang.org/learn/) — Zig community resources

#### Conferences
- [ICFP](https://icfp.sigplan.org/) — International Conference on Functional Programming
- [POPL](https://popl.sigplan.org/) — Principles of Programming Languages
- [Haskell Symposium](https://icfp.sigplan.org/category/haskell-symposium/) — Annual Haskell conference
- [Zig Software Foundation Events](https://ziglang.org/community/) — Zig community events

---

## Success Stories (Aspirational)

### The Server
```ko
# A simple web server
import http.{Server, Request, Response}

fn handler req =
  match req.path
    | "/" => Response.html "<h1>Hello, Kō!</h1>"
    | "/api/time" => Response.json { time = Time.now () }
    | _ => Response.notFound "Not found"

fn main =
  Server.serve 8080 handler
```

### The CLI Tool
```ko
# A file organizer
import sys.{args, exit}
import fs.{readDir, rename, mkdir}
import path.{join, extension}

fn main =
  let dir = args !! 0 or_else \ -> exit 1 "Usage: organize <dir>"
  let files = readDir dir
  let byExt = groupBy extension files
  forEach byExt \(ext, fs) ->
    mkdir (join dir ext)
    forEach fs \f -> rename (join dir f) (join (join dir ext) f)
  println (toString (length files) ++ " files organized")
```

### The Game
```ko
# Tetris in Kō
import graphics.{Canvas, Color, Event}
import list.{random}

type Piece = { shape : List (Int, Int), color : Color }

fn newPiece () =
  let shapes = [ [(0,0),(1,0),(2,0),(3,0)]  # I
               , [(0,0),(1,0),(0,1),(1,1)]  # O
               , [(0,0),(1,0),(2,0),(1,1)]  # T
               , ... ]
  { shape = random shapes, color = random [Color.red, Color.blue, ...] }

fn main =
  let canvas = Canvas.new 400 600
  let state = { board = emptyBoard, piece = newPiece (), score = 0 }
  gameLoop canvas state
```

---

## Philosophy

Kō doesn't try to be everything to everyone. It tries to be **simple enough to understand completely**, **powerful enough to be useful**, and **predictable enough to be reliable**.

The language is small enough that you can hold the entire thing in your head. The compiler is small enough that you can understand the entire implementation. The ecosystem is small enough that you can know every package.

**In a world of complexity, Kō chooses simplicity.**
