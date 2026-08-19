# Kō Modules: Imports, Resolution, and the Two IO Namespaces

A personal, plain-English tour of how modules work in Kō — what the `import`
statement does, exactly where a module file is looked up, what names become
available after the import, and the two different "IO" things that keep
confusing people (including me).

---

## The Short Version

- `import std.io` loads `std/io.ko` **from the directory next to the `ko` binary** — not from your source file's directory.
- `import something.else` loads `something/else.ko` **from your source file's directory**.
- After the import, every function, type, and constructor in that file becomes available **twice**: qualified (`io.readOrEmpty`) and unqualified (`readOrEmpty`). There is **no `pub` enforcement** — everything is importable.
- A missing module is **not a compile error**. The compiler logs `Module not found` and carries on; you only find out at the use site, as `undefined name`.
- `IO.readLine`, `IO.readFile`, etc. are **builtins**, pre-registered globally, no import needed. They live in the `IO.` namespace. `std/io.ko` is a *separate* thing that wraps them and lives in the `io.` namespace.
- The module block form — `module Math ...` in your own file — is a *third* thing: a purely in-file namespace for organizing definitions.

---

## 1. What an `import` actually does

`import std.io` is three steps in the compiler:

1. **Load + parse** the file (`module_loader.zig`).
2. **Typecheck it in a brand-new inferer** — as if it were a tiny standalone program (`typecheck.zig:1043`). This is why each module is self-contained: it must typecheck on its own terms before it can be used.
3. **Copy its definitions into *your* scope**, under both a qualified and an unqualified name (`typecheck.zig:1093-1149`).

There is no link step, no "compiled module" format. A module is just a `.ko` file that gets parsed and typechecked again, from scratch, every compile. The only thing that keeps this from being wasteful is a **cache keyed by file path** (`module_loader.zig:14`, `:120`) — load each file once per compiler run.

Because modules are re-typechecked fresh, they cannot see the file that imported them. Imports are one-way.

---

## 2. The resolution algorithm (where files are found)

The full lookup lives in `module_loader.zig`. `resolvePath` (`:51`) is the heart of it: take the import path, join with `/`, append `.ko`, and prepend a base directory.

### Non-std imports: relative to your source file

```
import sub2.lib      #  →  <dir of main.ko>/sub2/lib.ko
import helper        #  →  <dir of main.ko>/helper.ko
```

`base_dir` is set from the source file you're compiling: `std.fs.path.dirname(fname)` (`main.zig:387`). The `.` in the import path becomes `/` on disk.

### std imports: relative to the binary — and it's a *search*

```
import std.io   #  →  search for <root>/std/io.ko
```

`std.` gets special treatment (`module_loader.zig:108`, `:145`). The `std` prefix is **stripped** (`io` stays), then the loader tries a small search:

- **Roots**, in order: `KO_STDLIB_PATH` (an env override, if set) → the directory containing the `ko` executable (`exe_dir`).
- **Suffixes**, per root: `std`, `../std`, `../../std`.

So the candidates for `import std.io` with a binary at `/usr/local/bin/ko` are:

```
/usr/local/bin/std/io.ko
/usr/local/bin/../std/io.ko
/usr/local/bin/../../std/io.ko
```

First existing file wins. In practice this means: **the stdlib lives next to the binary.** If you install `ko` into `/usr/local/bin`, you must put `std/io.ko` (and `List.ko`, `Set.ko`, …) into `/usr/local/bin/std/`. The `../std` and `../../std` fallbacks exist so a binary sitting in a `bin/` subdirectory of a project can still find `std/` at the project root.

For the installed binary at `/home/bernard/.local/share/ko/ko`, `import std.io` resolves to `/home/bernard/.local/share/ko/std/io.ko`. You can check what's actually there with `ls ~/.local/share/ko/std/`.

### A resolution bug to know about: quoted imports

`import "some/path"` (a quoted string) **does not resolve** — the token slice keeps the quote characters, so the loader looks for `"some/path".ko` with literal quotes in the name and reports `Module not found`. Dotted paths (`import sub2.lib`) are the supported form. Nested directories work fine with dots.

---

## 3. What names become available (the features)

This is the part that surprises people. After `import std.io`, ALL of these exist (`typecheck.zig:1093-1149`):

