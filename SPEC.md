# Kō Language Specification v0.3.0

> **Kō** (光) — "light" in Japanese. A minimal functional language that compiles to C.

---

## 1. Manifesto

**Kō is a practical functional language for systems programmers.**

Most functional languages (Haskell, OCaml, Erlang) target managed runtimes. Most systems languages (C, C++, Rust) use imperative syntax. Kō sits in the gap: functional expressiveness, systems-level output.

**What Kō is:**
- A small, learnable language (the spec fits on a few pages)
- Functional by default: immutable data, pure functions, algebraic types
- Compiles to C99: runs everywhere a C compiler runs
- Practical: no monads, no type classes, no higher-kinded types in v0.1.0

**What Kō is NOT:**
- Not a research language (no dependent types, no linear types)
- Not an systems language (no manual memory, no unsafe blocks)
- Not trying to replace Haskell or Rust

**Design philosophy:** "Make the common thing easy, the hard thing possible, the wrong thing hard."

---

## 2. The Curse of Languages & Design Baggage

Every new language carries syntax DNA from its ancestors. Fights this and you get alien syntax that scares users. Kō deliberately accommodates these familiar patterns:

### From C/Go (imperative programmers know these):
- `fn` for functions (not `fun` or `def`)
- `if`/`else` with expression syntax
- `import` for modules
- Operator syntax: `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `>`, `<=`, `>=`

### From Haskell/ML (functional programmers know these):
- `let` for bindings (not `var`/`const`)
- `->` for function types and arrows
- `match` for pattern matching (not `case`)
- `type` for defining algebraic data types
- `True`/`False` as capitalized constructors

### From Python (indentation-based blocks):
- Indentation determines block structure (no `{}` or `begin`/`end`)
- Significant whitespace: 2-space indent

### From Zig (modern systems language):
- `comptime` for compile-time evaluation
- Explicit over implicit (no hidden allocations)

### What Kō deliberately breaks (innovations):
1. **No parentheses for function calls**: `add 1 2` not `add(1, 2)` — cleaner, more uniform
2. **No semicolons**: newlines separate expressions
3. **No curly braces**: indentation defines blocks
4. **No null/nil**: use `Maybe` type instead
5. **No exceptions**: use `Result` type instead
6. **No classes/objects**: use ADTs + functions instead
7. **All expressions return values**: `if`/`match`/blocks are expressions, not statements

---

## 3. Language Features

### 3.1 Core (v0.1.0)
| Feature | Example | Status |
|---------|---------|--------|
| Functions | `fn add a b = a + b` | Done |
| Let bindings | `let x = 5` | Done |
| Integers | `42`, `0xFF`, `0b1010`, `1_000` | Done |
| Floats | `3.14` | Done |
| Strings | `"hello"` | Done |
| Booleans | `true`, `false` | Done |
| Char | `'a'` | Done |
| If/then/else | `if x > 0 then x else -x` | Done |
| ADTs | `type Maybe = Just * \| Nothing` | Done |
| Pattern matching | `match x Just v -> v Nothing -> 0` | Done |
| Higher-order functions | `map \x -> x * 2 list` | Done |
| Closures | `\x -> x + y` (captures y) | Done |
| Lambda lifting | Automatic closure conversion | Done |
| String interpolation | `"hello ${name}!"` | Done |
| Ref cells (mutation) | `let x = ref 0; x := !x + 1` | Done |
| Comptime | `comptime 3 + 4` | Done |
| Modules | `import math` | Done (textual inclusion) |
| Comments | `# line`, `#\| block \|#` | Done |

### 3.2 Type System (v0.1.0)
| Feature | Example | Status |
|---------|---------|--------|
| Type inference | Hindley-Milner | Done |
| Type annotations | `fn add : Int -> Int -> Int` | Done |
| ADT constructors | `Just 42`, `Nothing` | Done |
| Wildcard patterns | `_` | Done |
| Exhaustiveness check | Compiler warns on missing cases | Done |
| Let-polymorphism | `fn id x = x` works for any type | Done |
| Multi-field constructors | `type Tree = Node * * * \| Leaf` | Done |
| Boolean operators | `&&`, `\|\|` | Done |
| Tuple types | `(Int, String)`, `(1, "hello")` | Done |
| Tuple destructuring | `let (x, y) = pair` | Done |
| Tuple field access | `tup.0`, `tup.1` | Done |
| Tuple match patterns | `match t (0, 0) -> "origin"` | Done |

