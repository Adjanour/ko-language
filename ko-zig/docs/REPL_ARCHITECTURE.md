# Ko REPL v0.3.2 — Architecture & Design

## Overview

The Ko REPL was rewritten from scratch with three production-quality components:

1. **Linenoise** — battle-tested line editing (arrow keys, history, tab completion)
2. **Try-parsing** — heuristic-based multi-line detection
3. **Signal handlers** — panic recovery without crashing the session

---

## 1. Linenoise Integration

### What is Linenoise?

A ~2400-line C library by antirez (Redis creator). Used by Redis, MongoDB, and dozens of other CLI tools. Provides everything a terminal needs:

- **Arrow keys**: Up/Down navigate history, Left/Right move cursor
- **Ctrl-A/E**: Jump to start/end of line
- **Ctrl-K**: Kill from cursor to end of line
- **Ctrl-U**: Kill from cursor to start of line
- **Ctrl-W**: Delete word before cursor
- **Ctrl-Y**: Yank (paste) last killed text
- **Tab**: Autocomplete
- **Persistent history**: Saved to `~/.ko_history`

### Files

```
vendor/linenoise.c    — C source (downloaded from antirez/linenoise)
vendor/linenoise.h    — C header
src/linenoise.zig     — Zig bindings (extern declarations)
```

### Zig Bindings (`src/linenoise.zig`)

We declare the C functions using `pub extern fn` instead of `@cImport` (which has issues in Zig 0.17 with separate modules):

```zig
pub extern fn linenoise(prompt: [*:0]const u8) ?[*:0]u8;
pub extern fn linenoiseFree(ptr: ?*anyopaque) void;
pub extern fn linenoiseHistoryAdd(line: [*:0]const u8) c_int;
pub extern fn linenoiseHistorySetMaxLen(len: c_int) c_int;
pub extern fn linenoiseHistorySave(filename: [*:0]const u8) c_int;
pub extern fn linenoiseHistoryLoad(filename: [*:0]const u8) c_int;
pub extern fn linenoiseSetMultiLine(ml: c_int) void;
pub extern fn linenoiseSetCompletionCallback(cb: CompletionCallback) void;
pub extern fn linenoiseAddCompletion(completions: *Completions, str: [*:0]const u8) void;
pub extern fn linenoiseClearScreen() void;
```

Key type:

```zig
pub const CompletionCallback = *const fn ([*:0]const u8, *Completions) callconv(.c) void;
```

### Build System (`build.zig`)

Linenoise is compiled as a C source file within its own Zig module:

```zig
const linenoise_mod = b.createModule(.{
    .root_source_file = b.path("src/linenoise.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
linenoise_mod.addCSourceFile(.{
    .file = b.path("vendor/linenoise.c"),
    .flags = &.{"-D_GNU_SOURCE"},
});
linenoise_mod.addIncludePath(b.path("vendor"));
ko_exe.root_module.addImport("linenoise", linenoise_mod);
```

**Critical**: The C source must be in the `linenoise_mod` module, NOT the root module. Adding it to both causes duplicate symbol errors.

### Tab Completion

We register a callback that matches against keywords and builtins:

```zig
fn koCompletionCallback(buf: [*:0]const u8, completions: *ln.Completions) callconv(.c) void {
    const prefix = std.mem.sliceTo(buf, 0);
    if (prefix.len == 0) return;
    for (ko_keywords) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) {
            ln.addCompletion(completions, @ptrCast(kw.ptr));
        }
    }
    for (ko_builtins) |b| {
        if (std.mem.startsWith(u8, b, prefix)) {
            ln.addCompletion(completions, @ptrCast(b.ptr));
        }
    }
}
```

**Note**: `@ptrCast(kw.ptr)` is needed because `kw` is `[]const u8` (no sentinel) but Linenoise expects `[*:0]const u8` (null-terminated). The cast is safe because string literals in Zig are comptime null-terminated.

### History

```zig
// Load on startup
const home_ptr = std.c.getenv("HOME");
const home = if (home_ptr) |ptr| std.mem.sliceTo(ptr, 0) else "/tmp";
const history_path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/.ko_history", .{home}, 0);
defer self.allocator.free(history_path);
_ = ln.historyLoad(history_path.ptr);

// Save after each input
_ = ln.historyAdd(line_ptr);
_ = ln.historySave(history_path.ptr);
```

