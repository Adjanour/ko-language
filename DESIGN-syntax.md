# Kō Syntax Design Decisions

> Rationale, tradeoffs, and frozen decisions for every syntax choice in Kō.

---

## 1. Overview

This document records every syntax decision in Kō, why it was made, what alternatives were considered, and what was rejected. It exists so that future contributors understand not just *what* the syntax is, but *why* it is that way.

**Decision process:**
1. Identify the problem (what syntax do we need?)
2. Research how other languages solve it
3. List tradeoffs
4. Choose based on Kō's design goals: simplicity, readability, mechanical sympathy
5. Freeze the decision

**Design goals driving syntax:**
- **Familiarity**: Borrow from C, Python, Haskell, ML — don't invent new symbols
- **Readability**: Code should read like prose where possible
- **Simplicity**: The grammar should fit on a page
- **No ambiguity**: One way to write each construct

---

## 2. Core Syntax Choices

### 2.1 Keywords

| Construct | Choice | Alternatives | Source | Rationale |
|-----------|--------|-------------|--------|-----------|
| Function | `fn` | `fun`, `def`, `function` | C/Go | Short, familiar to imperative programmers. `fun` is Haskell-ish but uncommon in systems languages. `def` is Python but conflicts with "define" generically. |
| Let binding | `let` | `var`, `const`, `val`, `:=` | Haskell/ML | Functional standard. `var`/`const` imply mutation. `val` is OCaml but less known outside ML. |
| Type definition | `type` | `data`, `enum`, `adt`, `newtype` | Haskell | `data` is Haskell-specific. `type` is lighter and more general. `enum` implies C-style enums only. |
| Match | `match` | `case`, `switch`, `select` | Haskell/ML | `case` is Haskell but used in C `switch`. `switch` implies imperative. `match` is unambiguous. |
| If | `if`/`then`/`else` | `if`/`{}`/`else`, `when`/`else` | Haskell/Python | `then`/`else` makes the expression nature explicit. No braces needed. |
| Lambda | `\` | `λ`, `fn`, `fun`, `lam` | Haskell | `\` is ASCII-standard for lambda (from `\lambda`). `λ` is Unicode. `fn` conflicts with function definition. |
| Import | `import` | `use`, `require`, `open` | C/Python/OCaml | `import` is the most universal. `use` is Rust but ambiguous. `require` is Ruby/JS. |
| Public | `pub` | `public`, `export`, `open` | Rust | Short, unambiguous. `export` implies JavaScript module semantics. |
| Reference | `ref` | `&`, `new`, `box` | OCaml/Rust | `ref` is explicit. `&` reserved for borrows (Phase 2). `new` implies constructor. |
| Comptime | `comptime` | `const`, `eval`, `static` | Zig | Direct from Zig — compile-time evaluation. `const` is overloading. `eval` implies Lisp. |
| Boolean negation | `not` | `!`, `-`, `~` | Python/Haskell | `!` is reserved for deref (C convention). `-` is arithmetic negation. `~` is bitwise in C. |
| Boolean and | `and` / `&&` | `&`, `&&`, `and` | Python/C | Both forms supported. `&&` for C programmers. `and` for readability. |
| Boolean or | `or` / `\|\|` | `\|`, `\|\|`, `or` | Python/C | Both forms supported. Same rationale as `and`. |

### 2.2 Operators

| Operator | Meaning | Alternatives | Rationale |
|----------|---------|-------------|-----------|
| `+` `-` `*` `/` `%` | Arithmetic | Same everywhere | Universal. No reason to change. |
| `==` `!=` `<` `>` `<=` `>=` | Comparison | Same everywhere | Universal. |
| `=` | Binding | `:=`, `<-`, `let` | `=` for bindings is Haskell/ML standard. `:=` reserved for mutation. |
| `:=` | Mutation | `=`, `<-`, `set!` | `=` is bindings. `<-` is imperative. `set!` is Lisp. `:=` is unambiguous. |
| `\|>` | Pipe | `>>`, `.`, `\|>` | F#/OCaml pipe. Reads left-to-right: `x \|> f \|> g`. `>>` is composition. `.` is field access. |
| `::` | Cons / infix constructor | `:`, `::`, `.` | `:` reserved for type annotations. `::` is OCaml cons. `.` is field access. |
| `->` | Function type arrow | `→`, `=>`, `:` | ASCII `->` is standard across ML/Haskell. `→` is Unicode. `=>` is match arms. |
| `=>` | Match arm separator | `->`, `\|>`, `:` | `->` is type arrows. `=>` is visually distinct and standard in Rust/Swift. |
| `!` | Deref | `*`, `deref`, `.!` | `*` conflicts with multiplication. `deref` is verbose. `!` is compact and unambiguous. |
| `#` | Comment | `//`, `/* */`, `--` | Python-style. Simpler than nested `/* */`. `--` is Haskell but looks like operator. |
| `..` | Record spread | `...`, `..` | `..` is Rust/JS. `...` is range in some languages. |
| `~` | Named argument prefix | `~name:expr`, `name:expr` | `~` prevents collision with identifiers. `name:expr` without prefix is ambiguous with record fields. |

