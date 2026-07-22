# Kō Syntax Cheat Sheet

Quick reference for Kō syntax.

---

## Functions

```ko
fn name param1 param2 = body
fn name ~named ~params = body       # Named parameters
fn name = body                      # No parameters
\x -> expr                          # Lambda
\x y -> expr                        # Multi-param lambda
```

## Types

```ko
type Name = Constructor1 | Constructor2 Type    # Sum type
type Name = Constructor Type1 Type2             # Multi-arg constructor
type Name = { field1 : Type, field2 : Type }   # Record type
type Name a = Constructor a | Nil              # Parameterized type
```

## Expressions

```ko
let x = expr                     # Let binding
let (a, b) = expr                # Tuple destructuring
let { x, y } = expr              # Record destructuring
if cond then expr1 else expr2    # If expression
match expr | Pattern => body     # Pattern matching
fn_call arg1 arg2                # Function application
expr.field                       # Field access
expr |> fn                       # Pipe operator
```

## Patterns

```ko
| Constructor                    # Zero-arg constructor
| Constructor arg1 arg2          # Constructor with args
| Constructor (Nested pattern)   # Nested pattern
| { field1, field2 }             # Record pattern
| (a, b)                         # Tuple pattern
| _                              # Wildcard
| literal                        # Literal match
| x                              # Variable binding
```

## Operators

```ko
+ - * / %                        # Arithmetic
== != < <= > >=                  # Comparison
and or not                       # Logical
::                               # Cons (list construction)
:=                               # Assignment
!                                # Deref
|>                               # Pipe
.                                # Field access
```

## Comments

```ko
# This is a comment
# Comments extend to end of line
```

## Imports

```ko
import module.name               # Full import
import module.{fn1, fn2}         # Selective import
import module as alias           # Alias import
```

## Modules

```ko
package module.name              # Package declaration
pub fn name = body               # Public function
fn name = body                   # Private function
```

## Comptime

```ko
comptime fn name params = body   # Comptime function
comptime expr                    # Comptime expression
```

## References

```ko
ref expr                         # Create reference
!expr                            # Dereference
ref_expr := expr                 # Update reference
```

## Built-in Syntax

```ko
println expr                     # Print with newline
print expr                       # Print without newline
inspect expr                     # Debug print
expr?                            # Try operator (Result)
```

---

## See Also

- [Tutorial](TUTORIAL.md) — beginner guide with examples
- [Language Reference](LANGUAGE_REFERENCE.md) — complete syntax reference
- [Handbook](HANDBOOK.md) — how to add features to the compiler
- [Known Issues](KNOWN_ISSUES.md) — bugs and limitations

---

*Kō (光) means "light" in Japanese.*
