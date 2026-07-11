# Kō Grammar

> Formal syntax for the current Kō direction.

## Design Notes

- Function application is implicit: `add 1 2`.
- Blocks are indentation-based (NEWLINE INDENT ... DEDENT).
- Records use braces, but blocks do not.
- Sum types and records are distinct at the syntax level.
- Pattern matches must stay exhaustive.
- Tuples use comma-separated values in parentheses: `(a, b, c)`.
- Selective imports use dot-brace: `import foo.{bar, baz}`.

## Grammar

```ebnf
program         = { top_level } ;

top_level       = import
                | package_def
                | module_def
                | definition ;

import          = "import" path [ "." "{" IDENT { "," IDENT } "}" ] [ "as" IDENT ] ;
package_def     = "package" IDENT ;
module_def      = [ "pub" ] "module" IDENT block ;

definition      = [ "pub" ] ( type_def | fn_def | let_def ) ;

type_def        = "type" IDENT { LOWER_IDENT } "=" type_body ;
type_body       = sum_body | record_body ;

sum_body        = variant { "|" variant } ;
variant         = CONSTRUCTOR { type_atom } ;

record_body     = "{" [ field_decl { "," field_decl } [ "," ] ] "}" ;
field_decl      = LOWER_IDENT ":" type_expr ;

fn_def          = "fn" IDENT { param } [ ":" type_expr ] "=" body ;
let_def         = "let" IDENT [ ":" type_expr ] "=" expr ;

param           = pattern ;

body            = expr | block ;
block           = NEWLINE INDENT { statement NEWLINE } DEDENT ;
statement       = let_def | expr ;

expr            = assign_expr ;
assign_expr     = pipe_expr [ ":=" expr ] ;

pipe_expr       = logic_or { "|>" logic_or } ;
logic_or        = logic_and { ( "||" | "or" ) logic_and } ;
logic_and       = compare { ( "&&" | "and" ) compare } ;
compare         = add { ( "==" | "!=" | "<" | ">" | "<=" | ">=" ) add } ;
add             = mul { ( "+" | "-" ) mul } ;
mul             = unary { ( "*" | "/" | "%" ) unary } ;

unary           = ( "-" | "!" | "ref" ) unary
                | postfix ;

postfix         = application [ "?" ] ;
application     = primary { argument } ;
argument        = named_arg | primary ;
named_arg       = "~" LOWER_IDENT ":" expr ;

primary         = literal
                | IDENT
                | CONSTRUCTOR
                | record_literal
                | "(" expr_or_tuple ")"
                | if_expr
                | match_expr
                | lambda
                | comptime_expr ;

expr_or_tuple   = expr { "," expr } ;

record_literal  = CONSTRUCTOR "{" [ field_init { "," field_init } [ "," ] ] "}" ;
field_init      = LOWER_IDENT "=" expr ;

if_expr         = "if" expr "then" expr [ "else" expr ] ;
match_expr      = "match" expr NEWLINE INDENT { match_arm NEWLINE } DEDENT ;
match_arm       = pattern "=>" expr ;

lambda          = "\\" { pattern } "->" expr ;
comptime_expr   = "comptime" expr ;

pattern         = pat_tuple
                | pat_record
                | pat_ctor
                | pat_literal
                | pat_ident
                | "_"
                | "(" pattern ")" ;

pat_tuple       = pattern { "," pattern } ;

pat_record      = CONSTRUCTOR "{" [ pat_field { "," pat_field } [ "," ".." ] ] "}" ;
pat_field       = LOWER_IDENT [ "=" pattern ] ;
pat_ctor        = CONSTRUCTOR { pattern_atom } ;
pattern_atom    = pat_literal | pat_ident | "_" | pat_record | "(" pattern ")" ;

pat_ident       = LOWER_IDENT ;
pat_literal     = INT | FLOAT | STRING | CHAR_LITERAL | "true" | "false" ;

literal         = INT | FLOAT | STRING | CHAR_LITERAL | "true" | "false" ;

type_expr       = type_atom [ "->" type_expr ] ;
type_atom       = type_primary { type_primary } ;
type_primary    = IDENT | CONSTRUCTOR | "(" type_expr ")" | record_body ;

path            = IDENT { "." IDENT } ;

INT             = DECIMAL | HEX | BINARY | OCTAL ;
DECIMAL         = DIGIT { DIGIT | "_" } ;
HEX             = "0" ( "x" | "X" ) HEX_DIGIT { HEX_DIGIT | "_" } ;
BINARY          = "0" ( "b" | "B" ) DIGIT { DIGIT | "_" } ;
OCTAL           = "0" ( "o" | "O" ) OCT_DIGIT { OCT_DIGIT | "_" } ;
FLOAT           = DECIMAL "." DECIMAL ;
STRING          = '"' { CHAR_ESC | STRING_CHAR } '"' ;
CHAR_LITERAL    = "'" ( CHAR_ESC | CHAR_CHAR ) "'" ;
CHAR_ESC        = "\\" ( "n" | "r" | "t" | "\\" | "\"" | "'" ) ;
STRING_CHAR     = ? any character except '"', '\\', or newline ? ;
CHAR_CHAR       = ? any character except '\'', '\\', or newline ? ;

IDENT           = LOWER_IDENT | CONSTRUCTOR ;
LOWER_IDENT     = LOWER { ALPHA | DIGIT | "_" | "-" } ;
CONSTRUCTOR     = UPPER { ALPHA | DIGIT | "_" | "-" } ;

DIGIT           = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
HEX_DIGIT       = DIGIT | "a" | "b" | "c" | "d" | "e" | "f" | "A" | "B" | "C" | "D" | "E" | "F" ;
OCT_DIGIT       = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" ;
LOWER           = "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" | "k" | "l" | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t" | "u" | "v" | "w" | "x" | "y" | "z" ;
UPPER           = "A" | "B" | "C" | "D" | "E" | "F" | "G" | "H" | "I" | "J" | "K" | "L" | "M" | "N" | "O" | "P" | "Q" | "R" | "S" | "T" | "U" | "V" | "W" | "X" | "Y" | "Z" ;
ALPHA           = LOWER | UPPER ;

NEWLINE         = "\n" ;
```

