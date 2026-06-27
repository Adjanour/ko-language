# Kō Implementation Research

Research findings for type system, comptime, reference counting, and codegen.

> **Current status**: Zig compiler complete with HM type inference, LLVM IR codegen, JIT/AOT compilation, and reference counting.

---

## 1. Type System (Hindley-Milner)

### Algorithm Choice: Algorithm J (Union-Find) over Algorithm W

Algorithm W builds explicit substitution maps and threads them through every recursive call. Algorithm J (used by Gleam, OCaml, and most real compilers) uses **union-find** instead, which is simpler and faster.

**Key idea**: Instead of building substitution maps, unification calls `union(a, b)` to merge equivalence classes. Lookup calls `find(a)` to get the current representative. No substitution composition needed.

### Data Structures

```
Type = TyVar(id) | TyCon(name, args) | Arrow(from, to) | Int | Float | Bool | String | Unit

Scheme = Forall(quantified_vars, type)   -- e.g., forall a. a → List a → a

UnionFind = array of { rank, parent_or_type }
```

### Core Algorithm

```
infer(env, expr) → type:

  Variable(x):
    scheme = env[x]
    return instantiate(scheme)     -- fresh vars for quantified vars

  Lambda(x, body):
    α = fresh()
    env' = env ∪ {x: Forall([], α)}
    τ_body = infer(env', body)
    return α → τ_body

  Application(func, arg):
    τ_func = infer(env, func)
    τ_arg = infer(env, arg)
    β = fresh()
    unify(τ_func, τ_arg → β)
    return β

  Let(x, value, body):
    τ_value = infer(env, value)
    σ = generalize(env, τ_value)   -- quantify free vars
    env' = env ∪ {x: σ}
    τ_body = infer(env', body)
    return τ_body

  Match(scrutinee, arms):
    τ_scrut = infer(env, scrutinee)
    for each (pattern, body) in arms:
      env' = env + bindings_from(pattern)
      unify(pattern_type(pattern), τ_scrut)
      infer(env', body) → τ_arm
      unify(τ_arm, result_type)
    return result_type
```

### ADT Type Registration

When encountering `type List a = Cons a (List a) | Nil`:

1. Register type constructor `List` with arity 1
2. Register data constructors in environment:
   - `Cons : forall a. a → List a → List a`
   - `Nil : forall a. List a`

### Unification with Occurs Check

```
unify(t1, t2):
  t1 = find(t1), t2 = find(t2)
  if t1 == t2: return
  if t1 is TyVar:
    if occurs_in(t1, t2): error("infinite type")
    union(t1, t2)
  elif t2 is TyVar:
    if occurs_in(t2, t1): error("infinite type")
    union(t2, t1)
  elif t1 is Arrow(a1,b1) and t2 is Arrow(a2,b2):
    unify(a1, a2)
    unify(b1, b2)
  elif t1 is TyCon(n1,args1) and t2 is TyCon(n2,args2):
    if n1 != n2 or len(args1) != len(args2): error("type mismatch")
    for (a1, a2) in zip(args1, args2): unify(a1, a2)
  else: error("type mismatch")
```

### Implementation Order

1. Define types: `Type`, `Scheme`, `UnionFind`
2. Implement union-find: `find`, `union`, `fresh`
3. Implement unification with occurs check
4. Implement core inference: var, lambda, application, let
5. Implement generalization/instantiation
6. Add ADT type registration
7. Add constructor inference
8. Add pattern matching inference
9. Better error messages

---

## 2. Comptime Features

### Approach: Embedded Interpreter in Type Checker

```
Source → Parser → AST → Type Checker + Comptime Evaluator → Specialized IR → Codegen
```

### What Can Be Evaluated at Compile Time

- Arithmetic: `comptime 2 + 3`
- Recursion: `comptime fib 10`
- Conditional branching: `comptime if x > 0 then x else 0`
- String manipulation: `comptime "hello " ++ name`
- Type construction: `comptime VectorOf Float 3` → `Array Float 3`
- Pattern matching on types: `comptime describeType t`