---

## 3. Structural Syntax (Block System)

### 3.1 Indentation-Based Blocks

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Block delimiter | Indentation | `{}` braces, `begin/end` | Python-inspired. Forces readable formatting. No visual clutter. |
| Indent width | 2-space | 4-space, tabs | Compact. Matches most functional languages (OCaml, Haskell). |
| Indent unit | spaces | tabs | Tabs render differently across editors. Spaces are consistent. |

**Grammar:**
```ebnf
block           = NEWLINE INDENT { statement NEWLINE } DEDENT ;
```

**Tradeoffs:**
- **+** Forces readable code — can't nest deeply without noticing
- **+** No visual clutter from braces
- **-** Fragile to indentation errors (but the parser gives clear errors)
- **-** Can't have mixed indent levels (but Kō doesn't need them)

### 3.2 Statement Termination

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Statement separator | Newline | `;`, `,`, `\n` | Python/Ruby convention. No semicolons. |

**Tradeoffs:**
- **+** Clean syntax, no noise
- **-** Requires careful line continuation (but `\|>` pipe and indentation handle most cases)

---

## 4. Function Definition Syntax

This is the most significant syntax decision in Kō v0.3.0. It affects every function definition in the language.

### 4.1 The Design Space

Function definitions need to express:
1. **Name** — what the function is called
2. **Parameters** — what it takes (possibly typed)
3. **Return type** — what it returns (possibly typed)
4. **Body** — the implementation

The question is how to arrange these, and how to handle the type annotations.

### 4.2 Alternatives Considered

| Syntax | Example | Source | Pros | Cons |
|--------|---------|--------|------|------|
| Haskell | `fn id :: a -> a; id x = x` | Haskell | Familiar to Haskellers | Two lines, verbose |
| OCaml | `let id (x : a) : a = x` | OCaml | Compact | `let` overloading with bindings |
| Rust | `fn id<T>(x: T) -> T { x }` | Rust | Explicit generics | Verbose, braces, `<T>` noise |
| Python | `def id(x: a) -> a:` | Python | Readable | `def` not `fn`, colon not `=` |
| Old Kō (v0.2.x) | `fn id x : a -> a = x` | Kō | Compact | Ambiguous: is `x : a -> a` a type? |
| **New Kō (v0.3.0)** | `fn id (x : a) -> a = x` | Kō | Clear, unambiguous | Parentheses required for typed params |

### 4.3 Chosen Syntax

```ebnf
fn_def          = "fn" IDENT param* [ "->" type_expr ] "=" body ;
param           = IDENT
                | "(" IDENT ":" type_expr ")" ;
```

**Rules:**
- **Untyped params**: bare identifiers — `fn f x y = ...`
- **Typed params**: parenthesized — `fn f (x : Int) (y : String) = ...`
- **Return type**: `->` after all params — `fn f x -> Int = ...`
- **Mixed**: untyped and typed params can mix — `fn f (x : Int) y = ...`
- **No return type**: body type is inferred — `fn f x = x`
- **Public functions**: signature mandatory — `pub fn f (x : Int) -> Int = x + 1`
- **Private functions**: signature optional — `fn f x = x + 1`

**Examples:**
```ko
# Untyped (unchanged from v0.2.x)
fn id x = x
fn add x y = x + y

# Typed params with return type
fn id (x : a) -> a = x
fn add (x : Int) (y : Int) -> Int = x + y

# Mixed typed and untyped
fn add_then_show (x : Int) y = x + y

# Multi-param typed
fn map (f : a -> b) (xs : List a) -> List b =
  match xs
    Cons h t -> Cons (f h) (map f t)
    Nil -> Nil

# Public with mandatory signature
pub fn process (x : Request) -> Response = ...
```