### 3.3 Future
- Generics: `type List a = Cons * * | Nil`
- Record types: `{ name: String, age: Int }`
- Type classes: `class Eq a where (==) : a -> a -> Bool`
- Effect system: `fn read_file : !IO (Result Error String)`
- Proper modules (separate compilation, namespaces)
- Self-hosting

---

## 4. Syntax Grammar (EBNF)

The grammar is **context-free** and **unambiguous**. It can be parsed with a recursive-descent parser (no conflicts).

```ebnf
(* === Top Level === *)
program         = package_decl? top_stmt* EOF
package_decl    = 'package' IDENT ('.' IDENT)*

top_stmt        = fn_def
                | type_def
                | import_stmt
                | let_def
                | module_def

fn_def          = 'pub'? 'fn' IDENT+ '=' expr
                | 'pub'? 'fn' IDENT+ ':' type_expr

type_def        = 'pub'? 'type' IDENT '=' variant ('|' variant)*

let_def         = 'pub'? 'let' IDENT '=' expr

module_def      = 'pub'? 'module' IDENT '{' top_stmt* '}'

variant         = IDENT ('*'*)?

import_stmt     = 'import' IDENT ('.' IDENT)*
                | 'import' IDENT ('.' IDENT)* '.' '{' IDENT (',' IDENT)* '}'
                | 'import' IDENT ('.' IDENT)* 'as' IDENT
                | 'import' STRING

(* === Types === *)
type_expr       = type_atom ('->' type_expr)?
type_atom       = IDENT
                | '(' type_expr ')'

(* === Expressions === *)
expr            = let_expr
                | if_expr
                | match_expr
                | lambda_expr
                | ref_expr
                | comptime_expr
                | or_expr

let_expr        = 'let' IDENT ['=' expr] '=' expr
                | 'let' IDENT ':' type_expr '=' expr
                | 'let' '(' pattern (',' pattern)+ ')' '=' expr    (* tuple destructuring *)

if_expr         = 'if' expr 'then' expr ('else' expr)?

match_expr      = 'match' expr match_arm+
match_arm       = pattern '->' expr

lambda_expr     = '\' IDENT+ '->' expr

ref_expr        = 'ref' expr

comptime_expr   = 'comptime' expr

(* === Operators (precedence low to high) === *)
or_expr         = and_expr ('||' and_expr)*
and_expr        = comparison ('&&' comparison)*
comparison      = addition (('==' | '!=' | '<' | '>' | '<=' | '>=') addition)*
addition        = multiplication (('+' | '-') multiplication)*
multiplication  = unary (('*' | '/' | '%') unary)*
unary           = '-' unary
                | '!' unary
                | 'comptime' unary
                | application

(* === Function Application === *)
application     = primary primary*

(* === Primary Expressions === *)
primary         = INT | FLOAT | STRING | CHAR | TRUE | FALSE
                | IDENT | CONSTRUCTOR
                | '(' expr ')'
                | '(' expr (',' expr)+ ')'    (* tuple literal *)
                | lambda_expr
                | '[' expr (',' expr)* ']'
                | ref_expr
                | '!' primary
                | comptime_expr

(* === Tuple field access === *)
application     = primary ('.' INT)*            (* tuple field access: tup.0, tup.1, etc. *)

(* === Patterns === *)
pattern         = CONSTRUCTOR pattern_arg*
                | '_'
                | LITERAL
                | IDENT
                | '(' pattern (',' pattern)+ ')'    (* tuple pattern *)

pattern_arg     = '_'
                | LITERAL
                | IDENT
                | CONSTRUCTOR pattern_arg*
                | '(' pattern (',' pattern)+ ')'    (* tuple pattern *)

(* === Tokens === *)
IDENT           = [a-z_][a-zA-Z0-9_-]*
CONSTRUCTOR     = [A-Z][a-zA-Z0-9_]*
INT             = [0-9][0-9_]*
                | '0x'[0-9a-fA-F][0-9a-fA-F_]*
                | '0b'[01][01_]*
FLOAT           = [0-9][0-9_]*'.'[0-9][0-9_]*
STRING          = '"' chars '"'
CHAR            = '\'' chars '\''
TRUE            = 'true'
FALSE           = 'false'
LITERAL         = INT | FLOAT | STRING | CHAR | TRUE | FALSE

(* === Comments === *)
line_comment    = '#' [^\n]*
block_comment   = '#|' block_chars '|#'
```