**NOT possible**: I/O, randomness, side effects (must be deterministic).

### Comptime Value Representation

```python
enum ComptimeValue:
    Int(i64)
    Float(f64)
    Bool(bool)
    String(str)
    Type(TypeIndex)           # Types are values too!
    Array(Vec<ComptimeValue>)
    Fn(params, body, env)     # Closure captured at comptime
```

### Integration with Type System

- `comptime` keyword marks expressions for compile-time evaluation
- Comptime expressions must have all inputs known at compile time
- After evaluation, the result is inlined into the generated code
- Types are first-class comptime values (enables generic programming)

### Implementation Order

1. Define `ComptimeValue` type
2. Implement comptime evaluator (tree-walking interpreter)
3. Add comptime check to type checker
4. Implement monomorphization from comptime results
5. Add dead code elimination for comptime-resolved branches

---

## 3. Reference Counting

### Approach: Compiler-Inserted RC (Perceus-style)

The compiler inserts `inc`/`dec` calls at compile time. No runtime cycle detector needed for purely functional code.

### Data Structure Layout

```c
// Every heap-allocated object needs a header
typedef struct {
    uint32_t refcount;
    uint16_t tag;           // constructor tag
} rc_header_t;

// User-visible pointer points to PAYLOAD, not header
// To access header: (rc_header_t*)((char*)ptr - sizeof(rc_header_t))
```

### Reference Counting Rules

| Operation | Action |
|-----------|--------|
| Create (`make_*`) | refcount = 1 |
| Copy (assign to new variable) | increment refcount |
| Overwrite (assign to existing variable) | decrement old, increment new |
| Go out of scope | decrement refcount |
| refcount hits 0 | free the object (and recurse on children) |

### Closures and Captured Environments

```c
typedef struct {
    rc_header_t header;
    void* code_ptr;
    uint32_t env_size;
    value_t env[];          // captured values
} closure_t;
```

When creating a closure: `inc_ref` each captured variable.
When dropping a closure: `dec_ref` each captured variable, then free.

### Cycle Handling

For purely functional languages: **cycles cannot be created** (immutable data).
For mutable ref cells: cycles are possible but rare.

**Recommendation**: Ignore cycles in v0.1. Document the limitation. Add weak references later if needed.

### Optimizations

1. **Borrow inference**: If value is unique (refcount==1), skip inc/dec
2. **Drop specialization**: Cancel matching inc/dec pairs
3. **Reuse analysis**: When pattern matching a unique constructor, reuse memory in-place

### Implementation Order

1. Add refcount header to all heap objects (constructors, closures, strings)
2. Generate `inc_ref`/`dec_ref` calls in codegen
3. Handle closure environment refcounting
4. Handle ref cell value refcounting
5. Add borrow inference (optimization)
6. Add reuse analysis (optimization)

---

## 4. C Codegen Rewriting

### Current Issues

1. **Memory leaks**: Only RefCell has refcounting; constructors, closures, strings leak
2. **String interpolation**: Parse-time desugaring creates multiple temporary allocations
3. **No RC for closures**: Captured variables leak when closure is dropped
4. **Pattern matching**: Uses ternary chains which have side-effect issues

### Recommended C Data Layout

```c
// Value representation
typedef enum {
    VAL_INT, VAL_FLOAT, VAL_BOOL, VAL_CHAR,
    VAL_STRING, VAL_CONSTRUCTOR, VAL_CLOSURE, VAL_REF, VAL_UNIT
} ValueType;

typedef struct Value {
    ValueType type;
    union {
        int64_t int_val;
        double float_val;
        bool bool_val;
        char char_val;
        char* string_val;
        struct { int tag; int arity; struct Value* args; } constructor;
        struct { void* env; void* func; } closure;
        struct RefCell* ref;
    } as;
} Value;
```

### Pattern Matching → C

