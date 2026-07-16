# Type Inference Without Annotations

The best thing about Haskell is that you don't have to write type annotations. You write `fn add x y = x + y` and the compiler figures out it's `Int -> Int -> Int`. You write `fn map f xs = ...` and the compiler figures out it's `(a -> b) -> List a -> List b`. The inference just works.

This is Hindley-Milner type inference. It's been around since the 1970s. It's the algorithm that Haskell, OCaml, ML, and their relatives use. It finds principal types — the most general type that works — without requiring any type annotations from the programmer.

Kō uses Hindley-Milner type inference. I implemented it from scratch, and it's one of my favorite parts of the compiler. It's elegant, it's practical, and it's surprisingly straightforward to implement.

---

The type system is small. Primitive types: Int, Float, Bool, Char, String, Unit. Type variables: a, b, c (polymorphic — can be any type). Parameterized types: List a, Maybe a, Result a b. Function types: a -> b. Tuples: (a, b). Records: { x : Int, y : Int }.

A type scheme is a type with quantified variables. `forall a. a -> a` means "for any type a, takes a and returns a." The `forall` is implicit in Kō — you don't write it. The compiler adds it automatically at let-bindings.

This is let-polymorphism. When you write `let id = \x -> x`, the compiler infers `forall a. a -> a`. Each use of `id` can instantiate `a` with a different type. `id 1` works. `id True` works. `id "hello"` works. The same function, different types, no annotations.

---

Algorithm W is the engine. It works in four steps.

First, create type variables. Every expression gets a fresh type variable. `x` gets `?a`, `y` gets `?b`, `f x` gets `?c`. Variables are placeholders for unknown types.

Second, generate constraints. Walk the AST, generate type equations. `x : ?a` means x has type ?a. `f : ?b -> ?c` means f is a function from ?b to ?c. `f x : ?c` means f x has type ?c. `x : ?b` means the argument x must match f's parameter type.

Third, unify constraints. Unification finds substitutions that satisfy all constraints. `?a = Int` means substitute Int for ?a everywhere. `?a -> ?b = Int -> String` means ?a = Int and ?b = String. Unification is the engine of type inference.

Fourth, generalize. After inference, generalize over unconstrained variables. `let id = \x -> x` becomes `forall a. a -> a`. The `forall` is added at let-bindings. This is let-polymorphism.

---

Unification is the hard part. It's the algorithm that makes type inference work.

Given two types, find a substitution that makes them equal. `?a` and `Int` → substitute ?a = Int. `?a -> ?b` and `Int -> String` → ?a = Int, ?b = String. `?a` and `?a` → already equal, no substitution needed.

The occurs check prevents infinite types. Before substituting ?a = T, check if ?a occurs in T. If it does, the type would be infinite: `?a = ?a -> ?b`. This is a type error. The occurs check catches it.

The unification algorithm is recursive. For arrow types, unify the from-types and the to-types. For constructor types, unify the names and the arguments. For variables, substitute.

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

It's straightforward. The complexity is in the details — handling nested types, following variable chains, catching infinite types. But the algorithm itself is simple.

---

Let-polymorphism is what makes generic code work.

Without let-polymorphism, `let id = \x -> x` would have type `?a -> ?a`. Every use of `id` would instantiate `?a` with the same type. `id 1` would fix `?a = Int`. `id True` would fail because `?a` is already `Int`.

With let-polymorphism, `id` has type `forall a. a -> a`. Each use of `id` can instantiate `a` with a different type. `id 1` works. `id True` works. `id "hello"` works. The same function, different types.

The key insight is that the `forall` is added at let-bindings, not at lambda abstractions. `let id = \x -> x` generalizes over `a`. `\x -> x` does not. This is the value restriction — only values can be generalized.

The value restriction prevents soundness issues with mutation. Without it, `let r = ref 0; let f = \x -> !r + x` would generalize `f` to `forall a. Int -> Int`. But `r` is mutable — changing `r` would change the behavior of `f`. The value restriction prevents this by not generalizing `f`.

---

Kō's implementation is about 500 lines of Zig.

The Inferer struct holds the state: the global type environment, the local type environment, a map from expressions to types, a counter for fresh variables, and a list of errors.

Generating fresh variables is simple. Increment the counter, create a new type variable with that ID. Each variable gets a unique ID, so there are no collisions.

Unification follows the algorithm above. Resolve both types, check if they're equal, check if one is a variable, check if both are arrows or constructors, unify recursively. The occurs check prevents infinite types.

Generalization happens at let-bindings. After inferring the type of the bound expression, collect all unconstrained variables. Wrap them in `forall`. Store the type scheme in the environment.

Instantiation happens at variable lookup. When you look up a variable, instantiate its type scheme with fresh variables. `forall a. a -> a` becomes `?b -> ?b` with a fresh variable `?b`. This ensures that different uses of the same variable don't interfere.

---

The inference rules are mathematical, but the implementation is practical.

For variables, look up the type scheme in the environment, instantiate with fresh variables.

For lambdas, create a fresh variable for the parameter, infer the body type with the parameter in scope, the result is parameter type → body type.

For applications, infer the function type, infer the argument type, unify the function's parameter type with the argument type, the result is the function's return type.

For let-bindings, infer the bound expression type, generalize, add to environment, infer the body type.

For match expressions, infer the scrutinee type, for each arm, pattern match and bind variables, infer the arm body type, unify all arm body types.

Each rule is simple. The complexity is in putting them together — handling recursive types, mutual recursion, nested expressions, and all the edge cases that come up in real code.

---

Error messages are the hardest part. Type inference works, but explaining *why* a type error occurred is hard.

The basic approach: when unification fails, report the two types and their locations. "Expected Int, got String." This is helpful but not sufficient. The programmer needs to know *why* the types don't match.

Kō tracks source locations for all expressions. When a type error occurs, it reports the two types, their locations, and a brief explanation. "Function `add` expects Int, but `name` is String (defined at line 5)."

This is better than most compilers, but it's not good enough. The ideal error message would explain the chain of inference that led to the error. "Function `add` expects Int because it's called with `1` at line 3, which is inferred as Int. But `name` is String because it's defined as a string literal at line 5. The conflict is at line 7 where `add` is called with `name`."

That's future work. For now, Kō's error messages are functional but not friendly.

---

Bidirectional type checking is an alternative to full inference. It requires some annotations but is more predictable. TypeScript, Rust, and Elm use this approach.

Algorithm J is similar to Algorithm W but less efficient. It's not used in practice.

Algorithm M is a monomorphic variant. More efficient, less powerful. Useful for languages without let-polymorphism.

HM with extensions adds features like GADTs, type families, and higher-kinded types. These make the type system more powerful but also more complex. Kō keeps it simple — vanilla HM with let-polymorphism.

---

Type inference is elegant and practical. Algorithm W is straightforward to implement. The hard part is error messages, not inference. Kō's implementation is about 500 lines of Zig.

The result is full type inference with no annotations. You write code, the compiler figures out the types. If something goes wrong, it tells you what went wrong. It's not perfect, but it's good enough.

The best thing about type inference is that it makes code shorter. No type annotations means less boilerplate. Less boilerplate means more readable code. More readable code means easier maintenance.

Kō's type inference is one of its best features. It makes the language feel lightweight and easy to use. You write what you mean, and the compiler figures out the rest.

---

*Kō (光) means "light" in Japanese. Type inference is how Kō understands your code — without you having to explain it.*