### 4.1 Key Grammar Decisions

**Function application is implicit (no parentheses):**
```
add 1 2          (* Curried: ((add 1) 2) *)
map \x -> x*2 xs
```

**Indentation rules:**
- Function bodies are indented by 2+ spaces from the `fn` line
- `match` arms are indented by 2+ spaces from the `match` keyword
- No other indentation rules (no Python-style block detection)

**Operator precedence (high to low):**
1. `*`, `/`, `%`
2. `+`, `-`
3. `==`, `!=`, `<`, `>`, `<=`, `>=`
4. `&&`
5. `||`
6. Function application (highest)

**Pattern syntax:**
- Uppercase identifiers are constructors: `Just`, `Nothing`, `Cons`
- Lowercase identifiers are variable bindings: `x`, `name`, `rest`
- `_` is wildcard (matches anything, binds nothing)
- Literal patterns: `0`, `"hello"`, `true`
- Constructor patterns can have arguments: `Cons head tail`

---

## 5. Type System

### 5.1 Design Goals
1. **Inferred**: Users rarely need type annotations
2. **Sound**: If it type-checks, no runtime type errors
3. **Simple**: Hindley-Milner, no extensions in v0.1.0
4. **Practical**: ADTs cover most use cases

### 5.2 Type Language
```
type ::= Int | Float | Bool | Char | String
       | a                           (* type variable *)
       | type -> type                (* function type *)
       | TypeName                    (* ADT type *)
       | TypeName type_atom*         (* parameterized ADT, future *)
       | '(' type (',' type)+ ')'    (* tuple type *)
```

### 5.3 Built-in Types
| Type | C Representation | Description |
|------|-----------------|-------------|
| `Int` | `int64_t` | 64-bit signed integer |
| `Float` | `double` | 64-bit floating point |
| `Bool` | `int` (0/1) | Boolean |
| `Char` | `char` | Single character |
| `String` | `char*` (heap) | UTF-8 string |
| `()` | `int` (0) | Unit type (like void) |
| `(T1, T2, ...)` | `Tuple_N` struct | Anonymous tuple (fixed-size, heterogeneous) |
| `(T1, T2, ...)` | `Constructor` | Anonymous tuple (fixed-size, heterogeneous) |

### 5.4 ADTs and Pattern Matching
```ko
type Maybe =
  Just *
  | Nothing

type Result =
  Ok *
  | Error *

type List =
  Cons * *
  | Nil

type Either =
  Left *
  | Right *

type Binding = {
  name : String,
  value : Int
}
```

`type Name = ...` defines a sum type.
`type Name = { ... }` defines a record.

Each `*` marks a data slot in the current sum-type notation. The compiler generates:
- A tag enum (0, 1, 2, ...)
- A C struct with a union of variant data
- Constructor functions: `Maybe Just(Value v)`
- Destructor/pattern matching via tag checks

Record patterns should support `..` for intentional partial matches.

### 5.5 Type Inference (Algorithm W)
The compiler infers types using unification:

1. Assign fresh type variables to all expressions
2. Generate constraints from usage:
   - `add 1 2`: `add : a -> b -> c`, `1 : Int`, `2 : Int`
   - Constraint: `a = Int`, `b = Int`
3. Unify constraints to find most general type
4. Substitute solved types back

**Result:** `add : Int -> Int -> Int`

### 5.6 Exhaustiveness Checking
The compiler verifies all match arms cover all constructors:
```ko
type Maybe = Just * | Nothing

fn safe_head xs =
  match xs
    Cons x _ -> Just x    (* covers Cons *)
    Nil -> Nothing         (* covers Nil *)
    (* compiler warns if a case is missing *)
```

---

## 6. Semantics

