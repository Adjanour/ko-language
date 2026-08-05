# KoString Implementation Plan

> **Date:** 2026-08-05
> **Status:** Decided — ready for implementation
> **Prerequisite:** Phase 1-3 Rc complete (248/248 tests pass)

---

## Implementation Order

1. **String RC (KoString)** — Fix memory leaks, prerequisite for data structures
2. **Array/Map/Set types** — Expand beyond List
3. **Runtime independence** — Replace libc with direct syscalls

---

## Design Decisions

### D1: String RC First
String RC is prerequisite for Array/Map/Set (these will store strings) and runtime independence (depends on our own string handling). Smallest scope of the three.

### D2: Immortal Strings (Option C)
Literals are `KoString*` with RC=0 (immortal). No allocation for literals, `ko_string_decref` skips if RC=0, builtins don't need type checks.

```c
typedef struct {
  i64 refcount;      // 0 = immortal (literal)
  i64 byte_length;
  char data[];       // flexible array, null-terminated
} KoString;
```

### D3: Flexible Array Member (Option A)
Use flexible array member for KoString. Exact-size allocation: `malloc(sizeof(KoString) + len + 1)`. No wasted memory. No SSO (premature optimization for a compiler).

### D4: Always Allocate New on Concat (Option A)
`String.append` always allocates new KoString. No special cases needed because literals are immortal KoString — the function works uniformly. No RC=1 in-place mutation optimization for v1.

### D5: Type Tag Dispatch for println
`println` uses type tag dispatch (tag=4 for string). After big bang, all strings are KoString. The tag is already passed.

### D6: Keep String.length as Function
`String.length s` reads `s->byte_length` — O(1). No field accessor syntax. Backward compatible, can be JIT-inlined.

### D7: Return List String from split
`String.split` returns `List String`. Consistent with functional style, works with existing types. Add Array later.

### D8: Defer String.toList/String.fromList to v2
Need to finalize Char type semantics first (byte? codepoint? grapheme?).

### D9: Defer StringBuilder to v2
Mutable builder breaks functional purity. `String.append` sufficient for v1.

### D10: Panic on Invalid Substring Bounds
Consistent with other runtime panics (division by zero, stack overflow). Can add Result version later.

### D11: String.isEmpty as Library Function
```ko
fn isEmpty s = String.length s == 0
```
O(1) with KoString, keeps builtin surface minimal.

---

## Implementation Scope

### New Runtime Functions
```c
KoString* ko_string_alloc(i64 len);
KoString* ko_string_from_cstr(const char* cstr);
void ko_string_incref(KoString* s);
void ko_string_decref(KoString* s);
```

### Modified Builtins
| Builtin | Current | New |
|---------|---------|-----|
| `String.append` | `malloc` + memcpy, returns `i8*` | `ko_string_alloc`, returns `KoString*` |
| `String.length` | `strlen` on `i8*` | Reads `s->byte_length` — O(1) |
| `String.replace` | `malloc` + loop, returns `i8*` | `ko_string_alloc`, returns `KoString*` |
| `String.split` | Returns `List` of `i8*` | Returns `List` of `KoString*` |
| `String.startsWith` | Returns `Bool` | Same, but works with `KoString*` |
| `String.endsWith` | Returns `Bool` | Same, but works with `KoString*` |
| `String.substring` | `malloc` + memcpy | `ko_string_alloc`, returns `KoString*` |
| `String.indexOf` | Scans `i8*` | Scans `KoString*` data |
| `String.eq` | Compares `i8*` | Compares `KoString*` data |
| `println` | `printf` with `i8*` | `printf` with `KoString*` data |
| `inspect` | `printf` with `i8*` | `printf` with `KoString*` data |

### Codegen Changes
- String literals: wrap in `KoString*` (immortal, RC=0)
- All string builtins: return `KoString*` instead of `i8*`
- `ko_decref`: handle string type (tag=4) by calling `ko_string_decref`

### Test Updates
- All existing string tests must pass
- Add memory leak test (verify no leaks after string operations)
- Add edge case tests (empty strings, very long strings)

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Breaking all string operations | 248 tests to catch regressions |
| Performance regression from allocation | KoString is same size as before + 16 bytes header |
| Literal wrapping overhead | One-time allocation at startup, amortized |
| Forgetting to decref somewhere | Linear type checker helps, plus tests |

---

## Future Optimizations (v2+)

1. **RC=1 in-place mutation** for `String.append`
2. **StringBuilder** for efficient string building
3. **String.toList / String.fromList** once Char type finalized
4. **SSO (Small String Optimization)** if profiling shows it matters
5. **String interning** for common strings (identifiers, keywords)
