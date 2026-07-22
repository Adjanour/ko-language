# Kō Typechecker — How It Works

This document explains the type inference system in `src/typecheck.zig`, line by line where needed.

## Overview

The typechecker implements **Hindley-Milner type inference** — a well-known algorithm that lets you write code without type annotations and the compiler figures out all the types automatically. If something doesn't type-check, it tells you what went wrong.

**Pipeline position:**
```
Source code → Lexer → Parser → AST → Typechecker → (typed AST + environment) → Codegen → LLVM IR
```

The typechecker runs **before** code generation. It either succeeds (all types are consistent) or fails with an error like "type mismatch: expected Int, got Bool".

## Core Data Structures

### `Type` (line 5)

Every value in Kō has a type. The `Type` union represents all possible types:

```zig
pub const Type = union(enum) {
    variable: *TypeVar,              // unknown type (like 'a' in polymorphic functions)
    int,                             // Int — 64-bit integer
    float,                           // Float — 64-bit float
    bool,                            // Bool — true | false
    char,                            // Char — single character
    string,                          // String — UTF-8 text
    unit,                            // () — the unit type (like void)
    arrow: struct { from: *Type, to: *Type },  // function type: from -> to
    tuple: []const *Type,            // (A, B, C) — tuple of types
    con: struct { name: []const u8, args: []const *Type },  // constructed type: List Int
    record: struct { name: []const u8, fields: []const RecordFieldType },  // { x: Int, y: Int }
    @"ref": *Type,                   // Ref a — mutable reference
};
```

**Key insight:** Types are heap-allocated pointers. When the typechecker works with types, it works with `*Type` — pointers to type objects. This allows type variables to be "pointed at" other types during unification.

### `TypeVar` (line 20)

A type variable is an **unknown type placeholder** — like a blank in a puzzle:

```zig
pub const TypeVar = struct {
    id: usize,           // unique identifier
    name: []const u8,    // human-readable name (for error messages)
    instance: ?*Type = null,  // once resolved, points to the actual type
};
```

When you write `fn id x = x`, the compiler doesn't know what type `x` is. It creates a type variable `?0` (with `name = "a0"` or similar). Later, when `id` is used as `id 5`, unification sets `?0.instance = Int`, resolving the variable.

**The `instance` field is the heart of unification.** Once set, a variable "becomes" whatever it points to. The `resolve` function follows this chain:

```zig
pub fn resolve(self: *Inferer, ty: *Type) *Type {
    return switch (ty.*) {
        .variable => |v| blk: {
            if (v.instance) |inst| {
                const resolved = self.resolve(inst);  // follow the chain
                v.instance = resolved;                 // path compression
                break :blk resolved;
            }
            break :blk ty;  // no instance yet — still unknown
        },
        else => ty,  // concrete type — nothing to resolve
    };
}
```

### `Scheme` (line 31)

A scheme is a **polymorphic type** — a type with quantified variables:

```zig
pub const Scheme = struct {
    quantified: []const usize,  // which type variable IDs are polymorphic
    body: *Type,                // the actual type
};
```

Example: `fn id x = x` has scheme `∀a. a → a`. Here:
- `quantified = [0]` (variable ID 0 is polymorphic)
- `body = arrow(variable(0), variable(0))` (a → a)

When `id` is used at a call site, `instantiate` replaces the quantified variables with fresh type variables, allowing each use to have a different concrete type.

### `Env` (line 45)

The environment is a **scope chain** — a linked list of name-to-type-scheme mappings:

```zig
pub const Env = struct {
    allocator: std.mem.Allocator,
    parent: ?*Env,                      // enclosing scope
    bindings: std.StringHashMap(Scheme), // name → type scheme
};
```

When looking up a name, it checks the current scope first, then walks up to parents. This handles nested scopes (function parameters shadow outer bindings).

## The Algorithm: Step by Step

### 1. `inferProgram` (line 422) — Entry Point

This is the top-level function that typechecks an entire program:

```zig
pub fn inferProgram(self: *Inferer, program: *const parser.Program) Error!void {
    // Step 1: Register type definitions (type Bool = True | False)
    for (program.definitions) |def| {
        if (def == .type_def) try self.registerTypeDef(def);
    }

    // Step 2: Predeclare built-in functions
    try self.global.set("println", .{ .body = int_to_int });
    try self.global.set("print", .{ .body = int_to_int });

    // Step 3: Predeclare all user functions (for recursion)
    for (program.definitions) |def| {
        try self.predeclareDefinition(def);
    }

    // Step 4: Infer each definition in order
    for (program.definitions) |def| {
        try self.inferDefinition(def);
    }
}
```

