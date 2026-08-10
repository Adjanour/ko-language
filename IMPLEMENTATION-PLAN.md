# Kō Implementation Plan

> **Status:** Active plan

> **Baseline verified:** 2026-08-06 at commit `d625407`, ko 0.3.0-alpha

> **Covers:** DESIGN-data-structures.md, DESIGN-strings-characters.md, DESIGN-io-model.md, DESIGN-syntax.md

Every status claim below was checked by compiling and running the feature, not by reading a doc's own checkboxes. Where a design doc disagrees with the compiler, the compiler wins and the discrepancy is called out.

---

## 1. Verified Baseline

| Area | State |
|------|-------|
| Syntax | Function syntax (§4) complete: typed params, return types, `pub fn`. Tuple access `.0` landed in Stage 0. Two *frozen* forms still missing: record spread `..`, named args `~name:`. |
| Strings | Phase 1 (KoString) and Phase 2 done in Stage 1, including interpolation and escapes. Phase 3 (`std.text`) not started. |
| IO | Console output only. No file I/O of any kind. |
| Data structures | Array landed in Stage 2 — literals, mutation, higher-order, sort. No Map, Set, or `hash` yet. List/tuple/record work; `List` is still user-declared, not builtin. |

Working today: generics (`fn apply f x = f x`), recursive ADTs, user-defined `type Result e a = Ok a | Err e`, records with annotations, pattern matching, `ref`/`:=`/`!`, `|>` on one line, `::`, `comptime`.

---

## 2. Why This Order

Four things block disproportionately much, so they come first:

- ~~**`Ok`/`Err`/`Just`/`Nothing` are undefined.**~~ Declared in the prelude in Stage 0, so `Array.pop : Maybe a`, `Map.get : Maybe v`, `String.toInt : Maybe Int` and the `Result`-returning I/O signatures are now spellable.
- ~~**Tuple access `.0` does not parse.**~~ Landed in Stage 0. `Map.toList : List (k, v)` and `Map.fromList` are now spellable.
- ~~**`panic` emits a terminator mid-block.**~~ It did not — see Stage 0. `panic` was already usable for the bounds checks the Array and Map designs specify.
- **`hash` gates Map, and Map gates Set** (Set is specified as `Map a ()`).

Stage 0 cleared the first three; only `hash` remains. Everything after it is largely parallelisable.

### Dependency graph

```
Stage 0 (prelude types, tuple access)  — DONE
   ├── Stage 1  Strings Phase 2      — DONE
   ├── Stage 2  Array — DONE (2.5 deferred) ─┐
   │                                     ├── Stage 4  Set
   ├── Stage 3  hash + Map            ──┘
   └── Stage 5  IO                    (needs Result + panic)

Stage 6  Syntax leftovers   (independent, do opportunistically)
Stage 7  Deferred to v0.4+  (std.text, Deque, PriorityQueue, Rope)
```

### How to add a builtin in this codebase

The LIR pipeline is the default as of `adc205d`. A new runtime function touches four places:

1. `src/typecheck.zig` — register the signature in `global` (see the `Float.*` block around line 1050)
2. `src/stdlib_codegen.zig` — emit the LLVM IR body, and call your `codegenX` from the generate-all routine
3. `src/lir_lower.zig` — add the Kō-name → runtime-symbol pair in the table at ~line 505, and the param/return types at ~line 985
4. `src/codegen.zig` — legacy path, only still used by the REPL

Miss step 3 and the function type-checks but fails to link.

---

## Stage 0 — Unblockers — DONE

**Goal:** make the vocabulary the other stages are written in expressible.
**Depends on:** nothing.

| # | Task | Files | Status |
|---|------|-------|--------|
| 0.1 | Declare `Maybe a = Just a \| Nothing` and `Result e a = Ok a \| Err e` in the prelude | `typecheck.zig`, `lir_lower.zig`, `codegen.zig` | done |
| 0.2 | ~~Fix `panic` codegen — terminator emitted mid-block~~ — **the claim was wrong**; `panic` already aborted with the right message and exit 134. The real defect was that `abort()` skips the atexit handlers that drain stdout, so buffered `println` output vanished through a pipe. Fixed with `fflush(NULL)` in `ko_panic` | `stdlib_codegen.zig` | done |
| 0.3 | Parse tuple access `t.0` / `t.1` | `parser.zig` | done |
| 0.4 | Lower tuple access to the tuple GEP path | `lir_lower.zig`, `codegen.zig` | done |

