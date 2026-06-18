# Kō Language Specification

> A minimal functional language with innovative syntax

## Design Philosophy

- **Minimal syntax, maximum expressiveness**
- **No parentheses for function calls** — `add 1 2` not `add(1, 2)`
- **Pattern matching as a core feature**
- **Compile to C99** for fast execution
- **Gradual complexity** — start simple, add features as needed

---

## Formal Grammar (EBNF)

```ebnf
(* ===== Program Structure ===== *)
program         = { definition | top_level_expr } ;

definition      = type_def | fn_def | let_binding ;

top_level_expr  = expr newline ;

(* ===== Type Definitions ===== *)
type_def        = "type" IDENT "=" type_alt { "|" type_alt } ;
type_alt        = IDENT { "*" } ;
                (* * marks a type slot, repeated for arity *)

(* ===== Function Definitions ===== *)
fn_def          = "fn" IDENT { IDENT } "=" newline indent expr
                | "fn" IDENT { IDENT } "=" expr ;
                (* params are bare identifiers after the name *)

(* ===== Let Bindings ===== *)
let_binding     = "let" IDENT "=" expr ;

(* ===== Blocks ===== *)
block           = newline indent { let_binding newline | expr newline } ;
indent          = NEWLINE INDENT (* increased indentation level *) ;

(* ===== Patterns ===== *)
pattern         = pat_constructor | pat_ident | pat_literal | pat_wildcard ;
pat_constructor = CONSTRUCTOR_IDENT { pattern } ;
                (* Constructor names start with uppercase *)
pat_ident       = ident ;
                (* Lowercase identifiers bind a value *)
pat_literal     = INT | FLOAT | STRING | CHAR | "true" | "false" ;
pat_wildcard    = "_" ;

(* ===== Expressions ===== *)
expr            = if_expr | match_expr | let_expr | or_expr ;

if_expr         = "if" expr "then" newline expr
                | "if" expr "then" expr "else" newline expr
                | "if" expr "then" expr "else" expr ;
                (* else is optional *)

match_expr      = "match" expr newline match_arm { match_arm } ;
match_arm       = pattern "->" newline expr
                | pattern "->" expr ;

let_expr        = "let" IDENT "=" expr "in" expr ;

(* ===== Operators (precedence low→high) ===== *)
or_expr         = and_expr { "||" and_expr } ;
and_expr        = cmp_expr { "&&" cmp_expr } ;
cmp_expr        = add_expr { ( "==" | "!=" | "<" | ">" | "<=" | ">=" ) add_expr } ;
add_expr        = mul_expr { ( "+" | "-" ) mul_expr } ;
mul_expr        = unary_expr { ( "*" | "/" | "%" ) unary_expr } ;
unary_expr      = "-" unary_expr | "!" unary_expr | application ;
application     = primary { primary } ;
                (* Function application: left-associative, no parens needed *)

(* ===== Primary Expressions ===== *)
primary         = INT | FLOAT | STRING | CHAR | "true" | "false"
                | IDENT | CONSTRUCTOR_IDENT | "_"
                | "(" expr ")" ;

(* ===== Literals ===== *)
INT             = DECIMAL | HEX ;
DECIMAL         = DIGIT { DIGIT | "_" } ;
HEX             = "0" ("x" | "X") HEX_DIGIT { HEX_DIGIT | "_" } ;
FLOAT           = DECIMAL "." DECIMAL ;
STRING          = '"' { CHAR_ESC | CHAR } '"' ;
CHAR            = "'" ( CHAR_ESC | CHAR ) "'" ;

(* ===== Identifiers ===== *)
IDENT           = LOWER_IDENT | BUILTIN_IDENT ;
LOWER_IDENT     = LOWER { ALPHA | DIGIT | "_" | "-" } ;
CONSTRUCTOR_IDENT = UPPER { ALPHA | DIGIT | "_" | "-" } ;
BUILTIN_IDENT   = "print" | "println" | "inspect" | "panic" ;
                (* built-ins are identifiers, not keywords *)

(* ===== Comments ===== *)
comment         = "#" NEWLINE_CHARS
                | "//" NEWLINE_CHARS
                | "/*" { CHAR } "*/" ;

(* ===== Character Classes ===== *)
DIGIT           = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
HEX_DIGIT       = DIGIT | "a" | "b" | "c" | "d" | "e" | "f"
                | "A" | "B" | "C" | "D" | "E" | "F" ;
LOWER           = "a" | "b" | ... | "z" ;
UPPER           = "A" | "B" | ... | "Z" ;
ALPHA           = LOWER | UPPER ;
NEWLINE         = "\n" ;
NEWLINE_CHARS   = { ANY_CHAR - NEWLINE } NEWLINE ;
```

---

## Lexical Structure