**Why predeclare?** Functions can call each other recursively. `fn factorial n = if n == 0 then 1 else n * factorial (n - 1)` references `factorial` before it's fully inferred. Predeclaring gives it a type variable placeholder, so the reference resolves.

### 2. `predeclareDefinition` (line 477) — Give Functions a Starting Type

For a function with N parameters, create a type: `?0 -> ?1 -> ... -> ?N -> ?ret` where all `?i` are fresh type variables.

```zig
fn predeclareDefinition(self: *Inferer, def: parser.Definition) Error!void {
    switch (def) {
        .fn_def => |f| {
            // fn add x y → type: ?a -> ?b -> ?c
            const fn_type = try self.functionTypeFromParams(f.name, f.params.len);
            try self.global.set(f.name, .{ .quantified = &.{}, .body = fn_type });
        },
        // ...
    }
}
```

### 3. `inferDefinition` (line 509) — Infer a Single Definition

For `fn add x y = x + y`:

```zig
fn inferDefinition(self: *Inferer, def: parser.Definition) Error!void {
    switch (def) {
        .fn_def => |f| {
            // Get the predeclared type: ?a -> ?b -> ?c
            const scheme = self.global.getScheme(f.name);
            const fn_type = scheme.body;

            // Create local scope with parameters
            var local = Env.init(self.allocator, &self.global);
            for (f.params) |param| {
                // Add "x" : ?a, "y" : ?b to local scope
                local.set(param.name, .{ .body = param_type });
            }

            // Infer the body: x + y → Int
            const body_ty = try self.inferExpr(&local, f.body);

            // Unify return type with body type: ?c = Int
            try self.unify(cur, body_ty);

            // Generalize: make free variables polymorphic
            _ = self.global.bindings.remove(f.name);  // remove predeclared
            try self.global.set(f.name, try self.generalize(&self.global, fn_type));
        },
    }
}
```

### 4. `inferExpr` (line 646) — Infer an Expression's Type

This is the core recursive function. It returns the type of any expression:

```zig
fn inferExpr(self: *Inferer, env: *Env, expr: *const parser.Expr) Error!*Type {
    return switch (expr.*) {
        .int_literal => try self.newType(.int),           // 42 → Int
        .float_literal => try self.newType(.float),       // 3.14 → Float
        .bool_literal => try self.newType(.bool),         // true → Bool
        .string_literal => try self.newType(.string),     // "hi" → String
        .identifier => |name| blk: {
            // Look up in environment, instantiate (freshen polymorphic vars)
            const scheme = try self.resolveName(env, name);
            break :blk try self.instantiate(scheme);
        },
        .binary_op => |b| try self.inferBinary(env, b.op, b.left, b.right),
        .fn_call => |call| try self.inferCall(env, call.func, call.args),
        // ... etc for every expression variant
    };
}
```

### 5. `unify` (line 183) — The Heart of the System

`unify(a, b)` says "types a and b must be the same." It either succeeds (modifying type variables to make them match) or fails with a type error:

```zig
fn unify(self: *Inferer, left: *Type, right: *Type) Error!void {
    const a = self.resolve(left);  // follow variable chains
    const b = self.resolve(right);

    if (a == b) return;  // same pointer → already unified

    // If either is a variable, point it at the other
    switch (a.*) {
        .variable => |v| {
            if (self.occurs(v, b)) return error.OccursCheck;  // prevent infinite types
            v.instance = b;  // ← THIS IS WHERE UNIFICATION HAPPENS
            return;
        },
        else => {},
    }
    switch (b.*) {
        .variable => |v| {
            if (self.occurs(v, a)) return error.OccursCheck;
            v.instance = a;
            return;
        },
        else => {},
    }

    // Both concrete — check structural equality
    switch (a.*) {
        .int => if (b.* != .int) return error.TypeMismatch,
        .arrow => |aa| switch (b.*) {
            .arrow => |bb| {
                try self.unify(aa.from, bb.from);  // unify argument types
                try self.unify(aa.to, bb.to);       // unify return types
            },
            else => return error.TypeMismatch,
        },
        // ... etc for tuples, constructors, records
    }
}
```

**Example:** `unify(?a -> ?b, Int -> Bool)`
1. Both are `arrow` → unify `?a` with `Int`, unify `?b` with `Bool`
2. `unify(?a, Int)` → `?a.instance = Int`
3. `unify(?b, Bool)` → `?b.instance = Bool`
4. Result: `?a = Int, ?b = Bool` → the function type is `Int -> Bool`

