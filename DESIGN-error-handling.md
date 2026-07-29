# Error Handling Design for Kō

> **Status:** Design Draft
> **Date:** 2026-07-27
> **Research:** Rust panic/Result split, Roc's total stdlib, OCaml's `Division_by_zero`, Koka's `exn` effect

---

## Problem

`ZEN.md` and `SPEC.md` both make the same promise: "no exceptions, Result is better." That's a
clean pitch. It's also not what the compiler currently does. This isn't a hypothetical design
question — it's an audit of real, shipped inconsistencies, each with a file and line:

1. **`head`/`tail` on `Nil` silently return sentinel values, not a panic.**
   `ko-zig/std/List.ko:5-11`:
   ```ko
   pub fn head xs = match xs
     | Cons x _ => x
     | Nil => 0
   ```
   `SPEC.md:629-630` documents both as "panics on empty." They don't. `head Nil` returns `0`.
   For `List Int` that's merely wrong; for `List String` or `List (List a)`, `0` is a bogus
   pointer that gets treated as a real heap value downstream — a memory-safety hole in a
   language whose whole pitch is RC-managed safety without a borrow checker.

2. **Integer division and modulo have no zero check.**
   `ko-zig/src/codegen.zig:730-731`:
   ```zig
   .div => core.LLVMBuildSDiv(self.builder, l, r, "sdiv"),
   .mod => core.LLVMBuildSRem(self.builder, l, r, "srem"),
   ```
   Both lower straight to LLVM's raw signed div/rem with no guard. `1 / 0` is a hardware
   `SIGFPE` trap — no Kō message, no stderr output, not even the word "Kō" on the way down.
   This is the one that most directly breaks "no exceptions": it's not an exception, it's
   worse — an unhandled hardware fault.

3. **`panic : String -> Unit` is documented but not implemented.**
   `SPEC.md:523` lists it in the stdlib table. Grepping the entire compiler
   (`ko-zig/src/*.zig`, `ko-zig/std/*.ko`) for `panic` turns up nothing except the unrelated
   stack-overflow checker's internal message. Calling `panic "..."` today either fails to
   resolve or does something undefined — the spec describes a function that doesn't exist.

4. **`assert`, `assert_eq`, `test`, `run_tests` are similarly vaporware.** `SPEC.md` §9.10
   documents all four; none appear in `stdlib.zig` or `std/*.ko`.

5. **`Result.unwrap` doesn't unwrap — it's `unwrapOr` wearing the wrong name.**
   `ko-zig/src/stdlib.zig:308`:
   ```zig
   pub fn ko_result_unwrap(default: i64, result: i64) callconv(.c) i64 {
       return if (resultTag(result) == .ok) resultValue(result) else default;
   }
   ```
   The type is `a -> Result a b -> a` (typecheck.zig:809) — it takes a default, always
   returns a value, never fails. That's a fine, total function. But in Rust, OCaml, and Roc,
   `unwrap` means "give me the value or panic." Anyone bringing that intuition to Kō will
   read `unwrap` in a code sample and assume it can crash, when it actually silently
   papers over the error. That's the opposite of the "no silent failure" pitch.

6. **Stack overflow detection is the one part that's actually done right.**
   `ko-zig/src/codegen.zig:3403-3433`: real depth check inserted at every function entry,
   clear message to stderr (`"ko: stack overflow (depth > 8MB)\nhint: rewrite recursion as
   iteration\n"`), clean exit. This is the template the rest of this doc generalizes.

7. **The `?` operator and `Result` combinators (`map`, `fold`, `and_then`) are the one fully
   coherent part of the story** — total, composable, no hidden control flow. Keep these
   exactly as they are.

So "what happens when something goes wrong in Kō" currently has four different answers
depending which corner of the compiler you're standing in: composable `Result` (good, keep),
silent wrong-value substitution (dangerous, actively memory-unsafe in one case), an
undocumented-to-the-user hardware crash (worse than the exceptions it claims to avoid), and
spec entries for functions that don't exist (misleading). None of this needs new syntax to
fix — it needs one decision, applied consistently.

---

## Research Summary

### Rust: panic vs. Result is a bucket, not a spectrum

