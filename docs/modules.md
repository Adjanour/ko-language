# Modules and Imports

How Kō resolves imports, the two IO namespaces, and local modules.

---

## Standard Library

The stdlib lives in `std/`. Import with the `std.` prefix:

```ko
import std.List
import std.String
import std.Int
```

Selective imports bring specific names into scope:

```ko
import std.List.{map, filter, foldl}
import std.String.{length, append}
```

Aliased imports give a short name:

```ko
import std.Int as I
# I.abs, I.min, I.max, ...
```

## Available Modules

| Module | Functions | Description |
|--------|-----------|-------------|
| `std.List` | 31 | Cons, Nil, map, filter, foldl, foldr, head, tail, length, reverse, append, ... |
| `std.String` | 20+ | length, append, charAt, substring, toInt, contains, split, trim, repeat, ... |
| `std.Int` | 13 | pow, factorial, abs, min, max, gcd, lcm, isqrt (builtins) + even, odd, mod, clamp, sign (imported) |
| `std.Float` | 14 | sqrt, sin, cos, tan, exp, log, floor, ceil, abs, ofInt, toInt, pow |
| `std.Bool` | -- | True, False |
| `std.Math` | -- | abs, max, min, clamp, div, mod, gcd, lcm, factorial, pow, isqrt |
| `std.Set` | 12 | empty, singleton, fromArray, contains, add, remove, size, union, intersection, ... |
| `std.io` | 4 | readOrEmpty, writeOrDie, eprintErr, exists |

## Resolution

Kō resolves imports from two places:

1. **Standard library** -- `import std.List` looks for `std/List.ko` in the stdlib directory.
2. **Local modules** -- `import math` looks for `math.ko` in the same directory as the source file.

Module names are case-sensitive. `import List` without `std.` looks for a local `List.ko`,
not the stdlib.

## IO Namespaces

There are two IO things:

**Global builtins** (no import needed):

```ko
fn main =
    println "hello"       # print + newline
    print "no newline"    # print without newline
    inspect 42            # debug representation
    eprintErr "warning"   # print to stderr
```

**`std.io` module** (requires `import std.io`):

```ko
import std.io

fn main =
    let line = IO.readLine "> "
    IO.eprintln line
    IO.writeOrDie "out.txt" "content"
    inspect (IO.exists "out.txt")   # True
    match IO.readOrEmpty "out.txt"
        | Ok content => println content
        | Err _ => println "not found"
```

`IO.*` (uppercase) are global builtins. `io.*` (lowercase) are imported from `std.io`.

## Local Modules

Any `.ko` file in the same directory is a local module:

```ko
# math.ko
fn square x = x * x

# main.ko
import math

fn main =
    inspect (math.square 5)   # 25
```

---

*See also: [Writing Kō Programs](writing-ko-programs#imports)*
