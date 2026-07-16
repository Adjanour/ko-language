# Article 5: Hindley-Milner Type Inference from Scratch

## Target Audience
PL researchers, compiler engineers, developers curious about type systems.

## Tone
Educational, precise, with working code. This is a "teach me" article.

## Word Count
4,000-5,000 words

## Structure

### Hook (200 words)
- Show a Kō function with no type annotations:
  ```ko
  fn map f xs = match xs
    | Cons x rest => Cons (f x) (map f rest)
    | Nil => Nil
  ```
- Show the inferred type: `(a -> b) -> List a -> List b`
- Promise: by the end, you'll understand exactly how this inference works

### The Problem: What Is Type Inference? (400 words)
- Type inference finds types without annotations
- The programmer writes code, the compiler figures out the types
- Hindley-Milner (HM) is the classic algorithm
- It finds principal types: the most general type that works
- Used by Haskell, OCaml, ML, and many others

### The Type System (600 words)

#### Types in Kō
- `Int`, `Float`, `Bool`, `Char`, `String`, `Unit` (primitive types)
- `a`, `b`, `c` (type variables — polymorphic)
- `List a`, `Maybe a`, `Result a b` (parameterized types)
- `a -> b` (function types)
- `(a, b)`, `{ x : Int, y : Int }` (tuples, records)

#### Type Schemes
- A type scheme is a type with quantified variables
- `forall a. a -> a` means "for any type a, takes a and returns a"
- Let-polymorphism: `let id = \x -> x` has type `forall a. a -> a`
- The `forall` is implicit in Kō

### The Algorithm: Algorithm W (800 words)

#### Step 1: Create Type Variables
- Every expression gets a fresh type variable
- `x` gets `?a`, `y` gets `?b`, `f x` gets `?c`
- Variables are placeholders for unknown types

