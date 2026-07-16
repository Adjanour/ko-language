# The Kō Lexer & Parser Challenge

A series of challenges to test your understanding of how Kō's lexer and parser work. Work through these without looking at the source code first. Then check your answers against the actual implementation in `src/lexer.zig` and `src/parser.zig`.

---

## Part 1: Lexer Intuition

### Challenge 1.1: The Comment Problem

Given this input:
```ko
x = 42  # this is a comment
y = 10
```

How many tokens does the lexer produce? What are they? And critically — how does the lexer know the comment is *inline* (attached to the `x = 42` line) versus *standalone* (a comment line on its own)?

<details>
<summary>Answer</summary>

The lexer produces: `x`, `=`, `42`, `# this is a comment`, `NEWLINE`, `y`, `=`, `10`, `NEWLINE`, `EOF`

The `isInlineComment()` check: look at the token before the comment. If there's a non-newline token before it on the same line, it's inline. If the previous tokens are all newlines/indents, it's standalone.

The key insight: the comment token is always produced. The *parser* decides what to do with it based on context. Standalone comments break non-indented blocks (they're doc comments for the NEXT definition). Inline comments are skipped transparently.
</details>

---

### Challenge 1.2: The Indentation Stack

Given this input:
```ko
fn add x y =
  if x == 0 then y
  else add (x - 1) (y + 1)
println (add 3 5)
```

Trace the INDENT and DEDENT tokens. When are they emitted? How many DEDENTs are emitted at once when indentation decreases?

<details>
<summary>Answer</summary>

Tokens: `fn`, `add`, `x`, `y`, `=`, `NEWLINE`, `INDENT`, `if`, `x`, `==`, `0`, `then`, `y`, `NEWLINE`, `else`, `add`, `(`, `x`, `-`, `1`, `)`, `(`, `y`, `+`, `1`, `)`, `NEWLINE`, `DEDENT`, `println`, `(`, `add`, `3`, `5`, `)`, `NEWLINE`, `EOF`

The INDENT is emitted after `=` when the next line has deeper indentation. The DEDENT is emitted when indentation decreases. If indentation decreases by two levels, two DEDENTs are emitted at once — they're queued and flushed together.

The key insight: the lexer tracks an *indentation stack*. When a new line's indentation is greater than the top of stack, push and emit INDENT. When less, pop and emit DEDENT for each level popped. When equal, emit nothing.
</details>

---

### Challenge 1.3: The `!` Ambiguity

How does the lexer handle `!expr` (deref) versus `not expr` (boolean negation)? Are they different tokens? What about `!=`?

<details>
<summary>Answer</summary>

`!` is a separate token (`.bang`). `!=` is a separate token (`.not_equal`). `not` is a keyword.

The parser decides what `!` means based on context. In `!x`, it's deref. In `! =` it would be a syntax error. The lexer doesn't distinguish — it just produces `.bang`. The parser's `parse_unary` handles it.

The key insight: the lexer is context-free. It produces tokens without knowing what they mean. The parser gives them meaning.
</details>

---

## Part 2: Parser Intuition

### Challenge 2.1: The Precedence Puzzle

What does this parse to?

```ko
1 + 2 * 3
```

And this?

```ko
1 * 2 + 3
```

And this?

```ko
1 + 2 + 3
```

How does the parser handle left-associativity vs right-associativity?

<details>
<summary>Answer</summary>

`1 + 2 * 3` parses as `1 + (2 * 3)` — multiplication binds tighter.

`1 * 2 + 3` parses as `(1 * 2) + 3` — same precedence, left-associative.

`1 + 2 + 3` parses as `(1 + 2) + 3` — left-associative.

The parser uses 12 precedence levels. Each level has a `parse_expr_precedence(level)` function. Higher precedence operators are parsed first. Left-associativity is handled by parsing the left side first, then checking for more operators at the same level.

The key insight: precedence is encoded in the parser structure, not in a table. Each precedence level is a separate parsing function.
</details>

---

### Challenge 2.2: The Match Arm Problem

Given this input:
```ko
match x
  | Cons a (Cons b rest) => a + b
  | Cons a Nil => a
  | Nil => 0
```

How does the parser know where one match arm ends and the next begins? What stops the parser from consuming the `|` as part of the previous arm?

<details>
<summary>Answer</summary>

Match arms are separated by `|`. The parser parses one arm, then checks if the next token is `|`. If yes, it parses another arm. If no, the match expression is done.

The `|` at the start of a line is the key signal. The parser knows it's a match arm separator because of the `|` token, not because of indentation.

The key insight: match arms are parsed in a loop. Each iteration checks for `|`, parses the pattern, then parses `=>` and the body. The loop ends when there's no `|`.
</details>

---

### Challenge 2.3: The `allow_let_in_body` Pattern

Why does `parse_block` need an `allow_let_in_body` flag? What happens without it?

Given this input:
```ko
fn main =
  let x = 1
  let y = 2
  x + y
```

And this input:
```ko
let x = 1
let y = 2
x + y
```

How does the parser handle each case differently?

<details>
<summary>Answer</summary>

The first input is a function body. `let x = 1` should terminate the block (it's a top-level let binding inside the function). The function body is `let x = 1`, then `let y = 2`, then `x + y`.

The second input is a sequence of let expressions. `let x = 1` is a let expression whose body is `let y = 2 in x + y`.

The `allow_let_in_body` flag distinguishes these cases. When parsing a function body, it's `false` — `let` terminates the block. When parsing a let expression body, it's `true` — `let` is parsed as a nested let expression.

Without this flag, the parser would either consume all lets into one function body (wrong) or break at every let (wrong). The flag is the switch that controls this behavior.

The key insight: `parse_block` is called from two contexts with different needs. The flag lets it behave correctly in both.
</details>

---

## Part 3: The Deep Cuts

### Challenge 3.1: The `@embedFile` Gotcha

Why does `@embedFile("path")` returning a null-terminated string cause problems? What goes wrong if you append `++ "\x00"`?

<details>
<summary>Answer</summary>

`@embedFile` returns `*const [N:0]u8` — already null-terminated. The source buffer's null terminator is at the end of the entire buffer.

If you append `++ "\x00"`, you get a double null: `...\0\0`. The tokenizer reads the first null and stops — it thinks it's reached the end of the source. But the actual source continues after the first null. The tokenizer misreads the source and produces wrong tokens.

The key insight: the null terminator is at the end of the buffer, not at the end of each slice. Parser slices are `[]const u8` — they don't know about the null terminator. The tokenizer must handle this correctly.
</details>

---

### Challenge 3.2: The `isInlineComment` Edge Case

Given this input:
```ko
x = 42
# standalone comment
y = 10
```

The lexer produces: `x`, `=`, `42`, `NEWLINE`, `# standalone comment`, `NEWLINE`, `y`, `=`, `10`, `NEWLINE`, `EOF`

The parser is in a non-indented block. It sees the comment token. How does `isInlineComment()` determine this is NOT an inline comment?

<details>
<summary>Answer</summary>

`isInlineComment()` looks at the token before the comment. It skips past any `.newline` tokens to find the previous non-newline token. If that token is on the same line as the comment, it's inline. If it's on a different line, it's standalone.

In this case, the previous non-newline token is `42`. There's a `NEWLINE` between `42` and the comment. So the comment is on a different line — it's standalone.

The key insight: the check must skip past consumed `.newline` tokens. If it doesn't, it sees the newline as the previous token and thinks the comment is standalone (which it is, but for the wrong reason). The logic must be: find the previous *content* token, then check if it's on the same line.
</details>

---

### Challenge 3.3: The `fn_body_stops` Mystery

What tokens are in `fn_body_stops`? Why is `keyword_let` NOT in it? What would happen if you added it?

<details>
<summary>Answer</summary>

`fn_body_stops` contains tokens that terminate a function body: `keyword_type`, `keyword_import`, `keyword_package`, `keyword_pub`, `keyword_comptime`, `comment` (standalone), and `newline` (non-indented).

`keyword_let` is NOT in it. If you added it, the function body would consume subsequent top-level let bindings. `fn main = let x = 1` would eat `let y = 2` as part of the body, breaking the program structure.

The key insight: `fn_body_stops` determines what terminates a function body. Adding `let` would make the body too greedy. The `allow_let_in_body` flag handles the let case separately, without changing `fn_body_stops`.
</details>

---

## Part 4: The Real Test

### Challenge 4.1: Debug This

This program crashes the parser. Why?

```ko
match xs
  | Cons x (Cons y rest) => x + y
  | Cons x Nil => x
  | Nil => 0
nextExpr
```

What's the bug? How would you fix it?

<details>
<summary>Answer</summary>

The multi-line `match` expression is followed by another expression (`nextExpr`). The parser's `parse_postfix` sees `nextExpr` after the match and tries to parse it as a match arm argument. The match consumes `nextExpr`, breaking the program.

This is a known parser limitation. The workaround is to extract the match into a helper function, or use single-line match arms.

The key insight: the parser's postfix handling is greedy. After a match expression, it expects nothing more on that line. If there's something there, it gets consumed. This is a design choice that causes edge cases.
</details>

---

### Challenge 4.2: Write the Tokenizer

Write a tokenizer (in pseudocode or any language) that handles:
- INDENT/DEDENT tracking
- Inline vs standalone comments
- String literals with escape sequences
- The `!` token (separate from `!=`)

Test it with this input:
```ko
fn hello name =
  let greeting = "Hello, " ++ name ++ "!"
  println greeting
```

<details>
<summary>Answer</summary>

The tokenizer should produce:
`fn`, `hello`, `name`, `=`, `NEWLINE`, `INDENT`, `let`, `greeting`, `=`, `"Hello, "`, `++`, `name`, `++`, `"!"`, `NEWLINE`, `println`, `greeting`, `NEWLINE`, `DEDENT`, `EOF`

Key points:
- INDENT after `=` when next line is deeper
- `!` is a separate token (not part of `++`)
- String literals include the quotes
- DEDENT when indentation decreases

The key insight: the tokenizer tracks indentation state. It doesn't know about function bodies or let expressions — it just tracks indentation levels. The parser gives meaning to INDENT/DEDENT.
</details>

---

## Part 5: The Ultimate Challenge

### Challenge 5.1: Add a Feature

Add `where` clauses to Kō. This would allow:

```ko
fn quadratic a b c x =
  a * x * x + b * x + c
  where
    x2 = x * x
```

What lexer changes are needed? What parser changes? What AST changes? What typechecker changes? What codegen changes?

<details>
<summary>Answer</summary>

**Lexer**: No changes. `where` would be a new keyword.

**Parser**: Add `where` as a keyword. In `parse_fn_def`, after parsing the body, check for `where`. If present, parse a block of let bindings. Add a new AST node `WhereClause` that holds the body and the let bindings.

**AST**: Add `where` field to `FnDef`. Or create a new `WhereExpr` node.

**Typechecker**: Process the where bindings before the body. Add them to the local environment.

**Codegen**: Generate the where bindings as let expressions before the body. The where clause is syntactic sugar for nested lets.

The key insight: `where` is syntactic sugar. It desugars to nested let expressions. The parser handles the syntax, the rest of the compiler treats it as if the programmer wrote nested lets.
</details>

---

## How to Use This Challenge

1. **Try each challenge without looking at the source.** Write your answer down.
2. **Check your answer against the source code.** Look at `src/lexer.zig` and `src/parser.zig`.
3. **If you got it wrong, understand why.** The source code is the truth.
4. **Repeat until you can answer confidently.**

The goal isn't to memorize the code. It's to understand *why* the code is written the way it is. Every design decision has a reason. Find the reason.

---

## Bonus: The Reading Order

If you want to understand the lexer and parser deeply, read the source in this order:

1. `src/ast.zig` — What the AST looks like
2. `src/lexer.zig` — How tokens are produced
3. `src/parser.zig` — How tokens become AST
4. `src/tests.zig` — What the tests verify
5. `src/tests_ko/` — What the test programs look like

Read each file completely. Don't skip. Don't skim. Understand every line. The code is small enough to read in a weekend. The understanding will last forever.
