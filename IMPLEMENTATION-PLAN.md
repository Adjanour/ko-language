# Kō Implementation Plan

> **Status:** Active plan

> **Baseline verified:** 2026-08-06 at commit `d625407`, ko 0.3.0-alpha

> **Covers:** DESIGN-data-structures.md, DESIGN-strings-characters.md, DESIGN-io-model.md, DESIGN-syntax.md

Every status claim below was checked by compiling and running the feature, not
by reading a doc's own checkboxes. Where a design doc disagrees with the
compiler, the compiler wins and the discrepancy is called out.

---

## 1. Verified Baseline

| Area | State |
|------|-------|
| Syntax | Function syntax (§4) complete: typed params, return types, `pub fn`. Three *frozen* forms missing: tuple access `.0`, record spread `..`, named args `~name:`. |
| Strings | Phase 1 (KoString) done. Phase 2 partial. Phase 3 (`std.text`) not started. Interpolation not implemented. |
| IO | Console output only. No file I/O of any kind. `panic` emits invalid LLVM. |
| Data structures | Nothing. No Array, Map, Set, or `hash`. List/tuple/record work. |

Working today: generics (`fn apply f x = f x`), recursive ADTs, user-defined
`type Result e a = Ok a | Err e`, records with annotations, pattern matching,
`ref`/`:=`/`!`, `|>` on one line, `::`, `comptime`.

---

## 2. Why This Order

Four things block disproportionately much, so they come first:

- **`Ok`/`Err`/`Just`/`Nothing` are undefined.** Not a machinery gap — user-defined
  ADTs with the same shape compile and run. Only the prelude declarations are
  missing. But `Array.pop : Maybe a`, `Map.get : Maybe v`, `String.toInt : Maybe Int`
  and every `Result`-returning I/O signature are unspellable until they exist.
- **Tuple access `.0` does not parse.** `Map.toList : List (k, v)` and
  `Map.fromList` are unusable without it.
- **`panic` emits a terminator mid-block** and fails LLVM verification. Every
  bounds-checked accessor in the Array and Map designs is specified to panic.
- **`hash` gates Map, and Map gates Set** (Set is specified as `Map a ()`).

Stage 0 clears all four. Everything after it is then largely parallelisable.

### Dependency graph

```
Stage 0 (prelude types, tuple access, panic)
   ├── Stage 1  Strings Phase 2      (toInt/ord/chr/interpolation)
   ├── Stage 2  Array                 ──┐
   │                                     ├── Stage 4  Set
   ├── Stage 3  hash + Map            ──┘
   └── Stage 5  IO                    (needs Result + panic)

Stage 6  Syntax leftovers   (independent, do opportunistically)
Stage 7  Deferred to v0.4+  (std.text, Deque, PriorityQueue, Rope)
```

### How to add a builtin in this codebase

The LIR pipeline is the default as of `adc205d`. A new runtime function touches
four places:

1. `src/typecheck.zig` — register the signature in `global` (see the `Float.*`
   block around line 1050)
2. `src/stdlib_codegen.zig` — emit the LLVM IR body, and call your `codegenX`
   from the generate-all routine
3. `src/lir_lower.zig` — add the Kō-name → runtime-symbol pair in the table at
   ~line 505, and the param/return types at ~line 985
4. `src/codegen.zig` — legacy path, only still used by the REPL

Miss step 3 and the function type-checks but fails to link.

---

## Stage 0 — Unblockers

**Goal:** make the vocabulary the other stages are written in expressible.
**Depends on:** nothing.

| # | Task | Files |
|---|------|-------|
| 0.1 | Declare `Maybe a = Just a \| Nothing` and `Result e a = Ok a \| Err e` in the prelude, registering constructors the way `True`/`False` are (`typecheck.zig` ~line 191) | `typecheck.zig` |
| 0.2 | Fix `panic` codegen — the terminator is emitted mid-block; the call must end the block and start a fresh unreachable one | `stdlib_codegen.zig`, `lir_lower.zig` |
| 0.3 | Parse tuple access `t.0` / `t.1` — `parse_postfix` rejects a numeric field after `.` | `parser.zig` |
| 0.4 | Lower tuple access to the existing tuple GEP path | `hir_lower.zig`, `lir_lower.zig` |

