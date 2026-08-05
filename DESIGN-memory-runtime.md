# Kō Memory & Runtime Model

> **Status:** Design Draft
> **Date:** 2026-08-01
> **Research:** Koka Perceus RC, Zig allocator patterns, Boehm GC, Swift ARC

---

## 1. Current State

### Value Representation

Every Kō value is an `i64` in LLVM IR. Type discrimination is done at the codegen level via `expr_type_tags` (per-expression type annotations from the typechecker) and runtime heuristics (values < 4096 are raw tags, > 4096 are pointers).

| Ko Type | LLVM Type | i64 Representation |
|---------|-----------|-------------------|
| Int | `i64` | Raw i64 value |
| Float | `double` | Bitcast double to i64 |
| Bool | `i1` | 0 = false, 1 = true |
| String | `i8*` | Pointer to null-terminated C string |
| Char | `i8` (stored as i64) | Byte value (ASCII) |
| Unit | `void` | 0 |
| Constructor (zero-arg) | `i64` | Raw tag number |
| Constructor (multi-arg) | `i64` | Pointer to heap struct, bitcast to i64 |
| Tuple | `i64` | Pointer to heap-allocated array of i64 |
| Record | `i64` | Pointer to heap-allocated struct |
| Function (no captures) | `i64` | Raw function pointer, bitcast to i64 |
| Function (with captures) | `i64` | Pointer to closure struct with bit 0 set |
| Reference | `i64` | Pointer to heap cell |

### Reference Counting

Heap-allocated values use reference counting via `ko_alloc`, `ko_incref`, `ko_decref`.

Memory layout:
```
[ i64 rc ][ ... user data ... ]
^         ^
|         pointer returned by ko_alloc (what codegen sees)
raw malloc ptr
```

- `ko_alloc(user_size)`: `malloc(user_size + 8)`, store RC=1 at offset 0, return ptr+8
- `ko_incref(ptr)`: Read RC from ptr-8, increment, store back
- `ko_decref(ptr)`: Read RC from ptr-8, decrement, if <= 0 then `free(ptr-8)`

Ownership tracking in codegen:
- `scope_heap_values`: Tracks all heap-allocated i64 values per function
- `consumed_heap_values`: Values stored in parent structures (skipped at decref time)
- `emitDecrefAll()`: At function exit, decrefs all unconsumed heap values

### Constructor Representation

Zero-argument constructors (e.g., `Nil`, `True`): The value IS the tag number directly.

Multi-argument constructors (e.g., `Cons`, `Ok`): The value is a pointer to a heap struct:
```
[ i64 tag | i64 arg_0 | i64 arg_1 | ... ]
```

Pattern matching uses a heuristic: values < 4096 are raw tags; values > 4096 are dereferenced and their `ptr[0]` is read as the tag.

### Closure Representation

Function values use a bit 0 tag:
- Bit 0 = 0: Raw function pointer (no captures)
- Bit 0 = 1: Closure pointer (has captures)

Closure struct layout:
```
offset 0: fn_ptr (pointer to wrapper function)
offset 8+: captured_value_0, captured_value_1, ...
```

Partial application uses a different layout:
```
offset 0: fn_ptr
offset 8: total_arity
offset 16: applied_count
offset 24+: applied_args[0], applied_args[1], ...
```

---

## 2. Known Bugs

### Bug 1: Strings Are Not Reference Counted

Heap-allocated strings (from `String.append`, `String.to_upper`, etc.) use raw `malloc` and are never freed. Every string operation leaks memory.

**Root cause:** `stdlib_codegen.zig` calls `malloc` directly for string operations instead of `ko_alloc`.

**Impact:** Any program that does string manipulation leaks memory proportional to the number of string operations. Long-running programs (REPL, servers) will grow unbounded.

### Bug 2: Recursive Decref Is Missing

`ko_decref` only frees the RC header. It does NOT recursively decrement child values stored in constructors, tuples, or records.

**Root cause:** The runtime doesn't track the types of values inside containers. A constructor's fields are just `i64` values — the runtime doesn't know which ones are pointers.

**Impact:** A `List String` (list of heap-allocated strings) will leak every string inside it when the list is freed. Only the outermost cons cells are freed.

### Bug 3: No Cycle Detection

Reference counting cannot collect cyclic data structures. If a node points to itself or forms a cycle, the RC never reaches 0 and the memory leaks.

**Impact:** Programs that create cyclic data (e.g., doubly-linked lists, graph structures) will leak.

---

## 3. Proposed Fixes

### Fix 1: KoString Wrapper

Wrap heap-allocated strings in a counted header:

```c
typedef struct {
  i64 refcount;
  i64 byte_length;
  char data[];       // flexible array, null-terminated
} KoString;
```