### 4.4 Rationale

**Why `(x : Type)` instead of `x : Type`?**

The old syntax `fn id x : a -> a = x` was ambiguous:
- Is `x : a -> a` a typed parameter `x` with type `a -> a`?
- Or is it an untyped parameter `x` with return type `a -> a`?

The answer was "return type" (the old convention), but it reads oddly: the type annotation comes after the parameter name, detached from what it describes.

Parentheses solve this:
- `(x : Int)` — a typed parameter, clearly delimited
- `x` — an untyped parameter, no noise
- `-> Int` — a return type, visually separate from params

**Why `->` instead of `:` for return type?**

`:` is overloaded in Kō:
- Type annotations: `x : Int`
- Record field types: `{ name : String }`
- Named arguments: `~name:expr`

Using `:` for return types would create ambiguity:
```ko
# Is this a function returning Int, or a parameter named "Int"?
fn f x : Int = x + 1
```

`->` is unambiguous and standard across ML/Haskell.

**Why parentheses required for typed params?**

Without parentheses, `fn f x : Int y = ...` is ambiguous:
- Is `x : Int` a typed param?
- Or is `: Int y` something else?

Parentheses make the intent clear:
```ko
fn f (x : Int) y = ...    # x is typed, y is untyped
fn f (x : Int) (y : Int) = ...  # both typed
```

### 4.5 What Changed from Old Syntax

| Old (v0.2.x) | New (v0.3.0) | Why |
|---------------|-------------|-----|
| `fn id x : a -> a = x` | `fn id (x : a) -> a = x` | Clearer, unambiguous |
| `fn add x y : Int -> Int -> Int = x + y` | `fn add (x : Int) (y : Int) -> Int = x + y` | Each param typed separately |
| `fn map f : (a -> b) -> List a -> List b = ...` | `fn map (f : a -> b) (xs : List a) -> List b = ...` | Each param typed separately |
| `fn main : () -> () = ...` | `fn main -> () = ...` | No params, just return type |
| `fn swap pair : (a * b) -> (b * a) = ...` | `fn swap (pair : a * b) -> b * a = ...` | Clearer |

**Untyped functions are unchanged:**
```ko
# These are identical in v0.2.x and v0.3.0
fn id x = x
fn add x y = x + y
fn map f xs = ...
```

### 4.6 Migration Notes

For existing code:
1. **Untyped functions**: no change needed
2. **Functions with return type only**: change `: Type` to `-> Type` after params
3. **Functions with typed params**: wrap each typed param in `()`
4. **Functions with full signature**: split into individual typed params + return type

```bash
# Quick migration pattern:
# Old: fn name param1 param2 : Type1 -> Type2 -> RetType = body
# New: fn name (param1 : Type1) (param2 : Type2) -> RetType = body
```

---

## 5. Expression Syntax

### 5.1 Function Application

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Application | Implicit | `f(x)`, `f x`, `f[x]` | Haskell/ML standard. No parentheses noise. |

```ko
add 1 2          # NOT add(1, 2)
map (\x -> x * 2) xs   # parentheses only for grouping
```

**Tradeoffs:**
- **+** Clean, no noise
- **+** Composes naturally: `map f (filter p xs)`
- **-** Can be ambiguous in complex expressions (but parentheses resolve it)

### 5.2 Tuples

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Tuple value | `(a, b)` | `{a, b}`, `[a, b]` | Standard ML convention |
| Tuple type | `(a, b)` | `a * b`, `a × b` | Matches value syntax |
| Tuple pattern | `(a, b)` | `{a, b}`, `[a, b]` | Matches value syntax |
| Tuple access | `t.0`, `t.1` | `fst t`, `snd t`, `t[0]` | Dot notation is compact |

```ko
let pair = (1, "hello")    # value
let (x, y) = pair          # pattern
(pair.0, pair.1)           # access
```

