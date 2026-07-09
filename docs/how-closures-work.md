# How Closures Work in Kō

A visual guide to the scariest functional programming concept.

---

## The Problem

```kō
let secret = 10
let add_secret = \x -> x + secret
println (add_secret 5)  # How does this know about secret?
```

When `add_secret` is called, `secret` is defined **outside** the function. Normally, functions can't see outside variables. But closures can.

---

## What Happens Under the Hood

Kō compiles to LLVM IR. When the compiler sees:

```kō
let secret = 10
let add_secret = \x -> x + secret
```

It generates a **closure struct** on the heap:

```
Closure struct (heap-allocated):
┌──────────────┬──────────────┬──────────────┬──────────────────┐
│ fn_ptr       │ total_arity  │ applied_count│ applied_args[]   │
│ (pointer to  │ (1)          │ (0)          │ (none yet)       │
│  the wrapper)│              │              │                  │
└──────────────┴──────────────┴──────────────┴──────────────────┘
```

But for a simple lambda like `\x -> x + secret`, the captured variable `secret` is embedded directly in the function's scope — no separate environment struct needed. The lambda becomes an anonymous LLVM function that loads `secret` from its enclosing scope.

When you call `add_secret 5`, LLVM calls the function pointer, passing `5` as the argument.

**Closure = function + captured variables.**

---

## Example: Counter

```kō
let counter = ref 0

let increment = \_ -> counter := (!counter + 1)

increment 0
increment 0
println !counter  # 2
```

Here's what the compiler does:

```
┌─────────────────────────────────────────┐
│ 1. Create ref cell: counter = ref 0     │
│    → heap-allocated { rc: 1, value: 0 } │
│                                         │
│ 2. Create closure:                      │
│    → LLVM function that loads counter   │
│      from enclosing scope, increments   │
│                                         │
│ 3. Call increment:                      │
│    → function loads counter ptr         │
│    → deref: load value (0 → 1 → 2)     │
│    → assign: store new value            │
└─────────────────────────────────────────┘
```

Both `increment` calls share the **same** `counter` ref cell. That's why it goes from 0 to 1 to 2.

---

## Visual: How map Uses Closures

```kō
type List a = Cons a (List a) | Nil

let nums = Cons 1 (Cons 2 (Cons 3 Nil))
let doubled = map (\x -> x * 2) nums
```

```
map is called with:
  f = closure { func: \x -> x * 2, env: {} }
  list = Cons 1 (Cons 2 (Cons 3 Nil))

Step 1: f applied to 1 → 1 * 2 = 2
Step 2: f applied to 2 → 2 * 2 = 4
Step 3: f applied to 3 → 3 * 2 = 6
Result: Cons 2 (Cons 4 (Cons 6 Nil))
```

The closure `\x -> x * 2` has no captured variables, but it's still a closure (a function value at runtime).

---

## Visual: How Partial Application Works

```kō
fn add a b = a + b
let add_ten = add 10
println (add_ten 5)  # 15
```

```
add is a 2-arity function. When called with 1 arg:

add 10 is called:
  add = \a -> \b -> a + b
  
  Step 1: apply add to 10
          → needs 1 more arg (arity 2, got 1)
          → create closure struct:
            ┌────────────┬───────────────┬───────────────┬──────────────┐
            │ fn_ptr     │ total_arity   │ applied_count │ applied_args │
            │ (wrapper)  │ 2             │ 1             │ [10]         │
            └────────────┴───────────────┴───────────────┴──────────────┘
          → return closure with bit 0 set (tag for partial application)

  Step 2: apply add_ten to 5
          → detect bit 0 = 1 (partial application)
          → load wrapper fn_ptr from closure
          → wrapper loads applied args [10], calls add(10, 5)
          → 10 + 5 = 15
```

Each partial application creates a new closure with more captured arguments.

---

## Why Closures Matter

Closures let you create **specialized functions**:

```kō
fn make_adder n = \x -> x + n
let add5 = make_adder 5
let add10 = make_adder 10

println (add5 3)    # 8
println (add10 3)   # 13
```

`make_adder` returns a closure that "remembers" `n`. You get different functions for different `n` values.

**This is how you create:**
- Event handlers
- Callbacks
- Stateful functions
- Specialized operations

---

## Common Patterns

### 1. Stateful Closures
```kō
let counter = ref 0
let increment = \_ -> counter := (!counter + 1)
let get_count = \_ -> !counter
```

### 2. Function Factories
```kō
fn make_multiplier n = \x -> x * n
let double = make_multiplier 2
let triple = make_multiplier 3
```

### 3. Closures in Callbacks
```kō
let name = ref ""
let on_click = \_ ->
  name := "clicked"
  println !name
```

---

## Memory Management

Kō uses **reference counting** for heap-allocated objects (including closure structs).

```
Closure struct memory layout:
┌─────────┬──────────────────────────────────┐
│ i64 rc  │ ... closure data ...             │
└─────────┴──────────────────────────────────┘
^         ^
|         pointer returned by ko_alloc
raw malloc ptr
```

When a closure is no longer referenced, its reference count drops to zero and the memory is freed immediately — no garbage collector needed.

---

## TL;DR

| Concept | What it is | Example |
|---------|-----------|---------|
| Closure | Function + captured variables | `\x -> x + secret` |
| Environment | Captured variables in scope | `secret` is captured |
| Capture | Grabbing outside variables | `\x -> x + secret` captures `secret` |
| Partial Application | Applying some args now, rest later | `add 10` returns a closure |
| Closure struct | Heap-allocated `{ fn_ptr, arity, count, args[] }` | The runtime representation |

**Rule of thumb:** If you see `\` and it uses variables from outside, it's a closure. The compiler ensures those variables are available when the function is called later.