### 6.1 Evaluation Order
Kō uses **strict evaluation** (eager): arguments are evaluated before function application.

```ko
let x = expensive_computation   (* evaluated now *)
add x 1                         (* x already computed *)
```

**Exception:** `comptime` expressions are evaluated at compile time.

### 6.2 Scoping
- `let` bindings are scoped to the current block
- Function parameters are scoped to the function body
- Closures capture variables from enclosing scope (lexical scoping)

### 6.3 Immutability
- `let` bindings cannot be reassigned
- ADT values are immutable
- Ref cells provide controlled mutability: `let x = ref 0; x := !x + 1`

### 6.4 Reference Counting
All heap-allocated values (strings, constructors, closures, ref cells) use reference counting:
- `make_*` functions increment refcount to 1
- Assignment to a new variable increments refcount
- When a variable goes out of scope, refcount decrements
- At refcount 0, memory is freed
- Ref cells have special semantics: `:=` replaces the value but doesn't free the cell

---

## 7. C Codegen

### 7.1 Value Representation
Every Kō value is a tagged union in C:
```c
typedef struct {
  int type;           // VAL_INT, VAL_STRING, VAL_CLOSURE, etc.
  union {
    int64_t int_val;
    double float_val;
    int bool_val;
    char char_val;
    char* string_val;
    struct Constructor* constructor_val;
    struct Closure* closure_val;
    struct RefCell* ref_val;
    int unit_val;
  } as;
} Value;
```

### 7.2 Constructor Representation
```c
typedef struct {
  int tag;            // Which variant (0, 1, 2, ...)
  int refcount;       // Reference count
  Value fields[];     // Variant data (flexible array member)
} Constructor;
```

### 7.3 Closure Representation
```c
typedef struct {
  int refcount;
  int env_size;
  Value* env;         // Captured variables
  ClosureFn func;     // Function pointer
} Closure;

typedef Value (*ClosureFn)(Closure* env, Value arg);
```

### 7.4 Ref Cell Representation
```c
typedef struct {
  int refcount;
  Value value;
} RefCell;
```

### 7.5 String Handling
- Strings are heap-allocated `char*`
- `==` uses `strcmp()` (not pointer comparison)
- String interpolation desugars to `concat` calls at parse time
- `to_string` converts any value to string representation

### 7.6 Generated C Structure
A Kō program compiles to a single `.c` file with:
1. Forward declarations
2. `#include` directives
3. Type tag enums
4. Constructor structs
5. Standard library functions
6. Lambda functions (hoisted from closures)
7. Top-level functions
8. `main()` function

---

## 8. Module System

### 8.1 Import Syntax
```ko
import std.math              (* import full module, prefixed as math *)
import std.math.{sin, cos}   (* selective import, no prefix *)
import std.math as m          (* alias import, prefixed as m *)
import "lib/custom.ko"        (* string path import *)
```

### 8.2 Package Declarations
Files can declare their package name (must be first statement):
```ko
package std.math

pub PI = 3.14159
pub fn sin x = ...
```

### 8.3 Visibility (`pub`)
By default, definitions are private (not importable). Use `pub` to make them visible:
```ko
pub fn public_fn x = x        (* importable *)
fn private_fn x = x           (* NOT importable *)
pub my_value = 42             (* importable let binding *)
```

### 8.4 Module Blocks
Group related definitions in a module block:
```ko
module Math =
  pub PI = 3.14159
  pub fn sin x = x
```

### 8.5 Module Resolution
Search order:
1. Current directory (relative to source file)
2. `lib/` in current directory
3. Compiler's `lib/` directory (standard library)
4. Package root (auto-detected by walking up to find `package.ko`)

### 8.6 Module Semantics
Modules are resolved by **textual inclusion**: imported definitions are inlined into the importing file. 
- Without selective imports: names are prefixed with the module name (`math_PI`, `math_sin`)
- With selective imports: names are imported as-is (`PI`, `sin`)
- With alias: names are prefixed with the alias (`m_PI`, `m_sin`)
- Only `pub` definitions are importable

### 8.4 Future: Proper Modules (v0.2.0)
- Each module is a separate compilation unit
- Explicit namespace: `math.sqrt`, `utils.map`
- No textual inclusion, proper linking

