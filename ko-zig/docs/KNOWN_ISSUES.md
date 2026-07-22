# Known Issues

## Parser: Negative numbers as function arguments need parentheses

**Status:** Open (GitHub #17)  
**Severity:** Medium  
**Last tested:** 2026-07-22

### Problem

Negative numbers as function arguments must be wrapped in parentheses. Without parentheses, the parser treats `-3` as a minus operator applied to the function call.

### Current behavior

```ko
fn main =
  println (abs -3)    # ERROR: type mismatch
  println (abs (-3))  # Works: 3
```

### Expected behavior

```ko
fn main =
  println (abs -3)    # Should work: 3
```

### Workaround

Use parentheses: `f (-3)` instead of `f -3`

See GitHub issue [#17](https://github.com/Adjanour/ko-language/issues/17).

---

## Parser: Multi-line pipe operator doesn't work

**Status:** Open (GitHub #18)  
**Severity:** Low  
**Last tested:** 2026-07-22

### Problem

The pipe operator `|>` doesn't work across multiple lines.

### Current behavior

```ko
fn main =
  let result = 5
    |> \x -> x * 2    # ERROR: expected expression
    |> \x -> x + 1
  println result
```

### Expected behavior

```ko
fn main =
  let result = 5
    |> \x -> x * 2    # Should work
    |> \x -> x + 1
  println result
```

### Workaround

Put the entire pipe chain on one line:

```ko
fn main =
  let result = 5 |> \x -> x * 2 |> \x -> x + 1
  println result
```

See GitHub issue [#18](https://github.com/Adjanour/ko-language/issues/18).

---

## Parser: Record literal syntax doesn't work

**Status:** Open (GitHub #19)  
**Severity:** Medium  
**Last tested:** 2026-07-22

### Problem

Record literal syntax `{ name = "Alice", age = 30 }` causes a parse error.

### Current behavior

```ko
fn main =
  let person = { name = "Alice", age = 30 }  # ERROR: expected expression
  println person.name
```

### Expected behavior

```ko
fn main =
  let person = { name = "Alice", age = 30 }  # Should work
  println person.name
```

See GitHub issue [#19](https://github.com/Adjanour/ko-language/issues/19).

---

## Parser: `if/else if` chains fail in multi-line function bodies

**Status:** Open (GitHub #20)  
**Severity:** Medium  
**Last tested:** 2026-07-22

### Problem

`if/else if` chains cause type errors when used in multi-line function bodies.

### Current behavior

```ko
fn classify n =
  if n > 0 then "positive"
  else if n < 0 then "negative"    # ERROR: type mismatch
  else "zero"
```

### Expected behavior

```ko
fn classify n =
  if n > 0 then "positive"
  else if n < 0 then "negative"    # Should work
  else "zero"
```

### Workaround

Use nested `if/else` with parentheses:

```ko
fn classify n =
  if n > 0 then "positive"
  else (if n < 0 then "negative"
  else "zero")
```

See GitHub issue [#20](https://github.com/Adjanour/ko-language/issues/20).

---

## Codegen: Pattern matching on `True`/`False` causes type mismatch

**Status:** Open (GitHub #21)  
**Severity:** High  
**Last tested:** 2026-07-22

### Problem

Pattern matching on `True`/`False` constructors causes a type mismatch error, even though they are built-in Bool constructors.

### Current behavior

```ko
fn negate b =
  match b
    True => False
    False => True

fn main =
  println (negate True)  # ERROR: type mismatch: expected Bool, got Bool
```

### Expected behavior

```ko
fn negate b =
  match b
    True => False
    False => True

fn main =
  println (negate True)  # Should work: False
```

See GitHub issue [#21](https://github.com/Adjanour/ko-language/issues/21).

---

## Codegen: Lowercase `true`/`false` causes segfault

**Status:** Open (GitHub #22)  
**Severity:** High  
**Last tested:** 2026-07-22

### Problem

Using lowercase `true`/`false` in pattern matching causes a segmentation fault.

### Current behavior

```ko
fn negate b =
  match b
    true => false
    false => true

fn main =
  println (negate true)  # SEGFAULT
```

### Expected behavior

```ko
fn negate b =
  match b
    true => false
    false => true

fn main =
  println (negate true)  # Should work: false
```

See GitHub issue [#22](https://github.com/Adjanour/ko-language/issues/22).

---

## String.trim only trims leading whitespace

**Status:** Open (GitHub #16)  
**Severity:** Low  
**Last tested:** 2026-07-22

### Problem

`String.trim` only removes leading whitespace, not trailing whitespace.

### Current behavior

```ko
fn main =
  println (String.trim "  hello  ")   # "hello  " (trailing spaces remain)
```

### Expected behavior

```ko
fn main =
  println (String.trim "  hello  ")   # "hello" (both sides trimmed)
```

### Fix

Update `ko_string_trim` in `stdlib.zig` to trim both leading and trailing whitespace.

See GitHub issue [#16](https://github.com/Adjanour/ko-language/issues/16).

---

## Users must define List type before using lists

**Status:** Open (GitHub #15)  
**Severity:** Medium  
**Last tested:** 2026-07-22

### Problem

Lists are not a built-in type. Users must define `type List a = Cons a (List a) | Nil` before using `Cons`/`Nil`. This is poor UX — lists are a fundamental data structure.

### Current behavior

```ko
# Fails: undefined constructor 'Nil'
fn main = println (Cons 1 (Cons 2 Nil))

# Must write:
type List a = Cons a (List a) | Nil
fn main = println (Cons 1 (Cons 2 Nil))
```

### What should work out of the box

Like `Bool` (`True`/`False`) and `Result` (`Ok`/`Err`), lists should work without a type definition.

### Fix

Register `List`, `Cons`, and `Nil` as built-in types in `typecheck.zig` init, following the same pattern as Bool/True/False.

See GitHub issue [#15](https://github.com/Adjanour/ko-language/issues/15).

---

## List element printing uses tag=100 (unknown)

**Status:** Deferred  
**Severity:** Medium  
**Last tested:** 2026-07-22

### Problem

When printing a list with `println` or `inspect`, the list structure is detected correctly (`[1, 2, 3]`), but individual elements are printed using type tag=100 (unknown). This means:

- Strings print as raw pointers: `println (Cons "hello" Nil)` → `[140073513881720]`
- Non-integer elements may print incorrectly

### Root cause

The LLVM IR `inspect` function prints list elements via `inspect(head, 100, null, raw)`. Tag 100 means "unknown" — the inspect function has no type information for the head element and prints the raw i64 value.

### What works

```ko
type List a = Cons a (List a) | Nil

fn main =
  let xs = Cons 1 (Cons 2 (Cons 3 Nil))
  println xs          # [1, 2, 3] ✓
  println Nil         # [] ✓
  inspect xs          # [1, 2, 3] ✓
  print xs            # [1, 2, 3] ✓
```

### What doesn't work

```ko
println (Cons "hello" Nil)   # [140073513881720] ✗ (should be ["hello"])
println (Cons True Nil)      # [1] ✗ (should be [True])
```

### Possible fixes

1. **Store type tags in list nodes** — Add a type tag field to Cons cells so each element carries its type. Changes the list memory layout.

2. **Runtime type detection heuristic** — In the inspect function's tag=100 case, try to detect the type by looking at the value:
   - If val > 4096 (pointer), dereference and check if ptr[0] is a valid tag (0-9)
   - If yes, re-invoke inspect with the detected tag
   - Risk: false positives for non-tag pointer values

3. **Codegen-level type tag propagation** — When printing list elements, use the typechecker's type information to determine the element's type tag. Requires propagating type info through the list structure.

4. **Separate list element type** — Change the inspect function to accept a "element type hint" parameter for list printing. The codegen would pass the correct element type when printing lists.

### Related code

- `src/stdlib_codegen.zig:1450` — `codegenInspect` case 6 list printing calls `inspect(head, 100, null, raw)`
- `src/codegen.zig:1139` — `codegenFnCall` println/print name_ptr resolution
- `src/codegen.zig:3293` — `builtin_inspect_tag` tag=6 handling (JIT fallback)

---

## See Also

- [Status](STATUS.md) — current state and completed work
- [Roadmap](../ROADMAP.md) — future plans and phases
- [Handbook](HANDBOOK.md) — how to add features to the compiler