**Done when:** satisfied — the acceptance program prints `1` then `5`, and `panic "x"` aborts with its message.

### What Stage 0 actually cost

Three bugs surfaced that the plan did not predict, each blocking the one above it:

- **`instantiate` freshened non-quantified type variables.** In Hindley-Milner only *quantified* variables are renamed per instantiation; free ones are shared, and that sharing is how a call site's argument type reaches the function body. Freshening them silently undid the monomorphic pinning `generalize` does for field accesses, so `fn fst p = p.0` — and equally `fn area r = r.w`, which predates this work — left the object type unbound at codegen and failed with `LIR lowering error: TypeError`. Field access through an unannotated parameter now works for tuples and records alike.
- **`generalize` pinned stale variable ids.** `field_access_vars` stored the id current at field-access time, but `unify` links a variable by setting `instance`, so by generalize time the representative had moved and the skip missed. It now stores type pointers and re-resolves.
- **The parser corrupted nested type applications.** `func = .{ .application = .{ .func = try self.newTypeExpr(func), ... } }` builds the union directly into `func`'s own storage, so the new tag lands before the operand is read and the saved pointer captures a half-overwritten value. `Cons a (List a)` came out as garbage. Nothing had ever dereferenced a nested type application — `ctorParamType` returned a fresh variable for `.application` — so it went unnoticed until 0.1 made that branch real.

**Note:** `type_ids` turned out to be write-only outside typecheck — no codegen reads it — so the "load-bearing `next_type_id`" warning was overstated. `Maybe` took id 2 and user types now start at 3.

**Known gap, not a regression:** the legacy pipeline fails LLVM verification (`PHI node operands are not the same type`) on any match returning `String` over an ADT, including plain user-defined ones. It predates this work and is unrelated to Stage 0; legacy is frozen and REPL-only.

---

## Stage 1 — Strings Phase 2 — DONE

**Goal:** close DESIGN-strings-characters §4 Phase 2.
**Depends on:** Stage 0 (for `Maybe`).

| # | Task | Status |
|---|------|--------|
| 1.1 | `ord : Char -> Int`, `chr : Int -> Char` (also `Char.toInt`/`Char.fromInt`) | done — representation-only, resolved during lowering with no runtime call |
| 1.2 | `String.toInt : String -> Maybe Int`, `String.toFloat : String -> Maybe Float` | done — stricter than the old `ko_string_to_int`, which used `strtoll` with a null end pointer and so accepted `"abc"` as 0 and `"12x"` as 12 |
| 1.3 | `String.fromInt`, `String.fromFloat` | done |
| 1.4 | **String interpolation** `"a ${e} b"` | done — see below |
| 1.5 | Escape sequences | done — `\n \t \r \0 \\ \" \' \$ \xNN \u{...}`. Scope was larger than stated: **no** escape was processed before, so `"a\nb"` printed a literal backslash-n |
| 1.6 | Char predicates and case conversion | done — `isAlpha`, `isDigit`, `isAlnum`, `isSpace`, `isUpper`, `isLower`, `toUpper`, `toLower` |

Already working, no action: `String.length` (O(1) bytes), `split`, `trim`, `contains`, `substring`, `indexOf`, `startsWith`, `endsWith`, `toUpperCase`, `toLowerCase`, `append`, `replace`.

**Done when:** satisfied — the acceptance program prints `Hello, World! (42)`.

### How interpolation works

`"a ${e} b"` is desugared by the parser into a left-nested chain of `String.append`, with each embedded expression wrapped in `String.from`:

```
"Hello, ${name}! n=${n}"
  => String.append
       (String.append
          (String.append "Hello, " (String.from name))
          "! n=")
       (String.from n)
```

Four decisions worth knowing:

**The lexer keeps the literal in one token.** It scans `${` and skips to the matching `}`, tracking brace depth and stepping over nested string and char literals. Without that, the inner quotes in `"len=${String.length "hello"}"` would close the outer literal. The parser then re-scans the token text and parses each embedded expression with a nested parser over that slice. The cost is location precision: an error inside an interpolation points at the string, not the exact column.

**Escapes are decoded at parse time, in the same scan.** `string_literal` and `char_literal` now hold their final bytes, unquoted — the quote-stripping that used to live in `hir_lower` and `codegen` is gone. `\$` is how you write a literal `${`. An unrecognised escape is an error rather than a silent passthrough, so adding sequences later cannot change what an existing program means.