---

## 9. Standard Library

All functions below are built into the compiler and runtime. No imports needed.

### 9.1 I/O
| Function | Type | Description |
|----------|------|-------------|
| `print` | `forall a. a -> Unit` | Print value to stdout without newline |
| `println` | `forall a. a -> Unit` | Print value to stdout with newline |
| `eprint` | `forall a. a -> Unit` | Print value to stderr without newline |
| `eprintln` | `forall a. a -> Unit` | Print value to stderr with newline |
| `inspect` | `forall a. a -> Unit` | Debug print with type and value info |
| `panic` | `String -> Unit` | Exit with error message to stderr |

### 9.2 String Operations
| Function | Type | Description |
|----------|------|-------------|
| `len` | `String -> Int` | String length |
| `concat` | `String -> String -> String` | Concatenate two strings |
| `char_at` | `String -> Int -> Char` | Character at index (0-based) |
| `substring` | `String -> Int -> Int -> String` | Extract substring [start, end) |
| `contains` | `String -> String -> Bool` | Check if substring exists |
| `starts_with` | `String -> String -> Bool` | Check if string starts with prefix |
| `ends_with` | `String -> String -> Bool` | Check if string ends with suffix |
| `to_upper` | `String -> String` | Convert to uppercase |
| `to_lower` | `String -> String` | Convert to lowercase |
| `trim` | `String -> String` | Remove leading/trailing whitespace |
| `repeat` | `String -> Int -> String` | Repeat string n times |
| `split` | `String -> String -> List` | Split string by delimiter into list |
| `join` | `List -> String -> String` | Join list elements with separator |
| `replace` | `String -> String -> String -> String` | Replace all occurrences of substring |
| `ord` | `Char -> Int` | Convert character to Unicode code point |
| `chr` | `Int -> Char` | Convert code point to character |
| `parse_int` | `String -> Int` | Parse string as integer |
| `parse_float` | `String -> Float` | Parse string as float |

### 9.3 Math
| Function | Type | Description |
|----------|------|-------------|
| `abs` | `Int -> Int` | Absolute value |
| `min` | `Int -> Int -> Int` | Minimum of two integers |
| `max` | `Int -> Int -> Int` | Maximum of two integers |
| `pow` | `Int -> Int -> Int` | Raise base to power |
| `mod` | `Int -> Int -> Int` | Modulo (remainder of division) |
| `sqrt` | `Float -> Float` | Square root |
| `floor` | `Float -> Int` | Round down to integer |
| `ceil` | `Float -> Int` | Round up to integer |

### 9.4 Type Conversion & Introspection
| Function | Type | Description |
|----------|------|-------------|
| `to_string` | `forall a. a -> String` | Convert any value to string |
| `to_int` | `String -> Int` | Parse string as integer |
| `to_float` | `forall a. a -> Float` | Convert value to float |
| `type_of` | `forall a. a -> String` | Get type name as string |
| `is_int` | `forall a. a -> Bool` | Check if value is Int |
| `is_float` | `forall a. a -> Bool` | Check if value is Float |
| `is_string` | `forall a. a -> Bool` | Check if value is String |
| `is_bool` | `forall a. a -> Bool` | Check if value is Bool |
| `is_null` | `forall a. a -> Bool` | Check if value is null (Nil constructor) |

### 9.5 File & System I/O
| Function | Type | Description |
|----------|------|-------------|
| `read_file` | `String -> String` | Read entire file as string |
| `write_file` | `String -> String -> Unit` | Write string to file (creates/overwrites) |
| `append_file` | `String -> String -> Unit` | Append string to file |
| `read_line` | `String -> String` | Read line from stdin (with prompt) |
| `run` | `String -> String` | Run shell command, return stdout |
| `get_env` | `String -> String` | Get environment variable value |
| `file_exists` | `String -> Bool` | Check if file exists |
| `file_size` | `String -> Int` | Get file size in bytes |
| `file_modified` | `String -> Int` | Get file modification time (ms since epoch) |
| `sleep` | `Int -> Unit` | Sleep for N milliseconds |
| `mkdir` | `String -> Bool` | Create directory (returns true on success) |
| `rm` | `String -> Bool` | Remove file or empty directory |
| `cp` | `String -> String -> Bool` | Copy file to destination |
| `mv` | `String -> String -> Bool` | Move/rename file to destination |
| `readdir` | `String -> List` | List directory contents as list of strings |