### 5.3 Records

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Record type | `{ name : String, age : Int }` | `{ name: String, age: Int }`, `struct { ... }` | `:` for type annotations, consistent |
| Record value | `{ name = "Alice", age = 30 }` | `{ name: "Alice", age: 30 }` | `=` for bindings, `:` for types |
| Record pattern | `{ name = n, age = a }` | `{ name: n, age: a }` | `=` for bindings |
| Record spread | `{ ..other, name = "Bob" }` | `{ ...other, name = "Bob" }` | `..` is compact |

```ko
type Person = { name : String, age : Int }

let alice = { name = "Alice", age = 30 }
let { name = n, age = a } = alice
```

**Key distinction:** `=` for value bindings, `:` for type annotations. This is consistent across the language.

### 5.4 Lambdas

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Lambda syntax | `\x -> expr` | `fn x => expr`, `\x. expr`, `λx → expr` | Haskell convention. `\` is ASCII. |

```ko
\x -> x * 2
\x y -> x + y
\ (x : Int) -> x * 2    # typed lambda (future)
```

### 5.5 If/Then/Else

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| If expression | `if e then e else e` | `if (e) { e } else { e }`, `e ? e : c` | Expression-oriented. No braces needed. |

```ko
if x > 0 then x else -x
if cond then "yes" else "no"
```

**Note:** `else` is optional (defaults to `()` / Unit).

### 5.6 String Interpolation

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Interpolation | `"${expr}"` | `s"expr"`, `f"expr"`, `#{expr}` | JavaScript-adjacent. Familiar. |

```ko
"Hello, ${name}!"
"Sum: ${Int.toString (a + b)}"
```

### 5.7 Mutation

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Assignment | `:=` | `=`, `<-`, `set!` | `=` is bindings. `:=` is unambiguous mutation. |
| Deref | `!expr` | `*expr`, `deref expr` | `*` is multiplication. `!` is compact. |
| Ref creation | `ref expr` | `&expr`, `new ref expr` | `&` reserved for borrows (Phase 2). |

```ko
let counter = ref 0
counter := !counter + 1
```

---

## 6. Type Syntax

### 6.1 Arrow Types

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Function type | `a -> b` | `a → b`, `a => b`, `(a) -> b` | ASCII `->` is standard across ML/Haskell |

```ko
Int -> Int                    # function from Int to Int
a -> b -> c                   # curried
(a -> b) -> List a -> List b  # higher-order
```

### 6.2 Tuple Types

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Tuple type | `(a, b)` | `a * b`, `a × b` | Matches value syntax |

```ko
(Int, String)       # pair
(Int, Int, Int)     # triple
```

### 6.3 Reference Types

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Ref type | `ref T` | `&T`, `Rc<T>`, `Ref T` | Explicit. `&` reserved for borrows. |

```ko
ref Int            # reference-counted integer
ref (List a)       # reference-counted list
```

### 6.4 Type Variables

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Type variables | Lowercase identifiers | `'a`, `'α`, `α`, `?a` | Simpler than OCaml tick-variables. No special syntax needed. |

```ko
fn id (x : a) -> a = x           # a is a type variable
fn map (f : a -> b) (xs : List a) -> List b = ...  # a, b are type variables
```

**Convention:** Type variables are lowercase single letters (a, b, c, t, etc.). Type constructors are capitalized (Int, List, Maybe, etc.).

### 6.5 Parameterized Types

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Parameterized types | `List a` | `List<a>`, `'a list`, `list a` | Haskell convention. No angle brackets. |

```ko
List Int              # NOT List<Int>
Maybe String          # NOT Maybe<String>
Result Error Response # NOT Result<Error, Response>
```

### 6.6 ADT Definition

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Type definition | `type Name = ...` | `data Name = ...`, `enum Name = ...` | `type` is general |
| Type parameters | Before `=` | After name, `type Name a = ...` | `type List a = Cons a (List a) | Nil` |
| Constructor params | Individual type primaries | Applied types, tuples | `Cons a (List a)` not `Cons (a, List a)` |

```ko
type Maybe a = Just a | Nothing
type List a = Cons a (List a) | Nil
type Tree a = Node (Tree a) a (Tree a) | Leaf
type Result e a = Ok a | Err e
```

---

## 7. Pattern Syntax

### 7.1 Basic Patterns

| Pattern | Syntax | Example | Rationale |
|---------|--------|---------|-----------|
| Wildcard | `_` | `match x _ -> 0` | Standard across ML/Haskell |
| Binding | `name` | `match x y -> y + 1` | Identifier binds the value |
| Literal | value | `match x 42 -> "yes"` | Direct comparison |
| Constructor | `Ctor arg...` | `match x Just v -> v` | Consistent with expression syntax |

