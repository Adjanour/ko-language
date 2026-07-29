# Kō Positioning

`VISION.md` (in `ko-zig/`) makes the case against the languages Kō learned from — Haskell,
OCaml, Rust, C, Lisp. Those are useful ancestors, but none of them are what a curious reader
will actually compare Kō to in 2026. This doc is about the living siblings: languages making
almost the identical bet, right now, that Kō is making.

If we can't say something specific and true about each of these, we don't have a positioning
yet — we have a language.

---

## The siblings

### Roc

Eager, strict, ML-family. Result instead of exceptions. Automatic reference counting with
Perceus-style reuse analysis (Reinking et al. — the exact paper `RESEARCH.md` cites for Kō's
own RC design). No GC pauses. Aimed explicitly at scripts, CLI tools, and "fast, friendly,
functional." Compiles to native code.

That is not a neighboring point in the design space. That is the same point. Anyone who
finds Kō after searching for "functional language, no GC, compiles native, Result not
exceptions" will find Roc in the same search, and Roc has a multi-year head start, a
platforms/hosting model for effects, and a bigger contributor base.

**What's actually different:** curried application with no parentheses (`add 1 2`, not
`add 1 2` via `add(1, 2)` — Roc still uses parens and comma-separated args). Indentation-based
blocks instead of Roc's brace-free-but-still-parenthesized-calls style. A smaller, more
Haskell/OCaml-shaped grammar. That's a real surface-level difference, not a cosmetic one — it
changes how the language reads and how easy it is to internalize the whole grammar.

**What's not yet different:** the runtime story. Roc's "platforms" model is a real answer to
the effects question (see below); Kō's charter says effects are "unrestricted for now," which
is a placeholder, not an answer. Until Kō has its own opinion here, this axis is a Roc win by
default.

**Verdict:** Roc is the comparison that matters most and the one the docs currently dodge.
Silence on it reads as not having noticed, which is worse than addressing it directly.

### Gleam

Eager, strict, ML-family, runs on the BEAM (and compiles to JS). Deliberately *no*
typeclasses — Gleam's designer has written publicly about cutting them for compile-time
simplicity and predictability. Small, readable, pragmatic language; famously good tooling and
error messages for a young language.

**What's actually different:** Gleam targets a VM (BEAM/JS), Kō targets native code via LLVM.
That's a real, defensible difference — actor-model concurrency and hot code reloading vs.
static binaries and predictable latency are genuinely different value propositions.

**What's worth stealing:** Gleam shipped without typeclasses and didn't die for it. If Kō is
weighing whether traits are load-bearing for v0.3/v0.4 (see `RESEARCH.md`'s priority list),
Gleam is the existence proof that a modern ML-family language can skip them and still be
taken seriously. Worth reading before writing the typeclass design doc.

### Koka

Eager-by-default, algebraic effect handlers, and the actual origin of Perceus RC — Kō's
memory model is downstream of Koka's research, not parallel to it. Koka is closer to a
research language in practice (smaller community, effect handlers are a steep concept), but
it is the language that *solved* the effects question that Kō has deferred.

**What's actually different:** Kō is deliberately not adopting effect handlers — `ZEN.md` and
`VISION.md` both commit to a small, unsurprising core, and effect handlers are exactly the
kind of feature that's powerful but expensive to learn (their own docs put "no category
theory prerequisite" as a selling point). That's a legitimate, defensible choice.

**What's borrowed without attribution yet:** the RC design. `RESEARCH.md` cites Koka in its
references section, but the public-facing docs (README, MARKETING, VISION) don't mention it
at all. Being explicit about "we use Koka's RC technique, not Koka's effect system" is more
credible than silence, especially to the exact audience (PL-literate early adopters) most
likely to notice the resemblance on their own.

---

## What the comparison exposes

Putting the three side by side surfaces the same open question three different ways: **Kō
has borrowed the *memory model* from this generation of languages (Roc, Koka) but not yet
made its own decision about *effects*.** Type system: settled (HM, no typeclasses yet, ADTs).
Memory: settled (Perceus RC). Effects: charter says "unrestricted for now." That's the one
axis where Kō doesn't have an opinion, and it's the axis on which Roc and Koka most clearly do.

This doesn't mean copying either one. It means the effects question is no longer optional to
defer — it's the single biggest unclaimed piece of design space between Kō and its two
closest relatives, and "for now" won't survive first contact with someone who's used both.

## The actual wedge

Strip away the runtime debate and the one thing genuinely distinctive about Kō, visible in
the first five seconds of `hello.ko`, is **no-parens curried application** combined with
**indentation-based blocks**. Roc, Gleam, Koka, OCaml, Haskell — none of them read quite like
`add 1 2` and `fn main = println "Hello, Kō!"`. That's the thing to make the headline, not
"Haskell meets Python" (MARKETING.md) or "fast, simple, functional, native" (VISION.md's
closing line) — both of those descriptions apply to Roc nearly verbatim.

## Open questions this doc doesn't answer

- Does Kō want an effects story at all, or is "eager, unrestricted effects, panic on the
  worst cases" the permanent answer (i.e., closer to OCaml than to Roc or Koka)? Either is
  defensible — but it needs to be a decision, not a gap.
- Is "CLI tools, compilers, data transforms, build tooling" (the charter's stated audience)
  actually different from Roc's stated audience, or the same audience being pitched a
  different syntax?
- Who is the reader who picks Kō over Roc once Roc reaches 1.0? What do they value that Roc
  doesn't give them? Right now the honest answer is "someone who wants no-parens syntax and
  is willing to accept a much younger, smaller ecosystem for it" — which is a fine answer,
  but it should be the stated answer, not an implied one.