### 9.6 CLI Arguments & Time
| Function | Type | Description |
|----------|------|-------------|
| `args_count` | `Int` | Number of command line arguments |
| `args_get` | `Int -> String` | Get CLI argument by index |
| `now` | `Int` | Milliseconds since program start |
| `exit` | `Int -> Unit` | Exit program with code |

### 9.7 Random
| Function | Type | Description |
|----------|------|-------------|
| `random` | `Int -> Int -> Int -> Int` | Pure random (seed, min, max) |
| `seed` | `Int` | Get next seed for chaining |

### 9.8 Path Operations
| Function | Type | Description |
|----------|------|-------------|
| `path_join` | `String -> String -> String` | Join path segments with `/` |
| `path_dirname` | `String -> String` | Get directory part of path |
| `path_basename` | `String -> String` | Get filename part of path |

### 9.9 JSON
| Function | Type | Description |
|----------|------|-------------|
| `json_parse` | `String -> List` | Parse JSON string to Kō value |
| `json_stringify` | `forall a. a -> String` | Convert Kō value to JSON string |

### 9.10 Testing
| Function | Type | Description |
|----------|------|-------------|
| `assert` | `Bool -> Unit` | Assert condition is true |
| `assert_eq` | `forall a. a -> a -> Unit` | Assert two values are equal |
| `test` | `forall a. String -> a -> Unit` | Run a named test group |
| `run_tests` | `Unit` | Print test summary and exit |

### 9.11 List Operations
| Function | Type | Description |
|----------|------|-------------|
| `head` | `forall a. List[a] -> a` | First element of list (panics on empty) |
| `tail` | `forall a. List[a] -> List[a]` | All but first element (panics on empty) |
| `append` | `forall a. List[a] -> a -> List[a]` | Append element to end of list |
| `reverse` | `forall a. List[a] -> List[a]` | Reverse a list |
| `sum` | `List[Int] -> Int` | Sum all integers in list |
| `product` | `List[Int] -> Int` | Product of all integers in list |

### 9.12 Reference Cells
| Syntax | Type | Description |
|--------|------|-------------|
| `ref x` | `forall a. a -> a` | Create mutable reference |
| `!x` | `forall a. a -> a` | Dereference a reference |
| `x := v` | `forall a. a -> a -> Unit` | Mutate a reference |

### 9.13 Higher-Order Functions (in Kō itself)
```ko
type List = Cons * * | Nil

fn map f xs =
  match xs
    Cons x rest -> Cons (f x) (map f rest)
    Nil -> Nil

fn filter f xs =
  match xs
    Cons x rest -> if f x then Cons x (filter f rest) else filter f rest
    Nil -> Nil

fn fold f acc xs =
  match xs
    Cons x rest -> fold f (f acc x) rest
    Nil -> acc

fn zip xs ys =
  match xs
    Cons x rest_x ->
      match ys
        Cons y rest_y -> Cons (x, y) (zip rest_x rest_y)
        Nil -> Nil
    Nil -> Nil
```

---

## 10. Implementation

### 10.1 Implementation Language
**Recommendation: Write v0.1.0 in Python, port to Rust/Zig later.**

Rationale:
- Python is fast to iterate with (current approach works)
- The compiler is small (~2000 lines)
- Runtime performance comes from the generated C, not the compiler
- Port to Rust/Zig for v0.2.0 when the design stabilizes

### 10.2 Compiler Pipeline
```
Source Code (.ko)
    ↓
Lexer → Tokens
    ↓
Parser → AST
    ↓
Semantic Analysis → Typed AST + exhaustiveness check
    ↓
Codegen → C99 Source (.c)
    ↓
C Compiler (gcc/clang) → Binary
```

### 10.3 Architecture
```
ko.py              CLI entry point
lexer.py           Tokenizer
parser.py          Recursive descent parser
typecheck.py       Hindley-Milner type inference
semantic.py        Exhaustiveness checking
codegen.py         C99 code generation
runtime.h          C runtime (value representation, stdlib, RC)
errors.py          Error reporting with source locations
lsp.py             Language Server Protocol server
vscode-ko/         VS Code extension
```