#### Step 2: Generate Constraints
- Walk the AST, generate type equations
- `x : ?a` (x has type ?a)
- `f : ?b -> ?c` (f is a function from ?b to ?c)
- `f x : ?c` (f x has type ?c)
- `x : ?b` (the argument x must match f's parameter type)

#### Step 3: Unify Constraints
- Unification finds substitutions that satisfy all constraints
- `?a = Int`, `?b = Int`, `?c = Int` → `x : Int`, `f : Int -> Int`
- Unification is the engine of type inference

#### Step 4: Generalize
- After inference, generalize over unconstrained variables
- `id = \x -> x` → `forall a. a -> a`
- The `forall` is added at let-bindings (let-polymorphism)

### Unification in Detail (600 words)

#### What Is Unification?
- Given two types, find a substitution that makes them equal
- `?a` and `Int` → substitute ?a = Int
- `?a -> ?b` and `Int -> String` → ?a = Int, ?b = String
- `?a` and `?a` → already equal (no substitution)

#### The Occurs Check
- Before substituting ?a = T, check if ?a occurs in T
- `?a = ?a -> ?b` would create an infinite type
- The occurs check prevents this
- If ?a occurs in T, it's a type error

#### Unification Algorithm
```
unify(s, t):
  s = resolve(s)  // follow variable chain
  t = resolve(t)
  if s == t: return  // already equal
  if s is variable: s := t; return
  if t is variable: t := s; return
  if s is arrow and t is arrow:
    unify(s.from, t.from)
    unify(s.to, t.to)
    return
  if s is constructor and t is constructor:
    if s.name != t.name: error
    for each (s.arg, t.arg): unify(s.arg, t.arg)
    return
  error: type mismatch
```

### Let-Polymorphism (500 words)

#### The Problem
- `let id = \x -> x in (id 1, id True)`
- `id` is used at two different types: `Int -> Int` and `Bool -> Bool`
- Without polymorphism, `id` would have one type

#### The Solution
- At let-bindings, generalize over unconstrained variables
- `id : forall a. a -> a`
- Each use of `id` can instantiate `a` with a different type
- This is "let-polymorphism" or "value restriction"

#### The Value Restriction
- Only values can be generalized
- `let id = \x -> x` → generalized (it's a value)
- `let result = f x` → not generalized (it's an expression)
- This prevents soundness issues with mutation

### Kō's Implementation (600 words)

#### The Inferer Struct
```zig
const Inferer = struct {
    allocator: Allocator,
    global: Env,           // global type environment
    local: Env,            // local type environment
    expr_types: TypeMap,   // expression → type mapping
    next_var_id: usize,    // fresh variable counter
    errors: ErrorList,     // type errors
};
```

#### Generating Fresh Variables
```zig
fn newVarType(self: *Inferer) !*Type {
    const id = self.next_var_id;
    self.next_var_id += 1;
    const ty = try self.allocator.create(Type);
    ty.* = .{ .variable = .{ .id = id, .instance = null } };
    return ty;
}
```

#### Unification
```zig
fn unify(self: *Inferer, s: *Type, t: *Type) !void {
    const s_resolved = self.resolve(s);
    const t_resolved = self.resolve(t);
    if (s_resolved == t_resolved) return;
    switch (s_resolved.*) {
        .variable => |v| {
            if (self.occursIn(v.id, t_resolved)) return error.OccursCheck;
            v.instance = t_resolved;
        },
        .arrow => |a| {
            switch (t_resolved.*) {
                .arrow => |b| {
                    try self.unify(a.from, b.from);
                    try self.unify(a.to, b.to);
                },
                else => return error.TypeMismatch,
            }
        },
        // ... other cases
    }
}
```

#### Inference Rules

**Variable:**
```
Γ(x) = σ
---
Γ ⊢ x : instantiate(σ)
```

**Lambda:**
```
Γ, x:α ⊢ e : β
---
Γ ⊢ \x -> e : α -> β
```

**Application:**
```
Γ ⊢ f : α -> β    Γ ⊢ x : α
---
Γ ⊢ f x : β
```

**Let:**
```
Γ ⊢ e : α    Γ, x: generalize(α) ⊢ body : β
---
Γ ⊢ let x = e in body : β
```

### Error Messages (400 words)

#### The Problem
- Type errors are notoriously hard to understand
- "Expected Int, got String" is not helpful
- The programmer needs to know *why* the types don't match

#### Kō's Approach
- Track source locations for all expressions
- When unification fails, report the two types and their locations
- "Function `add` expects Int, but `name` is String (defined at line 5)"
- Future: suggest fixes, explain type variable instantiation

### Comparison to Other Algorithms (400 words)

#### Algorithm J (Hindley 1969)
- Similar to Algorithm W but less efficient
- Not used in practice

#### Algorithm M (Marché 2004)
- Monomorphic type inference
- More efficient, less powerful

#### Bidirectional Type Checking
- Used by TypeScript, Rust, Elm
- Requires some annotations
- More predictable than full inference

### Lessons Learned (300 words)
- The occurs check is essential for soundness
- Let-polymorphism is the key to generic code
- Type variables are the engine of inference
- Error messages are the hardest part
- Testing with the REPL is invaluable

### Conclusion (200 words)
- HM type inference is elegant and practical
- Algorithm W is straightforward to implement
- The hard part is error messages, not inference
- Kō's implementation is ~500 lines of Zig
- The result: full type inference with no annotations

---

## Key Code Snippets to Include

1. The type representation (Type union)
2. The Inferer struct
3. The unification algorithm
4. The inference rules
5. The generalize function
6. The error message generation

## Images/Diagrams
1. The type inference pipeline
2. The unification process (step by step)
3. The let-polymorphism example
4. The type variable substitution
5. The error message format

## Publishing Platforms
- Personal blog
- Reddit (r/ProgrammingLanguages, r/haskell, r/ocaml)
- Hacker News
- ACM Queue / SIGPLAN
- Lambda the Ultimate
