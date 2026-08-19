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
| Data structures | Array (Stage 2) and Map (Stage 3) both landed. No Set yet, but Stage 3 unblocks it. List/tuple/record work; `List` is still user-declared, not builtin. |

Working today: generics (`fn apply f x = f x`), recursive ADTs, user-defined `type Result e a = Ok a | Err e`, records with annotations, pattern matching, `ref`/`:=`/`!`, `|>` on one line, `::`, `comptime`.

---

## 2. Why This Order

Four things block disproportionately much, so they come first:

- ~~**`Ok`/`Err`/`Just`/`Nothing` are undefined.**~~ Declared in the prelude in Stage 0, so `Array.pop : Maybe a`, `Map.get : Maybe v`, `String.toInt : Maybe Int` and the `Result`-returning I/O signatures are now spellable.
- ~~**Tuple access `.0` does not parse.**~~ Landed in Stage 0. `Map.toList : List (k, v)` and `Map.fromList` are now spellable.
- ~~**`panic` emits a terminator mid-block.**~~ It did not — see Stage 0. `panic` was already usable for the bounds checks the Array and Map designs specify.
- ~~**`hash` gates Map, and Map gates Set.**~~ Landed in Stage 3, so Set (specified as `Map a ()`) is unblocked.

All four are now cleared — the first three in Stage 0, `hash` in Stage 3.

### Dependency graph

```
Stage 0 (prelude types, tuple access)  — DONE
   ├── Stage 1  Strings Phase 2      — DONE
   ├── Stage 2  Array — DONE (2.5 deferred) ─┐
   │                                     ├── Stage 4  Set — DONE
   ├── Stage 3  hash + Map — code complete ──┘
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

## Stage 3 — `hash` + Map — DONE

**Goal:** DESIGN-data-structures §4.
**Depends on:** Stage 0 (`Maybe`), Stage 2 (buckets), tuple access from 0.3.

| # | Task | Status |
|---|------|--------|
| 3.1 | `ko_hash(val, type_tag)` | done for Int, Float, Bool, Char, String, Unit. **Tuple and constructor keys are rejected at compile time** rather than hashed — see below |
| 3.2 | `KoMap`, resize at load factor 0.75 | done — open addressing, not the doc's separate chaining |
| 3.3 | `ko_map_new/get/set/delete`, `length`, `containsKey`, `isEmpty` | done |
| 3.4 | Map literal `{"k": v}` | done |
| 3.5 | `keys`, `values`, `entries`, `fromArray`, `foldl` | done (`forEach` not done — `foldl` covers it) |
| 3.6 | `union`, `intersection`, `difference` | done |

**Regression tests done.** The `Stage 3: Map` block at the end of `src/tests.zig` covers literals and `{}`, get/set/delete with Int keys and String values, String-key hashing, `keys`/`values`/`entries` and a `fromArray` round-trip, `foldl`, the three set operations, and growth across several resizes (40 entries). A `nested map and array printing` test locks in the container-printing fix, and `tests_ko/map_ops.ko` is registered with the parser test. Suite is 293/293.

### Representation

```
[-32] refcount
[-24] type_tag = 13
[-16] length (live entries)
[ -8] capacity (bucket count, power of two)
[  0] key_tag — selects the hash and equality
[  8] flags: bits 0-1 = keys/values are heap; bits 2+ = value tag for printing
[ 16] buckets: capacity × { state, key, value }, 24 bytes each
```

State is 0 empty, 1 occupied, 2 tombstone; deletes tombstone so probe chains stay intact.

**Open addressing with linear probing, not the doc's separate chaining.** Buckets live in one allocation, so there are no per-entry nodes to allocate, walk or free, and the whole map is a single `ko_alloc`. Scalar hashes go through a splitmix64 finalizer — identity-hashed integer keys cluster badly under linear probing.

**The key tag and heap flags live in the map, not at the call site.** `ko_decref` sees only a pointer; at teardown there is no call site left to read a static type from. The value tag is packed into the flags word (bits 2+) for the same reason — `inspect` has no static type to print a map value with, so it reads the tag back from the header, which lets nested maps and arrays print correctly at any depth.

**`Map.set` returns the map, where the doc says `Unit`** — same reason as `Array.push`: a resize moves the table. `delete` returns `Unit`, since it only tombstones.

**`keys`/`values`/`entries` return `Array`, not the doc's `List`**, because there is no builtin `List` — the same gap that blocks Stage 2.5.

### Unhashable keys are a compile error

`ko_hash` handles the scalars and hashes String by content. Anything else would fall back to the payload bits, which for a tuple or constructor is its *address* — two structurally equal keys would land in different buckets and lookups would quietly miss. `validateMapKeys` rejects those after inference instead:

```
(Int, Int) cannot be a Map key
  note: keys are hashed and compared structurally, and only Int, Float,
        Bool, Char, String and Unit are
  help: key by one of those instead — for a compound key, derive a String