**Done when:**
```ko
fn main =
  let t = (1, "two")
  println t.0
  match Just 5
    | Just v => println v
    | Nothing => println 0
```
prints `1` then `5`, and a program calling `panic "x"` aborts with the message
instead of failing LLVM verification.

**Note:** `Result` already occupies type_id 1 and `Bool` type_id 0. Adding
constructors must not renumber those — `next_type_id` starting at 2 is load-bearing
and must match codegen.

---

## Stage 1 — Strings Phase 2

**Goal:** close DESIGN-strings-characters §4 Phase 2.
**Depends on:** Stage 0 (for `Maybe`).

| # | Task | Notes |
|---|------|-------|
| 1.1 | `ord : Char -> Int`, `chr : Int -> Char` | Documented as builtins in §3; currently `undefined name` |
| 1.2 | `String.toInt : String -> Maybe Int`, `String.toFloat` | Needs Stage 0 |
| 1.3 | `String.fromInt`, `String.fromFloat` | `ko_int_to_string` already exists — wire it up |
| 1.4 | **String interpolation** `"a ${e} b"` — desugar in the parser to `String.append` chains | The single highest-visibility gap; documented in two design docs and used throughout their examples |
| 1.5 | Escape sequences `\x41`, `\u{00E9}` in char and string literals | `lexer.zig` |
| 1.6 | Char predicates: `Char.isAlpha`, `isDigit`, `isUpper`, `isLower`, `toUpper`, `toLower` | Thin wrappers over libc |

Already working, no action: `String.length` (O(1) bytes), `split`, `trim`,
`contains`, `substring`, `indexOf`, `startsWith`, `endsWith`, `toUpperCase`,
`toLowerCase`, `append`, `replace`.

**Done when:**
```ko
fn main =
  let name = "World"
  println "Hello, ${name}! (${String.fromInt 42})"
```
prints `Hello, World! (42)`.

---

## Stage 2 — Array

**Goal:** DESIGN-data-structures §3.
**Depends on:** Stage 0 (`Maybe` for `pop`, working `panic` for bounds checks).

| # | Task |
|---|------|
| 2.1 | `KoArray` struct in the runtime — reuse the 32-byte header convention KoString uses so `ko_decref` stays generic; store `length` and `capacity` in the header, elements inline |
| 2.2 | `ko_array_make`, `ko_array_get`, `ko_array_set`, `ko_array_length`, `ko_array_push` with doubling growth |
| 2.3 | Array literal syntax `[1, 2, 3]` — parser currently says `expected expression` at `[` |
| 2.4 | RC: recursive decref of elements, using the header's field bitmap |
| 2.5 | `Array.toList` / `List.toArray` |
| 2.6 | Higher-order: `map`, `filter`, `foldl`, `foldr`, `reverse` |
| 2.7 | `Array.sort`, `sortWith` |

**Design note:** the doc's `KoArray` sketch puts `refcount/length/capacity` at the
front and returns a pointer to the struct. KoString instead returns a pointer to
the *data* with the header at negative offsets, which is what makes `ko_decref`
uniform. Follow the KoString convention and update §3 of the doc, or the two
allocators will drift the way the string header did.

**Done when:** the §9 Array example runs and prints the documented values.

---

## Stage 3 — `hash` + Map

**Goal:** DESIGN-data-structures §4.
**Depends on:** Stage 0 (`Maybe`), Stage 2 (buckets), tuple access from 0.3.

| # | Task |
|---|------|
| 3.1 | `ko_hash(val, type_tag)` covering Int, Float, Bool, Char, String (FNV-1a), Unit, tuple, constructor |
| 3.2 | `KoMap` with separate chaining; resize at load factor 0.75 |
| 3.3 | `ko_map_new/get/set/delete`, `Map.length`, `containsKey` |
| 3.4 | Map literal `{"k": v}` — note this collides with record-literal syntax; resolve before implementing |
| 3.5 | `Map.keys`, `values`, `toList`, `fromList`, `foldl`, `forEach` |
| 3.6 | `Map.union`, `intersection`, `difference` |

**Open question to settle first:** `{ ... }` is already record syntax. The doc
proposes `{"name": "Alice"}` for maps and `{ name = "Alice" }` for records,
distinguished by `:` vs `=`. That is decidable in the parser but subtle. Confirm
the decision before 3.4 rather than during.