## Stable Surface

- `_` is the wildcard token.
- Hyphenated identifiers are legal.
- Numeric literals support decimal, hex, binary, and octal.
- `#` comments and indentation-sensitive blocks stay as-is.
- Named args use `~name:expr`.
- Visibility stays `pub` before `fn`, `type`, `let`, and `module`.
- `|>` is the pipe operator.
- Record patterns use `..` for intentional partial matches.
- `or` and `and` are keyword alternatives to `||` and `&&`.
- `?` is postfix try operator for Result error propagation.

## Compile-Time Evaluation (`comptime`)

`comptime` marks expressions and functions for compile-time evaluation. The evaluator is a tree-walking interpreter that runs during compilation.

### Syntax

```
comptime fn name params = body    # comptime function definition
comptime expr                     # mark expression for compile-time evaluation
```

### What can be evaluated at compile time

**Literals and operations:**
```kō
comptime 1 + 2                    # => 3
comptime "hello " ++ "world"      # => "hello world"
comptime if x > 0 then x else 0  # conditional
```

**Recursive functions:**
```kō
comptime fn fact n = if n == 0 then 1 else n * fact (n - 1)
comptime fact 5                   # => 120
```

**Pattern matching:**
```kō
type Color = Red | Green | Blue

comptime fn name c =
  match c
    | Red => "red"
    | Green => "green"
    | Blue => "blue"

comptime name Red                 # => "red"
```

**Constructor construction:**
```kō
type Nat = Succ Nat | Zero

comptime fn from_int n = if n == 0 then Zero else Succ (from_int (n - 1))
comptime from_int 3               # => Succ (Succ (Succ Zero))
```

**Tuple creation and access:**
```kō
comptime fn make_pair x y = (x, y)
comptime fn fst p = match p | (a, _) => a
comptime fst (make_pair 1 2)     # => 1
```

**List operations (via builtins):**
```kō
type List a = Cons a (List a) | Nil

comptime fn sum lst =
  match lst
    | Cons x rest => x + sum rest
    | Nil => 0

comptime sum (Cons 1 (Cons 2 (Cons 3 Nil)))  # => 6
```

### Built-in comptime operations

| Module | Function | Signature |
|--------|----------|-----------|
| String | `String.length` | `String -> Int` |
| String | `String.append` | `String -> String -> String` |
| String | `String.charAt` | `String -> Int -> Char` |
| String | `String.substring` | `String -> Int -> Int -> String` |
| String | `String.startsWith` | `String -> String -> Bool` |
| String | `String.endsWith` | `String -> String -> Bool` |
| List | `List.cons` | `a -> List a -> List a` |
| List | `List.head` | `List a -> a` |
| List | `List.tail` | `List a -> List a` |
| List | `List.length` | `List a -> Int` |
| List | `List.reverse` | `List a -> List a` |
| List | `List.append` | `a -> List a -> List a` |
| Int | `Int.toString` | `Int -> String` |

### Limitations

- **Scalar splicing only:** Comptime results that are int, float, bool, char, string, or unit are spliced directly into LLVM IR. Complex results (lists, tuples, constructors) fall back to runtime evaluation.
- **Independent evaluations:** Each `comptime expr` evaluates independently. Intermediate values from one comptime expression are not available to subsequent comptime expressions through runtime `let` bindings.
- **Max depth:** 10,000 evaluation steps per comptime expression.