| You can write | Meaning |
|---|---|
| `io.readOrEmpty` | qualified — namespace is the last path component (`io`) |
| `readOrEmpty` | unqualified — plain name, same function |
| `io.writeOrDie` | qualified |
| `writeOrDie` | unqualified |
| `IO.readLine` | NOT from this module — see section 5 |

So a full import **pollutes your global scope** with every name from the module, not just the ones you asked for. If two imported modules both define `f`, the second one silently wins.

### Selective imports

```ko
import std.io { readOrEmpty, writeOrDie }
```

Only `readOrEmpty` and `writeOrDie` are registered unqualified; the rest stay reachable only by their qualified `io.` names (`typecheck.zig:1118`). Use this when you want a clean scope.

### Aliases

```ko
import std.io as stdio
# stdio.readOrEmpty, but NOT io.readOrEmpty or bare readOrEmpty
```

The namespace name becomes the alias (`module_name = imp.alias orelse imp.path[imp.path.len - 1]`, `typecheck.zig:1049`).

### Types and constructors

Types get `io.Error` (qualified) and `Error` (unqualified). Constructors get **both** forms too: `io.Ok` and `Ok` (`typecheck.zig:1130`). This means the unqualified `Ok`/`Err` you use in a `match` after `import std.io` come from the import — but since `Ok`/`Err` are also the *built-in* `Result` constructors, there's no practical conflict.

### There is no `pub` enforcement

`std/io.ko` marks its functions `pub fn`, but the import machinery never checks the flag (`typecheck.zig:1094` — it registers every `fn_def`). A non-`pub` function in an imported file is just as importable. (Verified: importing a `fn secret` from a plain module works.) `pub` is currently documentation, not access control.

### Module blocks (`module Math ...`) — in-file namespaces

```ko
module Math
  fn add x y = x + y

fn main = println (Math.add 1 2)
```

This is **not** an import. It's a way to organize definitions *within one file*: the inner definitions get typechecked with the `Math.` prefix (`typecheck.zig:1950`, `:2007`), and `current_module` is set while they're being inferred so a name reference inside the block resolves against `Math.` first (`resolveName`, `typecheck.zig:585`). Types inside a module block are registered with the prefix as well (`typecheck.zig:1157`).

### Loading a module twice = loaded once

The path-keyed cache (`module_loader.zig:120`) means `import std.io` from two files in the same compilation reuses one parsed, typechecked copy.

---

## 4. Failure modes (and the "undefined name 'io'" trap)

If a module can't be found or fails to typecheck, the importer does **not** fail. It logs:

```
std.log.err("Module not found: ...")
```

and `continue`s to the next definition (`typecheck.zig:1037-1047`). The compiler then proceeds, and the first use of a name from the missing module reports `undefined name 'io'` — often with a confusing "did you mean 'Ok'?" hint. This is exactly what you get with `import std.io` followed by `io.readLine |> io.println`:

```
undefined name 'io'   # the module's real names are readOrEmpty, writeOrDie, eprintErr, exists
```

The *two* things wrong there are (a) `io.` has no `readLine` or `println`, and (b) even the builtin would need to be `IO.readLine` and `IO.eprintln` — see the next section.

There is also **no circular-import detection** (documented gotcha in `src/AGENTS.md`). A module that imports its importer will blow the stack rather than reporting a cycle.

---

## 5. The two "IO"s — where beginners get lost

There are **two unrelated IO namespaces**. Keep them straight:

### `IO.` — the builtin namespace (always available)

Registered in `typecheck.zig:545` as predeclared names, and mapped to native Zig host functions in the JIT (`main.zig`). **No import required.** These are the real workhorses:

```ko
IO.readFile    IO.writeFile    IO.appendFile
IO.fileExists  IO.fileSize     IO.mkdir        IO.rm
IO.cp          IO.mv           IO.readdir
IO.readLine    IO.eprintln     IO.eprint       IO.getEnv
```

Signatures (see `std/io.ko` header comment and `DESIGN-io-model.md`):

- `IO.readLine : String -> String` — reads one line from **stdin**; the argument is the **prompt** printed first.
- `IO.eprintln : String -> Unit` / `IO.eprint : String -> Unit` — to **stderr** (fd 2).
- `IO.readFile : String -> Result Error String`, `IO.writeFile`/`IO.appendFile : String -> String -> Result Error Unit`, `IO.fileSize`/`IO.mkdir`/`IO.rm`/`IO.cp`/`IO.mv : ... -> Result Error ...`, `IO.fileExists : String -> Bool`, `IO.readdir : String -> Result Error (Array String)`, `IO.getEnv : String -> Maybe String`.

