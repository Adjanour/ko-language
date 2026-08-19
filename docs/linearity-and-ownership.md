# Linearity and Ownership in Kō

A plain-English guide to Kō's ownership model, what the linearity checker does
(and can't yet do), and how to read its warnings — with a worked case study
from `examples/mini_lexer.ko`.

---

## The Big Idea

**In Kō, most values are linear: a value should be consumed exactly once.**

This is the piece of the design that makes the performance claim honest. If the
compiler can *prove* every value is used exactly once, it can free tree-shaped
data (lists, ADTs, records) with plain `free` when a branch of the tree goes out
of scope — no garbage collector, and no reference counting on the common path.
Trees are naturally linear: a list node has one child, an expression has one
left and one right, a record has one owner. `DESIGN-linear-types.md` calls this
"zero-cost tree ownership."

Shared data is the exception, and it's opt-in: **`ref`** wraps a value in a
reference-counted box, and **`!`** (deref) borrows from it.

```ko
let xs = Cons 1 (Cons 2 Nil)   # xs owns its tree, linearly
let n  = length xs             # xs is CONSUMED — ownership transfers to length
println xs                     # ERROR: xs is gone

let shared = ref (Cons 1 (Cons 2 Nil))   # RC'd shared data
let a = !shared                # borrow 1 (RC incremented)
let b = !shared                # borrow 2 (RC incremented)
```

The design intent, from `DESIGN-linear-types.md` §3.5-3.6:

> `ref expr` creates a shared value (RC = 1); `!expr` borrows (RC incremented,
> decremented when the borrow ends); `!expr` returns a borrowed reference, not
> an owned value; the borrow is temporary — it doesn't outlive the `ref`.

---

## Consume vs. Borrow

The linearity checker (`ko-zig/src/linearity.zig`) walks the HIR and classifies
every use of a variable into one of two buckets:

| Context | Behaviour | Examples |
|---|---|---|
| **Consume** (ownership transfers) | marks the variable used-up; using it again is a warning | function-application arguments, `match` scrutinee, `if`/`else` branches, constructor args (`Cons x acc`), `ref` value, tuple/record fields, `:=` value |
| **Borrow** (read-only) | counted but *not* consumed; can be used again later | primop args (`x < 0`, `x + y`), `if` condition, match arm guards, field access (`record.field`), `!x` deref, `:=` target |

So this is fine — `x` is only ever borrowed:

```ko
fn double x = x + x        # both uses are primop args → borrows
```

And this is a warning — `xs` is consumed by `match` and again later:

```ko
fn first_or_zero xs =
  match xs                 # scrutinee → consume
    Cons h _ => h
    Nil      => 0
  # match on xs again here would warn
```

The model is deliberately *conservative*: a `match` scrutinee is always a
consume, and *any* function call is assumed to consume its arguments — even a
read-only helper like `length`. The type system cannot see inside `length`, so
it assumes the worst. That over-conservatism is the root cause of most warnings
you'll see in real programs.

## The Three Warnings

The checker emits three warnings (never hard errors, unless a linear variable
is never used at all — see below):

1. **`linear variable used twice (warning)`** — a variable was consumed in two
   places. The checker can't prove the first consumer handed it back.
2. **`linear variable used after consumption (warning)`** — a borrow happened
   after a consume. Same family, different wording.
3. **`linear variable never used (warning)`** — bound but never touched. Prefix
   the name with `_` to silence it (`let _tmp = ...`).

All three are reported at the variable's **binding site** (the `fn` signature or
`let` line), which is why a warning can point at a function definition while the
real story is several lines deeper. The `note: consumed at previous use` tells
you where the checker thinks the first consumption happened.

These are **warnings, not errors** — the program still compiles and runs.

## Case Study: `examples/mini_lexer.ko`

A small lexer + recursive-descent parser for arithmetic. Running it today
produces five warnings; the output is correct:

