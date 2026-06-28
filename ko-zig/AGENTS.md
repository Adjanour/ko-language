# AGENTS.md - Zig Development Patterns for Kō Compiler

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

# Run tests
zig build test

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
│   ├── ko_runtime.c   # C runtime for built-in functions (println, print)
│   ├── llvm/          # kassane/llvm-zig bindings source
│   ├── tests.zig      # All tests (71 tests)
│   └── tests_ko/      # .ko test programs (40 files)
│       ├── 01_literal.ko .. 40_minimal.ko
├── std/               # Kō stdlib (written in Kō)
└── tests/             # (unused, test .ko files are in src/tests_ko/)
```

### Module Dependencies

```
main.zig → parser.zig → lexer.zig
                       → ast.zig
         → typecheck.zig → parser.zig (re-exports ast types)
         → codegen.zig → parser.zig, typecheck.zig
                       → llvm/ (kassane/llvm-zig bindings)
```

- `ast.zig` is the single source of truth for all AST types
- `parser.zig` re-exports ast types for backward compatibility
- `typecheck.zig` imports parser types (which are re-exports from ast.zig)
- `codegen.zig` uses kassane/llvm-zig bindings (source in `src/llvm/`)

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

- Type: `Int -> Int` (returns 0 after printing)
- JIT: mapped to native C functions via `LLVMAddGlobalMapping`
- AOT: implemented in `src/ko_runtime.c`, compiled at link time with `/usr/bin/gcc -c`

#### Key pattern for built-in functions
```zig
// In typechecker: register in inferProgram
try self.global.set("println", .{ .quantified = &.{}, .body = int_to_int });

// In codegen: declare with LLVMAddFunction
const println_type = core.LLVMFunctionType(i64_type, &param_i64, 1, 0);
const println_fn = core.LLVMAddFunction(self.module, "println", println_type);

// In JIT: map to native function
engine.LLVMAddGlobalMapping(jit_engine, println_fn, @constCast(@ptrCast(&builtin_println)));
```

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

#### Runtime functions (in `ko_runtime.c`)
- `ko_alloc(user_size)` — allocate with RC header (rc=1), return pointer to user data
- `ko_incref(ptr)` — increment RC, return ptr
- `ko_decref(ptr)` — decrement RC, free if rc<=0

#### Codegen integration
- All heap allocations use `ko_alloc` instead of raw `malloc`
- `scope_heap_values` tracks all heap-allocated ptrs per function
- Before function return, `ko_decref` is called on all tracked values except the return value
- Return value detection: if body is `ptrtoint`, skip the underlying ptr

#### Gotcha: Only function-level decref
Currently only decref at function return is implemented. Intermediate variable reassignment, closure captures, and loop-scoped values are NOT decref'd. This means:
- Programs that return heap-allocated values: no leak (return value is skipped)
- Programs that allocate and discard (e.g., `let _ = (1,2,3)`): still leaks
- Closures capturing variables: captured values are not decref'd

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
- Polymorphic type variables show internal names (e.g., `ret8`) — improvement opportunity

### I/O Pattern — Raw Linux Syscalls (NOT std.Io)

**Critical: `std.Io` does NOT work with subprocess pipes.** The `Io.File.stdin().readerStreaming(io, &buffer)` approach fails because `Io.File.Reader` uses `sendFile` for streaming which returns 0 on pipes, and the `Io.Reader` interface doesn't properly delegate to the file for pipe reads.

**Solution: Use raw `std.os.linux` syscalls directly.** This bypasses the entire `std.Io` layer.

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
        const rc = linux.write(fd, data[pos..].ptr, data.len - pos);
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