**`String.from` is resolved from the static type, not a runtime tag.** Lowering reads the inferred type of the argument and emits `ko_int_to_string`, `ko_float_to_string`, `ko_bool_to_string`, `ko_char_to_string`, or nothing at all for a String. There is no dispatch and no boxing. The formats match `println_with_tag`, so `"${x}"` and `println x` agree on every type.

**Non-primitives are a compile error, not a debug rendering.** Records, ADTs and lists are rejected by `validateInterpolations` after inference, naming the type. A value whose type is still polymorphic at that point — a generic function's parameter — is *also* rejected, because the conversion is picked statically and there is nothing to pick; defaulting to Int would print a Float's raw bits. The fix is an annotation:

```ko
fn showf (m : Maybe Float) =      # without the annotation, ${v} is an error
  match m
    | Just v => "got ${v}"
    | Nothing => "none"
```

This deliberately does not reuse the formatter `println` has for records and lists. That is a debug format; making it reachable from ordinary string building would turn "how a record prints" into a compatibility commitment.

### Three bugs found underneath

- **Constructor patterns bound their fields to fresh, disconnected type variables.** `arg_types` was filled with new variables that were never linked to the scrutinee, so matching `Maybe Float` with `Just v` left `v` unbound and every use of it fell back to the integer representation — `"${v}"` printed a double's raw bits. Field types now come from the same instantiation the scrutinee type does. This also un-hid an ill-typed unit test: `Just x => x` / `Nothing => v` returns both `a` and `Maybe a`, and now correctly fails the occurs check.
- **`typeExprToType` treated a type application as a value application.** `Maybe Float` unified the head — already `con("Maybe", [?a])` — against an arrow, which can never succeed, so no parameterised type could be written in an annotation at all. Same shape as the `ctorParamType` gap found in Stage 0.
- **`ko_int_to_string` never passed the value to `snprintf`.** It supplied three arguments where `%ld` needs four, so it formatted whatever was in the register — in practice the buffer pointer. `Int.toString 42` returned the decimal digits of an address.

**Also fixed:** `char_literal` kept its surrounding quotes while every consumer read `val[0]`, so *every* char literal evaluated to `'`. `println 'x'` printed a quote.

---

## Stage 2 — Array — DONE except 2.5

**Goal:** DESIGN-data-structures §3.
**Depends on:** Stage 0 (`Maybe` for `pop`, working `panic` for bounds checks).

| # | Task | Status |
|---|------|--------|
| 2.1 | `KoArray` in the runtime, KoString header convention, elements inline | done |
| 2.2 | `make`, `new`, `get`, `set`, `length`, `isEmpty`, `push` (doubling), `pop` | done |
| 2.3 | Array literal syntax `[1, 2, 3]` | done |
| 2.4 | RC: recursive decref of elements | done |
| 2.5 | `Array.toList` / `List.toArray` | **not done** — see below |
| 2.6 | Higher-order: `map`, `filter`, `foldl`, `foldr`, `reverse` | done |
| 2.7 | `Array.sort`, `sortWith` | done |

### Representation

```
[-32] refcount
[-24] type_tag: 11 = scalar elements, 12 = heap elements
[-16] length
[ -8] capacity
[  0] elements, i64 each, contiguous
```

The value is a pointer to the elements with the header behind it, as KoString does, so `ko_decref` stays uniform. Two deviations from DESIGN-data-structures §3, both forced:

**The element kind lives in the type tag, not a field bitmap.** An array is homogeneous, so one bit says everything a 64-element bitmap would, and that frees the fourth header word for the capacity `push` needs. `ko_decref` branches on tag 12 to walk and release elements, the same way it already branches on tag 10 for closures.

**`Array.push` returns the array, where the doc says `Unit`.** With elements inline, growing an array moves it, so no handle into it can stay valid — a `Unit`-returning push would leave every existing binding dangling after the first reallocation. `set` does return `Unit`, since it never reallocates. Array literals desugar to a chain of `push` over `Array.new n`, which needs no new AST node and allocates exactly once.

`ko_decref_array` skips any element below one page: a nullary constructor is a bare tag rather than a pointer, so an `Array (Maybe a)` legitimately holds a mix, and reading a header 32 bytes below address 1 would fault.

**`Array.sort` is deliberately monomorphic — `Array Int -> Array Int`.** It orders the raw i64 payload, which *is* the value for an Int but is a bit pattern for a Float and an address for a String. With no typeclasses there is nothing to pick an ordering from, so anything else uses `Array.sortWith`. Sorting is insertion sort: O(n²), and a self-contained thing to replace.

### 2.5 needs a prerequisite the plan did not state

