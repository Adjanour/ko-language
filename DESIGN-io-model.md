# Kō I/O Model

> **Status:** Design Draft
> **Date:** 2026-08-01
> **Research:** Roc platforms, Haskell IO, OCaml Stdlib, Zig std.io, Go io package

---

## 1. Current State

### What Exists

Verified against the compiler, not assumed. Console output is all that is
implemented:

```ko
# Console (builtins) — implemented
println : forall a. a -> a     # prints value + newline, returns value
print : forall a. a -> a       # prints value, returns value
inspect : forall a. a -> a     # debug print, returns value
```

**There is no file I/O.** An earlier draft of this section listed `read_file`,
`write_file`, `append_file`, `read_line`, `run`, `get_env`, `file_exists`,
`file_size`, `file_modified`, `sleep`, `mkdir`, `rm`, `cp`, `mv` and `readdir`
as existing builtins. None of them exist: `grep -rn read_file src/` returns no
hits, and each name fails with `undefined name` at the call site. Nothing in
`stdlib_codegen.zig` emits them.

`panic : String -> a` is declared but **generates invalid LLVM** — a program
calling it dies in module verification with `Terminator found in the middle of
a basic block!`, so it cannot be used.

The `Result` type occupies type_id 1, but the `Ok` and `Err` constructors are
not registered: `match Ok 1 ...` fails with `undefined constructor 'Ok'`.

### What's Wrong

1. **`println` returns its argument.** The type `forall a. a -> a` is polymorphic in a way that doesn't reflect the side effect. `let x = println "hello"` makes `x = "hello"`, which is confusing.

2. **There is no file I/O to fix.** This is the significant one. Phase 1 below is
   written as though the work is to *wrap* existing builtins so they return
   `Result` — but the builtins have to be written first. Budget for implementing
   the I/O surface, not adapting it.

3. **No error type.** There's no `Error` type to distinguish "file not found" from "permission denied" from "I/O error". `Ok`/`Err` are also missing, so `Result`-returning signatures cannot be expressed yet.

4. **Naming convention undecided.** The names proposed below (`read_file`, `file_exists`) are snake_case while the rest of the stdlib uses dot notation (`String.append`). Since nothing is implemented, this is a free choice rather than a migration — prefer `IO.readFile` and settle it before writing the builtins.

5. **`run` is dangerous.** Shell command execution with no sandboxing or escaping.

---

## 2. Design Questions

### Q1: Should Kō track effects in the type system?

**Option A: No effect tracking (current)**

`println` is an ordinary function. You can't tell from a function's type whether it does I/O.

```ko
fn greet name = println ("Hello, " ++ name)  # does I/O, type doesn't say so
fn add a b = a + b                            # pure, type doesn't say so
```

Pros: Simple, no new type system machinery.
Cons: Can't tell which functions are pure without reading the body. Harder to test (can't mock `println` without changing the call site).

**Option B: Effect types**

```ko
fn greet (name : String) -> !IO () = println ("Hello, " ++ name)
fn add (a : Int) (b : Int) -> Int = a + b
```

The `!IO` annotation tells the typechecker this function does I/O. Pure functions can't call IO functions.

Pros: Type-safe purity. Can enforce that test code is pure.
Cons: Complex machinery (effect types, effect handlers, row polymorphism). Violates "small language" principle.

**Option C: Platform model (Roc-style)**

I/O is restricted by the platform. The language itself is pure; the platform provides I/O capabilities.

```ko
# In the language: pure
fn greet name = "Hello, " ++ name

# Platform: connects to I/O
platform linux =
  main = greet "World" |> println
```

Pros: Clean separation of pure and effectful code. Enables different platforms (CLI, web, embedded).
Cons: Complex platform system. Roc spent years designing this.

**Option D: Module-based (pragmatic)**

All I/O goes through a module. No type-level tracking, but organizational clarity.

```ko
import std.io

fn main =
  io.println "Hello"
  let config = io.read_file "config.ko"?
  parse config
```

Pros: Simple, auditable (grep for `io.`), testable (mock the module).
Cons: No compile-time enforcement. A function can do I/O without importing `io`.

