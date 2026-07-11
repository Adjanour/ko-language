# AGENTS.md - Zig Development Patterns for Kō Compiler

## Workflow Pattern: Research → Design → Implement

**MUST DO:** Before implementing any feature or fix, follow this process:

1. **Explain the problem** — Understand what's broken or missing
2. **Research** — Look at how other languages solve this (OCaml, Haskell, Rust, Zig, etc.)
3. **Finalize design decisions** — Choose an approach based on research, document why
4. **Identify implementation options** — What are the tradeoffs?
5. **Implement** — Write the code
6. **Test** — Verify with `zig build test --summary all`

This applies to ALL changes: features, bugs, architecture, syntax decisions.

**Example:**
- Problem: "Multi-arg constructors crash in REPL"
- Research: "How does OCaml handle boxed vs unboxed constructors?"
- Design: "Use raw tags for zero-arg, boxed structs for multi-arg"
- Options: "Fix inspectValue vs change constructor representation"
- Implement: Write the fix
- Test: Run `zig build test --summary all`

## Zig 0.17 API Patterns

### Main Function Signature

```zig
pub fn main(init: std.process.Init) !void {
    // init.gpa - general purpose allocator
    // init.arena - arena allocator (permanent storage)
    // init.io - I/O interface
    // init.minimal.args - command line arguments
    // init.minimal.environ - environment variables
}
```

### Allocators

```zig
// In Zig 0.17, GeneralPurposeAllocator is replaced with DebugAllocator
var gpa: std.heap.DebugAllocator(.{}) = .{};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Arena allocator (for permanent storage)
var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
defer arena.deinit();
const arena_allocator = arena.allocator();
```

### I/O Pattern

```zig
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    // Create threaded I/O
    var threaded: Io.Threaded = .init(init.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    
    // Get stdout/stderr
    const stdout = Io.File.stdout();
    const stderr = Io.File.stderr();
    
    // Create writer with buffer
    var buffer: [4096]u8 = undefined;
    var writer = stdout.writer(io, &buffer);
    
    // Write using interface
    try writer.interface.print("Hello {s}\n", .{"world"});
    try writer.interface.flush();
}
```

### File Reading Pattern

```zig
const cwd = Io.Dir.cwd();
const file = try cwd.openFile(io, filename, .{});
defer file.close(io);

var file_buffer: [4096]u8 = undefined;
var reader = file.reader(io, &file_buffer);
const source = try reader.interface.allocRemainingAlignedSentinel(
    init.arena.allocator(),
    .unlimited,
    @enumFromInt(0),
    0,
);
```

### Important Zig 0.17 Notes

- `std.fs.cwd()` is not the path for this codebase; use `std.Io.Dir.cwd()`.
- `std.heap.GeneralPurposeAllocator` is gone; use `std.heap.DebugAllocator(.{})`.
- `std.process.Init` provides `gpa`, `arena`, `io`, and `minimal.args`.
- `std.process.Args.Iterator.init(init.minimal.args)` is the current args pattern.
- `Io.File.stdout()` and `Io.File.stderr()` are used with `writer(io, buffer)`.
- Prefer null-terminated slices when the tokenizer benefits from sentinel checks.

### Command Line Arguments

```zig
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name
    
    const filename = args.next() orelse {
        // No filename provided
        return error.MissingArgument;
    };
}
```

### Memory Allocation

```zig
// Using allocator
const slice = try allocator.alloc(u8, 1024);
defer allocator.free(slice);

// Using arena (no need to free individual allocations)
const str = try arena_allocator.dupe(u8, "hello");
// Freed all at once when arena.deinit() is called
```

### Array Lists

```zig
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();

try list.append('a');
try list.appendSlice("hello");
const owned = try list.toOwnedSlice();
```

### Hash Maps

```zig
var map = std.StringHashMap(u8).init(allocator);
defer map.deinit();

try map.put("key", 'value');
if (map.get("key")) |val| {
    // use val
}
```

### Error Handling

```zig
// Errors are values, not exceptions
const result = doSomething() catch |err| {
    std.debug.print("Error: {}\n", .{err});
    return err;
};

// Or propagate up
const result = try doSomething();
```

### Testing

```zig
test "description" {
    try std.testing.expectEqual(expected, actual);
    try std.testing.expectError(error.Expected, actual);
}
```

#### `zig build test` output is misleading

The default `zig build test` output often shows `failed command:` lines and truncated status. This is noise from the Zig test runner's `--listen=-` protocol, not actual failures. **Always use `--summary all` to see the real result:**

```bash
zig build test --summary all 2>&1
# Shows: Build Summary: 3/3 steps succeeded; 77/77 tests passed
```

Without `--summary all`, the output may look like it failed even when all tests pass and exit code is 0.

#### Test memory management

- Use `ArenaAllocator` wrapping `std.testing.allocator` for parser/typechecker tests — frees everything on `defer arena.deinit()`
- Never use `std.testing.allocator` directly for parser tests without an arena — the parsed AST leaks
- The `page_allocator` bypasses leak detection entirely — use `std.testing.allocator` when you want leak checking

## Kō Language Patterns

### Indentation Tracking

- Kō uses significant whitespace (like Python)
- Newlines, INDENT, DEDENT tokens
- Track indentation stack for nested blocks

### Token Types

- Keywords: fn, let, if, then, else, match, type, import, package, pub, module, ref, comptime, not, and, or
- Operators: +, -, *, /, %, =, ==, !=, <, <=, >, ->, =>, :=, |>, &&, ||, !, :
- Delimiters: (, ), {, }, [, ], ,, ;, ., _, ~, ..
- Literals: number, string, identifier, constructor

### Tokenizer Rules We Learned

- Standalone `_` is a wildcard token; `_foo` and `map-maybe` are identifiers.
- `#` comments must fully disappear from the token stream, including comment-only indented lines.
- Indentation can emit more than one `dedent`; keep pending dedents queued.
- Numeric literals should support decimal, hex (`0x`), binary (`0b`), and octal (`0o`).
- Char literals should be tokenized separately from strings and support escapes.
- `&&` is the logical-and operator; bare `&` is a separate token.

### Syntax Freeze

- Do not change these forms before parser port unless a bug forces it:
  - `_` wildcard token
  - hyphenated identifiers
  - numeric literal bases
  - `#` comments and indentation
  - `~name:expr` named args
  - `pub` visibility placement
  - braces-based records
  - `..` in record patterns
  - `|>` pipe operator
  - `=>` for match arms (NOT `->`)
  - `!expr` for deref (NOT boolean negation)
  - `not expr` for boolean negation
  - `ref expr` for creating references
  - `:=` for assignment
  - `::` for infix constructor (right-associative, desugars to `Cons a b`)
  - `type List a = Cons a (List a) | Nil` syntax (type params before `=`)
  - Constructor params are individual type primaries, not applied types
  - `fn f x : Int = ...` — `: Int` is param annotation, not return type
  - Return type annotation uses separate syntax (TBD)

