# Kō Strings — Design

## Current State

Strings are `i8*` (null-terminated byte arrays) at the LLVM level. The typechecker has `string` as a primitive type. Operations are registered as qualified names (`String.length`, `String.append`, etc.) and generate LLVM IR that calls C library functions (`strlen`, `malloc`, `memcpy`, `strstr`, `toupper`, etc.).

**Known problems:**

- **No UTF-8 awareness.** Everything is raw bytes. `String.length` counts bytes, not code points. `String.charAt` returns a byte. `String.toUpperCase` uses C `toupper` (ASCII-only). Unicode strings will produce wrong results silently.
- ~~**`+` on strings is broken.**~~ **FIXED (middle-end branch).** `hir_lower` now detects string-typed operands to `+` and emits the `.concat` primop (→ `ko_string_append`) instead of `.add`. The legacy path still has the bug; the HIR→LIR→LLVM path is correct.
- **`String.split` is a half-implementation.** The LLVM IR body is empty; only the Zig fallback (JIT) works.
- ~~**Comptime vs runtime mismatch.**~~ Partially addressed — see Migration Path.
- **No efficient building.** Every `String.append` allocates + copies. Repeated appends in a loop are O(n²). Kō has no `StringBuilder` or difference-list pattern.
- **Null-terminated everywhere.** Every operation recomputes `strlen` or null-terminates. For strings with known lengths (which all Ko strings have at creation time), this is wasted work.
- ~~**Parser keeps raw quotes in string literals.**~~ **FIXED (middle-end branch).** `hir_lower` strips surrounding quotes when lowering `string_literal` to HIR, so all downstream paths (HIR folds, LIR lowering, codegen) see clean string bytes. The legacy path strips quotes per-consumer in `codegen.zig`.

## Design Goals

1. **One canonical string type.** Kō is not Haskell. No `[Char]`, no `Text`, no `ByteString`. One type: `String`.

2. **UTF-8 by default.** Strings are Unicode scalar value sequences encoded in UTF-8. Operations that count, index, or transform characters operate on code points, not bytes.

3. **Length-prefixed, not null-terminated.** A string header stores `(ptr, len)` at the LLVM level. This eliminates `strlen` calls. Null-termination is a compatibility layer for C interop, not the canonical representation.

4. **Building must be efficient.** Repeated concatenation must not be O(n²). Either a rope-like builder or a growable buffer with amortized O(1) append.

5. **Comptime/runtime parity.** Every string operation available at runtime must also be available at comptime, and vice versa.

6. **Pattern-matchable.** Strings should participate in `match`, at least for prefix patterns.

## Representation

### Internal (LLVM)

```
struct KoString {
  i64  len;     // byte length (for UTF-8, may differ from code point count)
  i64  cap;     // allocated capacity (may be > len for mutability in builder phase)
  i8   data[];  // UTF-8 bytes (not null-terminated internal, but data[0..len] is valid)
}
```

- `KoString*` is the canonical representation.
- `len` is byte length, not code point count. Code point count is O(n) to compute.
- `cap` enables in-place growth during construction. Strings are immutable once constructed; `cap` is metadata for the allocator.
- Data may be heap-allocated or point into a string literal segment of the binary. The runtime distinguishes via a tag bit in the pointer (see below).

### ABI for C interop

- A helper `KoString_toC(ks)` allocates a null-terminated copy (`malloc(len+1)`). Used only at FFI boundaries.
- A helper `KoString_fromC(cs)` copies a C string into the Ko representation.
- Internal operations never null-terminate.

### String literals at compile time

String literals compile to static `KoString` globals in the binary's read-only data section:

```
@.str.N = internal constant { i64, i64, [N x i8] } { i64 N, i64 N, c"N bytes..." }
```

The runtime detects read-only strings via pointer range checks (start of data section to end) and skips `free` on them.

## API

### Core operations (built-in, LLVM IR)

```ko
String.length   : String -> Int           # byte length (O(1))
String.isEmpty  : String -> Bool           # len == 0 (O(1))

String.append   : String -> String -> String   # concatenation
String.build    : List String -> String         # efficient concatenation

String.get      : String -> Int -> Char    # code point at position (O(n) scan)
String.slice    : String -> Int -> Int -> String  # substring by byte offset

String.startsWith : String -> String -> Bool
String.endsWith   : String -> String -> Bool
String.contains   : String -> String -> Bool

String.toUpperCase : String -> String
String.toLowerCase : String -> String
String.trim       : String -> String

String.split    : String -> String -> List String
String.replace   : String -> String -> String -> String

String.fromList : List Char -> String
String.toList   : String -> List Char
String.fromInt  : Int -> String
String.toInt    : String -> Result Int String
String.fromFloat : Float -> String
String.toFloat   : String -> Result Float String

(+) : String -> String -> String    # same as append, operator form
```

### Builder (efficient construction)

Repeated `String.append` in a loop is O(n²). The builder pattern solves this:

```ko
# Builder is a mutable growable buffer (hidden behind a pure API)
String.builder : () -> Builder              # create empty builder
Builder.append  : Builder -> String -> Builder  # add string
Builder.result  : Builder -> String          # finalize (consume builder, return owned String)
```

The Builder uses a geometric growth strategy (2× capacity). Internally it's represented as `KoString` with spare capacity. `Builder.append` memcpy's into the buffer, growing only when needed (amortized O(1) per append).

