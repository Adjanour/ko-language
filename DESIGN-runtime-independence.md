# Kō Runtime Independence Roadmap

> **Status:** Design Draft
> **Date:** 2026-08-01
> **Philosophy:** Functional pragmatism and mechanical sympathy aren't at odds. Take every win you can get.

---

## 1. The Thesis

Kō compiles to LLVM IR directly. It doesn't compile to C. But the generated code still calls libc for `malloc`, `printf`, `sin`, and CRT startup.

This document says: **keep libc for now, but have a roadmap for phasing it out.** Not because libc is bad, but because eliminating it gives Kō capabilities no other functional language has.

**Project sequencing (corrected):** The overall project priority is:
1. **Prove the thesis** — linear types on Linux/x86-64 (v0.3.0-v0.4.0). This is the existential risk.
2. **Widen the platform** — macOS, Windows, cross-compilation (v0.5.0). Backend labor.
3. **Ecosystem** — package manager, self-hosting, docs (v1.0.0). Depends on stability.

The libc elimination phases below are Phase 2 work (after linear types are proven). Do not parallelize Phase 1 (linear types) with Phase 2 (platform/libc). Linear types come first. Everything else depends on them.

The core insight: **functional purity and mechanical sympathy are complementary, not contradictory.**

- Purity gives the compiler information (no hidden side effects, no aliasing)
- Mechanical sympathy gives the compiler control (direct syscalls, explicit allocators, no hidden overhead)
- Together they enable optimizations that neither paradigm alone can achieve

Kō doesn't have to choose between "high-level functional" and "low-level systems." It can be both.

---

## 2. Where Kō Stands Today

### What Already Works Without libc

| Capability | Implementation | libc needed? |
|-----------|---------------|-------------|
| Lexer/Parser | Pure Zig | No |
| Typechecker | Pure Zig | No |
| Codegen | Pure Zig + LLVM IR | No |
| Reference counting | `ko_alloc`/`ko_incref`/`ko_decref` | Yes (wraps malloc) |
| String operations | LLVM IR in `stdlib_codegen.zig` | Yes (calls malloc, printf) |
| Math operations | LLVM intrinsics + loops | Partial (llvm.sin.f64 etc.) |
| I/O | `printf` calls in LLVM IR | Yes |
| Stack overflow detection | `__builtin_frame_address` | No |
| Comptime evaluator | Pure Zig | No |
| LSP server | Raw Linux syscalls | No |
| REPL | Raw Linux syscalls | No |

The compiler itself is mostly libc-free. The **generated code** is the problem.

### What the Generated Code Depends On

```
Generated binary
  ├── malloc (via ko_alloc)
  ├── free (via ko_decref)
  ├── printf (via inspect/println)
  ├── snprintf (via Int.toString)
  ├── sin/cos/sqrt/etc (via -lm)
  └── crt1.o/crti.o/crtn.o (startup)
```

Each dependency is a target for elimination.

---

## 3. The Roadmap

### Phase 0: Status Quo (Now)

**Keep libc. Ship working software.**

The generated code calls `malloc`, `printf`, etc. This is fine. The language is small, the compiler works, programs run. Don't let perfect be the enemy of good.

**What to do now:**
- Fix the actual bugs (string RC, recursive decref) — these matter more than libc
- Ship v0.3.0 with working Array, Map, String, I/O, Math
- Document the libc dependency

### Phase 1: Replace malloc (v0.3.0)

**Why first:** malloc is the most impactful dependency. Every heap allocation goes through it. Replacing it gives Kō control over memory layout, enables arena allocation, and is the prerequisite for everything else.

**Approach:** Ship a default allocator that wraps malloc (current behavior), but make it pluggable:

```ko
# Default: wraps malloc (backward compatible)
let arr = Array.make 10 0

# Explicit: use a different allocator
arena \a ->
  let arr = Array.init a 10 0
  # freed when arena exits
```

**Implementation:**
1. Define `Allocator` type in runtime:
   ```c
   typedef struct {
       void* (*alloc)(void* ctx, i64 size);
       void* (*realloc)(void* ctx, void* ptr, i64 old_size, i64 new_size);
       void (*free)(void* ctx, void* ptr);
       void* ctx;
   } KoAllocator;
   ```
2. Default allocator wraps malloc/free
3. `ArenaAllocator` — bump pointer, free all at once
4. `FixedBufferAllocator` — use a pre-allocated buffer
5. Codegen passes allocator to all allocation functions