### 10.4 Implementation Phases

**Phase 1: Core (done)**
- Lexer, Parser, Codegen
- ADTs, Pattern Matching
- Closures, Higher-Order Functions
- Basic standard library

**Phase 2: Type System (done)**
- Hindley-Milner type inference
- Type annotations (optional)
- Exhaustiveness checking

**Phase 3: Tooling (done)**
- LSP server (hover, definition, diagnostics, completion, symbols)
- VS Code extension
- Module imports with aliasing

**Phase 4: Module System v2 (done)**
- Hierarchical imports (`import std.math`)
- Selective imports (`import math.{sin, cos}`)
- Alias imports (`import math as m`)
- Package declarations (`package std.math`)
- Visibility (`pub` keyword)
- Module blocks (`module Name { ... }`)
- Package detection (`package.ko`)

**Phase 5: Next**
- Error handling (Result type)
- Named parameters
- Traits/typeclasses
- Generics

**Phase 6: Future**
- Rewrite compiler in Zig
- Self-hosting (Kō compiles itself)

---

## 11. v0.2.0 Roadmap

### Done
- [x] Lexer with all token types
- [x] Parser for core syntax
- [x] ADT definition and construction
- [x] Pattern matching with wildcards
- [x] Exhaustiveness checking
- [x] Function definitions and application
- [x] Closures via lambda lifting
- [x] Higher-order functions
- [x] Let bindings
- [x] If/then/else expressions
- [x] Basic operators (+, -, *, /, %, ==, !=, <, >)
- [x] String interpolation
- [x] Ref cells
- [x] Comptime (basic)
- [x] Comments (# and #| |#)
- [x] C codegen with reference counting
- [x] Standard library (50+ builtins)
- [x] Type inference (Hindley-Milner)
- [x] Type annotations
- [x] LSP server (hover, go-to-definition, diagnostics, completion, symbols)
- [x] VS Code extension
- [x] Module imports with aliasing

### Next
- [ ] Better error messages (did you mean...?)
- [ ] Generics: `type List a = Cons * * | Nil`
- [ ] Tuple types: `(Int, String)`
- [ ] Record types: `{ name: String, age: Int }`
- [ ] Pattern matching in let: `let (x, y) = pair`
- [ ] Nested function definitions

### Future
- [ ] Proper modules (separate compilation, namespaces)
- [ ] Effect tracking
- [ ] Type classes
- [ ] Self-hosting (Kō compiles itself)

---

## 12. Examples

### Hello World
```ko
fn main = print "Hello, World!"
```

### Fibonacci
```ko
fn fib n =
  if n <= 1 then n
  else fib (n - 1) + fib (n - 2)

fn main = print (fib 20)
```

### Maybe Type
```ko
type Maybe = Just * | Nothing

fn from_default default mx =
  match mx
    Just x -> x
    Nothing -> default

fn main =
  let x = Just 42
  let y = Nothing
  print (from_default 0 x)
  print (from_default 0 y)
```

### Map/Filter/Fold
```ko
type List = Cons * * | Nil

fn map f xs =
  match xs
    Cons x rest -> Cons (f x) (map f rest)
    Nil -> Nil

fn filter f xs =
  match xs
    Cons x rest -> if f x then Cons x (filter f rest) else filter f rest
    Nil -> Nil

fn fold f acc xs =
  match xs
    Cons x rest -> fold f (f acc x) rest
    Nil -> acc

fn main =
  let xs = Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil)))
  let doubled = map (\x -> x * 2) xs
  let evens = filter (\x -> x % 2 == 0) xs
  let sum = fold (+) 0 xs
  inspect doubled
  inspect evens
  print sum
```

### Ref Cells (Mutable State)
```ko
fn main =
  let counter = ref 0
  let i = ref 0
  while (!i < 10) (
    counter := !counter + !i
    i := !i + 1
  )
  print !counter
```

### String Interpolation
```ko
fn main =
  let name = "Kō"
  let version = "0.1.0"
  println "Welcome to ${name} v${version}!"
```

---

*This specification is a living document. It will be updated as Kō evolves.*