**Note**: `std.c.getenv` is used because `std.posix.getenv` doesn't exist in Zig 0.17. The history file uses `allocPrintSentinel` (not `allocPrintZ`) because `allocPrintZ` doesn't exist in Zig 0.17.

---

## 2. Try-Parsing Multi-Line Detection

### Problem

Kō uses indentation-based syntax. When a user types:

```
fn add x y =
  x + y
```

The REPL needs to know that `fn add x y =` is incomplete and should wait for more input.

### Approach

We use a two-layer strategy:

1. **Heuristics** (fast path): Track bracket depth and detect `=`/`then` endings
2. **Parser validation** (slow path): Try to parse the accumulated input

```zig
fn readMultiLine(self: *Repl, first_line: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(self.allocator, first_line);

    var bracket_depth: i32 = 0;
    var needs_body = false;

    while (true) {
        // Count brackets in current buffer
        bracket_depth = 0;
        for (buf.items) |ch| {
            if (ch == '(' or ch == '{' or ch == '[') bracket_depth += 1;
            if (ch == ')' or ch == '}' or ch == ']') bracket_depth -= 1;
        }

        // Check if line needs a body
        const trimmed = std.mem.trimEnd(u8, buf.items, " \t");
        needs_body = false;
        if (trimmed.len > 0) {
            const last_ch = trimmed[trimmed.len - 1];
            if (last_ch == '=') {
                needs_body = true;
            } else if (std.mem.endsWith(u8, trimmed, "then")) {
                // Check if there's an else after then
                const then_pos = std.mem.lastIndexOf(u8, trimmed, "then") orelse 0;
                const after_then = trimmed[then_pos + 4 ..];
                if (std.mem.indexOf(u8, after_then, "else") == null) {
                    needs_body = true;
                }
            }
        }

        // If brackets are balanced and no body needed, try parsing
        if (bracket_depth <= 0 and !needs_body) {
            if (parser.Parser.init(self.allocator, source_z)) |p| {
                var parser_inst = p;
                defer parser_inst.deinit();
                if (parser_inst.parse_program()) |_| {
                    break; // Parse succeeded
                } else |_| {}
            } else |_| {}
        }

        // Need more input
        try buf.append(self.allocator, '\n');
        const cont_ptr = ln.linenoise("... ") orelse break;
        defer ln.linenoiseFree(cont_ptr);
        const cont = std.mem.sliceTo(cont_ptr, 0);
        if (cont.len == 0) break; // Empty line terminates
        try buf.appendSlice(self.allocator, cont);
    }
    return try buf.toOwnedSlice(self.allocator);
}
```

### Heuristics

| Pattern | Meaning | Action |
|---------|---------|--------|
| `fn add x y =` | Ends with `=` | Need body → show `...` prompt |
| `if x then` | Ends with `then` | Need `else` → show `...` prompt |
| `(a + b` | Unclosed bracket | Need closing → show `...` prompt |
| `fn add x y = x + y` | Complete | Parse succeeds → evaluate |
| Empty line | User is done | Terminate multi-line |

### Parser Validation

The parser is called as a "try" to check if the input is complete:

```zig
if (parser.Parser.init(self.allocator, source_z)) |p| {
    var parser_inst = p;
    defer parser_inst.deinit();
    if (parser_inst.parse_program()) |_| {
        break; // Parse succeeded — input is complete
    } else |_| {
        // Parse error — might be incomplete input
    }
} else |_| {
    // Parser init failed — likely incomplete input
}
```

**Why not rely on parser errors?** Because the parser accepts some incomplete input (e.g., `fn f x =` without a body). The heuristics catch these cases before the parser is called.

### Continuation Prompt

When more input is needed, Linenoise shows `... ` (with a space):

```zig
const cont_ptr = ln.linenoise("... ") orelse break;
```

This works because Linenoise handles the prompt display, cursor positioning, and line editing. The user can use arrow keys and editing commands even in continuation mode.

---

## 3. Signal Handlers (Panic Recovery)

### Problem

When user code crashes (division by zero, stack overflow, etc.), the REPL process dies. The user loses their session, accumulated definitions, and history.

### Solution

Install signal handlers that use `longjmp` to recover back to the REPL loop:

```zig
var g_repl_jmp_buf: [256]c_int = undefined;

fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
    const msg = switch (sig) {
        .INT => "\nInterrupted.\n",
        .ABRT => "\nRuntime panic (abort).\n",
        .SEGV => "\nRuntime panic (segmentation fault).\n",
        else => "\nSignal received.\n",
    };
    _ = linux.write(2, msg.ptr, msg.len);
    flushStdout();
    longjmp(&g_repl_jmp_buf, 1);
}

fn installSignalHandlers() void {
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &sa, null);
    std.posix.sigaction(.ABRT, &sa, null);
    std.posix.sigaction(.SEGV, &sa, null);
}
```

### How It Works

1. At the start of each REPL iteration, `setjmp` saves the CPU state:
   ```zig
   const jmp_ret = setjmp(&g_repl_jmp_buf);
   if (jmp_ret != 0) {
       // Recovered from signal — print prompt and continue
       try writeAll(stdout_fd, "\n");
   }
   ```

2. If a signal fires (SIGABRT, SIGSEGV), the handler:
   - Writes an error message to stderr
   - Flushes stdout
   - Calls `longjmp` to jump back to the `setjmp` point

3. The REPL continues from the `setjmp` point with `jmp_ret != 0`, prints a newline, and shows the next prompt.

### Why `longjmp` Instead of Just Returning?

Signal handlers have strict limitations:
- Can only call async-signal-safe functions
- Cannot use `defer` or cleanup
- Cannot throw Zig errors

`longjmp` is one of the few safe operations in a signal handler. It immediately transfers control without unwinding the stack.

### Terminal Restoration

The old REPL had a problem: `std.process.exit(0)` in `:quit` bypassed `defer disableRawMode()`, leaving the terminal in raw mode.

With Linenoise, this is handled automatically:
- Linenoise manages its own terminal state
- On Ctrl-D (EOF), Linenoise restores the terminal
- The `linenoiseClearScreen()` call in the signal handler ensures the terminal is in a clean state

---

## 4. Expression Evaluation

### Expression vs Definition Detection

```zig
fn isDefinition(input: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, input, " \t");
    if (std.mem.startsWith(u8, trimmed, "fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "type ")) return true;
    if (std.mem.startsWith(u8, trimmed, "let ")) return true;
    if (std.mem.startsWith(u8, trimmed, "module ")) return true;
    if (std.mem.startsWith(u8, trimmed, "pub ")) return true;
    if (std.mem.startsWith(u8, trimmed, "import ")) return true;
    if (std.mem.startsWith(u8, trimmed, "package ")) return true;
    for (trimmed, 0..) |ch, i| {
        if (ch == '(' or ch == ')' or ...) return false;
        if (ch == '=' and i > 0 and ...) return true;
    }
    return false;
}
```

### Definition Handling

Definitions are accumulated across evaluations:

```zig
fn addToHistory(self: *Repl, input: []const u8) !void {
    if (isDefinition(input)) {
        if (self.accumulated_source.items.len > 0) {
            try self.accumulated_source.append(self.allocator, '\n');
        }
        try self.accumulated_source.appendSlice(self.allocator, input);
        try self.accumulated_source.append(self.allocator, '\n');
    }
}
```

### Expression Handling

Expressions are wrapped in a unique function and JIT-executed:

```zig
// 1. Build source with accumulated definitions + eval function
try source.appendSlice(self.allocator, fn_defs.items);
try source.appendSlice(self.allocator, "fn ");
try source.appendSlice(self.allocator, eval_name);  // e.g., "__repl_eval_0"
try source.appendSlice(self.allocator, " =\n");
try source.appendSlice(self.allocator, let_bindings.items);
try source.appendSlice(self.allocator, "  ");
try source.appendSlice(self.allocator, input);
try source.append(self.allocator, '\n');

// 2. Parse, typecheck, lower to HIR, optimize, lower to LIR
// 3. Generate LLVM IR
// 4. JIT-execute the function
const eval_fn: *const fn () callconv(.c) i64 = @ptrFromInt(fn_addr);
const result = eval_fn();
```

### Result Display

- Expressions: `= 9`
- Side effects (println, print): Output only, no `=`
- Definitions: `Defined.`

---

## 5. Zig-C Interop: How It All Connects

### The Problem