Rust draws one line: `Result`/`Option` for *expected* failure a caller should handle,
`panic!` for *broken invariants* the program has no sane way to continue past. The stdlib is
disciplined about naming: `unwrap` panics, `unwrap_or` supplies a default, `unwrap_or_else`
supplies a fallback computation, `?` propagates. The name always tells you which bucket
you're in. Kō's `Result.unwrap` currently violates this naming contract while accidentally
implementing the *semantics* of `unwrap_or`.

### Roc: division is Result, not a panic

Roc doesn't let `/` panic or trap — safe division returns `Result Int DivByZero` (or a
NaN-producing float variant), because zero is a value a program can receive from real input.
This is worth taking seriously: `100 / n` where `n` comes from user input is not a
"broken invariant," it's exactly the kind of expected failure `Result` exists for. Kō
currently treats it as neither — not a `Result`, not even a proper panic, just UB.

### OCaml: `Division_by_zero` is a 30-year-old lesson

OCaml turns integer division by zero into a catchable exception (`Division_by_zero`)
specifically *because* a silent hardware trap was judged unacceptable for a language that
wants to be used for real programs. Kō's current behavior (raw `sdiv`/`srem`, no check) is
the exact failure mode OCaml designed around decades ago. This isn't a novel problem needing
novel research — it's a solved problem Kō hasn't wired up yet.

### Koka: the far end of the spectrum

Koka can model partial functions via the `exn` effect, made visible in the type signature and
handled with `try`. That's more expressive than anything Kō is taking on — `VISION.md`
explicitly rejects effect systems for now, and that's the right call for a language betting
on "small enough to hold in your head." Koka is included here only as the reference point for
*how far* Kō is choosing not to go, not as a source of features to adopt.

---

## Design Goals

1. **One coherent model, no exceptions to the "no exceptions" rule.** `Result` for
   expected/recoverable failure. `panic` for broken invariants and programmer error. Nothing
   else — no silent sentinel values, no unguarded traps reaching the user.
2. **SPEC.md must describe the real compiler.** Every stdlib entry either exists and behaves
   as documented, or isn't in the table.
3. **Naming matches 15 years of ecosystem convention.** `unwrap` panics. `unwrapOr` supplies
   a default. Don't make users relearn a name that already means something specific
   everywhere else.
4. **No hardware traps escape to the user.** Every path that can fail goes through one panic
   mechanism — the one that already exists for stack overflow — not through raw LLVM
   instructions with undefined behavior on bad input.
5. **Stay small.** This is not an effects system and not typed exceptions. It's "which of two
   things happens when a function can't produce a value," decided once and applied everywhere.

---

## Proposed Design

### The two buckets

| | Recoverable (`Result`) | Unrecoverable (`panic`) |
|---|---|---|
| Meaning | Expected failure a caller should handle | Broken invariant / programmer error |
| Examples | `String.to_int` on bad input, file not found, `div`/`mod` by zero, safe list `at`/index | empty-list `head`/`tail` on the panicking variants, stack overflow, `assert` failure |
| Mechanism | Already exists — `Result`, `?`, `map`/`fold`/`and_then` | Generalize the stack-overflow path into a real `panic(msg)` |
| Rule of thumb | Failure a well-formed program can hit from real input | Failure that means the program itself has a bug |

