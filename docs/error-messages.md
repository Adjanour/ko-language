# Kō Error Messages

Every error and warning the ko compiler produces, with causes and fixes.

---

## Parse Errors

### `expected expression`

The parser expected a value. Common causes:

- Multi-line `let` value (`let x =\n  expr`). Keep the value on the same line as `=`.
- Trailing operator (`let x = 1 +`).
- Missing function body (`fn f x =`).

### `expected '=', got ':'`

Wrong annotation syntax:

```ko
# Wrong
fn add a b : Int = a + b

# Correct
fn add (a : Int) (b : Int) -> Int = a + b
```

### `expected constructor name`

Leading `|` in a type definition:

```ko
# Wrong
type Shape =
    | Circle Float
    | Rect Float Float

# Correct
type Shape = Circle Float | Rect Float Float
```

### `expected pattern`

Invalid pattern. Common cause: `\() ->` does not parse. Use `\_ ->` instead.

### `Module not found`

Import path does not resolve.

- `import List` should be `import std.List`
- Module names are case-sensitive
- Local modules must be in the same directory as the source file

---

## Type Errors

### `type mismatch: expected X, got Y`

Common causes:

- if branches return different types: `if cond then 1 else println "no"` (Int vs Unit).
- Pipe argument order: `list |> filter pred` passes list as first arg, but `filter` expects `predicate list`.
- Missing parens around `?` expression.

### `undefined name 'X'`

Name not in scope.

- Missing import: `map`, `filter`, `foldl` need `import std.List`.
- Wrong name: use `Int.toString` not `to_string`, `Float.sqrt` not `sqrt`, `%` not `mod`, `IO.eprintln` not `eprintln`.
- Top-level `let` not codegen'd: move into `fn main` or use `fn` definitions.

---

## Runtime Errors

### `panic: assertion failed`

An `assert` condition was false. Check input values.

### `panic: unwrap: Err value`

`Result.unwrap` called on an `Err`. Use `Result.unwrapOr`:

```ko
Result.unwrapOr "default" result
```

### `panic: write failed`

`IO.writeOrDie` failed. Check path and permissions.

### Segmentation fault

Usually a compiler bug. Report on GitHub with the source file.

---

## Warnings

### `linear variable used twice (warning)`

Variable consumed in two places. The checker is conservative -- common with
recursive accumulators, tree traversals, and shared cursors. The program
runs correctly. Use `--skip-linearity` to silence.

### `linear variable never used (warning)`

Binding never touched. Prefix with `_`:

```ko
let _unused = expr
```

### `linear variable used after consumption (warning)`

Borrow after consume. Same family as "used twice" -- often a false positive.

---

## Codegen Errors

### `LIR lowering error: ArityMismatch`

Wrong number of arguments. Known causes: curried multi-arg functions as values,
`Int.fromString` (bug), returned closures with wrong arity.

### `VerifierFailed`

LLVM IR verification failed. Usually a compiler bug. The function may still
run via legacy codegen fallback.

### `std init fn 'X' used as value not yet supported`

Stdlib builtin used unapplied:

```ko
# Wrong
let name = IO.readLine

# Correct
let name = IO.readLine "> "
```

---

## CLI Errors

### `error: cannot open file '--run'`

The `--run` flag does not exist. Use `ko file.ko` instead.

### `error: file not found`

Source file does not exist at the given path.