**New runtime functions:**

```c
KoString* ko_string_alloc(i64 len) {
  KoString* s = malloc(sizeof(KoString) + len + 1);
  s->refcount = 1;
  s->byte_length = len;
  s->data[len] = '\0';
  return s;
}

KoString* ko_string_from_cstr(const char* cstr) {
  i64 len = strlen(cstr);
  KoString* s = ko_string_alloc(len);
  memcpy(s->data, cstr, len);
  return s;
}

void ko_string_incref(KoString* s) {
  if (s) s->refcount++;
}

void ko_string_decref(KoString* s) {
  if (s && --s->refcount <= 0) {
    free(s);  // data[] is part of the struct
  }
}
```

**Changes to string builtins:**

| Builtin | Current behavior | New behavior |
|---------|-----------------|--------------|
| `String.append a b` | `malloc` + memcpy, returns `i8*` | `ko_string_alloc`, copy into `data[]`, returns `KoString*` |
| `String.to_upper s` | `malloc` + loop, returns `i8*` | `ko_string_alloc`, fill `data[]`, returns `KoString*` |
| `String.split s delim` | Returns `List` of `i8*` | Returns `List` of `KoString*` |
| `len s` | Counts bytes until `\0` on `i8*` | Reads `s->byte_length` — O(1) |
| `charAt s i` | Index into `i8*` | Index into `s->data` |

**Literal strings:** Stay as `i8*` (global constants, never freed). When passed to string builtins, they are wrapped into `KoString` by the builtin implementation.

**Codegen impact:** The codegen currently returns raw `i8*` for strings. Change to return `KoString*` (still an `i64` in the tagged representation, but pointing to a `KoString` instead of raw bytes).

### Fix 2: Type-Aware Decref

The core problem: the runtime doesn't know the types of values inside containers. Three approaches:

**Approach A: Store type tags alongside values**

Every heap-allocated container stores a parallel array of type tags:

```c
typedef struct {
  i64 refcount;
  i64 arity;
  i64* fields;      // array of i64 values
  i32* field_tags;  // parallel array of type tags
} Constructor;
```

```c
typedef struct {
  i64 refcount;
  i64 length;
  i64 capacity;
  i64* elements;
  i32* elem_tags;   // parallel array of type tags
} KoArray;
```

Pros: Decref is trivial — iterate the tag array and call `ko_decref_value` for each.
Cons: Doubles memory per container. Adds allocation overhead.

**Approach B: Emit decref metadata in codegen**

The typechecker knows the types. At codegen time, emit a decref table per function:

```c
struct DecrefEntry {
  i64* slot;       // pointer to the i64 value in the stack frame
  i32 type_tag;    // what type it is
};

void decref_main_fn(struct DecrefEntry* entries, i64 count) {
  for (i64 i = 0; i < count; i++) {
    ko_decref_value(*entries[i].slot, entries[i].type_tag);
  }
}
```

Pros: No runtime overhead per container. Type information exists only at compile time.
Cons: Doesn't help for values stored in dynamically-typed containers (e.g., `List a` where `a` is unknown).

**Approach C: Conservative decref (Boehm-style)**

Treat every `i64` as a potential pointer. If it looks like a pointer (aligned, in heap range), decref it.

```c
int is_heap_pointer(i64 val) {
  void* ptr = (void*)(val - 1);  // adjust for tag bit
  // Check if ptr is in heap range and aligned
  return ptr >= heap_start && ptr < heap_end && ((uintptr_t)ptr % 8 == 0);
}

void ko_decref_conservative(i64 val) {
  void* ptr = (void*)(val - 1);
  if (is_heap_pointer(val)) {
    i64 rc = *(i64*)ptr;
    if (rc > 0 && rc < 1000000) {  // sanity check
      ko_decref(ptr);
    }
  }
}
```

Pros: Works for any container, no metadata needed.
Cons: Can false-positive on integers that happen to look like pointers. Performance overhead from range checks.

### Recommended Approach

**Use Approach A for constructors** (we know field types at compile time, and constructors are the most common container).

**Use Approach B for closures** (emit metadata for captured values).

**Use Approach C as a fallback** for dynamically-typed containers like `List a` where the element type is unknown at compile time.

**Implementation plan:**

1. Add `i32* field_tags` to the `Constructor` struct
2. Emit field tags during codegen for every constructor call
3. Add `ko_decref_value(i64 val, i32 type_tag)` function
4. Call `ko_decref_value` for each field in `ko_decref` when freeing a constructor
5. Emit decref metadata for closure environments
6. Use conservative decref for `List a` elements

### Fix 3: Cycle Detection (Deferred)