### Language Charter

- `LANGUAGE_CHARTER.md` is the source of truth for what Kō should become.
- Use it to decide whether a syntax change is a fix, a feature, or churn.

### Data Model

- `type Expr = ...` defines a sum type.
- `type Binding = { ... }` defines a record.
- Record layout is a storage concern, not part of the type definition.
- Record patterns use `..` for intentional partial matches.

### Comments

- Kō uses `#` for comments (not //)
- Comments extend to end of line

## Lessons Learned (Hard-Won)

### The Grammar Is the Contract

The grammar (`GRAMMAR.md`) is the source of truth for parsing. The parser must implement it, not the other way around. If a test passes but violates the grammar, the test is wrong. If the grammar is wrong, fix the grammar first, then fix the parser.

**Rule: Every `.ko` test program must at least parse successfully before it can be used to test typechecking or codegen.** A test that fails at the lexer/parser level is invalid — it's testing nothing useful. Before adding or modifying a test, verify:

```bash
ko tests/some_test.ko 2>&1 | head -3
# Should show "Parsed: N definitions" (not an error)
```

**Adding a new test program:**
1. Write the `.ko` file in `src/tests_ko/`
2. Add a trailing newline if missing
3. Add the `@embedFile` entry to the parser test in `tests.zig`
4. Run `zig build test` — it must parse successfully

### Grammar vs Implementation Drift

If the grammar says one thing but the parser does another, fix the grammar to match the parser (unless the grammar is clearly better). The grammar is documentation, the parser is truth. But fix drift early — it compounds.

Example: grammar said `match_arm = pattern "->" expr` but parser uses `=>`. Fixed grammar to `=>`.

### `@embedFile` Is Already Sentinel-Terminated

In Zig, `@embedFile("path")` returns `*const [N:0]u8` — already null-terminated. Do NOT append `++ "\x00"`. Doing so creates a double null that the tokenizer misreads as premature EOF, causing parse errors on valid programs.

### How Parser Bugs Hid for Months

The parser was built incrementally to make individual tests pass, not to faithfully implement the grammar. This caused several classes of bugs:

1. **Grammar says "blocks are indentation-based everywhere"** but `parse_block` only handled `keyword_let` in indented blocks. Non-indented blocks (let bodies) crashed on `keyword_let` because it fell through to `parse_expr()` which can't parse `let`. Fixed with `allow_let_in_body` flag.

2. **Grammar says field access binds tighter than application** but `parse_postfix` treated all non-dot, non-brace tokens after a primary as function arguments. `println pt.x` became `(println pt).x`. Fixed with `parse_postfix_no_apply` helper.

3. **Grammar says every function needs a basic block** but `codegenFn` didn't create one for regular functions (only lambdas had it). Caused LLVM segfaults at address 0x48. Always create entry block in `codegenFn`.

### The `allow_let_in_body` Pattern

`parse_block` is called from two contexts with different needs:
- **From `parse_fn_def`**: `keyword_let` should terminate the block (it's a top-level definition)
- **From `parse_let_expr_in_block`**: `keyword_let` should be parsed as a nested let expression

Solution: `Parser.allow_let_in_body` flag. Set to `true` when entering a let body, `false` otherwise. In `parse_block`, when `!is_indented and keyword_let`, check `allow_let_in_body` before deciding to handle or break.

### Why `fn_body_stops` Matters

`fn_body_stops` (without `keyword_let`) is correct for function bodies. Adding `keyword_let` to it would make the fn body consume subsequent top-level let bindings, breaking the program structure. The let body issue is solved separately via `allow_let_in_body`, not by changing stop tags.

### Inline Comments and `isInlineComment`

Kō's tokenizer produces `.comment` tokens for both inline comments (`x + y  # comment`) and standalone comment lines (`# comment`). The parser must distinguish them:

- **Standalone comment lines** should break non-indented blocks (they're doc comments for the NEXT definition)
- **Inline comments** should be skipped transparently (they're annotations on the current expression)

`isInlineComment()` checks if there's a newline between the previous non-newline token and the comment. If no newline → inline. The check must skip past consumed `.newline` tokens to find the actual previous content token.

In `parse_block` (non-indented):
```zig
if (self.current().tag == .comment and !is_indented and !self.isInlineComment()) break;
```

In the skip loop:
```zig
if (self.current().tag == .newline or (self.current().tag == .comment and (is_indented or self.isInlineComment()))) {
    _ = self.advance();
    continue;
}
```

In `parse_let_expr_in_block`, skip comments after `skip_newlines()` so the body check sees the correct next token:
```zig
self.skip_newlines();
while (self.current().tag == .comment) {
    _ = self.advance();
}
```

### Test Pyramid for Compiler Stages

When testing compiler features, write tests in this order:
1. **Lexer test**: tokenize the input, verify token sequence
2. **Parser test**: parse the input, verify AST structure
3. **Typechecker test**: typecheck the parsed AST, verify no errors
4. **Codegen test**: generate LLVM IR, verify output
5. **Integration test**: `ko --run` the program, verify output

Never skip stages. A test that only does codegen without verifying parsing is fragile.

## Common Mistakes to Avoid

1. **Don't use deprecated APIs**
   - ❌ `std.heap.GeneralPurposeAllocator`
   - ✅ `std.heap.DebugAllocator`

2. **Don't forget to flush I/O**
   - Always call `writer.interface.flush()` after printing

3. **Don't mix allocator types**
   - Use the same allocator for alloc and free

4. **Don't ignore errors**
   - Use `try` or `catch` for fallible operations

5. **Don't forget arena cleanup**
   - Always call `arena.deinit()` to free all arena allocations

## Build Commands

```bash
# Build the project
zig build

# Run tests (use --summary all to see clean output)
zig build test --summary all

# JIT-execute a program
ko --run file.ko

# Dump LLVM IR
ko file.ko

# Emit LLVM IR to file
ko --emit-ir out.ll file.ko

# Emit object file
ko --emit-obj out.o file.ko

# Emit linked executable
ko --emit-exe out file.ko
```

## File Structure

```
ko-zig/
├── build.zig          # Build configuration
├── build.zig.zon      # Package metadata
├── src/
│   ├── main.zig       # Entry point
│   ├── lexer.zig      # Tokenizer
│   ├── parser.zig     # Recursive descent parser
│   ├── ast.zig        # AST node types (canonical definitions)
│   ├── errors.zig     # Error types
│   ├── typecheck.zig  # HM type inference
│   ├── codegen.zig    # LLVM IR generation
│   ├── stdlib.zig     # Zig stdlib implementations (math, string, int ops)
│   ├── stdlib_codegen.zig # LLVM IR generation for ALL stdlib functions
│   ├── ko_runtime.c   # Minimal C stub for AOT libc linkage
│   ├── comptime.zig   # Compile-time evaluator
│   ├── module_loader.zig # File-based module imports
│   ├── prettyprint.zig # Type-directed value pretty-printing
│   ├── repl.zig       # REPL implementation
│   ├── lsp.zig        # LSP server
│   ├── llvm/          # kassane/llvm-zig bindings source
│   ├── tests.zig      # All tests (77 tests, zero leaks)
│   └── tests_ko/      # .ko test programs (47 files)
│       ├── 01_literal.ko .. 47_float_math.ko
├── std/               # Kō stdlib (written in Kō)
│   ├── List.ko        # List operations (25 ops)
│   ├── Int.ko         # Extra Int operations
│   ├── Float.ko       # Float operations
│   ├── String.ko      # String operations
│   ├── Bool.ko        # Bool operations
│   └── Math.ko        # Pure Kō math operations
└── tests/             # (unused, test .ko files are in src/tests_ko/)
```

### Module Dependencies

```
main.zig → parser.zig → lexer.zig
                       → ast.zig
         → typecheck.zig → parser.zig (re-exports ast types)
         → codegen.zig → parser.zig, typecheck.zig
                       → stdlib.zig (JIT function implementations)
                       → llvm/ (kassane/llvm-zig bindings)
                       → llvm/ (kassane/llvm-zig bindings)
```

- `ast.zig` is the single source of truth for all AST types
- `parser.zig` re-exports ast types for backward compatibility
- `typecheck.zig` imports parser types (which are re-exports from ast.zig)
- `codegen.zig` uses kassane/llvm-zig bindings (source in `src/llvm/`)

## File-Based Imports

### How It Works
- `import lib.math` resolves to `{base_dir}/lib/math.ko`
- `import std.math` resolves to `{base_dir}/std/math.ko`
- Alias: `import lib.math as m` makes the module available as `m.add`, etc.
- Selective import: `import lib.math.{add, mul}` imports only named definitions

### Architecture
- `module_loader.zig` — `ModuleLoader` struct with raw Linux syscall file I/O
- `typecheck.zig` — `processImports` method loads/parses/typechecks imported modules
- `codegen.zig` — `codegenProgram` processes imports: loads, registers types/constructors, codegens functions

### Gotcha: Qualified Names
- Imported functions are registered as `module_name.fn_name` (e.g., `math.add`)
- Imported constructors are registered as both `module_name.CtorName` and `CtorName`
- Field access syntax `math.add` is parsed as `field_access(math, add)` — codegen resolves it via qualified name lookup

### Gotcha: HashMap Key Memory
- `std.fmt.allocPrint` allocates key strings — do NOT free them with `defer`
- The HashMap stores `[]const u8` slices (pointer + length), not copies of the underlying data
- Freeing the key string causes use-after-free during HashMap grow/rehash → crash

### Gotcha: Imported Module Codegen
- Imported modules are codegen'd in the same LLVM module as the main program
- The `Codegen.module_loader` field enables codegen to process imports
- Imported functions get both declarations and body codegen
- Import processing happens BEFORE the main program's flatten/codegen passes

### Known Limitations (v0.1)
- Imported type info doesn't propagate to main Inferer's type environment (type variables instead of concrete types)
- Constructor type tags from imported modules may show raw values in `println`
- No circular import detection
- No package/module system — just flat file imports

## Standard Library

### Architecture
- **Zig stdlib** (`src/stdlib.zig`): Canonical implementations for all builtins (math, string, int ops)
- **LLVM IR stdlib** (`src/stdlib_codegen.zig`): Generates LLVM IR for ALL stdlib functions including I/O (inspect, println, print)
- **Kō stdlib files** (`std/*.ko`): Higher-level operations written in Kō
- Builtins are auto-registered in typechecker and codegen — no import needed

### How It Works
- **JIT mode**: All functions are generated as LLVM IR in the module; only libc externals (printf, malloc, etc.) and LLVM intrinsics are linked at JIT time
- **AOT mode**: Same LLVM IR is emitted as object file; minimal `ko_runtime.c` stub provides libc linkage
- The canonical implementation is in stdlib_codegen.zig — no C copies needed

### Built-in Functions (auto-available)
- `println x`, `print x`, `inspect x` — polymorphic I/O
- `Int.toString n`, `Int.abs n`, `Int.min a b`, `Int.max a b`
- `Int.pow base exp`, `Int.gcd a b`, `Int.lcm a b`, `Int.factorial n`, `Int.isqrt n`
- `Float.ofInt n`, `Float.toInt f`, `Float.sqrt f`, `Float.pow b e`
- `Float.sin f`, `Float.cos f`, `Float.tan f`, `Float.log f`, `Float.log2 f`, `Float.log10 f`
- `Float.exp f`, `Float.floor f`, `Float.ceil f`, `Float.abs f`
- `String.length s`, `String.append a b`
- `True`, `False` — Bool constructors
- `Result.is_ok r` — returns `True` if Ok, `False` if Err
- `Result.is_err r` — returns `True` if Err, `False` if Ok
- `Result.unwrap default r` — returns Ok value, or `default` if Err
- `Result.map f r` — applies `f` to Ok value, returns new Result
- `Result.fold ok_fn err_fn r` — applies `ok_fn` to Ok value, `err_fn` to Err value
- `Result.and_then f r` — applies `f` to Ok value (f must return a Result)
- `expr?` — postfix try operator; unwraps Result, propagates Err

### Kō Stdlib Files (`std/`)
- `std/List.ko` — List type and operations (25 ops: foldl, foldr, head, tail, length, append, reverse, map, filter, any, all, find, take, drop, elem, zip, concat, sum, product, maximum, minimum, etc.)
- `std/Int.ko` — Extra Int operations (even, odd, clamp, sign, div, mod, max, min)
- `std/String.ko` — Extra String operations (isEmpty)
- `std/Bool.ko` — Bool operations (not)
- `std/Math.ko` — Pure Kō math operations (abs, max, min, gcd, lcm, factorial, pow, isqrt, sum, product, average)

### How to Add New Builtins
1. Add implementation to `src/stdlib_codegen.zig` (generates LLVM IR directly in module)
2. Register type in `typecheck.zig` (in `inferProgram`)
3. Register in `codegen.zig` `declareBuiltins` (look up with `LLVMGetNamedFunction`)

### Gotcha: JIT vs AOT
- **JIT**: All functions are LLVM IR in the module; only libc/LLVM intrinsics linked at JIT time
- **AOT**: Same LLVM IR emitted as object file; minimal `ko_runtime.c` stub provides libc linkage
- No C copies needed — `stdlib_codegen.zig` is the single source of truth

### Future: Eliminate ko_runtime.c entirely
- The C stub only exists to provide libc headers for AOT linking
- Could be replaced by linking against libc directly from LLVM's target machine

### Known Limitations
- Multi-line closures capturing free variables cause LLVM codegen errors
- `True`/`False` only work as match patterns or top-level values, not inside lambdas

## LLVM Codegen (kassane/llvm-zig bindings)

### Critical: Opaque Pointer Mode (LLVM 15+)

LLVM 22 uses **opaque pointers** — all pointers are `ptr`, no pointee types.

#### Never use `LLVMGetElementType` on pointer types
It is deprecated/removed in LLVM 22. The old typed-pointer APIs (`LLVMBuildCall`, `LLVMBuildLoad`, etc.) that relied on it are removed. Use the `2` variants instead.

#### `LLVMTypeOf` returns `ptr` for function values
With opaque pointers, `LLVMTypeOf(fn_value)` returns `ptr`, NOT the function type. To get the function type:
- For global functions: use `LLVMGlobalGetValueType(fn_value)` — available in our bindings
- For non-global function pointers: you must track the function type yourself

#### `LLVMBuildCall2` requires explicit function type
```zig
// CORRECT:
const fn_type = core.LLVMGlobalGetValueType(fn_val);
core.LLVMBuildCall2(builder, fn_type, fn_val, &args, argc, "call");

// WRONG — returns opaque ptr, not function type:
core.LLVMBuildCall2(builder, core.LLVMTypeOf(fn_val), fn_val, &args, argc, "call");
```

#### `LLVMBuildLoad2` requires explicit element type
```zig
core.LLVMBuildLoad2(builder, element_type, ptr, "name");
```

### String Null-Termination

Parser slices are `[]const u8` — they are NOT null-terminated. The source buffer's null terminator is at the **end of the entire buffer**, not at the end of each slice.

**Never** do `@ptrCast(slice.ptr)` as `[*:0]const u8` — this reads past the slice boundary.

**Always** create null-terminated copies:
```zig
const name_z = try allocator.dupeZ(u8, slice);
// or
const name_z = try std.fmt.allocPrintZ(allocator, "{s}", .{slice});
```

### All `*Ref` types are optional (`?*TOpaque`)

In the kassane/llvm-zig bindings, every `*Ref` type is `?*TOpaque` (nullable). This matches C's nullable pointer pattern. When passing to C functions, null causes undefined behavior — always check with `orelse` if uncertain.

### Key Function Signatures

| Operation | Function | Key Notes |
|-----------|----------|-----------|
| Get function type | `LLVMGlobalGetValueType(fn)` | Use for `LLVMBuildCall2`'s Ty param |
| Build call | `LLVMBuildCall2(builder, fn_type, fn, args, n, name)` | fn_type must be the function type, not LLVMTypeOf(fn) |
| Build load | `LLVMBuildLoad2(builder, elem_type, ptr, name)` | elem_type is the loaded type |
| Build GEP | `LLVMBuildGEP2(builder, elem_type, ptr, indices, n, name)` | elem_type is the pointee type |
| Add function | `LLVMAddFunction(mod, name_z, fn_type)` | name_z must be null-terminated |
| Set param name | `LLVMSetValueName(param, name_z)` | name_z must be null-terminated |

### Codegen Architecture

`codegen.zig` uses a two-pass approach:
1. **First pass**: `declareFn` for each function — creates LLVM function declarations and registers them in `named_values` and `fn_types`
2. **Second pass**: `codegenFn` for each function — generates the body IR

Function scoping:
- `named_values` is saved/restored per function
- Outer scope (function declarations) is copied into each function's scope
- Parameters are added on top

### JIT Execution (MCJIT)

The `Jit` struct in `codegen.zig` wraps LLVM's MCJIT for direct execution.

#### Setup required before creating JIT
```zig
_ = target.LLVMInitializeNativeTarget();
_ = target.LLVMInitializeNativeAsmParser();
_ = target.LLVMInitializeNativeAsmPrinter();
engine.LLVMLinkInMCJIT();
```

#### MCJIT takes ownership of the module
After `LLVMCreateJITCompilerForModule`, the engine owns the module. Do NOT dispose the module separately. Use `module_owned_by_jit` flag on `Codegen` to track this.

#### Getting function pointers
`LLVMGetFunctionAddress` returns `u64`, not a pointer. Cast with `@ptrFromInt`:
```zig
const addr = engine.LLVMGetFunctionAddress(self.engine, "main");
const fn_ptr: *const fn () callconv(.c) i64 = @ptrFromInt(addr);
const result = fn_ptr();
```

#### Mapping C functions to LLVM symbols
For calling C functions (like `printf`) from JIT'd code:
```zig
engine.LLVMAddGlobalMapping(self.engine, llvm_func, @ptrCast(&my_c_func));
```

#### CLI usage
```bash
ko --run file.ko    # JIT-execute main() and print return value
ko file.ko          # Dump LLVM IR (default)
ko --emit-ir out.ll file.ko   # Dump LLVM IR to file
ko --emit-obj out.o file.ko   # Emit object file only
ko --emit-exe out file.ko     # Emit object file + link to executable
```

### Built-in Functions (println, print)

`println` and `print` are pre-declared in both the typechecker and codegen.

- Type: `forall a. a -> a` (polymorphic, prints and returns the value)
- Runtime: uses `inspect` with type tags to print any type correctly
- **All functions are generated as LLVM IR** — no external C functions needed
- `inspect` uses an LLVM switch instruction with printf calls for each type tag
- Type tags: 0=int, 1=float, 2=bool, 3=char, 4=string, 5=unit, 6=constructor, 7=record, 8=function, 9=tuple

#### Key pattern for built-in functions
```zig
// In typechecker: register as polymorphic
const println_from = try self.newVarType("a");
const println_to = println_from;
const println_ty = try self.allocator.create(Type);
println_ty.* = .{ .arrow = .{ .from = println_from, .to = println_to } };
const println_var_id = println_from.variable.id;
const println_quantified = try self.allocator.alloc(usize, 1);
println_quantified[0] = println_var_id;
try self.global.set("println", .{ .quantified = println_quantified, .body = println_ty });

// In codegen: declare with 2 params (value, type_tag)
var param_i64_tag: [2]types.LLVMTypeRef = .{ i64_type, i64_type };
const println_type = core.LLVMFunctionType(i64_type, &param_i64_tag, 2, 0);
const println_fn = core.LLVMAddFunction(self.module, "println_with_tag", println_type);

// In JIT: map to native function
engine.LLVMAddGlobalMapping(jit_engine, println_fn, @constCast(@ptrCast(&builtin_println_tag)));
```

#### Gotcha: String/char literals need quote stripping
String literals include surrounding quotes in the lexer. Codegen must strip them before creating the LLVM constant, otherwise `inspect` double-quotes the output.

#### Gotcha: Float literals need bitcast
Float literals produce `double` in LLVM, but the C functions expect `i64`. Use `LLVMBuildBitCast` to convert before passing.

#### Gotcha: Type tag for identifiers is always 100
The codegen type-tag heuristic uses syntactic form (identifier → 100). This means `println xs` where `xs` is a list prints with tag 100 (unknown). Use a let-binding first: `let n = length xs; println n`.

#### Gotcha: `process.run` doesn't inherit PATH
When spawning subprocesses (like `gcc`), use absolute paths (`/usr/bin/gcc`). Zig's `process.run` doesn't inherit environment by default, so `gcc` can't find `cc1`.

### String Literal Codegen

String literals are codegen'd as global string constants with pointer types.

```zig
// Create global string constant
const str_val = core.LLVMConstStringInContext(ctx, ptr, len, 0);
const global = core.LLVMAddGlobal(module, core.LLVMTypeOf(str_val), "str");
core.LLVMSetInitializer(global, str_val);
core.LLVMSetGlobalConstant(global, 1);
core.LLVMSetLinkage(global, .LLVMPrivateLinkage);

// Return pointer via GEP
var indices: [1]LLVMValueRef = .{core.LLVMConstInt(i64_type, 0, 0)};
core.LLVMBuildGEP2(builder, i8_type, global, &indices, 1, "str_ptr");
```

#### Gotcha: `LLVMConstStringInContext` returns `[N x i8]`, not a pointer
Always wrap in a global and GEP to get a usable `i8*` pointer.

### Sum Type Codegen (ADTs)

Sum types are represented as `i64` values. Zero-argument constructors use sequential integer tags (0, 1, 2, ...). Constructors with single arguments store the tag + payload in a stack-allocated `{ i64, T }` struct.

```zig
// Register constructors with tags
try self.constructor_tags.put("True", .{ .type_name = "Bool", .tag = 0 });
try self.constructor_tags.put("False", .{ .type_name = "Bool", .tag = 1 });

// Constructor as value (no args) → return tag
const tag_val = core.LLVMConstInt(i64_type, @bitCast(info.tag), 0);

// Constructor with args (single) → allocate tagged struct
const tagged_type = core.LLVMStructTypeInContext(ctx, &.{i64_type, arg_type}, 2, 0);
const alloc = core.LLVMBuildAlloca(builder, tagged_type, "tagged");
// Store tag at index 0, value at index 1 via GEP
// Return pointer as i64 via LLVMBuildPtrToInt
```

### Pattern Matching Codegen

Match expressions use a chain of comparison blocks with conditional branches and a phi node to merge results.

```zig
// 1. Create cmp blocks, body blocks, merge_bb, unreachable_bb
// 2. Branch from entry to first cmp block
// 3. In each cmp block: compare tag, condBr to body or next_cmp/unreachable
// 4. In each body block: codegen arm body, br to merge
// 5. In merge: phi merges all arm results
```

#### Key pattern
```
entry → cmp[0] → (eq? → arm[0], ne? → cmp[1])
       cmp[1] → (eq? → arm[1], ne? → unreachable)
       arm[0] → merge
       arm[1] → merge
       merge  → phi(arm[0], arm[1])
```

#### Gotcha: Create unreachable_bb before the entry branch
If you create unreachable after the comparison chain, the `br` to the first cmp block gets built in the wrong block.

### Partial Application (Currying)

Multi-param functions support partial application: `add 1` on a 2-arity `add` returns a closure.

#### Representation
- Function values are `i64`. Bit 0 is a tag:
  - bit 0 = 0: raw function pointer (aligned, so bit is always 0)
  - bit 0 = 1: partial application closure pointer
- Closure struct (heap-allocated): `{ fn_ptr, total_arity, applied_count, applied_args[] }`
  - offset 0: fn_ptr (pointer to wrapper function)
  - offset 8: total_arity (total args needed)
  - offset 16: applied_count (args already applied)
  - offset 24+: applied_args (the pre-applied values)

#### How it works
1. When a global function is called with fewer args than its arity, `createPartialApp` is called
2. A wrapper function is generated: loads applied args from closure, calls original function with all args
3. Closure struct is allocated on heap, returned as i64 with bit 0 set
4. When the closure is called, bit 0 is detected, closure is unpacked, wrapper is called

#### Gotcha: Only global functions support partial application
Multi-param lambdas (`\x y -> ...`) do NOT get partial application in the current implementation. Only top-level `fn` definitions do. The indirect call path doesn't check arity for lambdas.

#### Gotcha: `LLVMAddIncoming` requires `LLVMBasicBlockRef` (not `LLVMIBasicBlockRef`)
The phi node incoming blocks use `types.LLVMBasicBlockRef`.

### Reference Counting (Memory Management)

Kō uses reference counting for heap-allocated objects. The runtime provides `ko_alloc`, `ko_incref`, and `ko_decref` functions.

#### Memory layout
```
[ i64 rc ][ ... user data ... ]
^         ^
|         pointer returned by ko_alloc (what codegen sees)
raw malloc ptr
```

#### Runtime functions (in `stdlib.zig`)
- `ko_alloc(user_size)` — allocate with RC header (rc=1), return pointer to user data
- `ko_incref(ptr)` — increment RC, return ptr
- `ko_decref(ptr)` — decrement RC, free if rc<=0

#### Codegen integration
- All heap allocations use `ko_alloc` instead of raw `malloc`
- `scope_heap_values` tracks all heap-allocated **i64 (ptrtoint)** values per function
- **Ownership-based decref**: Track "consumed" heap values; at exit only decref unconsumed values
- `heap_allocas` map: conditional allocations get allocas in the entry block (initialized to 0)
- `consumed_heap_values` set: heap values stored in parents (constructor/tuple/record/closure)
- `emitIncref`: called when heap values are stored in parents (shared ownership)
- `markConsumed`: called alongside emitIncref to skip the parent's reference at function exit

#### Critical: scope_heap_values stores ptrtoint, NOT raw ptr

`trackHeapAlloc` MUST store the `ptrtoint` result (i64), NOT the raw pointer from `ko_alloc` (ptr type). This is because:
1. `codegenExpr` for constructors/tuples/records returns `ptrtoint(raw_ptr)` (i64)
2. The consumption check compares `scope_heap_values` items against these i64 values
3. If scope_heap_values stores raw ptr, the comparison fails (different LLVM SSA types) → markConsumed never matches → double-free

```zig
// CORRECT:
const raw_ptr = call ko_alloc(...);
const result = LLVMBuildPtrToInt(raw_ptr);
self.trackHeapAlloc(result);  // stores i64
return result;

// WRONG — causes markConsumed to never match:
self.trackHeapAlloc(raw_ptr);  // stores ptr
return LLVMBuildPtrToInt(raw_ptr);
```

#### Critical: emitIncref at all consumption sites

When a heap value is stored in a parent structure (constructor, tuple, record, closure), the parent takes shared ownership. The function still owns its reference. So:
1. Call `emitIncref(heap_val)` to increment rc (parent takes its reference)
2. Call `markConsumed(heap_val)` to skip the function's reference at exit

Without emitIncref, the parent only has a borrowed reference → use-after-free when the function exits.

Sites requiring emitIncref + markConsumed:
- Constructor args (single-arg and multi-arg)
- Tuple elements
- Record fields
- Closure captures (partial app and lambda)

#### Critical: exclude return value from decref

The decref loop at function exit MUST skip the return value. The caller takes ownership of the return value — decrefing it causes use-after-free.

For unconditional allocations: Zig-level comparison `heap_val == body_val`.
For conditional allocations (alloca-tracked): LLVM-level runtime check `loaded != body_val` via select pattern.

#### Gotcha: Allocas must be before the entry block terminator
When creating allocas for conditional allocations, you MUST position the builder BEFORE the first instruction in the entry block, not at the end. After `codegenIf` emits a branch, positioning at the end places allocas AFTER the terminator (unreachable code). Use `LLVMPositionBuilder(builder, entry, first_inst)` to insert before the first instruction.

#### Gotcha: emitDecrefAll must use select for conditional values
Creating new basic blocks for decref null-checks causes control flow issues. Use `LLVMVMBuildSelect` instead: load from alloca, check if non-null, select between real pointer and null. This avoids creating new blocks and keeps the decref inline.

#### Gotcha: Zig 0.17 ArrayList API
In Zig 0.17, `std.ArrayList(T)` uses `.empty` default init and takes allocator on each call:
```zig
var list: std.ArrayList(T) = .empty;
defer list.deinit(allocator);
try list.append(allocator, item);
```

### AOT Compilation (Object File Emission)

The `Aot` struct in `codegen.zig` wraps LLVM's target machine API for object file emission.

#### Setup flow
```zig
// 1. Get default target triple
const triple = target_machine.LLVMGetDefaultTargetTriple();

// 2. Get target from triple
var t: types.LLVMTargetRef = undefined;
target_machine.LLVMGetTargetFromTriple(triple, &t, &error_msg);

// 3. Create target machine
const tm = target_machine.LLVMCreateTargetMachine(
    t, triple, "x86-64", "",
    .LLVMCodeGenLevelDefault,
    .LLVMRelocPIC,
    .LLVMCodeModelDefault,
);

// 4. Create data layout and set on module
const dl = target_machine.LLVMCreateTargetDataLayout(tm);
target.LLVMSetModuleDataLayout(mod, dl);

// 5. Emit object file
target_machine.LLVMTargetMachineEmitToFile(tm, mod, "out.o", .LLVMObjectFile, &err);
```

#### Linking
The CLI links object files with `ld` using CRT startup files (`crt1.o`, `crti.o`, `crtn.o`), libc, and libm. GCC's LTO configuration can interfere — use `ld` directly.

#### CLI usage
```bash
ko --emit-obj out.o file.ko    # Emit object file only
ko --emit-exe out file.ko      # Emit object file + link to executable
```

#### Key enums
- `LLVMCodeGenFileType`: `.LLVMObjectFile` (`.o`) or `.LLVMAssemblyFile` (`.s`)
- `LLVMRelocMode`: `.LLVMRelocPIC` for Linux userspace
- `LLVMCodeModel`: `.LLVMCodeModelDefault` or `.LLVMCodeModelSmall`
- `LLVMCodeGenOptLevel`: `.LLVMCodeGenLevelDefault`

## Learning Resources

- Zig Documentation: <https://ziglang.org/documentation/>
- Zig Standard Library: /home/bernard/.local/share/zig/lib/std/
- Zig Source Code: /home/bernard/.local/share/zig/lib/

## LSP Server (`src/lsp.zig`)

### Architecture
- Separate binary `ko-lsp` — no LLVM dependency (imports parser + typechecker only)
- JSON-RPC over stdio (LSP standard)
- Document store with parse/typecheck on open/change
- Provides: hover, completion, definition, document symbols, diagnostics

### Type Pretty-Printing for Hover
- `typecheck_mod.typeToString(alloc, type)` converts `Type` to human-readable string
- Follows `variable.instance` chain to resolve type variables to concrete types
- Handles: `Int`, `Float`, `Bool`, `String`, `Char`, `()`, arrows, tuples, constructors, records, refs
- Arrow types auto-parenthesize: `(Int -> Int) -> Int`
- Polymorphic type variables show friendly names (a, b, c) based on quantified list position
- **Parenthesization fix**: Check resolved type (via `variable.instance`) not raw type tag for parenthesization decisions

### I/O Pattern — Raw Syscalls (NOT std.Io)

**Critical: `std.Io` does NOT work with subprocess pipes.** The `Io.File.stdin().readerStreaming(io, &buffer)` approach fails because `Io.File.Reader` uses `sendFile` for streaming which returns 0 on pipes, and the `Io.Reader` interface doesn't properly delegate to the file for pipe reads.

**Solution: Use raw syscalls directly.** For reads, use `std.posix.read()` (cross-platform). For writes, use a `comptime` conditional to switch between `linux.write` (Linux) and `std.c.write` (macOS/other).

```zig
const linux = std.os.linux;

fn rawRead(fd: i32, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (rc < 0) {
        const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
        return switch (e) {
            .INTR => rawRead(fd, buf),  // retry on interrupt
            else => error.ReadFailed,
        };
    }
    if (rc == 0) return error.EndOfStream;
    return @intCast(rc);
}

fn writeAll(fd: i32, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const rc = if (comptime @import("builtin").os.tag == .linux)
            linux.write(fd, data[pos..].ptr, data.len - pos)
        else
            std.c.write(fd, data[pos..].ptr, data.len - pos);
        if (rc < 0) {
            const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
            switch (e) {
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
        pos += @intCast(rc);
    }
}
```

### LSP Header Parsing

```zig
fn readLine(fd: i32, line_buf: []u8) ![]const u8 {
    var line_len: usize = 0;
    while (line_len < line_buf.len) {
        const n = rawRead(fd, line_buf[line_len .. line_len + 1]) catch |err| {
            if (err == error.EndOfStream) return error.ConnectionClosed;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        if (line_buf[line_len] == '\n') break;  // DON'T increment line_len
        line_len += n;
    }
    // Strip trailing \r if present
    const end = if (line_len > 0 and line_buf[line_len - 1] == '\r') line_len - 1 else line_len;
    return line_buf[0..end];
}
```

**Gotcha: Don't increment `line_len` when breaking on `\n`.** The original code did `line_len += 1; break;` which included the `\n` in the returned line, causing empty lines (`\r\n`) to be returned as `"\r\n"` instead of `""`.

### Main Function

Use `std.process.Init.Minimal` (not `std.process.Init`) to avoid the `Io` layer:

```zig
pub fn main(_: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // ... use raw Linux syscalls for I/O
}
```

### Building
```bash
zig build          # Build all (ko + ko-lsp)
zig build lsp      # Build + run ko-lsp (requires piped input)
```

### VS Code Integration
- Extension in `vscode-ko/` (v0.5.0)
- Extension provides: TextMate grammar, LSP client via `vscode-languageclient`
- LSP server launched as `ko-lsp` subprocess

## REPL (`src/repl.zig`)

### Architecture
- Separate binary `ko --repl` — uses parser + typechecker + codegen (requires LLVM)
- Raw Linux syscalls for I/O (same pattern as LSP)
- Accumulates definitions across iterations; expressions are evaluated fresh each time
- Each expression is wrapped in a unique function: `fn __repl_eval_N =\n  expr\n`

### Expression Wrapping
Expressions are wrapped in `fn __repl_eval_N =\n  expr\n` (indented body). This is critical — a non-indented body like `fn __repl_eval_N = expr\n` causes `parse_block` to consume the next line as part of the function body, breaking multi-line workflows.

### Definition Detection
`isDefinition()` checks for:
- Keywords: `fn`, `type`, `let`, `module`, `pub`, `import`, `package`
- `=` at parenthesis depth 0 (catches `name = expr` patterns)

### Gotcha: `let` bindings at top level aren't codegen'd
`codegenProgram` only handles `fn_def` and `type_def` in its second pass. `let_binding` falls through to `else`. For the REPL, all definitions must use `fn`.

### Gotcha: `LLVMGetFunctionAddress` needs null-terminated names
`eval_name` must be null-terminated. Use `allocator.dupeZ(u8, slice)` to convert.

### Gotcha: REPL type lookup must walk blocks
The eval function body is `fn __repl_eval_N =\n  expr\n`. The parser creates a block wrapping the expression. `fd.body` is the block, not the expression. Type lookup must walk down blocks to find the innermost expression:
```zig
var inner = fd.body;
while (true) {
    switch (inner.*) {
        .block => |items| {
            if (items.len > 0) { inner = items[items.len - 1]; continue; }
        },
        else => {},
    }
    break;
}
result_type = inferer.expr_types.get(inner);
```

### Gotcha: REPL must look at LAST definition
`prog.definitions[0]` is the FIRST accumulated definition, not the eval function. Use `prog.definitions[prog.definitions.len - 1]` to find the eval function.

### Gotcha: `std.ArrayList(u8).empty` is unmanaged
In Zig 0.17, `std.ArrayList(u8).empty` creates an unmanaged list. Use `allocator` parameter on each call (e.g., `list.append(allocator, item)`). Use `std.ArrayList(u8).init(allocator)` for managed version with `.writer()`.

### Gotcha: `readLine` with raw Linux syscalls
The `readLine` function reads one byte at a time from stdin via `linux.read()`. The Zig `and` operator may NOT short-circuit bounds checks in all cases — use explicit `while` loops instead of `if (x > 0 and arr[x - 1] == ...)`. The pattern:
```zig
while (line_len > 0) {
    const last = line_buf[line_len - 1];
    if (last == '\n' or last == '\r') { line_len -= 1; } else { break; }
}
```

### Pretty-printing REPL results (`src/prettyprint.zig`)
- `inspectValue(alloc, val, ty, ctor_tag_names)` produces human-readable output for REPL results
- Handles: int, float, bool, char, string, unit, arrow (`<fn>`), tuple, con (constructors), record
- **Float literals must be bitcast to i64** before returning from functions: `LLVMConstBitCast(double_val, i64_type)`
- **Constructor name resolution**: `ctor_tag_names` map (type_name → {tag → ctor_name}) maps runtime tags to constructor names for display
- **Zero-arg constructors**: value IS the tag (not boxed). Heuristic: `val < 4096` → tag, `val > 4096 and aligned` → pointer
- **Multi-arg constructors**: value is heap pointer, tag at `ptr[0]`, args at `ptr[1..]`
- **Safety check**: if tag at `ptr[0]` > 255, it's likely a function pointer → show `<fn>`

### Gotcha: Zero-arg constructor boxing
When a zero-arg constructor (like `Nil`) is used as an **argument** to another constructor, it's boxed into a heap-allocated `{i64}` struct via `boxZeroArgCtor`. When used as a **value** (standalone), it returns the raw tag. This asymmetry exists because:
- Raw tags can't be dereferenced (they're small integers)
- Boxed values need heap allocation for consistent pointer semantics
- Pattern matching codegen needs to dereference constructor args

### Gotcha: `?` operator GEP element type
The `?` (try) operator accesses the Result struct `{ i64, i64 }` via GEP. The GEP element type **must** be the struct type, not `i64_type`. Using `i64_type` with 2 indices is invalid because `i64` is not an aggregate type. The working pattern:
```zig
const result_struct = core.LLVMStructTypeInContext(self.context, &result_struct_fields, 2, 0);
var tag_gep_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 0, 0) };
const tag_ptr = core.LLVMBuildGEP2(self.builder, result_struct, result_ptr, @ptrCast(&tag_gep_args), 2, "tag_ptr");
```
This matches the pattern used by `codegenConstructorFn` and inline constructor codegen. All GEP2 calls accessing struct fields through a pointer must use the struct type as the element type.

### Gotcha: `?` operator precedence
`?` is postfix and binds tighter than function application. `f x?` parses as `f (x?)`, not `(f x)?`. Use parentheses: `(f x)?`.

### Gotcha: Result operations as built-ins (not .ko files)
Result operations (`Result.is_ok`, `Result.map`, etc.) are built-in functions, not importable from a `.ko` file. This is because the imported module typechecker creates a fresh `Inferer` whose `deinit` frees types that the main inferer still references (dangling pointers). Any `.ko` file that uses built-in constructors (`Ok`, `Err`) in imported modules crashes during typechecking.

### Gotcha: Multi-line match body parser limitation
A multi-line `match` expression followed by another expression can cause the next expression to be swallowed by the parser's `parse_postfix` as a match arm argument. Workaround: extract the match into a helper function, or use single-line match arms.

### Gotcha: Constructor-as-value (first-class constructors)
Constructors can be used as function values (e.g., `foldr Cons ys xs`). The representation depends on arity:
- **Zero-arity constructors** (e.g., `Nil`): return raw tag when used as values. They are data, not functions.
- **Multi-arity constructors** (e.g., `Cons`): return wrapper function pointer when used as values. They are callable.

**How it works:**
1. `registerTypeDef` generates wrapper functions for each constructor (stored in `constructor_fns` map)
2. `codegenExpr` for `.constructor`: arity > 0 → ptrtoint of wrapper; arity == 0 → raw tag
3. `codegenFnCall` for constructor calls (e.g., `Cons 1 Nil`): constructs boxed value directly (unchanged)
4. When a multi-arity constructor is passed as an argument (e.g., `foldr Cons ys xs`), it's a function pointer
5. The indirect call path (bit 0 check) detects it's a raw function pointer (bit 0 = 0) and calls via inttoptr

**Wrapper function layout:**
- Zero-arg: `fn Nil() -> i64` returns raw tag
- Multi-arg: `fn Cons(i64, i64) -> i64` allocates tagged struct via ko_alloc, stores tag + args, returns ptr as i64

**Gotcha: Don't change zero-arg constructors to return function pointers**
If zero-arg constructors return function pointers, pattern matching breaks because the match codegen compares values < 4096 as raw tags. A function pointer (e.g., 0x7fff12345678) would be treated as a boxed pointer and dereferenced, causing a crash.

### Gotcha: Auto-return 0 from `main`
`codegenFn` for `main` checks if the body is a "value" expression (literal, binary_op, unary_op, if/else, fn_call, lambda, tuple, record, field_access, match, let, block, ref, assign). If not, auto-returns 0. This prevents undefined behavior from missing return statements.

### REPL Commands
- `:quit`, `:q` — exit
- `:type <expr>` — show type (uses `fn __type_query _ =\n  expr\n`)
- `:env` — show accumulated definitions
- `:reset` — clear accumulated source
- `:help`, `:h` — show help

### Stack Overflow Detection

Kō detects stack overflow at runtime and aborts with a clear error message instead of segfaulting.

**How it works:**
1. `ko_init_stack()` is called at the start of `main()` — captures the stack base address using `__builtin_frame_address(0)`
2. `ko_check_stack()` is called at the entry of every other function — compares current frame address against base + 8MB limit
3. If distance > limit, writes error to stderr and calls `std.c.abort()`

**Stack limit:** 8MB default. For AOT programs, override with `KO_STACK_LIMIT=N` environment variable (in bytes).

**JIT vs AOT:**
- JIT: Stack check functions are mapped to Zig wrapper functions via `LLVMAddGlobalMapping`
- AOT: Stack check functions are in `ko_runtime.c` (compiled by gcc at link time)

**Gotcha: `@frameAddress()` in JIT mode**
In Zig's JIT context, `@frameAddress()` returns the frame pointer. The stack check works because each recursive call adds a frame, increasing the distance from the base.

**Gotcha: TCO bypasses stack check**
Tail-call optimized functions (detected in `codegenFn`) don't add stack frames, so they don't trigger overflow. This is correct behavior — TCO converts recursion to iteration.

**Gotcha: Lambda stack check**
Lambda functions also get stack checks at entry, since they can be called recursively.

**Testing:**
- `sum_to 1000000` (non-tail-recursive) → triggers stack overflow
- `countdown 1000000` (tail-recursive with TCO) → works fine
- `fib 40` (tree recursion, ~40 frames deep) → works fine

## Compile-Time Evaluation (`src/comptime.zig`)

### Architecture
- `ComptimeValue` union: `int`, `float`, `bool`, `char`, `string`, `unit`, `list`, `tuple`, `constructor`
- `CompileTimeWorld` struct with hash maps for functions, constructors, values
- `evalExpr()` recursive evaluator supporting:
  - Literals: int, float, bool, char, string
  - Binary/unary ops (all arithmetic, comparisons, logical, cons `::`)
  - If-then-else expressions
  - Let bindings (with value save/restore)
  - Function calls (comptime fns + constructor-as-function + builtins)
  - Blocks, recursion (max depth 10,000)
  - **Match expressions** with constructor and identifier patterns
  - **Constructor expressions** (zero-arg constructors)
  - **Tuple expressions**
- `matchPattern()` pattern matching: wildcard, identifier binding, literal comparison, constructor matching with recursive arg matching
- `evalBuiltinFn()` built-in comptime operations:
  - String: `String.length`, `String.append`, `String.charAt`, `String.substring`, `String.startsWith`, `String.endsWith`
  - List: `List.cons`, `List.head`, `List.tail`, `List.length`, `List.reverse`, `List.append`
  - Int: `Int.toString`
  - Constructor-as-function: any registered constructor with correct arity

### Integration in codegen
- `comptime_world` field on `Codegen` struct
- Pass 1: populate comptime world with comptime functions + constructor info
- `codegenExpr` for `.comptime_expr`: try comptime eval, **only splice scalar results** (int/float/bool/char/string/unit). Complex values (list/tuple/constructor) fall back to runtime
- `codegenFnCall`: intercept calls to comptime functions with all-literal args; same splicing rules
- `comptimeValueToLlvm`: convert `ComptimeValue` to LLVM constants (constructors return tag only)
- **Field-access calls** (e.g., `String.length s`) resolved as `"String.length"` for comptime lookup

### Parser: `comptime` keyword
- `comptime fn name ...` — defines a comptime function (sets `FnDef.is_comptime = true`)
- `comptime expr` — marks an expression for compile-time evaluation
- `keyword_comptime` is in `top_level_stops` so `comptime fn` inside function bodies terminates the block (hoisted to top level)

### Gotcha: Comptime functions are also regular functions
Comptime functions must be declared AND codegen'd as regular LLVM functions. The comptime optimization is an EXTRA optimization on top of normal function support. Without the LLVM declaration, runtime fallback calls (`abs n` where `n` is runtime) fail with `UndefinedVariable`.

### Gotcha: `println` output during JIT
During JIT, `println` output goes to stdout. If a comptime expression calls `println`, the output happens at JIT time, not runtime. Comptime evaluators should NOT have side effects — they should only return values.

### Gotcha: Multi-line `if`/`else` in comptime fn bodies
The `if` expression's `else` branch must be on the same line or indented. A bare `else` on a new line after `then ...` may cause the block parser to split the definition. Test with single-line bodies first.

### Gotcha: Complex comptime results can't be spliced to LLVM
Comptime expressions that return lists, tuples, or constructors produce `ComptimeValue` types that have no direct LLVM representation. The codegen falls back to runtime evaluation for these. To chain comptime computations that produce complex values, compose them in a single comptime function (e.g., `comptime fn rev_sum lst = comptime_sum (comptime_reverse lst)`), not through runtime `let` bindings.

### Gotcha: Comptime expressions are independent
Each `comptime expr` evaluates in its own `CompileTimeWorld`. Intermediate values from one comptime expression are NOT available to subsequent comptime expressions through runtime `let` bindings. The comptime evaluator only sees values stored in its own `values` map.

### Gotcha: Field-access constructor names
`String.length s` is parsed as `field_access(constructor("String"), "length")`. The comptime evaluator resolves this as `"String.length"` for builtin lookup. Capital-letter module names (e.g., `Int`, `String`) are parsed as constructors, not identifiers.
