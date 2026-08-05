# Kō Strings & Characters

> **Status:** Design Draft
> **Date:** 2026-08-01
> **Research:** Swift String, Rust String/str, Go string, Zig []const u8, Python str

---

## 1. Current State

### Character

`Char` is a single byte, stored as `i64` in the tagged representation. Character literals are single ASCII characters: `'a'`, `'Z'`, `'0'`.

```ko
let c : Char = 'a'
ord c          # 97
chr 97         # 'a'
```

### String

Strings are null-terminated C strings (`i8*`). No length field, no reference counting, no encoding awareness.

```ko
len "hello"        # 5 (counts bytes until \0, O(n))
charAt "hello" 1   # 'e' (byte access)
"hello" ++ "world" # "helloworld" (malloc, memcpy, never freed)
```

String literal `"hello"` compiles to a global constant: `@str_hello = private constant [6 x i8] c"hello\00"`.

### String Interpolation

`"hello ${name}!"` desugars to `concat` calls at parse time:

```ko
concat "hello " (concat name "!")
```

### What's Implemented vs What's Documented

**Builtin (in stdlib_codegen.zig):**
- `ko_string_length` — byte count loop
- `ko_string_append` — malloc + memcpy
- `ko_string_contains` — libc strstr
- `ko_string_char_at` — byte index
- `ko_string_to_upper` / `to_lower` — toupper/tolower loop
- `ko_string_trim` — isspace loop
- `ko_string_replace` — strstr + memcpy loop
- `ko_string_split` — Zig implementation (JIT only)

**Documented in String.ko but not exposed as runtime builtins:**
- `split`, `replace`, `trim`, `contains`, `charAt`, `toUpperCase`, `toLowerCase`, `substring`, `indexOf`, `startsWith`, `endsWith`

These exist in `stdlib.zig` for comptime evaluation but are not registered as runtime builtins in the typechecker/codegen.

---

## 2. Design Questions

### Q1: What is the primitive unit of text?

**Option A: Bytes (current)**

Characters are bytes. `len` returns byte count. `charAt` returns a byte.

```ko
len "hello"     # 5
len "café"      # 5 (bytes: c, a, f, é as 2 bytes in UTF-8)
charAt "café" 1 # 'a'
```

Pros: Simple, O(1), matches C. Cons: `len` is misleading for multi-byte text. Substring operations break on codepoint boundaries.

**Option B: Codepoints**

Characters are Unicode codepoints (u32). `len` returns codepoint count. String is UTF-8 bytes internally, but indexing is by codepoint.

```ko
len "hello"     # 5
len "café"      # 4
charAt "café" 3 # 'é' (U+00E9)
```

Pros: Correct for internationalized text. Cons: `len` is O(n), `charAt` is O(n) — must scan the string. This is what Swift does.

**Option C: Grapheme clusters**

Characters are user-perceived characters (possibly multiple codepoints). Most complex, most correct.

```ko
len "🇨🇦"       # 1 (flag is two codepoints)
```

**Option D: Two-level (bytes + codepoints)**

`String` is byte-indexed. `std.text` provides codepoint operations. User picks the right tool.

```ko
len "café"              # 5 (bytes, O(1))
text.length "café"      # 4 (codepoints, O(n))
text.codepointAt "café" 3  # 'é'
```

### Q2: How should `String` be represented in memory?

**Option A: Null-terminated bytes (current)**

```c
char* data;  // null-terminated
```

Pros: Matches C, simple. Cons: O(n) length, can't contain `\0`, no RC.

**Option B: Length-prefixed bytes with RC**

```c
typedef struct {
  i64 refcount;
  i64 byte_length;
  char data[];  // NOT null-terminated (or null-terminated for C compat)
} KoString;
```

Pros: O(1) length, proper RC, can contain `\0`. Cons: 16 bytes overhead per string.

**Option C: Fat string (length + capacity + refcount)**

```c
typedef struct {
  i64 refcount;
  i64 byte_length;
  i64 capacity;
  char data[];
} KoString;
```

Pros: Supports in-place mutation (append without realloc). Cons: More overhead, mutation complicates RC.

### Q3: Should strings be mutable?

**Immutable (current):** Every string operation allocates a new string. Simple, safe, no aliasing issues.

**Mutable with COW:** Strings are immutable by default but can be mutated if RC == 1 (no other references). This is what PHP and Swift do.

**Mutable always:** Strings can be mutated in place. Fast but dangerous.

---

## 3. Proposed Design

### Core Decision: Bytes + `std.text` for Unicode

Kō uses **bytes** as the primitive unit. Characters are bytes. `len` returns byte count. This is O(1), simple, and correct for the common case (ASCII text, file paths, JSON keys).