### Recommendation

**Option D: Module-based.** This matches Kō's philosophy ("small language, big library"). The type system stays simple. Testing is handled by mock modules.

If effect tracking is needed later, add it as a v0.5.0 feature. The module-based approach doesn't prevent future type-level tracking.

### Q2: What should `println` return?

**Option A: Returns its argument (current)**

```ko
println : forall a. a -> a

let x = println "hello"   # x = "hello"
println (println x)       # prints twice, returns "hello"
```

Pros: Enables chaining. Cons: Confusing — the return value is usually ignored and looks like `println` is pure.

**Option B: Returns Unit**

```ko
println : String -> Unit

println "hello"            # prints, returns ()
# let x = println "hello"  # x = (), but why would you?
```

Pros: Honest about side effects. Matches most languages. Cons: Can't chain `println` calls without sequencing.

**Option C: Returns the string (for pipelines)**

```ko
println : String -> String

"hello" |> println          # prints "hello", returns "hello"
"hello" |> println |> len   # prints "hello", returns 5
```

Pros: Pipeline-friendly. Cons: Confusing — the return value is the input, not something new.

### Recommendation

**Option B: `println` returns `Unit`.** This is the honest choice. For pipelines, use explicit sequencing:

```ko
let msg = to_string (add 1 2)
println msg
```

Or with pipe:

```ko
add 1 2 |> to_string |> println
```

The pipe works because `println` is the last thing — you don't need its return value.

### Q3: How should errors be handled?

**Option A: Panic on error (current for some operations)**

```ko
read_file "missing.txt"   # runtime crash
```

**Option B: Return Result**

```ko
read_file : String -> Result Error String

match read_file "missing.txt"
  Ok contents -> process contents
  Err FileNotFound -> default_config ()
  Err PermissionDenied -> panic "cannot read config"
```

**Option C: Return Maybe (simpler)**

```ko
read_file : String -> Maybe String

match read_file "missing.txt"
  Just contents -> process contents
  Nothing -> default_config ()
```

### Recommendation

**Option B: Return Result.** `Maybe` loses error information. `Result` lets you distinguish "file not found" from "permission denied" from "I/O error". The `?` operator makes it ergonomic:

```ko
fn load_config =
  let contents = read_file "config.ko"?   # propagates error
  parse contents
```

---

## 3. Proposed Design

### Error Type

```ko
type Error =
  FileNotFound
  | PermissionDenied
  | InvalidPath
  | IOError String           # system error message
  | CommandFailed Int String # exit code, stderr
  | EncodingError String
```

### The `std.io` Module

```ko
module IO =
  # === Console ===
  println : String -> Unit
  print : String -> Unit
  eprintln : String -> Unit              # stderr
  eprint : String -> Unit
  inspect : forall a. a -> Unit
  readLine : String -> String            # with prompt

  # === File ===
  readFile : String -> Result Error String
  writeFile : String -> String -> Result Error Unit
  appendFile : String -> String -> Result Error Unit
  fileExists : String -> Bool
  fileSize : String -> Result Error Int
  fileModified : String -> Result Error Int

  # === Directory ===
  mkdir : String -> Result Error Unit
  readdir : String -> Result Error (List String)
  rm : String -> Result Error Unit
  cp : String -> String -> Result Error Unit
  mv : String -> String -> Result Error Unit

  # === System ===
  args : List String
  getEnv : String -> Maybe String
  now : Int                              # ms since epoch
  sleep : Int -> Unit                    # ms
  exit : Int -> Unit
  run : String -> Result Error String    # shell command

  # === Path ===
  pathJoin : String -> String -> String
  pathDirname : String -> String
  pathBasename : String -> String
```

### Migration: What Changes

| Current | New | Rationale |
|---------|-----|-----------|
| `println : forall a. a -> a` | `println : String -> Unit` | Honest about side effects |
| `read_file : String -> String` | `IO.readFile : String -> Result Error String` | Safe error handling |
| `write_file : String -> String -> Unit` | `IO.writeFile : String -> String -> Result Error Unit` | Safe error handling |
| `panic : String -> a` | `panic : String -> a` | No change — panics are for unrecoverable errors |
| `run : String -> String` | `IO.run : String -> Result Error String` | Safe error handling |
| `get_env : String -> String` | `IO.getEnv : String -> Maybe String` | Env vars may not exist |