### `+` operator

`String + String` is sugar for `String.append`. The typechecker already handles this. The codegen fix is straightforward: detect string operands in `codegenBinaryOp` and emit `ko_string_append` instead of integer add.

## Pattern Matching

String pattern matching in match arms uses literal strings:

```ko
match s
  | "hello" => 1
  | "world" => 2
  | _ => 0
```

At the LIR level, this lowers to a comparison tree (like any `match` on integers). The compiler generates:

```c
if (memcmp(s.data, "hello", 5) == 0) return 1;
else if (memcmp(s.data, "world", 5) == 0) return 2;
else return 0;
```

Short string optimization: strings up to 15 bytes can be compared inline (loaded as a single i128 and compared with a constant), avoiding the function call overhead of `memcmp`.

### Extended pattern: prefix matching

```ko
match s
  | "error: " ++ rest => handleError rest
  | "warning: " ++ rest => handleWarning rest
  | _ => ok
```

This desugars to `String.startsWith` checks + `String.slice` for the remainder. The compiler can optimize the case where multiple arms share a common prefix by generating a decision tree (like Maranget's algorithm on string prefixes).

## Unicode Strategy

**Phase 1 (v0.3):** Keep current byte-level operations but add UTF-8 validity invariant. The runtime guarantees that every `KoString` contains valid UTF-8. Construction from untrusted sources validates on entry.

**Phase 2 (v0.4):** Unicode-aware operations:

| Operation | Meaning |
|-----------|---------|
| `String.length` | Byte length (O(1)) |
| `String.codePointCount` | Code points (O(n), cached on demand) |
| `String.get i` | Code point at position i (O(n) scan, but fast for ASCII) |
| `String.slice start end` | Byte-offset substring (O(1) copy) |
| `String.toUpperCase` | Full Unicode case folding (via ICU4C or generated tables) |

The principle: byte-level operations are fast and sufficient for most code. Code-point-level operations are available but opt-in (explicit `String.codePointCount` vs `String.length`). This mirrors Rust's `str` vs `[u8]` distinction without requiring a separate type.

**Normalization:** No automatic normalization. Provide `String.nfc`, `String.nfd`, `String.nfkc`, `String.nfkd` as explicit operations. Users choose. The default is "whatever bytes the source provides, assumed valid UTF-8."

## Integration with LIR / Perceus

Strings are RC-managed heap objects like any other. The `KoString` header includes the RC field, making it compatible with the Perceus pipeline:

- `String.append` produces a new `KoString` with RC=1. If the source strings have RC=1 and no other references (reuse analysis), the old buffer can be reused in place instead of allocating + copying.
- `String.slice` can avoid copying entirely by returning a view into the source string (see "Slicing strategy" below). This is safe because RC keeps the source alive.
- `String.build` with a builder: the builder owns the buffer. On `Builder.result`, ownership transfers to the returned `KoString` with zero copy.

### Slicing strategy

Two approaches:

**A) Copy-on-write (CoW):** `String.slice` increments source RC and returns a pointer to the same data. The `KoString` stores `(ptr, len, source_string)` where `source_string` is the original allocation. On mutation (append, toUpperCase, etc.), the new string allocates fresh.

- Pros: Cheap slice (O(1), no alloc).
- Cons: Retains entire source string alive even for tiny slices (memory fragmentation). Adds pointer indirection.

**B) Eager copy:** `String.slice` always allocates and copies the requested range.

- Pros: No memory retention. Simple. No indirection.
- Cons: Every slice is O(n) in the slice length (not the source length, but still an alloc+copy).

**Recommendation:** Start with eager copy (v0.3). It's simpler, correct, and good enough for typical use. Add CoW slicing as an optimization in v0.5 if profiling shows it matters. The LIR representation doesn't change either way — only the implementation of the `slice` intrinsic changes.

## Migration Path

### v0.3 (current branch)

1. ~~Fix the `+` on strings codegen bug~~ **DONE** (HIR lowering emits `.concat`; legacy path still broken).
2. Complete `String.split` LLVM IR implementation.
3. Add `String.substring`, `String.startsWith`, `String.endsWith` runtime codegen to match comptime.
4. All operations remain null-terminated `i8*` internally.
5. Keep the existing `KoString`-as-`i8*` ABI.

**Note on representation ownership:** the HIR→LIR→LLVM path (middle-end branch) is now the reference for correct string behavior: quote stripping happens once in `hir_lower`, and `+`→`concat` dispatch is type-directed in `hir_lower`. String operations route through runtime functions (`ko_string_*`), so the v0.4 representation change (length-prefixed `KoString`) only touches the runtime implementations and the string-literal codegen in `codegen_lir` — not the LIR structure or lowering logic.

### v0.4

1. Change internal representation to length-prefixed `(i8*, len)`.
2. Add `String.build` and builder pattern.
3. Add `String.codePointCount`, `String.get` (code point).
4. Add UTF-8 validity invariant on construction.
5. Add `String.nfc`, `String.nfd` for normalization.
6. String pattern matching in `match` arms.

### v0.5+

1. CoW slicing (if needed).
2. Perceus reuse analysis integration (string append reuses buffer when unique).
3. Full Unicode case folding.
4. `String` backed by a small-string optimization (SSO) — inline short strings in the pointer itself, avoiding heap alloc.
