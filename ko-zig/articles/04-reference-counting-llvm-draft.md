# Reference Counting Without a Garbage Collector

Most programming languages have a garbage collector. Java has one. Python has one. Go has one. Haskell has one. The garbage collector runs in the background, finds objects that aren't being used anymore, and frees their memory. You don't have to think about memory management — the GC does it for you.

This is great until it isn't. Garbage collectors have pauses. When the GC runs, your program stops. For a web server handling thousands of requests, a 10-millisecond pause means 10 milliseconds where no requests are processed. For a game running at 60 frames per second, a 16-millisecond pause means a dropped frame. For a real-time system, any pause is unacceptable.

The alternative is manual memory management. C does this. You call malloc when you need memory, and free when you're done. You are responsible for every byte. If you forget to free, you leak memory. If you free too early, you get a use-after-free bug. If you free twice, you get a double-free bug. Manual memory management is powerful but dangerous.

There's a middle ground. Reference counting.

---

Reference counting is simple. Every object on the heap has a reference count — an integer that tracks how many pointers point to it. When you create an object, the count is 1. When you copy a pointer to the object, the count goes up. When you're done with a pointer, the count goes down. When the count reaches zero, nobody points to the object anymore, so you can free it.

It's deterministic. You know exactly when memory is freed. There are no pauses, no background threads, no stop-the-world events. The memory management happens inline, as part of your code.

The tradeoff is circular references. If object A points to object B, and object B points to object A, their reference counts never reach zero. They keep each other alive forever. This is a real limitation, but for most programs, it's acceptable. Trees, lists, strings, records — none of these have circular references. Only graphs and doubly-linked lists do.

Kō uses reference counting. No garbage collector. No runtime. Just LLVM IR that manages memory.

---

Every heap object in Kō has a reference count header. The memory layout looks like this:

```
[ i64 rc ][ ... user data ... ]
^         ^
|         pointer returned by ko_alloc (what codegen sees)
raw malloc ptr
```

The reference count is an 8-byte integer at the start of the allocation. The user data follows immediately after. The pointer returned by `ko_alloc` points to the user data, not the reference count. To access the reference count, you go back 8 bytes from the user pointer.

The runtime provides three functions:

`ko_alloc(user_size)` allocates `user_size + 8` bytes. It sets the reference count to 1 at offset -8. It returns a pointer to the user data.

`ko_incref(ptr)` increments the reference count. It accesses the count at `ptr - 8`, adds 1, and returns the pointer.

`ko_decref(ptr)` decrements the reference count. It accesses the count at `ptr - 8`, subtracts 1, and if the count reaches zero, frees the memory.

These functions are implemented as LLVM IR. No C code, no runtime library. The compiler generates the memory management code directly.

---

The codegen pattern is straightforward. Every call to `ko_alloc` is tracked in a list called `scope_heap_values`. This list contains all heap-allocated values in the current function. At function exit, the compiler decrements the reference count for each value in the list.

When a heap value is stored in a parent structure — a constructor, a tuple, a record, a closure — the parent takes shared ownership. The compiler must increment the reference count when this happens. It also marks the value as "consumed" so it doesn't decrement it again at function exit.

The return value is special. The caller takes ownership of the return value. The compiler must not decrement the reference count for the return value. Doing so causes a use-after-free.

Here's the pattern in pseudocode:

```
// At function entry
heap_values = []

// When storing a heap value in a parent
ko_incref(value)
mark_consumed(value)
heap_values.add(value)

// At function exit
for each value in heap_values:
    if not consumed(value):
        ko_decref(value)

return result
```

It's simple. It's predictable. It works.

---

There are gotchas. Real ones that will bite you if you're not careful.

The first gotcha: you must track the ptrtoint result, not the raw pointer. `codegenExpr` returns `ptrtoint(raw_ptr)` — a 64-bit integer that represents the pointer. If you track the raw pointer instead of the ptrtoint, the consumption check fails. The comparison compares different LLVM types, and `markConsumed` never matches. The result is a double-free.

The fix is simple: always store the ptrtoint result in `scope_heap_values`. Never store the raw pointer.

The second gotcha: you must exclude the return value from decref. The caller takes ownership of the return value. If you decrement its reference count at function exit, you cause a use-after-free. The fix is to check if each value is the return value before decrementing.

The third gotcha: allocas for conditional allocations must be before the entry block terminator. If you create an alloca after the entry block has a branch instruction, the alloca is placed after the terminator. LLVM considers this undefined behavior. The fix is to position the builder before the first instruction in the entry block when creating allocas.

The fourth gotcha: decref-at-exit must use select, not branch. Creating new basic blocks for null-checks causes control flow issues. The fix is to use `LLVMVMBuildSelect`: load from alloca, check if non-null, select between the real pointer and null. This keeps the decref inline without creating new blocks.