### Backward Compatibility

For v0.3.0, keep the old builtins working but deprecate them. Add the new `IO` module alongside:

```ko
# Old (deprecated, still works)
println "hello"
read_file "foo.ko"

# New (preferred)
import std.io
io.println "hello"
io.readFile "foo.ko"
```

In v0.4.0, remove the deprecated builtins.

### Testing Pattern

The module-based approach enables testing via mock modules:

```ko
# tests/config_test.ko
import "../config.ko" as Config
import "../io.ko" as RealIO

# Mock IO for testing
module MockIO =
  let files = ref {}
  let output = ref []

  readFile path =
    Map.get path !files |> Result.withDefault (Err (IOError "mock not found"))

  writeFile path content =
    files := Map.insert path content !files

  println msg =
    output := msg :: !output

  # ... other mocks as needed

# Run test with mock
fn test_parse_config =
  let config = Config.parse_with_io MockIO
  assert_eq config.name "test"
```

This isn't as clean as an effect system, but it's pragmatic and works within Kō's current design.

---

## 4. println Behavior

### Current: Polymorphic, Returns Argument

```ko
println : forall a. a -> a

println 42           # prints "42", returns 42
println true        # prints "True", returns true
println (1, 2)      # prints "(1, 2)", returns (1, 2)
```

The `inspect` function already handles type-directed printing. `println` should be string-only.

### Proposed: String-Only, Returns Unit

```ko
println : String -> Unit
print : String -> Unit
eprintln : String -> Unit
eprint : String -> Unit
inspect : forall a. a -> Unit    # stays polymorphic for debug printing
```

This means:
- `println "hello"` — prints "hello", returns ()
- `println (to_string 42)` — prints "42", returns ()
- `inspect 42` — prints "42" (or debug representation), returns ()

### Why Not Keep Polymorphic println?

The polymorphic `println` requires runtime type dispatch (the `inspect` function with its `switch` on type tags). This is complex and slow.

Making `println` string-only means:
- No runtime type dispatch
- Simpler codegen
- Clearer semantics
- User converts to string explicitly (`to_string`)

The polymorphic `inspect` stays for debugging.

---

## 5. File I/O Semantics

### readFile

```ko
IO.readFile : String -> Result Error String
```

Returns the entire file contents as a string. For large files, this allocates a lot of memory. Consider adding a streaming API later.

```ko
match IO.readFile "config.ko"
  Ok contents -> parse contents
  Err FileNotFound -> default_config ()
  Err e -> panic (to_string e)
```

### writeFile

```ko
IO.writeFile : String -> String -> Result Error Unit
```

Creates or overwrites the file. Returns `Ok ()` on success.

```ko
IO.writeFile "output.ko" generated_code?
```

### appendFile

```ko
IO.appendFile : String -> String -> Result Error Unit
```

Appends to the file. Creates if doesn't exist.

### readLine

```ko
IO.readLine : String -> String
```

Reads a line from stdin with a prompt. Returns the line without the trailing newline.

Note: This doesn't return `Result` because stdin reading rarely fails in practice. If you need error handling, use `IO.readFile` on `/dev/stdin`.

### run

```ko
IO.run : String -> Result Error String
```

Runs a shell command and returns stdout. Returns `Err (CommandFailed exit_code stderr)` on non-zero exit.

```ko
match IO.run "git status"
  Ok output -> println output
  Err (CommandFailed code stderr) -> eprintln stderr
  Err e -> panic (to_string e)
```

**Warning:** Shell injection is possible if the command string is built from user input. Document this. Consider adding an `IO.runArgs` that takes a list of arguments (no shell interpretation):

```ko
IO.runArgs : List String -> Result Error String
```

---

## 6. Concurrency (Future)

Kō is currently single-threaded. For v0.4.0+, consider:

**Option A: Green threads (Go-style)**

```ko
fn main =
  spawn (\ -> long_running_task ())
  another_task ()
```

**Option B: Async/await**

```ko
fn main =
  let! contents = readFileAsync "large_file.ko"
  process contents
```

**Option C: Actor model (Erlang-style)**

```ko
fn main =
  let pid = spawn_actor (\msg -> handle_message msg)
  send pid (Request "hello")
```

For now, keep it simple. Single-threaded with `IO.sleep` for basic timing. Add concurrency in v0.4.0.

---

## 7. Implementation Phases

### Phase 1: IO Module (v0.3.0)

- [x] Register `Ok`/`Err` constructors so `Result` can be spelled at all (Stage 0)
- [x] Add `Error` type to stdlib (prelude: `FileNotFound | PermissionDenied | InvalidPath | IOError String | EncodingError String`)
- [x] Fix `panic` — it currently emits a terminator mid-block and fails LLVM verification (fixed in the diagnostics change set)
- [x] Implement the file I/O builtins in `stdlib.zig` (native Zig host functions, JIT-mapped; not `stdlib_codegen.zig` — see note)
- [x] Create `std/io.ko` module wrapping them to return `Result Error` (`readOrEmpty`, `writeOrDie`, `eprintErr`, `exists`)
- [x] Add `IO.getEnv` returning `Maybe String`
- [x] Change `println`/`print` to return `Unit`

There are no "old I/O builtins" to deprecate — see §1.

> Note: the file I/O builtins live in `stdlib.zig` and are wired into the JIT via
> `mapLirJitResultFns` in `main.zig`/`tests.zig` (with `codegen_lir.zig`
> `declareRuntime` externs). AOT (`--emit-exe`) cannot resolve them yet; that
> gap closes with the runtime-independence milestone.

### Phase 2: Console I/O (v0.3.0)

- [x] Implement `IO.readLine` with prompt (reads stdin, arg is the prompt)
- [x] Implement `IO.eprintln`/`IO.eprint` for stderr (via `fdio.zig`)
- [ ] Update `inspect` for better debug output

### Phase 3: System I/O (v0.4.0)

- [ ] Implement `IO.runArgs` (shell command with argument list)
- [ ] Add path operations module
- [ ] Add environment variable operations

### Phase 4: Concurrency (v0.5.0)

- [ ] Design concurrency model
- [ ] Implement green threads or async/await
- [ ] Add channel-based communication

---

## 8. Examples

### Hello World

```ko
fn main =
  import std.io
  io.println "Hello, World!"
```

### File Processing

```ko
import std.io

fn main =
  match io.readFile "input.txt"
    Ok contents ->
      let lines = string.lines contents
      let processed = map process_line lines
      let output = string.join processed "\n"
      io.writeFile "output.txt" output
        |> Result.fold
            (\_ -> io.println "Done!")
            (\e -> io.eprintln (to_string e))
    Err e ->
      io.eprintln (to_string e)
      io.exit 1
```

### CLI Tool

```ko
import std.io

fn main =
  let args = io.args
  match args
    ["--help", ..] ->
      io.println "Usage: mytool [options] [file]"
    ["--version", ..] ->
      io.println "mytool v1.0.0"
    [file, ..] ->
      match io.readFile file
        Ok contents -> process contents
        Err FileNotFound ->
          io.eprintln "File not found: ${file}"
          io.exit 1
        Err e ->
          io.eprintln (to_string e)
          io.exit 1
    [] ->
      io.eprintln "No arguments provided. Use --help for usage."
      io.exit 1
```

### Testing with Mocks

```ko
import "../io.ko" as RealIO

module MockIO =
  let output = ref []

  println msg = output := msg :: !output
  eprintln msg = output := msg :: !output
  readFile path =
    if path == "test.txt" then Ok "test content"
    else Err FileNotFound

fn test_process =
  let result = process_file MockIO "test.txt"
  assert_eq result "processed content"
  assert_eq (MockIO.output |> reverse) ["processed content"]
```

---

*This document is a living design draft. It will be updated as implementation progresses.*