---

## Stage 4 — Set

**Goal:** DESIGN-data-structures §5. Small once Map lands.
**Depends on:** Stage 3.

`Set a` is `Map a ()`. Implement as a thin `std/Set.ko` wrapper: `empty`,
`singleton`, `fromList`, `contains`, `add`, `remove`, `size`, `union`,
`intersection`, `difference`, `isSubset`, `toList`.

---

## Stage 5 — IO

**Goal:** DESIGN-io-model §7.
**Depends on:** Stage 0 (`Result`, `panic`).

This stage is **larger than the doc's Phase 1 implies** — §1 has been corrected,
but re-read it: there is no existing file I/O to wrap. It must be written.

| # | Task |
|---|------|
| 5.1 | Decide naming: `IO.readFile` (dot notation, matches stdlib) vs `read_file`. Nothing is implemented, so this is a free choice |
| 5.2 | `Error` type in the prelude |
| 5.3 | Implement the file I/O builtins: read, write, append, exists, size, mkdir, rm, cp, mv, readdir |
| 5.4 | `std/io.ko` wrapping them to return `Result Error` |
| 5.5 | `IO.readLine`, `IO.eprintln`, `IO.eprint` |
| 5.6 | `IO.getEnv : String -> Maybe String` |
| 5.7 | Change `println`/`print` to return `Unit` — **breaking**; do it last in the stage and update every example and test |
| 5.8 | `IO.run` (shell) — deferred to v0.4; the doc flags it as dangerous and it needs an escaping story |

---

## Stage 6 — Syntax leftovers

**Goal:** close DESIGN-syntax gaps. Independent of the other stages; pick up
opportunistically.

| # | Task | Issue |
|---|------|-------|
| 6.1 | Record spread `{ ..other, name = "Bob" }` — listed as *frozen* in §8.2, does not parse | — |
| 6.2 | Named arguments `~name:expr` — listed as *frozen* in §8.1, does not parse | #25 |
| 6.3 | Multi-line pipe `\|>` | #18 |
| 6.4 | Negative numbers as bare args: `f -3` | #17 |
| 6.5 | `!` is absent from `is_expr_start`, so `println !c` silently prints nothing while `println (!c)` prints correctly | — |
| 6.6 | Anonymous record literals `{ name = "Alice" }` without a type name | #19 |
| 6.7 | Pattern guards `pat when expr` — §7.3 defers these deliberately; only do it if demand appears | — |

6.4 and 6.5 are the same underlying gap: `is_expr_start` does not admit prefix
operators, so an unparenthesised prefix expression cannot be an argument. Fixing
the set once addresses both.

---

## Stage 7 — Deferred (v0.4+)

- `std.text`: codepoint length, `codepoints`, `codepointAt`, `fromCodepoints`;
  graphemes later (DESIGN-strings §4 Phase 3)
- `Deque`, `PriorityQueue`, `Rope` (DESIGN-data-structures §7) — library
  concerns, implement in `std.collections`
- Concurrency (DESIGN-io-model §6)

---

## 3. Sequencing Advice

Stage 0 is the only strictly-blocking stage and it is small — do it as one
change set. After that, Stage 1 (strings) and Stage 2 (Array) are independent
and can proceed in parallel.

Prefer Stage 1 first if the goal is demo-ability: string interpolation is the
most visible missing feature, appears throughout every design doc's examples,
and needs no runtime work beyond parser desugaring.

Prefer Stage 2 first if the goal is capability: Array unblocks Map, Set, and the
whole §7 family.

Leave 5.7 (`println` returning `Unit`) until the end of Stage 5. It breaks every
existing example and test in the repo, and there is no reason to absorb that
churn while other stages are still landing.

---

## 4. Test Discipline

Each stage lands with runtime output tests, not just parse tests. Use
`testRuntimeOutputLir` in `src/tests.zig`, and iterate with:

```bash
zig build test -Dtest-filter="<substring>"
```

The full suite relinks all of LLVM; filtering keeps the loop at ~125ms against
~3s. See `ko-zig/docs/HANDBOOK.md` for the stdout-capture rules — output tests
have sharp edges around fd 1.