For Unicode-aware text processing, use the `std.text` module. This follows the 80/20 rule: 80% of string operations are ASCII, byte-level access is correct and fast for those.

### Char Type

```ko
# Char is a byte (i64 in the tagged representation)
let c : Char = 'a'
let c : Char = '\n'    # newline
let c : Char = '\t'    # tab

# Char operations (builtins)
ord : Char -> Int          # byte value (0-255)
chr : Int -> Char          # int to byte (mod 256)
```

Escape sequences:
```ko
'\n'    # newline (0x0A)
'\r'    # carriage return (0x0D)
'\t'    # tab (0x09)
'\\'    # backslash
'\''    # single quote
'\"'    # double quote
'\0'    # null byte
'\x41'  # hex escape (A)
'\u{00E9}'  # unicode escape (é) — stored as UTF-8 bytes
```

### String Type

```ko
# String is a byte sequence (UTF-8 encoded)
let s : String = "hello"
let s : String = "café"      # 5 bytes in UTF-8
let s : String = "hello\n"   # includes newline
let s : String = ""           # empty string
```

### KoString Runtime Representation

```c
typedef struct {
  i64 refcount;
  i64 byte_length;
  char data[];       // flexible array, NOT null-terminated
} KoString;

// Literal strings are global constants (i8*, null-terminated)
// Heap strings are KoString* (refcounted, length-prefixed)
```

### API: Builtins (No Import Needed)

```ko
# Core operations
len : String -> Int                    # byte count, O(1)
charAt : String -> Int -> Char         # byte at index, O(1)
concat : String -> String -> String    # concatenate

# String interpolation (desugared at parse time)
"hello ${name}!"  # => concat "hello " (concat name "!")
```

### API: `std.string` Module

```ko
import std.string

# === Core ===
string.length : String -> Int              # same as builtin len
string.isEmpty : String -> Bool
string.reverse : String -> String          # reverse bytes
string.repeat : String -> Int -> String    # repeat n times
string.replicate : Int -> String -> String # alias for repeat

# === Searching ===
string.contains : String -> String -> Bool
string.startsWith : String -> String -> Bool
string.endsWith : String -> String -> Bool
string.indexOf : String -> String -> Maybe Int
string.lastIndexOf : String -> String -> Maybe Int

# === Transforming ===
string.toUpper : String -> String
string.toLower : String -> String
string.trim : String -> String
string.trimStart : String -> String
string.trimEnd : String -> String
string.replace : String -> String -> String -> String

# === Extracting ===
string.substring : String -> Int -> Int -> String    # [start, end)
string.take : Int -> String -> String
string.drop : Int -> String -> String
string.takeWhile : (Char -> Bool) -> String -> String
string.dropWhile : (Char -> Bool) -> String -> String

# === Splitting/Joining ===
string.split : String -> String -> List String
string.join : List String -> String -> String
string.lines : String -> List String
string.words : String -> List String

# === Conversions ===
string.toList : String -> List Char
string.fromList : List Char -> String
string.toInt : String -> Maybe Int
string.toFloat : String -> Maybe Float
string.fromInt : Int -> String
string.fromFloat : Float -> String

# === Char operations ===
char.isAlpha : Char -> Bool
char.isDigit : Char -> Bool
char.isAlphaNum : Char -> Bool
char.isUpper : Char -> Bool
char.isLower : Char -> Bool
char.toUpper : Char -> Char
char.toLower : Char -> Char
char.ord : Char -> Int
char.chr : Int -> Char
```

### API: `std.text` Module (Unicode-Aware)

```ko
import std.text

# Codepoint operations (O(n) — scan UTF-8 bytes)
text.length : String -> Int               # codepoint count
text.codepoints : String -> List Int      # list of codepoint values
text.codepointAt : String -> Int -> Maybe Int
text.fromCodepoints : List Int -> String

# Grapheme clusters (complex, future)
text.graphemes : String -> List String
text.graphemeCount : String -> Int

# Unicode categories
char.isWhitespace : Char -> Bool
char.isControl : Char -> Bool
char.isPunctuation : Char -> Bool
```

### String Operations: Semantics

**`len`:** Returns byte count. O(1) for `KoString`, O(n) for raw `i8*` literals (computed at compile time).

```ko
len "hello"     # 5
len "café"      # 5 (é is 2 bytes in UTF-8)
len "🇨🇦"       # 8 (each regional indicator is 4 bytes)
len ""          # 0
```

**`charAt`:** Returns byte at index. Returns -1 if out of bounds.

```ko
charAt "hello" 0    # 'h'
charAt "hello" 4    # 'o'
charAt "hello" 5    # -1 (out of bounds)
charAt "" 0         # -1
```

**`substring`:** Extract bytes [start, end). No codepoint awareness.

