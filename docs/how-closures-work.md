# How Closures Work in Kō

A visual guide to the scariest functional programming concept.

---

## The Problem

```kō
let secret = 10
let add_secret = \x -> x + secret
println (add_secret 5)  // How does this know about secret?
```

When `add_secret` is called, `secret` is defined **outside** the function. Normally, functions can't see outside variables. But closures can.

---

## What Happens Under the Hood

When the compiler sees:

```kō
let secret = 10
let add_secret = \x -> x + secret
```

It generates something like:

```c
// Step 1: Create the environment (a "bag" of captured variables)
Env* env = make_env(1);
env_pack(env, 0, make_int(10));  // pack "secret" into the bag

// Step 2: Create closure = function + environment
Value add_secret = make_closure(env, add_secret_func);
```

When you call `add_secret 5`:

```c
// Step 3: Unpack variables from the bag inside the function
Value add_secret_func(Env* env, Value x) {
    Value secret = env_unpack(env, 0);  // get secret from bag
    return make_int(x.as.int_val + secret.as.int_val);
}
```

**Closure = function + bag of captured variables.**

---

## Example: Counter

```kō
let counter = ref 0

let increment = \_ -> counter := (!counter + 1)

increment 0
increment 0
println !counter  // 2
```

Here's what the compiler does:

```
┌─────────────────────────────────────┐
│ 1. Create ref cell: counter = ref 0 │
│ 2. Create closure:                  │
│    - Function: \_ -> counter := ... │
│    - Environment: { counter }       │
│ 3. Call increment:                  │
│    - Unpack counter from env        │
│    - Mutate it: counter := ...      │
└─────────────────────────────────────┘
```

Both `increment` calls share the **same** `counter` ref cell. That's why it goes from 0 to 1 to 2.

---

## Visual: How map Uses Closures

```kō
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

The closure `\x -> x * 2` has no captured variables (empty env), but it's still a closure.

---

## Visual: How Partial Application Works

```kō
fn add a b = a + b
let add_ten = add 10
println (add_ten 5)  // 15
```

```
add 10 is called:
  add = \a -> \b -> a + b
  
  Step 1: apply add to 10
          → (\b -> 10 + b)
          → new closure with env { a = 10 }
  
  Step 2: apply add_ten to 5
          → 10 + 5
          → 15
```

Each partial application creates a new closure with more captured variables.

---

## Why Closures Matter

Closures let you create **specialized functions**:

```kō
fn make_adder n = \x -> x + n
let add5 = make_adder 5
let add10 = make_adder 10

println (add5 3)    // 8
println (add10 3)   // 13
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

## TL;DR

| Concept | What it is | Example |
|---------|-----------|---------|
| Closure | Function + captured variables | `\x -> x + secret` |
| Environment | Bag of captured variables | `{ secret = 10 }` |
| Capture | Grabbing outside variables | `\x -> x + secret` captures `secret` |
| Partial Application | Applying some args now, rest later | `add 10` returns `\b -> 10 + b` |

**Rule of thumb:** If you see `\` and it uses variables from outside, it's a closure. The compiler packs those variables into an "environment" so the function can access them later.
