# Kō Grammar

> The complete formal grammar for Kō v0.1.0

---

## Design Philosophy

- **No parentheses** for function calls: `add 1 2` not `add(1, 2)`
- **No curly braces**: indentation defines blocks
- **No semicolons**: newlines separate statements
- **Context-free**: can be parsed with recursive descent

---

## Formal Grammar (EBNF)

```ebnf
(* ===== Top Level ===== *)
program         = { import | definition } ;

import          = "import" ( IDENT | STRING ) [ "as" IDENT ] ;

definition      = type_def | fn_def ;

(* ===== Type Definitions ===== *)
type_def        = "type" IDENT "=" type_alt { "|" type_alt } ;
type_alt        = IDENT { "*" } ;
                (* * marks a type slot, repeated for arity *)

(* ===== Function Definitions ===== *)
fn_def          = "fn" IDENT [ type_annotation ] { IDENT } "=" block
                | "fn" IDENT [ type_annotation ] { IDENT } "=" expr ;

type_annotation = ":" type_expr ;

(* ===== Type Expressions ===== *)
type_expr       = type_atom { "->" type_expr } ;
                (* function types are right-associative *)

type_atom       = "Int" | "Float" | "Bool" | "String" | "Char" | "Unit"
                | IDENT
                | "(" type_expr ")" ;

(* ===== Blocks ===== *)
block           = NEWLINE INDENT { let_expr NEWLINE | expr NEWLINE } DEDENT ;
                (* body of fn_def, or after = on same line *)

(* ===== Let Bindings ===== *)
let_expr        = "let" IDENT "=" expr ;

(* ===== Expressions ===== *)
expr            = if_expr | match_expr | let_inline_expr
                | lambda | comptime_expr | ref_expr | or_expr ;

if_expr         = "if" expr "then" expr [ "else" expr ] ;

match_expr      = "match" expr NEWLINE match_arm { match_arm } ;
match_arm       = pattern "->" expr NEWLINE ;

let_inline_expr = "let" IDENT "=" expr "in" expr ;

lambda          = "\" { IDENT } "->" expr ;

comptime_expr   = "comptime" expr ;

ref_expr        = "ref" expr ;

(* ===== Operators (precedence low→high) ===== *)
or_expr         = and_expr { "||" and_expr } ;
and_expr        = cmp_expr { "&&" cmp_expr } ;
cmp_expr        = add_expr { ( "==" | "!=" | "<" | ">" | "<=" | ">=" ) add_expr } ;
add_expr        = mul_expr { ( "+" | "-" | "++" ) mul_expr } ;
mul_expr        = unary_expr { ( "*" | "/" | "%" ) unary_expr } ;
unary_expr      = "-" unary_expr
                | "!" unary_expr
                | application ;

(* ===== Function Application ===== *)
application     = primary { primary } ;
                (* left-associative, no parens needed *)

(* ===== Primary Expressions ===== *)
primary         = INT | FLOAT | STRING | CHAR | "true" | "false"
                | IDENT | CONSTRUCTOR
                | "_"
                | list_literal
                | "(" expr ")"
                | ref_set ;

ref_set         = IDENT ":=" expr ;
                (* ref cell mutation: x := value *)

list_literal    = "[" [ expr { "," expr } ] "]" ;
                (* [1, 2, 3] desugars to Cons 1 (Cons 2 (Cons 3 Nil)) *)

(* ===== Patterns ===== *)
pattern         = pat_constructor | pat_ident | pat_literal | pat_wildcard ;

pat_constructor = CONSTRUCTOR { pattern } ;
                (* Constructor patterns with arguments *)

pat_ident       = LOWER_IDENT ;
                (* Variable binding in pattern *)

pat_literal     = INT | FLOAT | STRING | CHAR | "true" | "false" ;

pat_wildcard    = "_" ;

(* ===== Literals ===== *)
INT             = DECIMAL | HEX | BINARY ;
DECIMAL         = DIGIT { DIGIT | "_" } ;
HEX             = "0" ("x" | "X") HEX_DIGIT { HEX_DIGIT | "_" } ;
BINARY          = "0" ("b" | "B") DIGIT { DIGIT | "_" } ;
FLOAT           = DECIMAL "." DECIMAL ;
STRING          = '"' { CHAR_ESC | CHAR } '"' ;
CHAR            = "'" ( CHAR_ESC | CHAR ) "'" ;

(* ===== Identifiers ===== *)
IDENT           = LOWER_IDENT | CONSTRUCTOR ;
LOWER_IDENT     = LOWER { ALPHA | DIGIT | "_" | "-" } ;
CONSTRUCTOR     = UPPER { ALPHA | DIGIT | "_" | "-" } ;

(* ===== Comments ===== *)
comment         = "#" NEWLINE_CHARS
                | "//" NEWLINE_CHARS
                | "#|" { ANY_CHAR } "|#" ;

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

## Key Grammar Decisions

### Function Application is Implicit

```kō
add 1 2          (* Curried: ((add 1) 2) *)
map \x -> x*2 xs
fold (\acc x -> acc + x) 0 xs
```

### Indentation Rules

- Function bodies are indented by 2+ spaces from the `fn` line
- `match` arms are indented by 2+ spaces from the `match` keyword
- No other indentation rules (no Python-style block detection)

### Operator Precedence (high to low)

1. `*`, `/`, `%` (multiplication)
2. `+`, `-`, `++` (addition)
3. `==`, `!=`, `<`, `>`, `<=`, `>=` (comparison)
4. `&&` (logical and)
5. `||` (logical or)
6. Function application (highest)

### Pattern Syntax

- Uppercase identifiers are constructors: `Just`, `Nothing`, `Cons`
- Lowercase identifiers are variable bindings: `x`, `name`, `rest`
- `_` is wildcard (matches anything, binds nothing)
- Literal patterns: `0`, `"hello"`, `true`
- Constructor patterns can have arguments: `Cons head tail`

---

## Keywords

```
fn        type      let       if        then      else
match     import    as        ref       comptime  true
false     in
```

## Built-in Identifiers

```
print     println    inspect    panic
```

---

## Token Examples

```
// Numbers
42          // decimal
0xFF        // hexadecimal
0b1010      // binary
1_000_000   // underscores for readability
3.14        // float

// Strings
"hello"                 // basic string
"line\nbreak"           // escape sequences
"hello ${name}!"        // string interpolation
"x = ${x}"             // expressions inside ${}

// Characters
'c'                     // character
'\n'                    // newline character

// Identifiers
x                       // variable
add                     // function
from-maybe              // hyphenated name
Just                    // constructor
Nothing                 // constructor
```

---

## Comments

```kō
# This is a Kō comment (hash style)
// This is a C-style single-line comment
/* This is a
   multi-line comment */
```

---

## Compilation

```bash
python3 ko.py program.ko        # compiles to program
python3 ko.py program.ko out    # compiles to 'out'
python3 ko.py -e "println 42"   # inline execution
```