```

The accepted set there must stay in step with what `ko_hash` and `ko_key_eq` implement.

### The brace decision

`{"k": v}` took the brace syntax. It was free: record literals require a type-name prefix (`P { x = 1 }`), and a bare `{` did not parse at all. `braceIsRecordBody` now separates the two with one identifier plus one `=` of lookahead, which is also what lets anonymous records (6.6) land later without conflict.

### Two bugs found underneath

- **`()` inferred as `tuple []`, not `unit`.** The two never unified, producing the memorable error `expected (), got ()`. Any signature taking `Unit` was unusable.
- **Generalization had no value restriction.** `let m = Map.new ()` was generalized, so every use instantiated a fresh copy of the key and value variables while the binding's own copy stayed unbound — the map was built keying on tag 100 and every lookup missed. Let-bindings now generalize only syntactic values, which is ML's value restriction and exists for exactly this failure. It broke nothing in the suite.

---

## Stage 4 — Set ✅ DONE

**Goal:** DESIGN-data-structures §5. Small once Map lands.
**Depends on:** Stage 3.

`Set a` is `Map a ()`. Implemented as a thin `std/Set.ko` wrapper: `empty`, `singleton`, `fromArray`, `contains`, `add`, `remove`, `size`, `isEmpty`, `union`, `intersection`, `difference`, `isSubset`, `isSuperset`, `toArray`.

### Divergences from DESIGN-data-structures §5

- **`fromList`/`toList` → `fromArray`/`toArray`.** There is no builtin List (only `std/List.ko`, which is unimportable from a stdlib module — transitive imports are not supported), and `Map.keys` returns an Array, so conversions mirror the Map module.
- **`add : a -> Set a -> Set a`** (doc says `Unit`), matching `Map.set` returning the map — a resize moves the table, so the caller must receive the new set.
- **`remove : a -> Set a -> Unit`** matches `Map.delete` (mutates in place, returns Unit). Like `Map.delete`, the linearity checker warns if the set is used afterwards; the runtime mutation still takes effect.
- Added `isSuperset` (derived from `isSubset`).

### Supporting fixes landed with this stage

- **LIR module-qualified calls:** `lir_lower.lowerApplyChain` only treated a type namespace (`.constructor` object, e.g. `Map.union`) as a qualified global; a module name lowers to a `.global` object (e.g. `lib.unwrap`), which fell through to a closure call → `undefined global 'lib'`. Now both `.constructor` and `.global` objects resolve `ns.field` against the global table (`lir_lower.zig:887-899`).
- **`Unit` type name:** `typeExprToType`/`ctorParamType` mapped `Int`/`Float`/`Bool`/`String`/`Char` but not `Unit` → `Map a Unit` in a type definition produced a fresh type variable. Added the `Unit` → unit mapping in both functions (`typecheck.zig:898, 2065`).
- **Test harness module loading:** `testRuntimeLir`/`testRuntimeOutputLir` now attach a `ModuleLoader` with `stdlib_override` = the repo `std/` dir (passed via a build option from `build.zig`), so inline tests can `import std.*`.

### Tests

- 5 runtime tests (fromArray dedup/membership, add, union/intersection/difference, subset/superset, in-place remove) + `src/tests_ko/set_ops.ko` parser/execution test.

---

## Stage 5 — IO

**Goal:** DESIGN-io-model §7.
**Depends on:** Stage 0 (`Result`, `panic`).
**Status:** ✅ **DONE** (committed as part of the Stage 5 change set; tests in `53_io_file.ko`, `54_io_dir.ko`, `55_io_env.ko`).

This stage is **larger than the doc's Phase 1 implies** — §1 has been corrected, but re-read it: there is no existing file I/O to wrap. It must be written.

| # | Task | Status |
|---|------|--------|
| 5.1 | Decide naming: `IO.readFile` (dot notation, matches stdlib) vs `read_file`. Nothing is implemented, so this is a free choice | ✅ `IO.*` dot notation |
| 5.2 | `Error` type in the prelude | ✅ `FileNotFound=0 \| PermissionDenied=1 \| InvalidPath=2 \| IOError String=3 \| EncodingError String=4` |
| 5.3 | Implement the file I/O builtins: read, write, append, exists, size, mkdir, rm, cp, mv, readdir | ✅ native Zig host fns in `stdlib.zig`, JIT-mapped in `main.zig`/`tests.zig`, externs declared in `codegen_lir.zig` `declareRuntime`. POSIX-only (Windows documented as unsupported) |
| 5.4 | `std/io.ko` wrapping them to return `Result Error` | ✅ `io.readOrEmpty`, `io.writeOrDie`, `io.eprintErr`, `io.exists` |
| 5.5 | `IO.readLine`, `IO.eprintln`, `IO.eprint` | ✅ `readLine : String -> String` reads stdin with the arg as prompt; `eprintln`/`eprint` go to fd 2 via `fdio.zig` |
| 5.6 | `IO.getEnv : String -> Maybe String` | ✅ |
| 5.7 | Change `println`/`print` to return `Unit` — **breaking**; do it last in the stage and update every example and test | ✅ `println/print : forall a. a -> Unit`; `inspect : forall a. a -> a` unchanged; 4 tests asserting the old return semantics updated |
| 5.8 | `IO.run` (shell) — deferred to v0.4; the doc flags it as dangerous and it needs an escaping story | ⏸ deferred |

Notes:
- The IO builtins are JIT-only. AOT (`--emit-exe`) cannot see them; the doc's "runtime independence" milestone is where they become shared runtime exports. See the §4/§5 note in `DESIGN-io-model.md`.
- Two latent LIR lowering bugs were fixed along the way: string `==`/`!=` is now keyed off the HIR type (a String pulled out of a `Result` box is an i64 local, not a `.string` local) and both operands are coerced before calling `ko_string_eq`; bool `==`/`!=` coerces both sides to i64 (values like `x < y` are i1 while `True`/`False` are i64 small ints).
- Module match arms use `=>` (Set.ko style), not `->`; a `let x =\n  match ...` value must be pulled out into a top-level `fn`.

---

## Stage 6 — Syntax leftovers

**Goal:** close DESIGN-syntax gaps. Independent of the other stages; pick up opportunistically.

| # | Task | Issue |
|---|------|-------|
| 6.1 | Record spread `{ ..other, name = "Bob" }` — listed as *frozen* in §8.2, does not parse | — |
| 6.2 | Named arguments `~name:expr` — listed as *frozen* in §8.1, does not parse | #25 |
| 6.3 | Multi-line pipe `\|>` | #18 |
| 6.4 | Negative numbers as bare args: `f -3` | ✅ `-` (and `!`, `not`, `ref`) are now admitted as argument starts; a minus glued to its operand (`f -3`) applies f to -3, a spaced minus (`f - 3`) stays binary subtraction |
| 6.5 | `!` is absent from `is_expr_start`, so `println !c` silently prints nothing while `println (!c)` prints correctly | ✅ `println !c` derefs and prints; `syntax_neg_arg.ko` + 3 output tests added |
| 6.6 | Anonymous record literals `{ name = "Alice" }` without a type name | #19 |
| 6.7 | Pattern guards `pat when expr` — §7.3 defers these deliberately; only do it if demand appears | — |

6.4 and 6.5 are the same underlying gap: `is_expr_start` does not admit prefix operators, so an unparenthesised prefix expression cannot be an argument. Fixed by admitting `.minus`/`.not` and parsing args with `parse_unary_no_apply` (prefix binds to a postfix expression without application). A whitespace-adjacency gate on `.minus` keeps `f - 3` as subtraction. Also fixed en route: the constant folder dropped unary negation (a one-arg `sub` folded to the positive value), so `-3` silently became `3`.

---

## Stage 7 — Deferred (v0.4+)

- `std.text`: codepoint length, `codepoints`, `codepointAt`, `fromCodepoints`; graphemes later (DESIGN-strings §4 Phase 3)
- `Deque`, `PriorityQueue`, `Rope` (DESIGN-data-structures §7) — library concerns, implement in `std.collections`
- Concurrency (DESIGN-io-model §6)

---

## Stage 8 — IO & module polish

**Goal:** close the rough edges found while writing a first real IO program and poking the module system by hand. Mostly small, independent fixes.

| # | Task | Notes |
|---|------|-------|
| 8.1 | Stdlib builtins usable as first-class values | `let name = IO.readLine` (no application) → `lir_lower: stdlib fn 'IO.readLine' used as value not yet supported`, falls back to legacy codegen, which dies with `UndefinedVariable` because `IO.*` are JIT-only. Either lower applied-builtin references (the common case), error clearly for the value case, or map `IO.*` into the legacy path too. |
| 8.2 | Quoted imports don't resolve | `import "sub/lib"` reports `Module not found` — the token slice keeps the quote characters, so the loader looks for a file literally named `"sub/lib".ko`. Fix: strip quotes in `parse_import` (parser.zig:444) or dequote in the lexer. |
| 8.3 | Missing module is not a compile error | `loadModule` returning `null` only logs `Module not found` and the typechecker `continue`s (typecheck.zig:1037-1047) — you find out later as a baffling `undefined name 'io'` with a `did you mean 'Ok'?` hint. Make a failed import a hard, located diagnostic at the `import` statement. |
| 8.4 | `pub` is not enforced on imports | Every `fn_def`/type/constructor from an imported module is registered regardless of `pub` (typecheck.zig:1093-1149). Verified: a `fn secret` imports fine. Either enforce the flag (breaking) or document it as access-control-by-convention and maybe lint. |
| 8.5 | `IO.writeFile` rejects empty content | `io.writeOrDie ""` panics ("write failed") because a zero-byte write is treated as an error. Decide: an empty string is a legitimate file write (`ftruncate`-style truncate), or document the panic. Affects `readOrEmpty → writeOrDie` round-trips. |
| 8.6 | `let _ = expr` does not parse | Only `let name = ...` works; a bare `_` discard is a parse error (`expected identifier, got '_'`). Sequence-only side effects must use `_name`. Small parser gap: allow `_` (and treat `_*` as linearity-ignore, which `_name` already is). |
| 8.7 | No `Array` stdlib module | `IO.readdir` returns `Array String` but there is no `std/Array.ko`; `Array.to_string`/`Array.*` are undefined and arrays print only via `println`. Decide whether `Array` should gain a stdlib module, aliases to `List`, or documented builtins (e.g. `Array.toString`). |
| 8.8 | `io.` module surface too small / confusing | `std/io.ko` exports only `readOrEmpty`, `writeOrDie`, `eprintErr`, `exists` — no `readLine`, `println`, `eprintln` — so `io.readLine`, `io.eprintln` are undefined while `IO.*` builtins exist globally. Two options: add thin wrappers (`io.readLine`, `io.println`) to `std/io.ko`, or lean on docs (already written in `docs/modules.md`) and leave the split as-is. |
| 8.9 | Linearity warnings misattributed | "linear variable never used" is reported at a comment line or the line before the real unused binding, making the actual culprit hard to find. Diagnostic span quality fix in linearity.zig. |

Notes:
- Root cause of 8.1 is shared with Stage 0/1 work: the LIR pipeline lowers stdlib calls only when fully applied; partial application / value use of a stdlib fn is an unhandled `lir_lower` case.
- 8.2/8.3/8.4 all live in the module machinery and were discovered together while writing `docs/modules.md`; fixing 8.3 will surface missing-module errors earlier, which is the highest-value one for beginners.
- 8.5/8.6/8.7/8.8 were found by running the exploratory IO program (`sample.ko`) — the first "real" program written against the JIT builtins.

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