### 7.2 Compound Patterns

| Pattern | Syntax | Example | Rationale |
|---------|--------|---------|-----------|
| Tuple | `(a, b)` | `match p (x, y) -> x + y` | Matches value syntax |
| Record | `Ctor { field = pat }` | `match r Person { name = n } -> n` | Matches record syntax |
| Infix cons | `::` | `match xs x :: rest -> ...` | OCaml convention. `:` reserved for types. |
| Or | `\|` | `match x 0 \| 1 -> "small"` | Standard |
| Nested | `Ctor (Ctor v)` | `match x Just (Just v) -> v` | Recursive destructuring |

```ko
match xs
  Nil -> 0
  Cons x Nil -> x
  Cons x (Cons y rest) -> x + y

match point
  (0, 0) -> "origin"
  (x, 0) -> "on x-axis"
  (x, y) -> "at (${Int.toString x}, ${Int.toString y})"
```

### 7.3 Guard Patterns

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| Guards | Not implemented | `pat when expr`, `pat if expr` | Deferred — complexity vs benefit in v0.1 |

Guards can be simulated with nested `if`:
```ko
match x
  n -> if n > 0 then "positive" else "non-positive"
```

---

## 8. Frozen Syntax

These forms are frozen and must not change before the parser port unless a bug forces it. Documented in `AGENTS.md` and reproduced here for completeness.

### 8.1 Lexer Tokens

| Token | Syntax | Rationale |
|-------|--------|-----------|
| Wildcard | `_` | Standard, unambiguous |
| Hyphenated identifiers | `map-maybe`, `is-empty` | Kō convention for multi-word names |
| Numeric literals | `42`, `0xFF`, `0b1010`, `0o77` | Standard bases |
| Comments | `# line` | Python-style, simple |
| Named args | `~name:expr` | Prevents collision with identifiers |

### 8.2 Parser Forms

| Form | Syntax | Rationale |
|------|--------|-----------|
| Match arm | `=>` (NOT `->`) | `->` reserved for type arrows |
| Deref | `!expr` (NOT boolean negation) | `not expr` for boolean |
| Boolean negation | `not expr` | `!` is deref |
| Reference creation | `ref expr` | `&` reserved for borrows |
| Reference type | `ref T` | Explicit, no confusion with borrows |
| Assignment | `:=` | `=` is bindings |
| Infix constructor | `::` | `:` is type annotations |
| Pipe | `\|>` | Left-to-right composition |
| Record spread | `..` in patterns | Compact |
| Braces | Records only | Blocks are indentation-based |

### 8.3 Type Definition Syntax

| Form | Syntax | Rationale |
|------|--------|-----------|
| Type params | Before `=`: `type List a = ...` | Clear, readable |
| Constructor params | Individual type primaries | `Cons a (List a)` not `Cons (a, List a)` |

### 8.4 Function Definition Syntax

| Form | Syntax | Rationale |
|------|--------|-----------|
| Typed param | `(x : Type)` | Parentheses delimit, prevent ambiguity |
| Return type | `-> Type` after params | `:` overloaded, `->` unambiguous |
| Untyped param | Bare identifier | Minimal noise |

---

## 9. Known Parser Limitations

### 9.1 `parse_type_atom` Greedy Consumption

**Bug:** `parse_type_atom` consumes any identifier as a type application, even when the identifier is not a type constructor.

**Impact:** In expressions like `fn f (x : Int) y = ...`, the parser may try to parse `y` as part of a type expression rather than as an untyped parameter.

**Root cause:** `parse_type_atom` is greedy — it consumes `IDENT type_atom*` without checking whether the identifier is a known type constructor.

**Current behavior:**
```ko
fn f (x : Int) y = x + y
# Parser sees: (x : Int) -> typed param ✓
# Parser sees: y -> untyped param ✓
# This works because `)` terminates the typed param

fn f (x : Int -> String) y = ...
# Parser sees: (x : Int -> String) -> typed param with function type ✓
# Parser sees: y -> untyped param ✓
```

**The limitation is theoretical, not practical** — the current implementation works because:
1. Typed params are delimited by `()`
2. The `)` terminates the param before `parse_type_atom` can over-consume
3. Untyped params are bare identifiers that don't trigger type parsing

