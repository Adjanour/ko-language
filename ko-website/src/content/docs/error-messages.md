---
title: "Kō Error Messages"
---
# Kō Error Messages

A reference for every error and warning the ko compiler produces,
what it means, and how to fix it.

---

## Parse errors

These happen before type checking. The compiler found syntax it does not
recognize.

### `expected expression`

The parser expected a value but found something else. Common causes:

- **Multi-line let value:** `let x =\n  expr` does not parse. Keep value inline.
- **Trailing operator:** `let x = 1 +` (missing right side).
- **Missing function body:** `fn f x =` (nothing after `=`).

### `expected '=', got ':'`

Wrong annotation syntax. Use:

```ko
# WRONG:
fn add a b : Int = a + b

# CORRECT:
fn add (a : Int) (b : Int) -> Int = a + b
```

### `expected constructor name`

You used leading `|` in a multi-line type definition:

```ko
# WRONG:
type Shape =
  | Circle Float
  | Rect Float Float

# CORRECT (inline):
type Shape = Circle Float | Rect Float Float
```

### `expected pattern`

The pattern is not valid. Common cause: `\() ->` (unit lambda) does not
parse. Use `\_ ->` instead.

### `Module not found`

Import path does not resolve. Check:

- `import List` should be `import std.List` (stdlib needs `std.` prefix)
- Module names are case-sensitive
- Local modules must be in the same directory as the source file

---

## Type errors

### `type mismatch: expected X, got Y`

The types do not match. Common causes:

- **if branches return different types:** `if cond then 1 else println "no"`
  (Int vs Unit).
- **Pipe argument order:** `list |> filter pred` passes list as first arg,
  but `filter` expects `predicate list`. Use `filter pred list`.
- **Using a Result where Int is expected:** `let n = (String.toInt s)?`
  without parens around the `?` expression.

### `undefined name 'X'`

The name is not in scope. Common causes:

- **Missing import:** `map`, `filter`, `foldl` need `import std.List`.
- **Wrong name:** `to_string` should be `Int.toString`; `sqrt` should
  be `Float.sqrt`; `mod` should be `%` operator; `eprintln` should be
  `IO.eprintln`.
- **Top-level let:** top-level `let` bindings are not codegen'd in v0.3.x.
  Move into `fn main` or use `fn` definitions.

---

## Runtime errors

### `panic: assertion failed`

An `assert` condition was false. The program was called with invalid input,
or an internal invariant was violated.

### `panic: unwrap: Err value`

`Result.unwrap` was called on an `Err`. Use `Result.unwrapOr` instead:

```ko
# PANICS on Err:
Result.unwrap result

# Returns default on Err:
Result.unwrapOr "default" result
```

### `panic: write failed` or similar IO panic

`IO.writeOrDie` was called and the write failed (e.g. disk full, invalid path).
Check the path and permissions.

### Segmentation fault

Usually caused by a compiler bug, not a user error. Report it on GitHub
with the source file that triggers it.

---

## Warnings

### `linear variable used twice (warning)`

A variable was consumed in two places. The checker is conservative -- this
often happens with:

- Recursive accumulator patterns (`reverse xs acc`)
- Tree traversals (`show_expression left` then `show_expression right`)
- Shared cursors (`parse_expression cursor`)

The program runs correctly. See [linearity-and-ownership.md](linearity-and-ownership.md)
for details. Use `--skip-linearity` to silence.

### `linear variable never used (warning)`

A binding was created but never touched. Prefix with `_` to silence:

```ko
let _unused = expr
```

### `linear variable used after consumption (warning)`

A borrow happened after the variable was consumed. Same family as "used twice"
-- often a false positive in recursive functions.

---

## Codegen errors

### `LIR lowering error: ArityMismatch`

A function was called with the wrong number of arguments. This can happen
with:

- Passing a curried multi-arg function as a value
- Using `Int.fromString` (known bug in v0.3.x)
- Returned closures called with wrong arity

### `VerifierFailed`

The generated LLVM IR failed verification. Usually a compiler bug. The
function still runs in some cases via the legacy codegen fallback.

### `std init fn 'X' used as value not yet supported`

A stdlib builtin was used unapplied (as a value) instead of called:

```ko
# FAILS:
let name = IO.readLine

# WORKS:
let name = IO.readLine "> "
```

---

## CLI errors

### `error: cannot open file '--run'`

The `--run` flag does not exist. Use `ko file.ko` instead.

### `error: file not found`

The source file does not exist at the given path. Check for typos.