### Whitespace
- Spaces, tabs, and carriage returns are ignored
- Newlines are significant (separate statements)
- Indentation defines block scope for function bodies

### Comments
```
# This is a Kō comment (hash style)
// This is a C-style single-line comment
/* This is a
   multi-line comment */
```

### Identifiers
- **Lowercase**: `x`, `add`, `from-maybe` — variables and functions
- **Uppercase**: `Just`, `Nothing`, `Cons` — type constructors
- **Built-ins**: `print`, `println`, `inspect`, `panic` — treated as identifiers

### Numbers
```
42          # decimal
0xFF        # hexadecimal
1_000_000   # underscores for readability
3.14        # float
0x1A_FF     # hex with underscores
```

### Strings
```
"hello"         # basic string
"line\nbreak"   # escape sequences: \n \t \\ \"
```

### Characters
```
'c'         # character
'\n'        # newline character
```

---

## Type System

### Algebraic Data Types
```kō
type Maybe = Just * | Nothing
type Result = Ok * | Err *
type List = Cons * * | Nil
type Shape = Circle * | Rect * *
```

- `*` marks a type slot (positional)
- Constructors with 0 slots are nullary (like `Nothing`)
- Constructors with slots take arguments: `Just 42`, `Cons 1 Nil`

### Inferred Types
Kō is untyped — values carry runtime type tags, no compile-time checking.

---

## Expressions

### Arithmetic
```
a + b       # addition
a - b       # subtraction
a * b       # multiplication
a / b       # division
a % b       # modulo
```

### Comparison
```
a == b      # equal
a != b      # not equal
a < b       # less than
a > b       # greater than
a <= b      # less or equal
a >= b      # greater or equal
```

### Logical
```
a && b      # logical and
a || b      # logical or
!a          # logical not
```

### Function Application
```kō
add 1 2             # == add(1, 2) in other languages
map (fn x -> x * 2) xs
fold 0 (+) xs
```

### If Expressions
```kō
if x > 0 then x
else -x

if cond then a else b
```

### Pattern Matching
```kō
match xs
  Cons x rest -> x + sum rest
  Nil -> 0

match value
  Just x -> x
  Nothing -> default
  _ -> 0
```

---

## Functions

### Simple Functions
```kō
fn add a b = a + b
fn double x = x * 2
fn negate x = -x
```

### Multi-line Functions
```kō
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)
```

### Pattern Matching in Functions
```kō
fn head xs =
  match xs
    Cons x _ -> x
    Nil -> panic "empty list"
```

---

## Built-in Functions

```kō
print x         # print value (no newline)
println x       # print value with newline
inspect x       # print detailed type/value info
panic msg       # print error and exit
```

### inspect Output
```
inspect 42
# Value{type=Int, value=42}

inspect "hello"
# Value{type=String, value="hello"}

inspect (Just 42)
# Value{type=Constructor(tag=0, arity=1)}
```

---

## Examples

### Hello World
```kō
println "hello, world"
```

### Factorial
```kō
fn factorial n =
  if n == 0 then 1
  else n * factorial (n - 1)

fn main =
  println (factorial 10)
```

### Maybe Type
```kō
type Maybe = Just * | Nothing

fn from-just default mx =
  match mx
    Just x -> x
    Nothing -> default

fn main =
  let x = Just 42
  println (from-just 0 x)
  println (from-just 0 Nothing)
```

### Linked Lists
```kō
type List = Cons * * | Nil

fn sum xs =
  match xs
    Cons x rest -> x + sum rest
    Nil -> 0

fn length xs =
  match xs
    Cons _ rest -> 1 + length rest
    Nil -> 0

fn main =
  let xs = Cons 1 (Cons 2 (Cons 3 Nil))
  println (sum xs)
  println (length xs)
```

### Hex Numbers and Underscores
```kō
fn main =
  let color = 0xFF0000
  let big = 1_000_000
  inspect color
  inspect big
```

---

## Compilation

### From Source
```bash
python3 ko.py program.ko        # compiles to program
python3 ko.py program.ko out    # compiles to 'out'
```

### Inline Execution
```bash
python3 ko.py -e "println 42"
python3 ko.py -e "inspect 0xFF"
```

### REPL
```bash
python3 ko.py
ko> println 42
ko> :q
```

---

## Implementation Notes

### Runtime Representation
All values are tagged unions:
```c
typedef struct Value {
    ValueType type;  // VAL_INT, VAL_FLOAT, VAL_BOOL, ...
    union { ... } as;
} Value;
```

### ADT Compilation
- Constructors become C functions: `Value Just(Value arg0)`
- Pattern matching becomes `if/else if` chains with tag checks
- Nullary constructors (`Nothing`) are zero-arity functions

### Limitations (v0.1)
- No closures or higher-order functions
- No polymorphism or type inference
- No lazy evaluation
- No exhaustive pattern match checking