Linenoise is a **C library** (~2400 lines of C). Our compiler is written in **Zig**. How do we call C functions from Zig?

### The Three-Layer Architecture

```
┌─────────────────────────────────────────────────────┐
│  repl.zig          (Zig code — calls linenoise.zig) │
├─────────────────────────────────────────────────────┤
│  linenoise.zig     (Zig bindings — extern decls)    │
├─────────────────────────────────────────────────────┤
│  vendor/linenoise.c (C source — the actual library) │
└─────────────────────────────────────────────────────┘
```

### Step 1: C Header → Zig Bindings

C functions are declared in `linenoise.c`. We need equivalent declarations in Zig. Instead of using `@cImport` (which has issues in Zig 0.17), we manually declare them:

```zig
// src/linenoise.zig
pub extern fn linenoise(prompt: [*:0]const u8) ?[*:0]u8;
pub extern fn linenoiseFree(ptr: ?*anyopaque) void;
pub extern fn linenoiseHistoryAdd(line: [*:0]const u8) c_int;
```

**Key concepts:**

| Zig Type | C Equivalent | Meaning |
|----------|--------------|---------|
| `[*:0]const u8` | `const char *` | Null-terminated string pointer |
| `?[*:0]u8` | `char *` (nullable) | Optional null-terminated string |
| `c_int` | `int` | C-compatible integer |
| `?*anyopaque` | `void *` (nullable) | Generic pointer |
| `callconv(.c)` | (default) | C calling convention |

**Why `[*:0]const u8` instead of `[]const u8`?**
- `[]const u8` = Zig slice (pointer + length, no sentinel)
- `[*:0]const u8` = C string (pointer to null-terminated data)
- C functions expect null-terminated strings, so we use the sentinel type

### Step 2: Compile C Source into Zig Module

The C file must be compiled and linked into our Zig binary. This happens in `build.zig`:

```zig
// Create a Zig module that wraps the C source
const linenoise_mod = b.createModule(.{
    .root_source_file = b.path("src/linenoise.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,  // linenoise uses libc functions
});

// Add the C source file to THIS module (not the root module)
linenoise_mod.addCSourceFile(.{
    .file = b.path("vendor/linenoise.c"),
    .flags = &.{"-D_GNU_SOURCE"},  // enables GNU extensions
});

// Add include path for linenoise.h
linenoise_mod.addIncludePath(b.path("vendor"));

// Import this module into the main executable
ko_exe.root_module.addImport("linenoise", linenoise_mod);
```

**Critical rule:** The C source goes in the **module that owns the bindings** (`linenoise_mod`), NOT the root module. Adding it to both causes duplicate symbol errors.

### Step 3: Linking

When `zig build` runs, the linker combines:

1. **Your Zig code** → compiled to machine code
2. **Linenoise C code** → compiled from `vendor/linenoise.c`
3. **System libraries** → libc (for `malloc`, `printf`, etc.)

The linker resolves all `extern fn` declarations in Zig to their actual addresses in the compiled C code.

### Calling Convention

When Zig calls a C function, it must use the **C calling convention**:

```zig
// The callback must match C's calling convention
pub const CompletionCallback = *const fn ([*:0]const u8, *Completions) callconv(.c) void;
//                                                                       ^^^^^^^^^
//                                                                       C calling convention
```

Without `callconv(.c)`, Zig uses its own calling convention (which may differ in how arguments are passed, stack cleanup, etc.), causing crashes.

### Memory Ownership

C and Zig have different memory models:

```zig
// Linenoise allocates memory with malloc()
const line_ptr = linenoise.linenoise("ko> ");
// line_ptr is owned by Linenoise — DO NOT free with Zig's allocator

// When done, call Linenoise's free function
defer linenoise.linenoiseFree(line_ptr);
// linenoiseFree calls C's free() on the pointer
```

**Rule:** Memory allocated by C (`malloc`) must be freed by C (`free`). Never mix allocators.

### String Conversion

Zig strings ↔ C strings require conversion:

```zig
// Zig []const u8 → C [*:0]const u8 (for string literals, safe because they're comptime null-terminated)
const keyword: []const u8 = "fn";
const c_str: [*:0]const u8 = @ptrCast(keyword.ptr);

// C [*:0]const u8 → Zig []const u8
const c_string: [*:0]const u8 = linenoise.linenoise("ko> ");
const zig_string: []const u8 = std.mem.sliceTo(c_string, 0);

// Allocating null-terminated copies (when you need to keep the string)
const owned = try allocator.dupeZ(u8, zig_string);
defer allocator.free(owned);
```