**What this buys:**
- Arena allocation for temporary data (parser, typechecker, comptime)
- Stack-based allocation for known-lifetime data
- Custom allocators for embedded targets
- No hidden malloc in generated code (it's explicit)

### Phase 2: Replace printf (v0.3.0)

**Why second:** printf is the second most used libc function. Replacing it with direct syscalls eliminates the I/O dependency.

**Approach:** Generate direct Linux syscalls for output:

```c
// Current generated code:
printf("%ld", val);

// New generated code:
// 1. Format number into a stack buffer
// 2. Write buffer to stdout via syscall
char buf[32];
i64 len = ko_int_to_string(val, buf, 32);
ko_write(1, buf, len);  // syscall: write(1, buf, len)
```

**Implementation:**
1. `ko_write(fd, buf, len)` — generates `linux_write` syscall on Linux, `WriteFile` on Windows
2. `ko_int_to_string(val, buf, buf_size)` — format integer into buffer (no snprintf)
3. `ko_float_to_string(val, buf, buf_size)` — format float into buffer
4. `ko_string_to_fd(fd, str)` — write string to file descriptor

**What this buys:**
- No printf/formatting library dependency
- Faster I/O (no libc overhead)
- Works on bare metal (no libc needed for output)
- Cross-platform via syscall abstraction

### Phase 3: Replace string operations (v0.4.0)

**Why third:** String operations currently call `malloc` for every new string. With the allocator from Phase 1, strings can use the provided allocator instead of raw malloc.

**Implementation:**
1. `KoString` uses the allocator (not raw malloc)
2. `String.append` allocates via allocator
3. `String.to_upper` allocates via allocator
4. All string operations use `KoString.length` (O(1)) instead of `strlen`

**What this buys:**
- No hidden malloc in string operations
- Arena-friendly strings (allocate many, free all at once)
- Foundation for string interning, rope structures, etc.

### Phase 4: Replace libm (v0.4.0)

**Why fourth:** Math functions are used less frequently than allocation or I/O. The LLVM intrinsics already handle most cases.

**Approach:** Use LLVM intrinsics where available, pure implementations elsewhere:

```llvm
; LLVM intrinsics (no libm needed on most platforms)
%sin = call double @llvm.sin.f64(double %x)
%cos = call double @llvm.cos.f64(double %x)
%sqrt = call double @llvm.sqrt.f64(double %x)
%exp = call double @llvm.exp.f64(double %x)
%log = call double @llvm.log.f64(double %x)
```

LLVM lowers these to native instructions (x87 `fsin`, SSE `sqrtsd`) or libm calls depending on the target. On x86 with SSE, most are native instructions.

For functions without intrinsics (like `atan2`), provide pure Kō implementations.

**Implementation:**
1. Map `Float.sin`, `Float.cos`, etc. to LLVM intrinsics in codegen
2. Implement `Float.atan2`, `Float.asin`, `Float.acos` in Kō (Taylor series / CORDIC)
3. Remove `-lm` from the linker command

**What this buys:**
- No libm dependency
- Math works on bare metal
- LLVM can inline and optimize math calls

### Phase 5: Replace CRT (v0.5.0)

**Why last:** CRT is the hardest to replace and least important for most users. It only matters for bare metal / embedded targets.

**Approach:** Provide a custom `_start` that doesn't need `crt1.o`:

```asm
; Linux x86_64
.section .text
.globl _start
_start:
    ; Set up stack (argc, argv, envp are on the stack)
    movq (%rsp), %rdi      ; argc
    leaq 8(%rsp), %rsi     ; argv
    call ko_main            ; call Kō's main
    ; Exit with return value
    movq %rax, %rdi
    movq $60, %rax         ; sys_exit
    syscall
```

**Implementation:**
1. Generate `_start` symbol in LLVM IR
2. Parse argc/argv from stack
3. Call `main`
4. Exit with return value

**What this buys:**
- Bare metal targets (embedded, OS kernels)
- No CRT overhead
- Smallest possible binary

---

## 4. What Each Phase Buys

| Phase | Eliminates | Enables | Effort |
|-------|-----------|---------|--------|
| 0 | Nothing (status quo) | Working language | Done |
| 1 | Hidden malloc | Explicit allocators, arenas | Medium |
| 2 | printf, snprintf | Direct syscalls, faster I/O | Medium |
| 3 | Hidden string malloc | Arena-friendly strings | Low |
| 4 | libm | Math on bare metal | Low |
| 5 | CRT | Bare metal, smallest binary | High |

After Phase 5, generated binaries have **zero libc dependency** on Linux.

---

## 5. The Unique Position

After all phases, Kō occupies a position no other language fills:

```
                    Low-level control
                          ↑
                          |
           Zig ←——————————+——————————→ Rust
           |              |              |
           |     Kō ←—————+              |
           |              |              |
           ↓              ↓              ↓
         C ←——————————————+————————————→ Go
                          |
                    High-level ergonomics
```

**What Kō has that Zig doesn't:**
- Functional purity (compiler can prove no side effects)
- ADTs + pattern matching (algebraic data as first-class)
- Curried application without parens (cleaner syntax)
- Comptime (already there)
- Exhaustiveness checking (compiler catches missing cases)

**What Kō has that Haskell/OCaml don't:**
- Native compilation (no GC, no runtime)
- No libc dependency (after roadmap)
- Explicit allocation (when you want it)
- Systems-level control (direct syscalls)
- Small spec (learnable in a day)

**The thesis:** A small, functional, native-compiling language with mechanical sympathy. That doesn't exist yet.

---

## 6. The Philosophy

### Functional Pragmatism

Kō is functional by default. Mutability is explicit (`ref`). Purity is the norm. Pattern matching handles the world.

But Kō is also pragmatic. It compiles to native code. It runs fast. It doesn't require a GC. It doesn't require libc (eventually).

**Pragmatism means:**
- Ship working software first
- Optimize later
- Keep the simple thing simple
- Make the hard thing possible

### Mechanical Sympathy

"Mechanical sympathy" means writing code that works *with* the hardware, not against it.

- Contiguous arrays (cache-friendly) over linked lists (pointer chasing)
- Direct syscalls (no libc overhead) over printf (formatting overhead)
- Explicit allocation (predictable) over GC (unpredictable pauses)
- Stack allocation (fast) over heap allocation (slow)

**But:** Mechanical sympathy doesn't mean "always low-level." It means "understand the cost and choose appropriately."

- `List` for functional patterns (immutable, pattern-matchable)
- `Array` for performance (contiguous, mutable, cache-friendly)
- `Map` for lookup (hash-based, O(1) average)
- Arena for temporary data (allocate fast, free all at once)

### The Balance

Kō doesn't force you to choose between "clean" and "fast."

- Write pure functions → compiler optimizes aggressively
- Use `ref` when you need mutation → explicit, not hidden
- Use `Array` when you need performance → mutable, cache-friendly
- Use `arena` when you need speed → allocate fast, free all at once
- Use direct syscalls when you need control → no libc overhead

The language gives you the tools. You choose when to use them.

---

## 7. What This Means for the Design Documents

The previous design documents should be updated to reflect this roadmap:

1. **DESIGN-memory-runtime.md:** Add allocator abstraction, arena allocation, explicit allocator passing
2. **DESIGN-strings-characters.md:** String operations use allocator, not raw malloc
3. **DESIGN-io-model.md:** I/O uses direct syscalls, not printf
4. **DESIGN-math-semantics.md:** Math uses LLVM intrinsics, not libm
5. **DESIGN-data-structures.md:** Array/Map use allocator, not raw malloc
6. **DESIGN-linear-types.md:** Linear types are the design center. All other work depends on this.

**The critical path:** DESIGN-linear-types.md → everything else. Linear types prove the thesis. After that, libc elimination, platform widening, and ecosystem are all sequential.

---

## 8. Success Criteria

After all phases:

- [ ] Generated binaries have zero libc dependency on Linux
- [ ] `ko --emit-exe out.ko` produces a static binary (no dynamic linking)
- [ ] Binary runs on bare metal (with custom `_start`)
- [ ] Arena allocation works for temporary data
- [ ] All string operations use explicit allocator
- [ ] All I/O uses direct syscalls
- [ ] All math uses LLVM intrinsics or pure implementations
- [ ] Binary size is smaller than equivalent C program (no libc overhead)

---

## 9. The Timeline

```
v0.3.0  ──  Prove the thesis (linear types)
            ├── Linear type checker
            ├── Consumption analysis
            ├── Rc type
            └── Zero-cost codegen for linear values

v0.4.0  ──  Widen the platform + libc elimination begins
            ├── macOS support
            ├── Phase 1: Replace malloc with explicit allocator
            ├── Phase 2: Replace printf with direct syscalls
            └── Phase 3: Replace string operations (use allocator)

v0.5.0  ──  Cross-compilation + more libc elimination
            ├── Windows support
            ├── Phase 4: Replace libm with LLVM intrinsics
            ├── Phase 5: Replace CRT with custom _start
            └── Performance optimization

v1.0.0  ──  Release
            ├── Zero libc dependency on Linux
            ├── Self-hosting (Kō compiles itself)
            ├── Ecosystem (packages, tooling)
            └── Documentation
```

---

*The future is bright. Functional pragmatism and mechanical sympathy aren't at odds. We just have to find where we can take our wins and hammer down.*