---

Some allocations only happen on certain code paths. Consider:

```ko
fn maybe_cons cond x =
  if cond then Cons x Nil else Nil
```

The Cons is only allocated when `cond` is true. If `cond` is false, only Nil is returned. The compiler must handle this correctly.

The solution is an alloca initialized to zero. When the allocation happens, the pointer is stored in the alloca. At function exit, the compiler loads from the alloca, checks if it's non-null, and decrements if so.

```
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

It's verbose, but it works. The alloca is always in the entry block. The conditional allocation stores the pointer. The exit check loads and conditionally decrements. No control flow issues, no undefined behavior.

---

The ownership model determines when to increment and when to decrement.

Unconsuming operations don't consume their arguments. `add x y` reads x and y, doesn't consume them. Both x and y must be decremented at function exit. The function borrows them temporarily.

Consuming operations take ownership. `Cons x Nil` consumes x — it stores it in the constructor. The parent (Cons) takes ownership. The compiler increments x's reference count when storing, marks x as consumed for exit.

The return value is always consumed by the caller. Never decrement the return value. This is the most common source of use-after-free bugs.

The model is simple: if you store a heap value somewhere, increment its count and mark it consumed. If you return a heap value, don't decrement it. If you're done with a heap value and it's not stored or returned, decrement it.

---

Reference counting has overhead. Every time you share a value, you increment the count. Every time you're done with a value, you decrement the count. For tight loops, this overhead can be significant.

But it's predictable overhead. There are no GC pauses. No stop-the-world events. No background threads. The memory management happens inline, as part of your code. You know exactly when memory is allocated and freed.

LLVM optimizes many incref/decref pairs away. If a value is created and immediately consumed, the incref and decref cancel out. LLVM's dead code elimination removes them. The overhead is often zero.

For most programs, the overhead is negligible compared to garbage collection. GC pauses are measured in milliseconds. Reference counting overhead is measured in nanoseconds. The tradeoff is worth it for programs that need predictable performance.

---

 Boehm GC is a conservative garbage collector. It's simple to implement — you just link it and it works. But it has pauses. When the GC runs, your program stops. For programs that need predictable performance, this is unacceptable.

Rust's ownership is compile-time. The borrow checker tracks who owns what and when. It's brilliant, but it's complex. You have to think like the borrow checker to write correct code. Kō's reference counting is runtime, but it's simpler. You don't have to think about ownership — the reference counts handle it.

ARC is Automatic Reference Counting, used by Swift and Objective-C. It's similar to Kō's approach, but with cycle detection. Swift's ARC detects cycles and breaks them. Kō's reference counting doesn't detect cycles. This is a tradeoff: Kō is simpler, but circular references leak.

C++ `std::shared_ptr` is a smart pointer with reference counting. It's similar to Kō's approach, but manual. You have to wrap values in `shared_ptr` explicitly. Kō's reference counting is automatic — the compiler generates the incref/decref code. You don't have to think about it.

---

I learned a lot building Kō's memory management. Some of it was technical, some of it was about the process.

The hardest part is tracking which values to decref at exit. If you miss one, you leak memory. If you decrement too many, you get use-after-free. The `scope_heap_values` list is the key — it tracks everything, and the exit code decrements everything in the list (except consumed values and the return value).

Ownership tracking is essential for correctness. The `consumed` set tracks which values have been stored in parents. These values must not be decremented at exit — the parent owns them now. Without this tracking, you double-free.

Conditional allocations require careful alloca management. The alloca must be in the entry block, not in the conditional branch. The exit check must handle the null case. This is verbose but necessary.

LLVM IR generation is tedious but straightforward. Each incref is a function call. Each decref is a function call. Each allocation is a function call. The codegen is just stringing these calls together in the right order.

Testing with address sanitizer catches most bugs. Address sanitizer detects use-after-free, double-free, and memory leaks. Running the test suite with address sanitizer is essential for catching memory management bugs.

---

Reference counting is a viable alternative to garbage collection. It's deterministic, has no pauses, and is straightforward to implement in LLVM IR. The gotchas are real but manageable. The ownership model is simple: increment when sharing, decrement when done, never decrement the return value.

Kō proves that you can have functional programming without GC. Pattern matching, type inference, eager evaluation, reference counting. These features work together. Pattern matching works well with eager evaluation. Type inference works well with reference counting. Eager evaluation makes reference counting simpler.

The result is a language with predictable performance. No GC pauses, no stop-the-world events, no background threads. Just code that runs as fast as it can, with memory management that happens inline.

For programs that need predictable performance, this matters. For games, for real-time systems, for high-performance servers — reference counting is the right choice.

---

*Kō (光) means "light" in Japanese. Reference counting is how Kō manages memory — simply, predictably, without pauses.*