RC cannot collect cycles. Options for future consideration:

**Option A: Weak references**

```ko
type Weak a = Weak (Ref (Maybe a))

Weak.make : a -> Weak a           # create weak reference
Weak.get : Weak a -> Maybe a      # dereference (Nothing if collected)
```

Weak references don't increment the RC. When the strong reference count reaches 0, the value is collected and all weak references become `Nothing`.

**Option B: Epoch-based cycle collector**

Periodically run a mark-sweep pass to find cycles. This is what Python does (generational GC with cycle detector).

**Option C: Ignore**

Document the limitation. Cycles are rare in CLI tools and compilers. If a user needs cycles, they can use `Weak` (future) or restructure their data.

**Recommendation:** Ignore for now. Document the limitation. Add `Weak a` in v0.4.0 if needed.

---

## 4. Allocation Strategies

### Current: Per-Object malloc

Every `ko_alloc` call does `malloc`. This is simple but slow for programs that allocate many small objects (cons cells, closures).

### Future: Arena Allocation

For function-local data with known lifetime, use an arena allocator:

```c
typedef struct {
  i64* base;        // start of arena
  i64* current;     // next allocation position
  i64 size;         // total arena size in bytes
  i64 used;         // bytes used
} Arena;

void* arena_alloc(Arena* arena, i64 size) {
  if (arena->used + size > arena->size) {
    // Grow arena or fall back to malloc
  }
  void* ptr = arena->current;
  arena->current += size;
  arena->used += size;
  return ptr;
}

void arena_free_all(Arena* arena) {
  arena->current = arena->base;
  arena->used = 0;
}
```

Use cases:
- Function-local temporaries (intermediate strings, lists)
- Comptime evaluation
- Parser allocations (AST nodes during parsing)

### Future: Pool Allocation

For frequently allocated small objects (cons cells, closures), use a free-list pool:

```c
typedef struct {
  i64* free_list;    // linked list of free slots
  i64* memory;       // contiguous block of slots
  i64 slot_size;     // bytes per slot
  i64 count;         // total slots
} Pool;
```

Pool allocation is O(1) and avoids malloc overhead.

---

## 5. The i64 Unification — Keep or Replace?

### Current: Everything is i64

The i64 unification means:
- All values are the same size (8 bytes)
- Phi nodes in LLVM don't need type mismatches
- Values can be stored in uniform arrays

But:
- Type safety is lost at the IR level
- Debugging requires knowing the implementation
- The < 4096 heuristic is fragile

### Alternative: Structured Tagged Union

```c
typedef struct {
  i32 tag;     // type discriminator
  i32 pad;     // alignment
  i64 payload; // raw value or pointer
} Value;
```

This is what the legacy C runtime had. It's honest about types but doubles memory per value.

### Recommendation

**Keep the i64 unification.** The benefits (uniform size, simple phi nodes) outweigh the costs (heuristic, lost type safety). Fix the actual bugs (string RC, recursive decref) before redesigning the value representation.

The i64 approach is well-established (NaN-boxing in Lua/Dart, tagged pointers in many runtimes). The key is to make the heuristics robust and the decref correct.

---

## 6. Implementation Phases

### Phase 1: Correctness (v0.3.0)

- [ ] Add `KoString` wrapper to runtime
- [ ] Change string builtins to allocate `KoString`
- [ ] Fix `len` to read `byte_length` (O(1))
- [ ] Add `i32* field_tags` to `Constructor` struct
- [ ] Add `ko_decref_value(i64 val, i32 type_tag)`
- [ ] Update `ko_decref` to recursively decrement constructor fields
- [ ] Emit field tags during codegen for constructor calls

### Phase 2: Closures & Tuples (v0.3.0)

- [ ] Emit decref metadata for closure environments
- [ ] Add type tags to tuple elements (or use conservative decref)
- [ ] Add type tags to record fields

### Phase 3: Optimization (v0.4.0)

- [ ] Arena allocation for function-local data
- [ ] Pool allocation for cons cells and closures
- [ ] Weak references for cycle support
- [ ] Cycle collector (optional, behind a flag)

---

## 7. Testing Strategy

### Unit Tests

- String allocation and deallocation (leak detection)
- Constructor field decref (nested data structures)
- Closure environment decref (captured values)
- Partial application decref (applied arguments)

### Integration Tests

- Programs that do heavy string manipulation (leak check)
- Programs with nested data structures (correctness check)
- Programs that create and discard many closures (leak check)

### Stress Tests

- Deeply nested constructors (1000+ levels)
- Wide constructors (100+ fields)
- Many closures created and discarded
- String-heavy programs (JSON parser, etc.)

---

*This document is a living design draft. It will be updated as implementation progresses.*
