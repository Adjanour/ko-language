---
title: "Kō Philosophy"
---

# Kō Philosophy

> **Kō** (光): "light" in Japanese. The language should be as light as its name.

---

## 1. What Kō Is

Kō is a small, eager, statically-typed functional language. It aims to stay predictable: one obvious way to apply functions, one obvious way to model state, and one obvious way to understand control flow.

Kō exists to make practical programs easier to reason about. It should be pleasant to write, simple to parse, and straightforward to compile to native code.

Each clause matters:

- **Small**: the language should resist feature drift.
- **Eager**: evaluation should stay predictable.
- **Explicit mutation via refs**: mutation must be visible at the type and syntax level.
- **Exhaustive pattern matching over ADTs**: unhandled cases should be compiler errors.
- **No parentheses for function calls**: curried application is a first-class part of the surface language.

---

## 2. The Principles

```
No parentheses for function calls.
add 1 2 is cleaner than add(1, 2).
The spec fits on a few pages.
If it doesn't, simplify.
ADTs model the world.
Pattern matching handles it.
Immutability by default.
Mutability when you need it.
Compile to native code.
Run everywhere.
Nothing is better than null.
Maybe is better than nothing.
Nothing is better than exceptions.
Result is better than exceptions.
The language should be small.
The library should be big.
Code is read more than written.
Write for the reader.
The compiler is your friend.
It catches your mistakes.
If the compiler can't help, the language is wrong.
Functions are values.
Values are functions.
Everything returns something.
Even nothing.
Compute what you can at compile time.
The rest runs itself.
```

---

## 3. Semantics Before Syntax

These are the commitments syntax must obey.

- **Mutation is explicit and total**. Ordinary bindings do not change. State lives in refs.
- **Effects are unrestricted for now**. `println` is an ordinary function, not an `IO` action.
- **Pattern matches are exhaustive or they do not compile**.
- **Recursion is the default control structure**. Kō does not center loops.
- **Application is implicit**. Calls should read as `add 1 2`, not `add(1, 2)`.

---

## 4. The Rules

1. **No parentheses for function calls.** `add 1 2` not `add(1, 2)`.
2. **Indentation defines blocks.** No curly braces.
3. **Newlines separate expressions.** No semicolons.
4. **No null.** Use `Maybe` instead.
5. **No exceptions.** Use `Result` instead.
6. **No classes.** Use ADTs + functions instead.
7. **Everything returns a value.** Even `if` and `match`.
8. **Immutability by default.** Use `ref` for mutation.
9. **Functions are values.** Pass them around.
10. **Compile to native code.** Run fast everywhere.
11. **Name your arguments.** `~name:value` when clarity helps.
12. **Compute at compile time.** `comptime` when you can.

---

## 5. Data Model

Kō treats algebraic data and named-field records as the two primary shapes of data.

### Sum Types

Use sum types for closed sets of alternatives:

```ko
type Expr =
  Num Int
  | Var String
  | Add Expr Expr
  | Let String Expr Expr
```

### Records

Use records for named-field product types:

```ko
type Binding = {
  name : String,
  value : Int
}
```

### Layout Is A Storage Choice

- The data type itself should stay pure and structural.
- Array-of-structs vs struct-of-arrays belongs to the container or storage wrapper, not the type definition.
- Layout specialization should be a comptime decision over a closed record type.

### Pattern Matching

- Constructor patterns match sum types.
- Record patterns match named fields.
- Partial record patterns must be explicit with `..`.

```ko
Binding { name, .. } => ...
```

---

## 6. Design Principles

1. Prefer the simplest syntax that reads well.
2. Keep the core small and explicit.
3. Add syntax only when it clearly improves everyday code.
4. Preserve predictable parsing and type checking.
5. Favor one canonical way to express a concept.
6. Keep the language easy to compile to native code.

---

## 7. Decision Rule

Keep a feature if it:

- reduces ambiguity
- improves readability
- lowers implementation complexity
- fits the functional core

Reject or defer a feature if it:

- adds overlapping syntax
- creates hidden control flow
- makes errors harder to explain
- forces the typechecker to infer too much

---

## 8. The Language in Numbers

- 19 keywords
- 20 operators
- ~22 expression types
- 1 type system (ADTs + records)
- Compile-time evaluation (`comptime`)
- Named parameters (`~name:expr`)

You can learn it in an afternoon. You can master it in a week.

---

## 9. What Kō Is For

Kō is aimed at:

- CLI tools
- compilers and transpilers
- data transforms
- build and automation tooling
- small-to-medium systems programs

## 10. What Kō Is Not

Kō is deliberately not:

- an object-oriented language
- a feature kitchen sink
- a syntax zoo
- a language with many interchangeable ways to express the same idea
- a system that requires the typechecker to guess too much

---

## 11. The Promise

Kō promises to be:

- **Small**: learnable in a day
- **Simple**: no magic, no hidden behavior
- **Practical**: compiles to real code
- **Functional**: immutable by default
- **Expressive**: ADTs + pattern matching
- **Fast**: compiles to native code via LLVM
- **Clever**: computes what it can at compile time

Kō promises NOT to be:

- **Large**: no thousands of keywords
- **Complex**: no monads, no type classes (yet)
- **Slow**: no interpreter overhead
- **Unsafe**: no null, no exceptions
- **Magic**: no hidden allocations, no implicit conversions

---

## 12. The Future

Kō is small today. It will grow. But it will always be:

- Simple before complex
- Explicit before implicit
- Practical before theoretical
- Human before machine

---

## 13. Positioning: Where Kō Sits

### The Closest Sibling: Roc

Eager, strict, ML-family. Result instead of exceptions. Automatic reference counting with
Perceus-style reuse analysis. No GC pauses. Aimed at scripts, CLI tools, and "fast, friendly,
functional." Compiles to native code.

That is not a neighboring point in the design space. That is the same point. Anyone who
finds Kō after searching for "functional language, no GC, compiles native, Result not
exceptions" will find Roc in the same search, and Roc has a multi-year head start.

**What's actually different:** curried application with no parentheses (`add 1 2`, not
`add(1, 2)`). Indentation-based blocks. A smaller, more Haskell/OCaml-shaped grammar. That's a
real surface-level difference, not a cosmetic one: it changes how the language reads and how
easy it is to internalize the whole grammar.

**What's not yet different:** the runtime story. Roc's "platforms" model is a real answer to
the effects question; Kō's charter says effects are "unrestricted for now," which is a
placeholder, not an answer.

### Gleam: Proof That Typeclasses Are Optional

Eager, strict, ML-family, runs on the BEAM (and compiles to JS). Deliberately *no*
typeclasses. Small, readable, pragmatic language; famously good tooling and error messages.

**What's worth stealing:** Gleam shipped without typeclasses and didn't die for it. If Kō is
weighing whether traits are load-bearing, Gleam is the existence proof that a modern ML-family
language can skip them and still be taken seriously.

### Koka: The Memory Model Origin

Eager-by-default, algebraic effect handlers, and the actual origin of Perceus RC: Kō's
memory model is downstream of Koka's research, not parallel to it.

**What's different:** Kō is deliberately not adopting effect handlers: `ZEN.md` commits to
a small, unsurprising core, and effect handlers are exactly the kind of feature that's powerful
but expensive to learn.

**What's borrowed:** the RC design. Being explicit about "we use Koka's RC technique, not
Koka's effect system" is more credible than silence.

### The Open Question

Kō has borrowed the *memory model* from this generation of languages (Roc, Koka) but not yet
made its own decision about *effects*. Type system: settled (HM, no typeclasses yet, ADTs).
Memory: settled (Perceus RC). Effects: "unrestricted for now." That's the one axis where Kō
doesn't have an opinion.

The actual wedge: **no-parens curried application** combined with **indentation-based blocks**.
Roc, Gleam, Koka, OCaml, Haskell: none of them read quite like `add 1 2` and
`fn main = println "Hello, Kō!"`. That's the thing to make the headline.