```ko
substring "hello" 1 3    # "el"
substring "café" 0 3     # "caf" (bytes 0-2, é is bytes 3-4)
substring "café" 0 4     # "caf" + first byte of é (broken UTF-8!)
```

The broken UTF-8 case is a known limitation. Users who need codepoint-aware substring should use `std.text`.

**`split`:** Split by delimiter string. Returns list of strings.

```ko
split "a,b,c" ","       # ["a", "b", "c"]
split "hello" ","       # ["hello"]
split "" ","            # [""]
split ",," ","          # ["", "", ""]
```

**`replace`:** Replace all occurrences of substring.

```ko
replace "hello world" "world" "Kō"    # "hello Kō"
replace "aaa" "a" "b"                 # "bbb"
replace "hello" "x" "y"               # "hello" (no match)
```

### Codegen Changes

**String literals:** Stay as global constants (`i8*`, null-terminated). The compiler emits:

```llvm
@str_hello = private constant [6 x i8] c"hello\00"
```

When a literal is used as a function argument or stored in a container, it is wrapped into `KoString` by the calling convention or the builtin implementation.

**String builtins:** Each builtin that returns a new string allocates a `KoString`:

```llvm
; String.append "hello" "world"
%len_a = call i64 @ko_string_length(%KoString* %a)
%len_b = call i64 @ko_string_length(%KoString* %b)
%total = add i64 %len_a, %len_b
%s = call %KoString* @ko_string_alloc(i64 %total)
call void @ko_string_copy(%KoString* %s, 0, %KoString* %a, 0, %len_a)
call void @ko_string_copy(%KoString* %s, %len_a, %KoString* %b, 0, %len_b)
```

**`len` on KoString:** Reads the `byte_length` field directly — O(1).

```llvm
%len = load i64, i64* getelementptr(%KoString, %KoString* %s, 0, 1)
```

---

## 4. Migration Path

### Phase 1: KoString Wrapper (v0.3.0)

- Add `KoString` struct to runtime
- Add `ko_string_alloc`, `ko_string_decref`
- Change string builtins to return `KoString*`
- Fix `len` to read `byte_length` (O(1))
- Wrap literal strings when passed to builtins

### Phase 2: Expose Missing Builtins (v0.3.0)

- Register `split`, `replace`, `trim`, `contains`, `charAt`, `toUpper`, `toLower`, `substring`, `indexOf`, `startsWith`, `endsWith` as runtime builtins in the typechecker
- Update `String.ko` to document these as available

### Phase 3: std.text Module (v0.4.0)

- Implement `std.text` module with codepoint operations
- Add grapheme cluster support (future)
- Add Unicode category predicates

---

## 5. Examples

### Basic String Operations

```ko
fn main =
  let name = "Kō"
  let version = "0.3.0"
  println "Welcome to ${name} v${version}!"
  println (len name)                    # 2 (bytes)
  println (string.toUpper "hello")      # HELLO
  println (string.contains "hello world" "world")  # true
  println (string.split "a,b,c" ",")    # ["a", "b", "c"]
```

### Character Processing

```ko
fn main =
  let s = "Hello, World!"
  let chars = string.toList s
  let upper_chars = map char.toUpper chars
  let result = string.fromList upper_chars
  println result                        # HELLO, WORLD!
```

### Unicode-Aware Processing

```ko
import std.text

fn main =
  let s = "café"
  println (len s)                       # 5 (bytes)
  println (text.length s)               # 4 (codepoints)
  match text.codepointAt s 3
    Just cp -> println cp               # 233 (é)
    Nothing -> println "out of bounds"
```

---

## 6. Open Questions

### Q1: Should `split` return `List String` or a lazy iterator?

For large strings, materializing the entire split result as a list is expensive. A lazy iterator would be more efficient:

```ko
string.splitLazy : String -> String -> Iterator String
```

But iterators add complexity. For v0.3.0, return `List String`. Add lazy iteration in v0.4.0 if profiling shows it matters.

### Q2: Should string comparison be lexicographic or byte-ordered?

For UTF-8 strings, byte order matches codepoint order for ASCII but not for all Unicode. Two options:

- **Byte order:** `strcmp` semantics. Fast, simple, correct for ASCII.
- **Codepoint order:** Unicode-aware comparison. Correct for all text, slower.

For v0.3.0, use byte order. Add `std.text.compare` for Unicode-aware comparison later.

### Q3: Should `+` work on strings?

Currently `+` is arithmetic only. String concatenation uses `concat` or `++`.

Options:
- Keep `+` for numbers only, `++` or `concat` for strings (current)
- Overload `+` for strings (like Python/JavaScript)

Recommendation: Keep `+` for numbers only. Overloading is a type system burden and can cause confusing error messages.

---

*This document is a living design draft. It will be updated as implementation progresses.*
