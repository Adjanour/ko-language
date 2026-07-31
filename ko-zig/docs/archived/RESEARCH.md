# Kō Implementation Research

Research findings for type system, comptime, reference counting, and codegen.

> **Current status**: v0.2.0-alpha — Zig compiler complete with HM type inference, LLVM IR codegen, JIT/AOT compilation, reference counting, file-based module imports, `?` operator, and Result operations.

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

## 4. Implementation Priority

Based on dependencies and impact (updated for v0.2.0-alpha):

| Priority | Feature | Status |
|----------|---------|--------|
| 1 | Reference counting | Done |
| 2 | LLVM codegen | Done |
| 3 | Type system (HM) | Done |
| 4 | Comptime | Done |
| 5 | File-based imports | Done |
| 6 | `?` operator | Done |
| 7 | Result operations | Done |
| 8 | Record type syntax | Planned |
| 9 | Generics | Planned |
| 10 | Traits/typeclasses | Planned |

### What's Done

- All core compiler infrastructure (lexer, parser, typechecker, codegen)
- HM type inference with let-polymorphism
- LLVM IR codegen with JIT and AOT modes
- Reference counting for heap-allocated objects
- Partial application (currying)
- File-based module imports with selective imports
- `?` operator for Result error propagation
- Result built-in operations (map, unwrap, fold, is_ok, is_err, and_then)
- Stack overflow detection
- Compile-time evaluation for literals and arithmetic
- LSP server with hover, completion, diagnostics
- REPL with pretty-printing

### What's Next

- Record type syntax with field access
- Generics (monomorphization)
- Traits/typeclasses
- Module system v2 (hierarchical imports, first-class modules)
- Package manager

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