**How to fix it (if needed in the future):**
1. Maintain a set of known type constructors (registered during parsing of `type` definitions)
2. In `parse_type_atom`, only consume `IDENT` as a type application if the identifier is in the known type set
3. Otherwise, treat the identifier as a value identifier and let the caller handle it

**This fix is not needed now** because the current syntax design avoids the ambiguity by design.

### 9.2 `let` Bindings Don't Support Typed Param Syntax

**Limitation:** The `(param : type)` syntax only works in `fn` definitions, not in `let` bindings.

```ko
# Works:
fn id (x : a) -> a = x

# Doesn't work:
let id (x : a) = x    # Parser error

# Workaround:
let id = \(x : a) -> x   # Use lambda with typed param
```

**Why:** `let` bindings parse `IDENT` as the binding name, then `=` as the binding operator. The `(x : a)` syntax would require `let` to recognize it as a parameter list, which adds complexity.

**Fix (future):** Extend `let_def` to support parameter lists:
```ebnf
let_def = "let" IDENT param* [ "->" type_expr ] "=" expr ;
```

This would allow:
```ko
let id (x : a) -> a = x
let add (x : Int) (y : Int) -> Int = x + y
```

### 9.3 Tuple Patterns in `fn` Params No Longer Supported

**Limitation:** With the new syntax, `(` is exclusively for typed params. Tuple destructuring in function parameters is no longer supported.

```ko
# Old (v0.2.x) — worked:
fn swap (a, b) = (b, a)

# New (v0.3.0) — doesn't work:
fn swap (a, b) = (b, a)    # Parser sees (a, b) as two typed params

# Workaround:
fn swap pair = match pair (a, b) -> (b, a)
```

**Why:** `(` is now exclusively for typed params `(x : Type)`. Tuple patterns in params would require additional parsing logic to distinguish from typed params.

**This is a deliberate tradeoff** — typed params are more common than tuple destructuring in params, and the workaround (match in body) is clear.

---

## 10. Migration: Old Syntax -> New Syntax

### 10.1 What Changed

The function definition syntax changed in v0.3.0 to support bidirectional type inference with mandatory signatures.

### 10.2 Migration Rules

| Pattern | Old (v0.2.x) | New (v0.3.0) |
|---------|-------------|-------------|
| Untyped | `fn f x = x` | `fn f x = x` (unchanged) |
| Return type only | `fn f x : Int = x + 1` | `fn f x -> Int = x + 1` |
| One typed param | `fn f x : Int -> Int = x + 1` | `fn f (x : Int) -> Int = x + 1` |
| Multiple typed params | `fn f x y : Int -> Int -> Int = x + y` | `fn f (x : Int) (y : Int) -> Int = x + y` |
| Higher-order typed | `fn f g : (a -> b) -> List a -> List b = ...` | `fn f (g : a -> b) (xs : List a) -> List b = ...` |
| No params, return type | `fn main : () -> () = ...` | `fn main -> () = ...` |
| Full signature | `fn process req : Request -> Response = ...` | `fn process (req : Request) -> Response = ...` |

### 10.3 What's Unchanged

- Untyped functions: `fn f x y = x + y` (no change)
- Lambda syntax: `\x -> x * 2` (no change)
- Let bindings: `let x = expr` (no change)
- Type definitions: `type Maybe a = Just a | Nothing` (no change)
- Pattern matching: `match x Just v -> v` (no change)
- All expression syntax: unchanged

### 10.4 Files Updated for New Syntax

| File | Change |
|------|--------|
| `ko-zig/src/parser.zig` | `parse_fn_def` updated |
| `ko-zig/src/tests.zig` | 4 tests updated |
| `ko-zig/src/tests_ko/syntax_fn.ko` | Updated to new syntax |
| `ko-zig/AGENTS.md` | Frozen syntax updated |
| `SPEC-0.md` | Examples updated |
| `SPEC.md` | Grammar and examples updated |
| `DESIGN-polymorphism.md` | Examples updated |
| `DESIGN-perceus-analysis.md` | Examples updated |
| `DESIGN-io-model.md` | Examples updated |
| `ko-zig/ROADMAP.md` | Examples updated |
| `docs/ko-crash-course.md` | Examples updated |
| `docs/ko-by-example.md` | Examples updated |
