# Linearity and Ownership

Kō's ownership model, the linearity checker, and how to read its warnings.

---

## Linear Types

Most values in Kō are linear -- used exactly once. This lets the compiler
free tree-shaped data with plain `free` instead of reference counting or
a garbage collector.

```ko
let xs = Cons 1 (Cons 2 Nil)   # xs owns its tree
let n  = length xs             # xs is consumed -- ownership transfers to length
```

## Shared Data with `ref`

When you need shared access, use `ref`:

```ko
let shared = ref (Cons 1 (Cons 2 Nil))   # RC'd shared data
let a = !shared    # borrow (RC incremented)
let b = !shared    # borrow (RC incremented)
```

`ref` creates a reference-counted box. `!` borrows temporarily. The borrow
does not outlive the `ref`.

## Consume vs. Borrow

The linearity checker classifies every variable use:

| Context | Behaviour | Examples |
|---------|-----------|----------|
| **Consume** | Ownership transfers, variable used-up | function args, `match` scrutinee, `if`/`else` branches, constructor args, tuple/record fields |
| **Borrow** | Read-only, can be reused | primop args (`x + y`), `if` condition, field access, `!x` deref |

```ko
fn double x = x + x    # both uses are borrows (primop args)
```

```ko
fn first_or_zero xs =
    match xs              # xs consumed by match
        | Cons h _ => h
        | Nil => 0
```

Function arguments are always assumed to consume, even read-only helpers
like `length`. The type system cannot see inside functions, so it assumes
the worst.

## Warnings

The checker produces three warnings (never errors):

**`linear variable used twice`** -- variable consumed in two places.
Common with recursive accumulators and tree traversals:

```ko
fn reverse xs acc =
    match xs
        | Cons x rest => reverse rest (Cons x acc)   # xs and acc consumed
        | Nil => acc
```

**`linear variable used after consumption`** -- borrow after consume.
Same family, different wording.

**`linear variable never used`** -- binding never touched. Prefix with `_`:

```ko
fn first xs =
    match xs
        | Cons h _ => h    # _ silences the warning
        | Nil => 0
```

All warnings are reported at the variable's binding site.

## Case Study: `mini_lexer.ko`

A lexer/parser with five linearity warnings:

```ko
fn reverse xs acc = ...            # xs and acc are accumulators
fn parse_multiplication cursor = ...  # cursor threaded through calls
fn parse_addition_tail cursor left = ...
fn parse_expression cursor = ...
fn show_expression expression = ...   # tree traversal
```

Each warning is a checker limitation, not an unsafe ownership bug. The
cursor is wrapped in `ref` for shared access -- the warnings reflect the
checker's conservative analysis of parameter flow, not actual ownership
hazards.

## Working Around It

- `--skip-linearity` disables the checker entirely.
- `_name` bindings silence "never used" warnings.
- Restructure code to split values at consumption points.

## When to Worry

Treat a warning as a question, not a verdict. It is a real bug when you
rely on a value after handing it away. It is noise when the flow is a
single ownership spine (accumulator recursion, tree walks, cursor
threading) -- the checker just cannot prove it yet.

---

*See also: [Writing Kō Programs](writing-ko-programs#linearity)*