`Array.toList` and `List.toArray` need a `List` type, and **there is no builtin `List`** — every program and test that uses one declares its own `type List a = Cons a (List a) | Nil`. The `::` operator and `println`'s list formatting work against whatever `Cons`/`Nil` are in scope.

So 2.5 is not a matter of writing two conversions: it first requires deciding whether `List` joins `Maybe` and `Result` in the prelude. That is a language decision, not an implementation detail, and it interacts with every existing program that defines its own. Left for an explicit call rather than settled in passing.

### Bugs found

- **Curried application inside a runtime function loses the closure tag.** A function value crossing into a runtime call has bit 0 set to distinguish a closure from a bare function pointer, but the *result* of applying a curried function to one argument is a plain closure pointer with that bit clear. `foldl` called it as a raw function pointer and crashed. Runtime code doing a second application has to re-tag.
- **A Bool-returning Kō function returns `i1`.** Only the low bit of the return register is defined, so `filter` testing the whole word accepted every element. It now masks bit 0.

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

**Open question to settle first:** `{ ... }` is already record syntax. The doc proposes `{"name": "Alice"}` for maps and `{ name = "Alice" }` for records, distinguished by `:` vs `=`. That is decidable in the parser but subtle. Confirm the decision before 3.4 rather than during.

---

## Stage 4 — Set

**Goal:** DESIGN-data-structures §5. Small once Map lands.
**Depends on:** Stage 3.

`Set a` is `Map a ()`. Implement as a thin `std/Set.ko` wrapper: `empty`, `singleton`, `fromList`, `contains`, `add`, `remove`, `size`, `union`, `intersection`, `difference`, `isSubset`, `toList`.

---

## Stage 5 — IO

**Goal:** DESIGN-io-model §7.
**Depends on:** Stage 0 (`Result`, `panic`).

This stage is **larger than the doc's Phase 1 implies** — §1 has been corrected, but re-read it: there is no existing file I/O to wrap. It must be written.

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

**Goal:** close DESIGN-syntax gaps. Independent of the other stages; pick up opportunistically.

| # | Task | Issue |
|---|------|-------|
| 6.1 | Record spread `{ ..other, name = "Bob" }` — listed as *frozen* in §8.2, does not parse | — |
| 6.2 | Named arguments `~name:expr` — listed as *frozen* in §8.1, does not parse | #25 |
| 6.3 | Multi-line pipe `\|>` | #18 |
| 6.4 | Negative numbers as bare args: `f -3` | #17 |
| 6.5 | `!` is absent from `is_expr_start`, so `println !c` silently prints nothing while `println (!c)` prints correctly | — |
| 6.6 | Anonymous record literals `{ name = "Alice" }` without a type name | #19 |
| 6.7 | Pattern guards `pat when expr` — §7.3 defers these deliberately; only do it if demand appears | — |

6.4 and 6.5 are the same underlying gap: `is_expr_start` does not admit prefix operators, so an unparenthesised prefix expression cannot be an argument. Fixing the set once addresses both.

---

## Stage 7 — Deferred (v0.4+)

- `std.text`: codepoint length, `codepoints`, `codepointAt`, `fromCodepoints`; graphemes later (DESIGN-strings §4 Phase 3)
- `Deque`, `PriorityQueue`, `Rope` (DESIGN-data-structures §7) — library concerns, implement in `std.collections`
- Concurrency (DESIGN-io-model §6)

---

## 3. Sequencing Advice

Stage 0 is the only strictly-blocking stage and it is small — do it as one change set. After that, Stage 1 (strings) and Stage 2 (Array) are independent and can proceed in parallel.

Prefer Stage 1 first if the goal is demo-ability: string interpolation is the most visible missing feature, appears throughout every design doc's examples, and needs no runtime work beyond parser desugaring.

Prefer Stage 2 first if the goal is capability: Array unblocks Map, Set, and the whole §7 family.

Leave 5.7 (`println` returning `Unit`) until the end of Stage 5. It breaks every existing example and test in the repo, and there is no reason to absorb that churn while other stages are still landing.

---

## 4. Test Discipline

Each stage lands with runtime output tests, not just parse tests. Use `testRuntimeOutputLir` in `src/tests.zig`, and iterate with:

```bash
zig build test -Dtest-filter="<substring>"
```

The full suite relinks all of LLVM; filtering keeps the loop at ~125ms against ~3s. See `ko-zig/docs/HANDBOOK.md` for the stdout-capture rules — output tests have sharp edges around fd 1.
