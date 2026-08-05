# Kō Math Semantics

> **Status:** Design Draft
> **Date:** 2026-08-01
> **Research:** Rust integer overflow, Python arbitrary precision, JavaScript IEEE 754, Zig math

---

## 1. Current State

### Integer

- `Int` = `i64` (64-bit signed, two's complement)
- Operators: `+`, `-`, `*`, `/`, `%`
- Division by zero: panics at runtime
- Overflow: wraps (LLVM default for `add`/`sub`/`mul`)
- Builtins: `Int.abs`, `Int.pow`, `Int.gcd`, `Int.lcm`, `Int.factorial`, `Int.isqrt`

### Float

- `Float` = `f64` (IEEE 754 double precision)
- Operators: Not yet supported by the typechecker (only builtins work)
- Builtins: `Float.sqrt`, `Float.sin`, `Float.cos`, `Float.tan`, `Float.exp`, `Float.log`, `Float.floor`, `Float.ceil`, `Float.abs`, `Float.pow`
- Edge cases: Follows IEEE 754 (NaN propagation, infinity)

### What's Documented But Not Implemented

- Float arithmetic operators (`+`, `-`, `*`, `/`) — typechecker doesn't support them
- `Float.round`, `Float.trunc`
- `Float.atan`, `Float.atan2`, `Float.asin`, `Float.acos`
- `Int.fromString` (parse string as int)
- `Int.min_value`, `Int.max_value` constants

---

## 2. Design Questions

### Q1: Should integer overflow panic, wrap, or be undefined?

| Behavior | Language | Pros | Cons |
|----------|----------|------|------|
| Wrap | C, Rust (release), Go | Fast, predictable, matches hardware | Silent bugs |
| Panic | Rust (debug), Kō (div by zero) | Catches bugs | Runtime cost, unpredictable |
| Undefined | C (signed) | Maximum optimization | Security risk, hard to debug |
| Arbitrary precision | Haskell, Python | No overflow | Slow, unpredictable allocation |

### Q2: Should `Int` be fixed-size or arbitrary precision?

**Fixed-size (`i64`):** Fast, predictable, matches hardware. But overflows silently for large numbers.

**Arbitrary precision:** Correct, no overflow. But allocation per operation, unpredictable performance, larger memory footprint.

### Q3: How should division by zero be handled?

**Panic (current):** Simple, catches bugs. But crashes the program.

**Result:** Safe, composable. But verbose for the common case (known non-zero divisors).

**Mixed:** Panic for `/` operator, Result for `Int.div` function.

### Q4: What about Float edge cases?

- `0.0 / 0.0` = NaN
- `1.0 / 0.0` = Infinity
- `NaN != NaN`
- Should these panic or propagate?

### Q5: Should Float operators use different syntax from Int?

If `+` works on both `Int` and `Float`, the typechecker needs to infer which one. This can cause confusing error messages when the types are ambiguous.

Alternative: Use `.` suffix for Float operators (`+.`, `-.`, `*.`, `/.`).

---

## 3. Proposed Design

### Integer Semantics

**Width:** `Int` = `i64` (64-bit signed, two's complement). No arbitrary precision in the language — that's a library concern (`std.math.big`).

**Overflow:** Wraps. `2^63 - 1 + 1` = `-2^63`. This is what hardware does and is the fastest behavior.

**Operators vs functions:**

| Operation | Operator | Function | Behavior on error |
|-----------|----------|----------|-------------------|
| Addition | `a + b` | `Int.add a b` | Wraps |
| Subtraction | `a - b` | `Int.sub b` | Wraps |
| Multiplication | `a * b` | `Int.mul a b` | Wraps |
| Division | `a / b` | `Int.div a b` | Panics on /0 |
| Modulo | `a % b` | `Int.mod a b` | Panics on /0 |
| Negation | `-a` | `Int.neg a` | Wraps |

Operators always use the wrapping/panicking behavior. Functions give you control.

**Checked arithmetic (new):**

```ko
# Returns Result instead of wrapping/panicking
Int.addChecked : Int -> Int -> Result Overflow Int
Int.subChecked : Int -> Int -> Result Overflow Int
Int.mulChecked : Int -> Int -> Result Overflow Int

# Division by zero returns Result
Int.div : Int -> Int -> Result DivisionByZero Int
Int.mod : Int -> Int -> Result DivisionByZero Int

# Safe division with default
Int.divOr : Int -> Int -> Int -> Int    # divOr 0 10 0 => 0
```

**Error types:**

```ko
type Overflow = Overflow
type DivisionByZero = DivisionByZero
```

**Constants:**

```ko
Int.maxValue : Int                  # 2^63 - 1 = 9223372036854775807
Int.minValue : Int                  # -2^63 = -9223372036854775808
```

### Float Semantics

**Width:** `Float` = `f64` (IEEE 754 double precision).

**Operators:** Use `.` suffix to distinguish from integer operators.

| Operation | Operator | Function |
|-----------|----------|----------|
| Addition | `a +. b` | `Float.add a b` |
| Subtraction | `a -. b` | `Float.sub a b` |
| Multiplication | `a *. b` | `Float.mul a b` |
| Division | `a /. b` | `Float.div a b` |
| Negation | `-.a` | `Float.neg a` |
| Comparison | `a <. b`, `a <=. b`, etc. | `Float.compare a b` |

**Edge cases:** Follow IEEE 754. Do not panic.

```ko
0.0 /. 0.0        # NaN
1.0 /. 0.0        # Infinity
-.1.0 /. 0.0      # -Infinity
0.0 *. infinity    # NaN
```

**Predicates:**

```ko
Float.isNaN : Float -> Bool
Float.isInfinite : Float -> Bool
Float.isFinite : Float -> Bool
Float.isNormal : Float -> Bool
Float.sign : Float -> Int          # -1, 0, 1 (NaN returns 0)
```

**Comparison that handles NaN:**

```ko
type Ordering = Less | Equal | Greater | Unordered

Float.compare : Float -> Float -> Ordering
```

Standard comparison operators return `false` when either operand is NaN:

```ko
nan < 5.0     # false
nan == nan     # false
nan <= 5.0     # false
```

Use `Float.compare` for total ordering.

**Type safety:** `5 + 3.0` is a type error. Use `5 +. (Int.toFloat 3)`.

```ko
Int.toFloat : Int -> Float        # lossless for small ints
Float.toInt : Float -> Int        # truncates toward zero
Float.round : Float -> Int        # rounds to nearest, ties to even
Float.floor : Float -> Int        # rounds toward -inf
Float.ceil : Float -> Int         # rounds toward +inf
```

**Constants:**

```ko
Float.pi : Float                    # 3.141592653589793
Float.e : Float                     # 2.718281828459045
Float.infinity : Float              # inf
Float.nan : Float                   # nan
Float.maxValue : Float              # 1.7976931348623157E+308
Float.minValue : Float              # 2.2250738585072014E-308
Float.epsilon : Float               # 2.220446049250313E-16 (smallest x where 1.0 + x != 1.0)
```

### Numeric Tower

Kō doesn't have a numeric tower. `Int` and `Float` are separate types with explicit conversion:

```ko
Int.toFloat : Int -> Float
Float.toInt : Float -> Int
```

No implicit coercions. `5 + 3.0` is a type error.

### BigInt (Future: `std.math.big`)

For when `i64` isn't enough:

```ko
import std.math.big

let x = Big.fromInt 123456789012345678901234567890
let y = Big.fromInt 999999999999999999999999999999
let z = Big.add x y
Big.toString z  # "1123456789012345678901234567889"
```

BigInt is a library, not a language feature. It uses `malloc` for arbitrary-precision arithmetic.

---

## 4. Detailed Semantics

### Integer Division

`Int.div` is truncation division (toward zero):

```ko
7 / 2       # 3
-7 / 2      # -3
7 / -2      # -3
-7 / -2     # 3
```

`Int.mod` is the remainder of truncation division:

```ko
7 % 2       # 1
-7 % 2      # -1
7 % -2      # 1
-7 % -2     # -1
```

The invariant: `(a / b) * b + (a % b) == a` (when b != 0).

**Floor division alternative (future):**

If floor division is needed, add it as a separate function:

```ko
Int.divFloor : Int -> Int -> Int    # toward -inf
Int.modFloor : Int -> Int -> Int    # always non-negative
```

### Integer Negation

`-a` wraps: `-(-2^63)` = `-2^63` (no positive representation).

```ko
Int.neg : Int -> Int
Int.negChecked : Int -> Result Overflow Int
```

### Float Division

Follows IEEE 754 exactly:

```ko
0.0 /. 0.0        # NaN (not a number)
1.0 /. 0.0        # Infinity
-.1.0 /. 0.0      # -Infinity
infinity /. 2.0    # Infinity
nan /. 2.0         # NaN
```

No panic. NaN propagates through all operations.

### Float-Int Mixing

No implicit mixing. Explicit conversion required:

```ko
let x : Int = 5
let y : Float = 3.14

x + y       # TYPE ERROR
x +. y      # TYPE ERROR (still Int vs Float)
y +. (Int.toFloat x)  # OK: Float + Float
x + (Float.toInt y)    # OK: Int + Int
```

### Bitwise Operations

```ko
# Bitwise (Int only)
a land b       # bitwise AND
a lor b        # bitwise OR
a lxor b       # bitwise XOR
lnot a         # bitwise NOT
a lsl n        # logical shift left
a lsr n        # logical shift right
a asr n        # arithmetic shift right
```

These are not in the current spec. Add them to the stdlib or as builtins.

### Random Numbers

```ko
# Pure random (seeded)
random : Int -> Int -> Int -> Int    # seed, min, max

# Time-seeded (impure)
randomInt : Int -> Int -> Int        # min, max
randomFloat : Float -> Float         # min, max
```

The current `random` function uses a seed parameter for reproducibility. This is fine for testing. Add time-seeded variants for real randomness.

---

## 5. Implementation

### Codegen for Integer Operators

```llvm
; a + b (integer)
%result = add i64 %a, %b

; a - b (integer)
%result = sub i64 %a, %b

; a * b (integer)
%result = mul i64 %a, %b

; a / b (integer, with zero check)
%is_zero = icmp eq i64 %b, 0
br i1 %is_zero, label %panic, label %divide
panic:
  call void @ko_panic(i8* @div_by_zero_msg)
  unreachable
divide:
  %result = sdiv i64 %a, %b

; a % b (integer, with zero check)
%is_zero = icmp eq i64 %b, 0
br i1 %is_zero, label %panic, label %modulo
modulo:
  %result = srem i64 %a, %b
```

### Codegen for Float Operators

```llvm
; a +. b (float)
%result = fadd double %a, %b

; a -. b (float)
%result = fsub double %a, %b

; a *. b (float)
%result = fmul double %a, %b

; a /. b (float) — no zero check, IEEE 754 handles it
%result = fdiv double %a, %b
```

### Codegen for Checked Arithmetic

```llvm
; Int.addChecked a b
%result = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %a, i64 %b)
%value = extractvalue { i64, i1 } %result, 0
%overflow = extractvalue { i64, i1 } %result, 1
br i1 %overflow, label %overflow_err, label %ok
overflow_err:
  ; Return Err Overflow
  %err = call %Constructor* @ko_make_constructor(i64 1, i64 0)  ; tag 1 = Err
  ret %Constructor* %err
ok:
  ; Return Ok value
  %ok_val = call %Constructor* @ko_make_constructor(i64 0, i64 %value)  ; tag 0 = Ok
  ret %Constructor* %ok_val
```

### Codegen for Float Predicates

```llvm
; Float.isNaN
%result = call i1 @llvm.isnan.f64(double %x)

; Float.isInfinite
%result = call i1 @llvm.isinf.f64(double %x)

; Float.isFinite
%result = call i1 @llvm.isfinite.f64(double %x)
```

---

## 6. std.math Module

```ko
module Math =
  # === Constants ===
  PI : Float
  E : Float
  TAU : Float           # 2 * PI
  SQRT2 : Float
  SQRT3 : Float
  LN2 : Float
  LN10 : Float
  LOG2E : Float
  LOG10E : Float

  # === Int operations ===
  abs : Int -> Int
  sign : Int -> Int     # -1, 0, 1
  clamp : Int -> Int -> Int -> Int
  gcd : Int -> Int -> Int
  lcm : Int -> Int -> Int
  pow : Int -> Int -> Int
  isqrt : Int -> Int    # integer square root
  factorial : Int -> Int
  even : Int -> Bool
  odd : Int -> Bool
  min : Int -> Int -> Int
  max : Int -> Int -> Int

  # === Checked Int operations ===
  addChecked : Int -> Int -> Result Overflow Int
  subChecked : Int -> Int -> Result Overflow Int
  mulChecked : Int -> Int -> Result Overflow Int
  divChecked : Int -> Int -> Result DivisionByZero Int
  modChecked : Int -> Int -> Result DivisionByZero Int

  # === Float operations ===
  sqrt : Float -> Float
  cbrt : Float -> Float
  pow : Float -> Float -> Float
  exp : Float -> Float
  log : Float -> Float
  log2 : Float -> Float
  log10 : Float -> Float
  sin : Float -> Float
  cos : Float -> Float
  tan : Float -> Float
  asin : Float -> Float
  acos : Float -> Float
  atan : Float -> Float
  atan2 : Float -> Float -> Float
  sinh : Float -> Float
  cosh : Float -> Float
  tanh : Float -> Float
  floor : Float -> Int
  ceil : Float -> Int
  round : Float -> Int
  trunc : Float -> Int
  abs : Float -> Float
  min : Float -> Float -> Float
  max : Float -> Float -> Float
  clamp : Float -> Float -> Float -> Float

  # === Float predicates ===
  isNaN : Float -> Bool
  isInfinite : Float -> Bool
  isFinite : Float -> Bool
  isNormal : Float -> Bool
  sign : Float -> Int

  # === Conversions ===
  Int.toFloat : Int -> Float
  Float.toInt : Float -> Int

  # === Comparison ===
  compare : Float -> Float -> Ordering   # Less | Equal | Greater | Unordered

  # === Big integers (future) ===
  # module Big =
  #   fromInt : Int -> Big
  #   add : Big -> Big -> Big
  #   mul : Big -> Big -> Big
  #   toString : Big -> String
```

---

## 7. Examples

### Integer Arithmetic

```ko
fn main =
  println (7 / 2)         # 3
  println (7 % 2)         # 1
  println (-7 / 2)        # -3
  
  match Int.divChecked 10 0
    Ok result -> println result
    Err DivisionByZero -> println "cannot divide by zero"
  
  let x = Int.addChecked 9223372036854775807 1
  match x
    Ok v -> println v
    Err Overflow -> println "overflow!"
```

### Float Arithmetic

```ko
fn main =
  let pi = Float.pi
  let r = 5.0
  let area = pi *. r *. r
  println area             # 78.53981633974483
  
  println (0.0 /. 0.0)    # nan
  println (1.0 /. 0.0)    # inf
  
  if Float.isNaN (0.0 /. 0.0) then
    println "NaN detected"
```

### Checked Arithmetic

```ko
import std.math

fn safe_divide a b =
  match Int.divChecked a b
    Ok result -> result
    Err DivisionByZero ->
      println "Warning: division by zero, returning 0"
      0

fn main =
  println (safe_divide 10 2)    # 5
  println (safe_divide 10 0)    # Warning: division by zero, returning 0
                                 # 0
```

### Bitwise Operations

```ko
fn main =
  println (0xFF land 0x0F)      # 15
  println (0xF0 lor 0x0F)      # 255
  println (0xFF lxor 0x0F)     # 240
  println (1 lsl 8)            # 256
  println (256 lsr 4)          # 16
```

---

## 8. Implementation Phases

### Phase 1: Core Math (v0.3.0)

- [ ] Fix float arithmetic typechecker support
- [ ] Add Float operators (`+.`, `-.`, `*.`, `/.`)
- [ ] Add `Int.addChecked`, `Int.subChecked`, `Int.mulChecked`
- [ ] Add `Int.divChecked`, `Int.modChecked`
- [ ] Add `Float.isNaN`, `Float.isInfinite`, `Float.isFinite`
- [ ] Add `Int.maxValue`, `Int.minValue` constants
- [ ] Add `Float.pi`, `Float.e`, `Float.infinity`, `Float.nan` constants

### Phase 2: Extended Math (v0.3.0)

- [ ] Add `Float.atan2`, `Float.asin`, `Float.acos`, `Float.atan`
- [ ] Add `Float.sinh`, `Float.cosh`, `Float.tanh`
- [ ] Add `Float.round`, `Float.trunc`
- [ ] Add `Float.compare` (total ordering)
- [ ] Add bitwise operators (`land`, `lor`, `lxor`, `lnot`, `lsl`, `lsr`, `asr`)

### Phase 3: BigInt (v0.4.0)

- [ ] Design `std.math.big` module
- [ ] Implement BigInt with `malloc`-based arithmetic
- [ ] Add `Big.fromInt`, `Big.add`, `Big.mul`, `Big.toString`

---

## 9. Open Questions

### Q1: Should `%` be modulo or remainder?

Currently `%` is remainder (sign follows dividend). Some languages use modulo (sign follows divisor).

| Operation | Kō (remainder) | Python (modulo) |
|-----------|----------------|-----------------|
| `7 % 2` | `1` | `1` |
| `-7 % 2` | `-1` | `1` |
| `7 % -2` | `1` | `-1` |
| `-7 % -2` | `-1` | `-1` |

Kō's current behavior matches C/Java (remainder). Python's behavior (modulo) is sometimes more useful for indexing.

**Recommendation:** Keep remainder for `%`. Add `Int.modFloor` for modulo behavior if needed.

### Q2: Should integer division truncate or floor?

Currently `/` truncates toward zero. Some languages floor toward -inf.

| Operation | Kō (trunc) | Python (floor) |
|-----------|------------|----------------|
| `7 / 2` | `3` | `3` |
| `-7 / 2` | `-3` | `-4` |
| `7 / -2` | `-3` | `-4` |

Truncation matches C/Java. Floor is sometimes more useful for negative numbers.

**Recommendation:** Keep truncation for `/`. Add `Int.divFloor` for floor division if needed.

### Q3: Should we add `Int.pow` as an operator?

Currently `Int.pow` is a function. An operator would be convenient:

```ko
a ** b    # power
```

But `**` is not in the current operator set. Adding it requires lexer/parser changes.

**Recommendation:** Keep `Int.pow` as a function for now. Add `**` operator in v0.4.0 if demand exists.

---

*This document is a living design draft. It will be updated as implementation progresses.*