### 6. `occurs` (line 155) — Prevent Infinite Types

The occurs check prevents circular types like `a = List a` (a list of itself). It checks if a type variable appears inside a type:

```zig
fn occurs(self: *Inferer, tv: *TypeVar, ty: *Type) bool {
    const resolved = self.resolve(ty);
    return switch (resolved.*) {
        .variable => |v| v.id == tv.id,  // found it!
        .arrow => |a| self.occurs(tv, a.from) or self.occurs(tv, a.to),
        .tuple => |items| for (items) |item| {
            if (self.occurs(tv, item)) break true;
        } else false,
        // ... etc
    };
}
```

### 7. `generalize` (line 294) — Make Variables Polymorphic

After inferring a function's type, `generalize` identifies which type variables are **free** (not bound in the environment) and makes them polymorphic:

```zig
fn generalize(self: *Inferer, env: *Env, ty: *Type) Error!Scheme {
    // Collect all free variables in the type
    var free_ty = collectFree(ty);

    // Collect all free variables in the environment
    var env_free = collectEnvFree(env);

    // Quantified = free in type BUT NOT in environment
    var quantified = free_ty - env_free;

    return .{ .quantified = quantified, .body = ty };
}
```

**Why exclude environment variables?** If `env` has `x : ?a`, and the type is `?a -> Int`, then `?a` is bound by the environment — it shouldn't be polymorphic. Only truly free variables become polymorphic.

### 8. `instantiate` (line 318) — Freshen Polymorphic Variables

When using a polymorphic function, `instantiate` replaces quantified variables with fresh type variables:

```zig
fn instantiate(self: *Inferer, scheme: Scheme) Error!*Type {
    if (scheme.quantified.len == 0) return scheme.body;  // monomorphic

    // Map each quantified variable to a fresh variable
    var map = AutoHashMap(usize, *Type);
    for (scheme.quantified) |qid| {
        const fresh = try self.newVarType(freshName("t"));
        map.put(qid, fresh);
    }

    // Clone the type, replacing quantified vars with fresh ones
    return self.cloneType(scheme.body, &map);
}
```

**Example:** `id : ∀a. a → a` used as `id 5`:
1. `instantiate` creates fresh variable `?t42`
2. Type becomes `?t42 → ?t42`
3. Call inference: `unify(?t42 → ?t42, ?t42 → Int)` → `?t42 = Int`
4. Result: `id 5 : Int`

## Key Inference Rules

### Binary Operations (`inferBinary`, line 738)

```zig
.add => {
    // String concatenation: "hi" + "lo" → String
    if (lt.* == .string or rt.* == .string) {
        try self.unify(lt, try self.newType(.string));
        try self.unify(rt, try self.newType(.string));
        return string;
    }
    // Integer addition: 1 + 2 → Int
    try self.unify(lt, try self.newType(.int));
    try self.unify(rt, try self.newType(.int));
    return int;
},
.eq, .neq, .lt, .lte, .gt, .gte => {
    // Comparisons: a == b → Bool (a and b must be the same type)
    try self.unify(lt, rt);
    return bool;
},
```

### Function Calls (`inferCall`, line 772)

For `f x y` where `f : A -> B -> C`:
1. Infer type of `f` → `?a -> ?b -> ?c`
2. Infer type of `x` → `?x`
3. Infer type of `y` → `?y`
4. Unify: `?a -> ?b -> ?c = ?x -> ?y -> ?ret`
5. Result: `?ret`

```zig
fn inferCall(self: *Inferer, env: *Env, func: *parser.Expr, args: []const *parser.Expr) Error!*Type {
    const fn_ty = try self.inferExpr(env, func);
    const expected = try self.newVarType(freshName("ret"));

    // Build expected type: arg1 -> arg2 -> ... -> ret
    var chain = expected;
    var i = args.len;
    while (i > 0) : (i -= 1) {
        const arg_ty = try self.newVarType(freshName("arg"));
        chain = try self.newType(.{ .arrow = .{ .from = arg_ty, .to = chain } });
    }

    // Unify function type with expected chain
    try self.unify(fn_ty, chain);

    // Infer each argument and unify with expected param type
    for (args, 0..) |arg, idx| {
        const arg_ty = try self.inferExpr(env, arg);
        try self.unify(arg_tys[idx], arg_ty);
    }

    return expected;
}
```

### Lambda (`inferLambda`, line 796)

