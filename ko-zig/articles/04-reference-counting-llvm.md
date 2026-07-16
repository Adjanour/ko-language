# Article 4: Reference Counting Without GC: Implementing Memory Management in LLVM IR

## Target Audience
Systems programmers, language implementers, developers tired of GC pauses.

## Tone
Practical, detailed, with real-world tradeoffs. This is a "how to actually do it" article.

## Word Count
4,000-5,000 words

## Structure

### Hook (200 words)
- Kō has no garbage collector
- No runtime, no stop-the-world, no GC pauses
- Everything is LLVM IR — the compiler generates memory management code directly
- Show a simple Kō program and the generated RC code
- Promise: you can do this too

### The Problem: Why Not Garbage Collection? (400 words)
- GC is great for most programs
- But: unpredictable pauses, runtime overhead, complex implementation
- Kō's goal: predictable performance, no hidden costs
- Reference counting is deterministic: you know exactly when memory is freed
- The tradeoff: circular references are not handled (acceptable for Kō's use case)

### The Basics: Reference Counting (500 words)
- Every heap object has a reference count (RC) header
- When you create an object: RC = 1
- When you share an object: RC += 1
- When you're done with an object: RC -= 1
- When RC reaches 0: free the memory

### Kō's Memory Layout (600 words)

#### The RC Header
```
[ i64 rc ][ ... user data ... ]
^         ^
|         pointer returned by ko_alloc (what codegen sees)
raw malloc ptr
```

- 8 bytes for the reference count
- User data follows immediately
- The pointer returned by `ko_alloc` points to the user data, not the RC header
- To access the RC: go back 8 bytes from the user pointer

#### The Runtime Functions
```zig
fn ko_alloc(user_size) -> ptr {
    // Allocate user_size + 8 bytes
    // Set RC to 1 at offset -8
    // Return pointer to user data
}

fn ko_incref(ptr) -> ptr {
    // Access RC at ptr - 8
    // Increment RC
    // Return ptr
}

fn ko_decref(ptr) {
    // Access RC at ptr - 8
    // Decrement RC
    // If RC <= 0: free(ptr - 8)
}
```

### The Codegen Pattern (800 words)

#### Step 1: Track Heap Allocations
- Every call to `ko_alloc` is tracked in `scope_heap_values`
- This is a list of all heap-allocated values in the current function
- At function exit, we decref all of them (unless consumed)

#### Step 2: Emit Incref When Sharing
- When a heap value is stored in a parent structure (constructor, tuple, record, closure), the parent takes shared ownership
- We must `ko_incref` the value
- We mark it as "consumed" so we don't decref it again at function exit

```llvm
; Storing a heap value in a constructor
%raw_ptr = call i64* @ko_alloc(i64 16)
store i64 %tag, i64* %raw_ptr
store i64 %value, i64* (getelementptr ...) ; <-- value is shared
call i64* @ko_incref(i64* %value_ptr)     ; <-- incref!
; Mark %value as consumed (skip decref at exit)
```

#### Step 3: Emit Decref at Function Exit
- At the end of each function, decref all tracked heap values
- Skip values that were consumed (stored in parents)
- Skip the return value (caller takes ownership)

```llvm
; Function exit
%is_consumed_1 = icmp eq i64 %heap_val_1, %consumed_val_1
br i1 %is_consumed_1, label %skip_1, label %decref_1
decref_1:
  call void @ko_decref(i64 %heap_val_1)
  br label %skip_1
skip_1:
  ; ... repeat for all heap values
  ret i64 %result
```

### The Gotchas (600 words)

#### Gotcha 1: Store ptrtoint, Not Raw Pointer
- `scope_heap_values` MUST store the `ptrtoint` result (i64), NOT the raw pointer
- Why: `codegenExpr` returns `ptrtoint(raw_ptr)` for constructors
- The consumption check compares these i64 values
- If you store raw ptr, the comparison fails → markConsumed never matches → double-free

```zig
// CORRECT:
const raw_ptr = call ko_alloc(...);
const result = LLVMBuildPtrToInt(raw_ptr);
self.trackHeapAlloc(result);  // stores i64
return result;

// WRONG — causes double-free:
self.trackHeapAlloc(raw_ptr);  // stores ptr
return LLVMBuildPtrToInt(raw_ptr);
```

#### Gotcha 2: Exclude Return Value from Decref
- The caller takes ownership of the return value
- Decrefing it causes use-after-free
- For unconditional allocations: Zig-level comparison `heap_val == body_val`
- For conditional allocations: LLVM-level runtime check

#### Gotcha 3: Allocas Before Entry Block Terminator
- When creating allocas for conditional allocations, position BEFORE the first instruction
- After `codegenIf` emits a branch, positioning at the end places allocas AFTER the terminator
- Use `LLVMPositionBuilder(builder, entry, first_inst)` to insert before the first instruction

#### Gotcha 4: emitDecrefAll Must Use Select
- Creating new basic blocks for decref null-checks causes control flow issues
- Use `LLVMVMBuildSelect` instead: load from alloca, check if non-null, select between real pointer and null
- This keeps the decref inline without creating new blocks

#### Gotcha 5: Zig 0.17 ArrayList API
```zig
// In Zig 0.17:
var list: std.ArrayList(T) = .empty;
defer list.deinit(allocator);
try list.append(allocator, item);
```

### Conditional Allocations (400 words)
- Some allocations only happen on certain code paths
- Example: `if cond then Cons x Nil else Nil`
- The Cons is only allocated when `cond` is true
- Solution: use an alloca initialized to 0, store the pointer if allocated
- At exit: load from alloca, check if non-null, decref if non-null

```llvm
%alloc = alloca i64, i64 0        ; initially null
br i1 %cond, label %allocate, label %skip
allocate:
  %raw = call i64* @ko_alloc(i64 16)
  %ptrtoint = ptrtoint i64* %raw to i64
  store i64 %ptrtoint, i64* %alloc
  br label %skip
skip:
  ; ... at exit:
  %val = load i64, i64* %alloc
  %is_null = icmp eq i64 %val, 0
  br i1 %is_null, label %skip_decref, label %do_decref
do_decref:
  %ptr = inttoptr i64 %val to i64*
  call void @ko_decref(i64* %ptr)
  br label %skip_decref
skip_decref:
  ; continue
```

### The Ownership Model (500 words)

#### Unconsuming Operations
- Most operations don't consume their arguments
- `add x y` reads x and y, doesn't consume them
- Both x and y must be decreffed at function exit

#### Consuming Operations
- Some operations consume their arguments
- `Cons x Nil` consumes x (stores it in the constructor)
- The parent (Cons) takes ownership
- We incref x when storing, mark it consumed for exit

#### The Return Value
- The return value is always consumed by the caller
- Never decref the return value
- This is the most common source of use-after-free bugs

### Performance (300 words)
- Reference counting has overhead: incref/decref on every share/drop
- But it's deterministic: no GC pauses
- LLVM optimizes many incref/decref pairs away (dead code elimination)
- The runtime cost is predictable: O(1) per operation
- For most programs, the overhead is negligible compared to GC

### Comparison to Other Approaches (400 words)

#### Boehm GC
- Conservative garbage collector
- Simple to implement, but has pauses
- Kō's approach: more code, but no pauses

#### Rust Ownership
- Compile-time ownership tracking
- Zero runtime overhead, but complex type system
- Kō's approach: runtime RC, but simpler types

#### ARC (Automatic Reference Counting)
- Used by Swift, Objective-C
- Similar to Kō's approach, but with cycle detection
- Kō's approach: no cycle detection (simpler)

#### C++ shared_ptr
- Smart pointers with reference counting
- Similar to Kō, but manual management
- Kō's approach: automatic, compiler-generated

### Lessons Learned (300 words)
- The hardest part is tracking which values to decref at exit
- Ownership tracking is essential for correctness
- Conditional allocations require careful alloca management
- LLVM IR generation is tedious but straightforward
- Testing with address sanitizer catches most bugs

### Conclusion (200 words)
- Reference counting is a viable alternative to GC
- The implementation in LLVM IR is straightforward
- The gotchas are real but manageable
- The result: deterministic memory management with no runtime overhead
- Kō proves that you can have functional programming without GC

---

## Key Code Snippets to Include

1. The ko_alloc, ko_incref, ko_decref implementations
2. The scope_heap_values tracking pattern
3. The emitIncref + markConsumed pattern
4. The decref-at-exit codegen
5. The conditional allocation alloca pattern
6. The ownership model examples

## Images/Diagrams
1. Memory layout (RC header + user data)
2. The reference counting lifecycle (create → share → decref → free)
3. The ownership flow (unconsuming vs consuming)
4. Conditional allocation control flow
5. The decref-at-exit decision tree

## Publishing Platforms
- Personal blog
- Reddit (r/Programming, r/Compilers, r/Zig)
- Hacker News
- Lobste.rs
- LLVM Dev Meeting (if timing works)