The `Result` / `Error` / `Maybe` types are builtins too — `Ok`, `Err`, `Just`, `Nothing` are always in scope.

### `io.` — the `std/io.ko` module (imported)

A small convenience wrapper over the builtins:

```ko
io.readOrEmpty : String -> String   # read a file, "" if missing
io.writeOrDie  : String -> String -> Unit   # panic "write failed" on error
io.eprintErr   : String -> Unit     # "error: <msg>" to stderr
io.exists      : String -> Bool     # alias for IO.fileExists
```

`readOrEmpty` is the friendly one to use with `Result`-based code. Note its one quirk: `readOrEmpty` on a missing file returns `""`, and `writeOrDie ""` then **panics**, because a zero-byte write is treated as an error by `IO.writeFile`.

### The working "echo a line" idiom

```ko
# read a line from stdin (printing the prompt "> "), echo it to stderr
fn main = IO.readLine "> " |> IO.eprintln
```

No import. Pipe works on a single line. What does **not** work:

- `io.readLine` / `io.println` — no such names (see the table above).
- `IO.readLine |> IO.eprintln` — pipes the *function* `readLine`, not its result. `x |> f` is `f x`, so this would try to print a function. It needs its prompt argument first: `IO.readLine "> " |> IO.eprintln`.
- A multi-line pipe:
  ```ko
  fn main =
      IO.readLine "> "
      |> IO.eprintln
  ```
  The `|>` on its own line doesn't parse yet — that's the open Stage 6.3 item (`#18`). Keep pipes on one line for now.
- `println lib.f 1` — application is left-associative and field access binds tighter than application, so this parses as `(println lib.f) 1` (a type error). You need parens: `println (lib.f 1)`.

---

## 6. How to experiment (and what to expect)

A quick self-check kit for the resolver, runnable with the installed `ko`:

```ko
# mymod.ko
fn secret x = x
fn shown x = x * 2

# main.ko, same directory
import mymod
fn main = println (shown 21)     # 42 — unqualified name works
```

```ko
import mymod as m
fn main = println (m.shown 21)   # 42 — qualified via alias
```

```ko
import mymod { shown }
fn main = println (shown 21)     # 42 — selective
# fn main = println (secret 1)   # undefined name 'secret' — hidden
```

- `import mymod.nested` works if the file is at `mymod/nested.ko`.
- `import "mymod"` (quoted) does **not** work — quoted imports are broken.
- `ls $(dirname $(readlink -f $(which ko)))/std` shows the stdlib the binary actually finds.
- Setting `KO_STDLIB_PATH=/some/dir` makes `import std.*` resolve from `/some/dir/std/` instead of the binary's directory.

---

## 7. Mental model in one paragraph

A module is a `.ko` file parsed and type-checked in isolation, then its definitions are *copied by name* into the importing scope — qualified by the module's last path component (or alias) and also unqualified, unless you said `{ only, these }`. Where the file is found depends on one bit of the path: `std.` prefixes search outward from the binary (with a `KO_STDLIB_PATH` override), everything else searches outward from your source file. Loading is cached by path, missing modules degrade to a log line instead of an error, and `pub` is cosmetic. The `IO.` builtins are pre-registered globally and have nothing to do with the `io.` module — think of `std/io.ko` as a thin hand-rolled wrapper you import, and `IO.*` as the built-in host functions that are always there.

---

## Where it lives in the source

| Thing | File |
|---|---|
| Import parsing (`import a.b {x} as y`) | `ko-zig/src/parser.zig:444` |
| Path resolution + cache | `ko-zig/src/module_loader.zig` |
| base_dir / exe_dir setup | `ko-zig/src/main.zig:387-390` |
| Import processing, name registration | `ko-zig/src/typecheck.zig:1035-1149` |
| `IO.*` builtin registration | `ko-zig/src/typecheck.zig:545` |
| `module X ...` block handling | `ko-zig/src/typecheck.zig:1950`, `:2007` |
| `IO.*` → native host fns (JIT) | `ko-zig/src/main.zig` (JIT mapping) |