For `\x y -> x + y`:
1. Create fresh type for each param: `?a`, `?b`
2. Add params to local scope
3. Infer body: `x + y` → `Int`
4. Build type: `?a -> ?b -> Int`

### Match Expressions (`inferMatch`, line 891)

```zig
fn inferMatch(self: *Inferer, env: *Env, value: *parser.Expr, arms: []const parser.MatchArm) Error!*Type {
    // Infer the scrutinee type
    const scrutinee_ty = try self.inferExpr(env, value);

    var result_ty: ?*Type = null;
    for (arms) |arm| {
        // Create arm scope, bind pattern variables
        var arm_env = Env.init(self.allocator, env);
        try self.inferPattern(&arm_env, arm.pattern, scrutinee_ty);

        // Infer arm body
        const body_ty = try self.inferExpr(&arm_env, arm.body);

        // All arms must return the same type
        if (result_ty) |prev| {
            try self.unify(prev, body_ty);
        } else {
            result_ty = body_ty;
        }
    }
    return result_ty orelse unit;
}
```

### Pattern Matching (`inferPattern`, line 910)

Patterns bind variables and constrain types:

```zig
fn inferPatternBindings(self: *Inferer, bindings: *std.ArrayList(PatternBinding), pat: parser.Pattern, expected: *Type) Error!void {
    switch (pat) {
        .wildcard => {},  // _ — no binding, no constraint
        .identifier => |name| try bindings.append(.{ .name = name, .ty = expected }),
        .constructor => |ctor| {
            // Look up constructor: Cons : a -> List a -> List a
            const info = self.ctors.get(ctor.name);
            // Unify expected type with constructor's result type
            try self.unify(expected, con(info.type_name, type_args));
            // Recurse into constructor arguments
            for (ctor.args, arg_types) |sub_pat, arg_ty| {
                try self.inferPatternBindings(bindings, sub_pat, arg_ty);
            }
        },
        // ...
    }
}
```

## Type Definitions (`registerTypeDef`, line 567)

For `type List a = Cons a (List a) | Nil`:

1. Register type name: `type_names["List"] = 1` (1 type parameter)
2. For each constructor, create its type:
   - `Cons : ∀a. a → List a → List a`
   - `Nil : ∀a. List a`
3. Store in `ctors` map for pattern matching

```zig
fn registerTypeDef(self: *Inferer, t: parser.TypeDef) Error!void {
    try self.type_names.put(t.name, t.type_params.len);

    for (ctors) |ctor| {
        // Build type: arg1 -> arg2 -> ... -> TypeName args
        var fn_type = result;
        for (ctor.params) |param| {
            const arg_var = try self.newVarType(freshName(ctor.name));
            fn_type = arrow(arg_var, fn_type);
        }

        // Register constructor with its type scheme
        try self.ctors.put(ctor.name, .{ .type_name = t.name, .arity = ctor.params.len });
        try self.global.set(ctor.name, .{ .quantified = quantified, .body = fn_type });
    }
}
```

## Type Annotations

When the programmer writes `fn double x : Int = x + x`, the `: Int` is a **return type annotation**. The typechecker:

1. Infers the function type normally
2. Converts the annotation to a `Type`
3. Unifies the inferred return type with the annotation

```zig
if (f.return_type) |ann| {
    const ann_ty = try self.typeExprToType(ann);
    try self.unify(cur, ann_ty);  // cur is the return type position
}
```

This lets you constrain polymorphic functions: `fn identity (x : Int) : Int = x` forces `Int -> Int` instead of `∀a. a → a`.

## Error Reporting

When `unify` fails, it creates an `ErrorContext` with human-readable messages:

```zig
self.last_error = .{
    .message = "type mismatch: expected Int, got Bool",
    .expected = "Int",
    .actual = "Bool",
};
```

The `typeToString` function (line 1040) converts internal types to readable strings, using quantified variable names (a, b, c) for polymorphic types.

## Summary

| Step | What happens |
|------|-------------|
| Predeclare | Give all functions placeholder types: `?a -> ?b -> ...` |
| Infer | Walk the AST, creating type variables and unifying as we go |
| Unify | Say "these two types must be the same" — point variables at concrete types |
| Generalize | After inferring a function, make free variables polymorphic |
| Instantiate | When using a polymorphic function, freshen its variables for this use |

---

## See Also

- [Codegen](CODEGEN.md) — how LLVM IR generation works
- [Handbook](HANDBOOK.md) — how to add features to the compiler
- [Theory](THEORY.md) — theoretical foundations and references
- [Status](STATUS.md) — current state and completed work