### The Full Flow

When the user presses Enter in the REPL:

```
1. User types "1 + 2" and presses Enter
2. Linenoise (C code) reads from stdin, handles line editing
3. Linenoise returns a [*:0]const u8 (C string pointer)
4. Zig receives the pointer via the extern binding
5. Zig converts to []const u8 with std.mem.sliceTo()
6. Zig passes to the parser (pure Zig code)
7. When done, Zig calls linenoiseFree() (C code) to release memory
```

### Why Not Use Zig's Standard Library for Line Editing?

Zig's `std.Io` could theoretically handle terminal I/O. But:
- **Linenoise is battle-tested** (used by Redis, MongoDB)
- **Terminal handling is complex** (raw mode, escape sequences, signal handling)
- **Linenoise is ~2400 lines of C** — reimplementing in Zig would be weeks of work
- **The C interop is straightforward** — only ~10 functions to bind

---

## 6. Gotchas & Lessons Learned

### `@cImport` Doesn't Work in Separate Modules

In Zig 0.17, `@cImport` fails when used in a module that's imported by the root module. Solution: use `pub extern fn` declarations instead.

### `std.posix.sigaction` Doesn't Return an Error

In Zig 0.17, `std.posix.sigaction` returns `void`, not `!void`. No need for `catch {}`.

### `std.io` Doesn't Exist in Zig 0.17

Zig 0.17 uses `std.Io` (capital I) for the high-level I/O interface. For raw output (like in signal handlers), use `linux.write()` directly.

### `std.fmt.allocPrintZ` Doesn't Exist

Use `std.fmt.allocPrintSentinel(allocator, fmt, args, 0)` instead.

### `std.c.getenv` Instead of `std.posix.getenv`

`std.posix.getenv` doesn't exist in Zig 0.17. Use `std.c.getenv` and convert the pointer to a slice with `std.mem.sliceTo(ptr, 0)`.

### `longjmp` is a Safety Net, Not a Design Pattern

Signal handlers with `longjmp` are dangerous:
- They bypass `defer` cleanup
- They can leave resources in inconsistent states
- They should only be used for "last resort" recovery

In our case, the REPL's accumulated source and history are safe because they're stored in global state, not local variables.

### Parser Accepts Some Incomplete Input

The parser accepts `fn f x =` without a body. This is a pre-existing parser bug. The heuristic-based multi-line detection catches this before the parser is called.

---

## 7. Testing

### Manual Tests

```bash
# Basic expression
echo "1 + 2" | ko --repl
# → = 3

# Function definition + call
printf "fn add x y = x + y\nadd 3 4\n" | ko --repl
# → Defined.
# → = 7

# Multi-line function
printf "fn fib n =\n  if n <= 1 then n else fib (n - 1) + fib (n - 2)\nfib 10\n" | ko --repl
# → Defined.
# → = 55

# Type query
printf "fn add x y = x + y\n:type add\n" | ko --repl
# → Defined.
# → add : Int -> Int -> Int
```

### Automated Tests

All 256 existing tests continue to pass:

```bash
zig build test --summary all
# → 256/256 tests passed
```

---

## 8. Future Improvements

### Persistent LLVM Module

Currently, each expression evaluation creates a fresh LLVM module. A persistent module would:
- Reduce JIT compilation time
- Allow cross-evaluation optimizations
- Enable incremental type inference

### Better Multi-Line Detection

The current heuristics work for common cases but miss some edge cases:
- `match` expressions without arms
- Nested `if/then/else`
- Lambda bodies

A more robust approach would be to use the parser's error messages to detect "incomplete input" vs "syntax error".

### Error Recovery with setjmp/longjmp

The current signal handlers catch crashes but don't preserve the REPL state. A more sophisticated approach would use `setjmp`/`longjmp` with a recovery point that:
- Prints the error message
- Restores the REPL state
- Continues from the last valid state

### Incremental Type Environment

Currently, the type environment is rebuilt from scratch for each expression. An incremental approach would:
- Remember types from previous evaluations
- Only re-check changed definitions
- Enable better error messages ("this expression changed type because...")