```c
// Use switch for ≥4 constructors (jump table optimization)
switch (_match_val.as.constructor.tag) {
    case TAG_JUST: {
        Value v = _match_val.as.constructor.args[0];
        result = v;
        break;
    }
    case TAG_NOTHING: {
        result = make_int(0);
        break;
    }
}

// Use if/else if for <4 constructors
if (_match_val.type == VAL_CONSTRUCTOR && _match_val.as.constructor.tag == TAG_JUST) {
    Value v = _match_val.as.constructor.args[0];
    result = v;
} else if (...) { ... }
```

### String Interpolation → snprintf

Instead of desugaring at parse time, generate a single `snprintf`:

```c
// "hello ${name}!" →
char _buf[1024];
snprintf(_buf, sizeof(_buf), "hello %s!", name.as.string_val);
Value result = make_string(_buf);
```

### Tail Calls

Trust GCC `-O2` for sibling tail call optimization. Document that users should write tail-recursive functions with accumulators:

```kō
# This is tail-recursive (GCC optimizes to loop):
fn factorial n acc =
  if n == 0 then acc
  else factorial (n - 1) (n * acc)
```

### Reference Counting in Generated C

```c
// When a let binding goes out of scope:
dec_ref_value(old_x);

// When a function returns:
// Parameters and locals are decremented automatically

// When overwriting a variable:
Value old_x = x;
x = new_value;
dec_ref_value(old_x);
```

### Testing Strategy

1. **Golden tests**: Run .ko files, compare stdout to expected output
2. **Sanitizer testing**: Compile with `-fsanitize=address,undefined`
3. **Valgrind**: Run under Valgrind for memory leak detection
4. **Codegen unit tests**: Verify generated C contains expected patterns
5. **Differential testing**: Compare Kō output against Python/OCaml reference

### Implementation Order

1. Add refcount header to all heap objects
2. Generate inc/dec_ref calls systematically
3. Fix string interpolation (snprintf)
4. Fix pattern matching (switch for many constructors)
5. Add golden test infrastructure
6. Add sanitizer/valgrind testing

---

## 5. Implementation Priority

Based on dependencies and impact:

| Priority | Feature | Reason |
|----------|---------|--------|
| 1 | Reference counting | Everything else depends on correct memory management |
| 2 | Codegen rewriting | Fix existing issues, add proper RC |
| 3 | Type system (HM) | Enables better error messages and generic types |
| 4 | Comptime | Depends on type system for type-level computation |
| 5 | Testing infrastructure | Verify everything works correctly |

### Suggested Sprint Plan

**Sprint 1: RC + Codegen Foundation**

- Add refcount header to Value
- Generate inc/dec_ref calls
- Fix string interpolation
- Add golden test infrastructure
- Run all tests through sanitizers

**Sprint 2: Type System**

- Implement union-find
- Implement unification
- Implement core HM inference
- Add ADT type registration
- Add pattern matching inference

**Sprint 3: Comptime**

- Implement comptime evaluator
- Add comptime check to type checker
- Implement monomorphization

**Sprint 4: Polish**

- Better error messages
- Borrow inference optimization
- Reuse analysis optimization
- Comprehensive test suite

---

## Key References

- Algorithm W: Milner 1978, "A Theory of Type Polymorphism in Programming"
- Union-Find: Tarjan 1975, "Efficiency of a Good But Not Linear Set Union Algorithm"
- Perceus RC: Reinking et al. 2021, "Perceus: Garbage Free Reference Counting with Reuse"
- Lean 4 RC: Ullrich & de Moura 2019, "Counting Immutable Beans"
- Gleam compiler: github.com/gleam-lang/gleam (production HM with ADTs in Rust)
- Koka compiler: github.com/koka-lang/koka (Perceus RC implementation)
- Scheme→C: Matt Might, matt.might.net/articles/compiling-scheme-to-c/
- OCaml Runtime: ocaml.org/manual/intfc.html