Division by zero is the one case worth debating explicitly: this doc puts it in the `Result`
bucket (Roc's answer), because a divisor coming from user input, a config file, or a
computation isn't a programmer error — it's exactly the shape of failure `Result` exists to
carry. If that's judged too heavy a change for `/` and `%`'s current unchecked-arithmetic
type (`Int -> Int -> Int`), the fallback is OCaml's answer: keep the signature, but panic with
a message instead of trapping. Either is acceptable; silent UB is not.

### `panic` as a real, general mechanism

Generalize `codegen.zig:3403-3433`'s stack-overflow path into the actual `panic : String ->
a` builtin the spec already promises: print to stderr, exit nonzero, no unwinding. Every other
panic site (`head`/`tail` on empty, `assert` failure, eventually out-of-bounds indexing)
calls through this one mechanism instead of each inventing its own failure behavior. One
implementation, one message format, one exit path.

### Fix the naming, not just the behavior

```ko
Result.unwrap    : Result a b -> a        # panics on Err — new
Result.unwrapOr  : a -> Result a b -> a   # today's ko_result_unwrap, renamed
```

This is a small breaking change. Better now, at alpha with 60 commits and no external users
of record, than after v1.0 when renaming a core stdlib function is a migration.

### Fix `head`/`tail` to match the spec

Either:
- (a) make them actually panic on `Nil`, matching `SPEC.md` as written, or
- (b) drop the panicking versions and make `head`/`tail` return `Maybe a` — more idiomatic
  for a language whose charter already says "no null, use `Maybe`" — and add `headOr`/`tailOr`
  for the default-supplying case, mirroring the `unwrap`/`unwrapOr` split above.

(b) is more consistent with Kō's own stated values (`ZEN.md`: "nothing is better than null,
Maybe is better than nothing") and is the recommendation — but it's a real API decision, not
a bug fix, and belongs in the Open Questions resolution below rather than assumed here.

---

## Implementation Plan

### Phase 1 — Fix what's already broken (no new syntax)
- Generalize the stack-overflow panic path into a callable `panic(msg)` builtin.
- Guard `div`/`mod` codegen with a zero check that calls `panic`, closing the SIGFPE hole.
- Rename `ko_result_unwrap` → `ko_result_unwrap_or`; add a real panicking `unwrap`.
- Fix `head`/`tail` in `List.ko` to panic on `Nil` (matches current `SPEC.md` — cheapest fix,
  can be revisited under the Maybe-returning design in Phase 2).
- Update `SPEC.md` §9 to remove `assert`/`assert_eq`/`test`/`run_tests` until implemented, or
  implement them against the same `panic` mechanism.

### Phase 2 — Resolve the `Maybe`-vs-panic question for the stdlib
- Decide (a) vs (b) above for `head`/`tail` and any future indexing operations.
- If (b): add `Maybe`-returning variants, migrate `List.ko`, add `headOr`/`tailOr`.

### Phase 3 — Polish
- Source location in panic messages (file:line), matching the stack-overflow message's
  existing "hint:" convention.
- Implement `assert`/`assert_eq`/`test`/`run_tests` on top of the same `panic` path.

---

## Open Questions

- **Maybe-only stdlib vs. panicking-by-default with `Or` variants?** Roc leans total
  (`List.first` returns `Result`); Rust/OCaml lean panic-by-default with escape hatches. Kō's
  own charter already commits to `Maybe` over null, which argues for leaning total — but this
  is a real API-surface decision for v0.3, not something this doc should force.
- **Does this decide the effects question from `POSITIONING.md`?** Not fully. File IO, network
  calls, and other genuinely external failures still need a home — likely `Result`, by the
  same "expected failure" logic as division — but that's the effects doc's job, not this one's.
  This doc only closes the gap between what `SPEC.md` promises and what the compiler does for
  *values that are already in the language*.
- **Is `panic` ever catchable?** This doc assumes no — unconditional process abort, matching
  Rust's `panic = "abort"` profile and Kō's stated preference for a small, unsurprising core.
  Revisit only if a real use case shows up (e.g. a long-running REPL wanting to catch a panic
  from one input without dying).

---

## Risk Assessment

Low. Nothing here requires new syntax, a grammar change, or a type-system feature — it's bug
fixes (unguarded div/mod, wrong `head`/`tail` behavior) plus one rename plus deleting or
implementing four spec entries that don't exist yet. The risk is entirely on the "don't do
this" side: `head Nil` silently returning `0` is a landmine for the first person who calls it
on a `List String`, and it's the kind of bug that's invisible until someone hits it in
production and it's much more expensive to fix once real programs depend on the current
(wrong) behavior.

---

## Next Steps

1. Ship Phase 1 as a set of correctness fixes — no design debate needed, `SPEC.md` already
   says what the behavior should be, the compiler just doesn't do it yet.
2. Decide the Phase 2 `Maybe`-vs-panic question before `head`/`tail`/indexing APIs get more
   callers in the standard library that would need migrating later.
3. Cross-reference with the effects doc once written — this doc's "expected failure → Result"
   rule should be the same rule that decides how file IO reports errors.