```ko
$ ko mini_lexer.ko
 at mini_lexer.ko:74:1: linear variable used twice (warning)      # reverse
 at mini_lexer.ko:111:1: linear variable used twice (warning)     # parse_multiplication
 at mini_lexer.ko:115:1: linear variable used twice (warning)     # parse_addition_tail
 at mini_lexer.ko:127:1: linear variable used twice (warning)     # parse_expression
 at mini_lexer.ko:131:1: linear variable used twice (warning)     # show_expression
Operation -
Operation +
Name total
Operation *
Integer 12
```

Each warning is a **checker limitation**, not an unsafe-ownership bug. Three
patterns:

### 1. Accumulator recursion — `reverse xs acc`

```ko
fn reverse xs acc =
  match xs
    Cons x rest => reverse rest (Cons x acc)   # xs consumed, acc consumed
    Nil => acc
```

`xs` is consumed by the `match` scrutinee; `acc` is consumed when it's pushed
into `Cons x acc` and when it's returned in the `Nil` arm. Every actual use is
once-per-*path*, but the checker can't see that the recursion hands ownership
back along a single spine — the accumulator pattern (a fresh list node per step)
looks like multiple consumption to a conservative analysis.

### 2. The shared cursor — `parse_multiplication`, `parse_addition_tail`, `parse_expression`

```ko
fn parse_multiplication cursor =
  let left = parse_primary cursor        # consume
  parse_multiplication_tail cursor left  # consume again → warning
```

The parser threads one `cursor` through many calls. Each call takes ownership,
uses it, and the next call needs it again. Functionally this is one
ownership chain; the checker sees the parameter used at several application
sites and flags it. Note the helper `parse_multiplication_tail` itself does the
same thing *internally* (`peek cursor`, `take cursor`, then a recursive call)
yet only the *entry* functions warn — the warning lands on the outermost
re-users.

### 3. Tree traversal — `show_expression`

```ko
fn show_expression expression =
  match expression
    Operation op left right =>
      println (String.append "Operation " op)
      show_expression left              # child consumed
      show_expression right             # second child → warning
```

One `match` consumes the root, then both children are traversed recursively.
Each child is a *different* subtree, but the checker attributes the two
recursive calls to the same consumed parameter. Structurally sound — the warning
is a false positive for a tree walk.

### Why the cursor warnings are benign

The lexer/parser deliberately uses `ref` for the cursor:

```ko
let cursor = ref tokens
show_expression (parse_expression cursor)
```

`ref` is the *shared-ownership* construct. `!cursor` is a temporary borrow
(RC up then down), and the checker handles `deref` as a borrow (`linearity.zig`
treats `.deref` args with `false` — read-only). So the shared cursor is exactly
the pattern the design intends for shared access; the warning is the checker
being conservative about the *parameter flow*, not about the ref. Borrows are
temporary and don't outlive the `ref`, so there is no ownership hazard here.

## Working Around It

- **`--skip-linearity`** disables the checker entirely (`ko --skip-linearity
  file.ko`). Handy for compiler experiments; it also disables the useful
  "never used" warnings, so don't make it your default.
- **`_name` bindings** silence the "never used" family without disabling the
  pass.
- **Restructure** when a warning is real: split the value at the consumption
  point, or pass the pieces you actually need rather than re-piping one variable
  into several calls.

## When to Worry

Treat a warning as a *question*, not a verdict. It's a real bug when you
genuinely rely on a value after handing it away — e.g. borrowing from `ref`
after the `ref` has been consumed, or consuming a box twice. It's noise when the
flow is a single ownership spine (accumulator recursion, tree walks, cursor
threading) — the checker just can't prove it yet. The honest long-term fixes are
in the design's spirit: a smarter checker (path-sensitive consume analysis) or
explicit `clone`/`rebind` operations so the programmer can say "this is a fork,
not a second use" instead of being warned.

---

## Where it lives in the source

| Thing | File |
|---|---|
| Ownership model design | `DESIGN-linear-types.md` |
| Linearity checker (borrow/consume, three warnings) | `ko-zig/src/linearity.zig` |
| `--skip-linearity` flag | `ko-zig/src/main.zig:274` |
| The case study | `ko-zig/src/examples/mini_lexer.ko` |