# Kō Language Roadmap

> **Version:** 0.2.0-alpha  
> **Date:** 2026-07-12  
> **Status:** Alpha Release

---

## Executive Summary

This document outlines the development of Kō from a Python prototype to a production-ready language with a Zig compiler and LLVM backend.

**Current state (v0.2.0-alpha):** Zig compiler with HM type inference, LLVM IR codegen, JIT/AOT compilation, reference counting, partial application, file-based module imports, `?` operator for error propagation, LSP server, REPL with pretty-printing, Result operations, and 78 passing tests.

---

### Known Limitations (v0.2.0-alpha)

- **LLVM 22 optimization broken:** AOT compilation uses `LLVMCodeGenLevelNone`. `LLVMTargetMachineEmitToMemoryBuffer` hangs and `LLVMRunPasses` crashes with any optimization pass. Root cause: `CodeGenPrepare` infinite loop with bitcast+phi patterns. Fix expected in LLVM 23 ([PR #186468](https://github.com/llvm/llvm-project/pull/186468)).
- **2 examples fail:** `expr_eval.ko` and `higher_order.ko` fail due to blank-line scoping in tokenizer `scan_indent`.
- **1 example hangs:** `list_ops.ko` hangs due to pre-existing `reverse_aux` codegen bug.
- **Windows not supported:** LLVM 22 has no prebuilt Windows packages; MCJIT doesn't support Windows.
- **Multi-line closures with free variables** cause LLVM codegen errors.

---

## Part 1: Language Feature Roadmap

### 1.1 Current State (v0.2.0-alpha)

**Zig Compiler (complete):**

- Lexer (~872 lines) — all token types, indentation tracking, comment tokens, `::` for cons
- Parser (~1316 lines) — full grammar implementation, multi-line lambdas, block doc comments, `comptime fn`/`comptime expr`, `?` operator
- Typechecker (~1495 lines) — Hindley-Milner inference, let-polymorphism, polymorphic println/print, `?` operator type checking, Result type propagation
- Codegen (~3039 lines) — LLVM IR via kassane/llvm-zig bindings
  - JIT execution (MCJIT) and AOT compilation
  - Sum types, records, tuples, lambdas, pattern matching
  - Built-in polymorphic functions (println, print, inspect)
  - Reference counting for heap-allocated objects
  - Partial application (currying)
  - Module definitions with pub visibility
  - `::` infix operator for list construction
  - Compile-time evaluation (`comptime.zig`) — literals, arithmetic, recursive fn calls, if-then-else, pattern matching, constructors, tuples, string/list builtins
  - `?` operator codegen (unwraps Ok values, propagates Err)
  - Result operations as built-in functions (map, unwrap, fold, is_ok, is_err, and_then)
  - File-based module imports with selective import support
- Pretty-printer (`prettyprint.zig`) — type-directed value display for REPL/results
- LSP server (`lsp.zig`) — hover, completion, diagnostics, documentSymbol, go-to-definition
- REPL (`repl.zig`) — expression evaluation, definition binding, multi-line input, commands
- VS Code extension (v0.5.0) with LSP client
- Tree-sitter grammar (~450 lines) with nvim integration
- 78 tests passing, 53 .ko test programs, 12 examples

### 1.2 Next Milestones

#### v0.3.0 — Language Maturity

**A. Staged Compilation & AST Construction**

Design documents written:
- `DESIGN-staged-compilation.md` — `stage expr` for compile-time code generation
- `DESIGN-ast-construction.md` — `code expr` for AST construction helpers

**B. Type System Enhancements**

- Record type syntax: `type Point = { x: Int, y: Int }` with field access on values
- Pattern matching on records in match arms
- Named/struct parameters for constructors
- Better error messages with source locations

**B. Generics v1 (Monomorphization)**

```ko
type List[T] = Cons(T, List[T]) | Nil

fn map[T, U] xs f =
  match xs
    Cons h t -> Cons (f h) (map t f)
    Nil -> Nil

let doubled = map [1, 2, 3] (\x -> x * 2)
```

**C. Module System v2**

- Hierarchical imports: `import std.collections.list`
- First-class modules (modules as values)
- Compile-time module instantiation
- Import hooks (programmable resolution)

**D. Trait/Typeclass System**

```ko
trait Printable {
  fn to_string: Self -> String
}

impl Printable for User {
  fn to_string user = concat user.name " user"
}

fn print[T: Printable] item =
  println (T.to_string item)
```

#### v0.4.0 — Standard Library & Tooling

- Comprehensive standard library (collections, I/O, math, string)
- Package manager
- Build system integration
- Debugger support

#### v0.5.0 — Polish & Release

- Performance optimization
- Documentation
- Examples and tutorials
- Security audit
- v1.0.0 release

### 1.3 Feature Priority Matrix

| Feature | Impact | Effort | Status |
|---------|--------|--------|--------|
| Result type + `?` operator | High | Medium | Done |
| File-based module imports | High | High | Done |
| Stack overflow detection | High | Medium | Done |
| Comptime evaluation | Medium | Medium | Done |
| Result built-in operations | Medium | Low | Done |
| LLVM optimization (AOT -O2) | Medium | Low | Blocked (LLVM 22 bug) |
| Staged compilation (`stage expr`) | High | High | Design |
| AST construction helpers (`code expr`) | High | High | Design |
| Record type syntax | High | Medium | Planned |
| Generics | High | High | Planned |
| Traits/typeclasses | High | High | Planned |
| Module system v2 | High | High | Planned |
| Named parameters | Medium | Low | Planned |

---

## Part 2: Innovative Module System Design

### 2.1 Research Insights (2025-2026)

From recent research and production systems:

**Content-Addressed Identity (Janus)**

- Module identity is BLAKE3 hash of canonical AST, not filesystem path
- Moving a file doesn't change its identity
- Enables reproducible builds and caching

**Modules as Structs (Zig)**

- `@import("file.zig")` turns entire file into a struct
- Types double as namespaces
- No separate "module" concept

**Import Hooks (JavaScript TC39)**

- Programmable import resolution
- Can mock, deny, or transform imports
- Enables testing and sandboxing

**Modular Explicits (OCaml Research)**

- Functions can take modules as arguments
- Enables typeclasses without core language changes
- Compatible with existing module system

**Sandboxed Modules (Warble)**

- Modules sandboxed by default
- Explicit allow-list for external interactions
- Security by default

### 2.2 Current Implementation (v0.2.0-alpha)

File-based imports are working:

```ko
import std.Math.{abs, max, min}   # selective import
import std.Math                     # full module import
import std.List                     # import entire module
```

- `module_loader.zig` resolves paths relative to the source file and stdlib
- Typechecker creates fresh `Inferer` per imported module, registers functions/constructors with both qualified and unqualified names
- Codegen generates LLVM IR for imported functions in the same module
- No circular import detection yet
- No package system or hierarchical namespaces yet

### 2.3 Future Design (v0.3.0+)

#### Core Principles

1. **Content-addressed identity** (like Git, not filesystem paths)
2. **Programmable resolution** (import hooks)
3. **Sandboxed by default** (explicit permissions)
4. **First-class modules** (can be passed as arguments)
5. **Hierarchical namespaces** (dot-separated paths)

#### Syntax Design

**Basic Import**

```ko
# Simple import (module becomes namespace)
import std.math

# Use with namespace
let x = std.math.sin(1.0)

# Aliased import
import std.math as m
let x = m.sin(1.0)

# Selective import
import std.math.{sin, cos, PI}
let x = sin(1.0)

# Aliased selective
import std.math.{sin as trig_sin, cos as trig_cos}
```

**Module Definition**

```ko
# math.ko
package std.math

pub PI = 3.14159265358979

pub fn sin x = ...
pub fn cos x = ...
fn internal_helper = ...  # private
```

**Visibility**

```ko
# Everything public by default in package root
pub fn public_fn = ...
fn private_fn = ...  # package-private

# Explicit public/private
pub type PublicType = ...
type PrivateType = ...

pub trait PublicTrait = ...
trait PrivateTrait = ...
```

**Module Scoping**

```ko
module MyModule {
  type Internal = ...
  
  pub fn public_api = 
    # can access Internal here
    let x = Internal(...)
    x
}
```

**First-Class Modules**

```ko
# Module as argument
trait Comparable {
  type T
  fn compare: T -> T -> Int
}

# Module as value
module IntCompare = {
  type T = Int
  fn compare a b = a - b
}

# Pass module as argument
let result = sort [3, 1, 2] IntCompare

# Or with module syntax
let result = sort [3, 1, 2] {
  type T = Int
  fn compare a b = a - b
}
```

**Compile-Time Module Instantiation**

```ko
# Generic module
module Pair(T) {
  type Pair = (T, T)
  
  fn make a b = (a, b)
  fn fst p = p.0
  fn snd p = p.1
}

# Instantiate at compile time
import Pair(Int) as IntPair
import Pair(String) as StringPair

let p = IntPair.make 1 2
let q = IntPair.make "a" "b"
```

**Module Interfaces (Signatures)**

```ko
# Trait as interface
trait Iterable {
  type Item
  fn next: Iterator -> Maybe(Iterator.Item)
  fn fold: (Iterator, (acc: T, Item) -> T, T) -> T
}

# Module must satisfy interface
module ListIterator(T) : Iterable {
  type Item = T
  fn next iter = ...
  fn fold iter f acc = ...
}
```

**Import Hooks (Programmable Resolution)**

```ko
# Define import hook
fn my_import_hook request =
  match request.path
    "std/*" -> resolve_from_stdlib request
    "local/*" -> resolve_from_project request
    _ -> Err "unknown module"

# Use hook
with import_hook = my_import_hook
import std.math
```

**Sandboxed Modules**

```ko
# Module with explicit permissions
module NetworkModule {
  # Declare permissions
  permissions = [Network, FileSystem]
  
  fn fetch url = ...  # can use network
  fn read_file path = ...  # can use filesystem
}

# Untrusted module (no permissions)
module UntrustedCode {
  # No permissions declared = sandboxed
  fn do_something = ...
  # fn evil = read_file "/etc/passwd"  # ERROR: no permission
}
```

**Content-Addressed Identity**

```ko
# Module identity is content hash
# Moving file doesn't change identity
# Changing function does change identity

# Import by content hash (for reproducibility)
import "abc123def456" as math

# Or by path (resolved to content hash)
import std.math  # resolved to BLAKE3 hash
```

### 2.3 Module Resolution Algorithm

```
1. Parse import statement
2. Check for import hook
   - If hook exists, delegate to hook
   - Else continue to default resolution
3. Resolve path
   - Absolute: "std/math" → stdlib path
   - Relative: "./foo" → relative to current file
   - Package: "math" → package search paths
4. Compute content hash (BLAKE3)
   - Hash canonical AST representation
   - Check cache for existing compilation
5. If cached, use cached version
6. Else, parse, typecheck, and compile module
7. Store in cache with content hash as key
```

### 2.4 Module System Implementation Phases

**Phase 1: Basic Hierarchical Imports**

- Dot-separated paths
- Package detection (package.ko or ko.toml)
- Basic visibility (pub/private)

**Phase 2: First-Class Modules**

- Modules as values
- Module arguments to functions
- Compile-time instantiation

**Phase 3: Import Hooks**

- Programmable resolution
- Mock modules for testing
- Sandboxing support

**Phase 4: Content-Addressed Identity**

- BLAKE3 hashing
- Reproducible builds
- Distributed caching

---

## Part 3: Zig Port Architecture

### 3.1 Why Zig?

**Advantages:**

- **Performance:** 100-1000x faster compilation than Python prototype
- **Memory safety:** No GC, explicit allocation
- **C interop:** Perfect for LLVM bindings
- **Self-hosting potential:** Compile Kō to Zig eventually
- **Cross-compilation:** Built-in support
- **Compile-time execution:** `comptime` for metaprogramming

### 3.2 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Kō Compiler (Zig)                      │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│  │  Lexer   │  │  Parser  │  │  Type    │  │  Module  │     │
│  │          │  │          │  │  Checker │  │  System  │     │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘     │
│       │              │              │              │        │
│       └──────────────┴──────────────┴──────────────┘        │
│                            │                                │
│                    ┌───────▼───────┐                        │
│                    │  AST / HIR    │                        │
│                    └───────┬───────┘                        │
│                            │                                │
│              ┌─────────────┼─────────────┐                  │
│              │             │             │                  │
│        ┌─────▼─────┐ ┌─────▼─────┐ ┌─────▼─────┐            │
│        │  LLVM IR  │ │  Zig IR   │ │  C IR     │            │
│        │  Codegen  │ │  Codegen  │ │  Codegen  │            │
│        └─────┬─────┘ └─────┬─────┘ └─────┬─────┘            │
│              │             │             │                  │
│              └─────────────┼─────────────┘                  │
│                            │                                │
│                    ┌───────▼───────┐                        │
│                    │   LLVM Pass   │                        │
│                    │   Optimization│                        │
│                    └───────┬───────┘                        │
│                            │                                │
│                    ┌───────▼───────┐                        │
│                    │   Object File │                        │
│                    └───────┬───────┘                        │
│                            │                                │
│                    ┌───────▼───────┐                        │
│                    │    Linker     │                        │
│                    │  (system ld)  │                        │
│                    └───────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 Component Design

#### Lexer (Zig)

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Token = struct {
    type: TokenType,
    loc: Location,
    value: []const u8,
};

pub const TokenType = enum {
    // Literals
    INT, FLOAT, STRING, CHAR, BOOL,
    // Identifiers
    IDENT, CONSTRUCTOR,
    // Keywords
    FN, LET, IF, THEN, ELSE, MATCH, TYPE, TRAIT,
    IMPORT, PACKAGE, PUB, MODULE,
    // Operators
    PLUS, MINUS, STAR, SLASH, PERCENT,
    EQ, NEQ, LT, GT, LEQ, GEQ,
    AND, OR, NOT,
    PIPE, PIPE_GT,
    ARROW, FAT_ARROW,
    // Delimiters
    LPAREN, RPAREN, LBRACKET, RBRACKET,
    LBRACE, RBRACE, COMMA, COLON, SEMICOLON,
    DOT, DOUBLE_DOT, UNDERSCORE,
    // Special
    NEWLINE, EOF, ERROR,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
            .allocator = allocator,
        };
    }

    pub fn next_token(self: *Lexer) !Token {
        // Skip whitespace
        // Handle newlines specially
        // Recognize tokens
        // Return token with location
    }
};
```

#### Parser (Zig)

```zig
pub const Parser = struct {
    lexer: *Lexer,
    allocator: Allocator,
    current: Token,

    pub fn init(allocator: Allocator, lexer: *Lexer) !Parser {
        return Parser{
            .lexer = lexer,
            .allocator = allocator,
            .current = try lexer.next_token(),
        };
    }

    pub fn parse_program(self: *Parser) !Program {
        var imports = std.ArrayList(Import).init(self.allocator);
        var defs = std.ArrayList(Definition).init(self.allocator);

        while (self.current.type != .EOF) {
            if (self.current.type == .IMPORT) {
                try imports.append(try self.parse_import());
            } else if (self.current.type == .FN) {
                try defs.append(.{ .fn_def = try self.parse_fn_def() });
            } else if (self.current.type == .TYPE) {
                try defs.append(.{ .type_def = try self.parse_type_def() });
            } else if (self.current.type == .MODULE) {
                try defs.append(.{ .module_def = try self.parse_module_def() });
            } else {
                return error.UnexpectedToken;
            }
        }

        return Program{
            .imports = imports.toOwnedSlice(),
            .definitions = defs.toOwnedSlice(),
        };
    }
};
```

#### Type Checker (Zig)

```zig
pub const TypeChecker = struct {
    allocator: Allocator,
    env: Environment,
    errors: std.ArrayList(TypeError),

    pub fn init(allocator: Allocator) TypeChecker {
        return TypeChecker{
            .allocator = allocator,
            .env = Environment.init(allocator),
            .errors = std.ArrayList(TypeError).init(allocator),
        };
    }

    pub fn check(self: *TypeChecker, program: *Program) !void {
        // Register built-in types
        // First pass: register type definitions
        // Second pass: infer function types
        // Third pass: check exhaustiveness
    }

    pub fn infer_expr(self: *TypeChecker, expr: *Expr) !Type {
        return switch (expr.*) {
            .int_literal => .int,
            .string_literal => .string,
            .identifier => |id| self.env.lookup(id),
            .binary_op => |op| self.infer_binary_op(op),
            // ... other cases
        };
    }
};
```

#### Module System (Zig)

```zig
pub const ModuleSystem = struct {
    allocator: Allocator,
    modules: std.StringHashMap(*Module),
    hooks: ?ImportHook,
    content_cache: std.HashMap([32]u8, *Module, ContentHashContext),

    pub const ImportHook = struct {
        resolve: *const fn ([]const u8) anyerror![]const u8,
    };

    pub fn init(allocator: Allocator) ModuleSystem {
        return ModuleSystem{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
            .hooks = null,
            .content_cache = std.HashMap([32]u8, *Module, ContentHashContext).init(allocator),
        };
    }

    pub fn resolve_import(self: *ModuleSystem, path: []const u8) !*Module {
        // Check cache first
        // If hook exists, use hook
        // Else, resolve path
        // Compute content hash
        // Parse and compile if not cached
    }

    pub fn compute_content_hash(self: *ModuleSystem, source: []const u8) [32]u8 {
        // BLAKE3 hash of canonical AST
    }
};
```

#### LLVM Codegen (Zig)

```zig
const llvm = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/Transforms/PassManagerBuilder.h");
});

pub const LLVMCodegen = struct {
    context: llvm.LLVMContextRef,
    module: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    allocator: Allocator,
    functions: std.StringHashMap(llvm.LLVMValueRef),

    pub fn init(allocator: Allocator, module_name: []const u8) LLVMCodegen {
        return LLVMCodegen{
            .context = llvm.LLVMContextCreate(),
            .module = llvm.LLVMModuleCreateWithName(@ptrCast(module_name.ptr)),
            .builder = llvm.LLVMCreateBuilderInContext(llvm.LLVMContextCreate()),
            .allocator = allocator,
            .functions = std.StringHashMap(llvm.LLVMValueRef).init(allocator),
        };
    }

    pub fn generate(self: *LLVMCodegen, program: *Program) !void {
        // Generate LLVM IR for each definition
        // Optimize with LLVM passes
        // Emit object file
    }

    pub fn generate_function(self: *LLVMCodegen, fn_def: *FnDef) !llvm.LLVMValueRef {
        // Create function type
        // Create function
        // Generate basic blocks
        // Return function value
    }
};
```

### 3.4 LLVM Integration

#### LLVM Passes

```zig
pub fn optimize_module(module: llvm.LLVMModuleRef) void {
    const pass_manager = llvm.LLVMCreatePassManager();

    // Optimization levels
    llvm.LLVMAddConstantPropagationPass(pass_manager);
    llvm.LLVMAddInstructionCombiningPass(pass_manager);
    llvm.LLVMAddCFGPassthroughPass(pass_manager);
    llvm.LLVMAddDeadCodeEliminationPass(pass_manager);
    llvm.LLVMAddGlobalOptimizerPass(pass_manager);
    llvm.LLVMAddFunctionInliningPass(pass_manager);

    llvm.LLVMRunPassManager(pass_manager, module);
    llvm.LLVMDisposePassManager(pass_manager);
}
```

#### Target Triple

```zig
pub fn get_target_triple() []const u8 {
    // Detect current platform
    const os = @import("builtin").os.tag;
    const arch = @import("builtin").cpu.arch;

    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => "x86_64-unknown-linux-gnu",
            .aarch64 => "aarch64-unknown-linux-gnu",
            else => unreachable,
        },
        .macos => switch (arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => unreachable,
        },
        .windows => "x86_64-pc-windows-msvc",
        else => unreachable,
    };
}
```

### 3.5 Zig Stdlib Design

#### Core Types

```zig
// std/core/value.zig
pub const Value = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    char: u8,
    string: []const u8,
    nil: void,
    constructor: *Constructor,
    closure: *Closure,
    function: *FnPtr,
    tuple: *Tuple,
};

pub const Constructor = struct {
    tag: u32,
    args: []Value,
};

pub const Closure = struct {
    env: []Value,
    fn_ptr: *const fn ([]Value) Value,
};

pub const Tuple = struct {
    elements: []Value,
};
```

#### Memory Management

```zig
// std/core/memory.zig
const std = @import("std");

pub const Allocator = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing_allocator: std.mem.Allocator) Allocator {
        return Allocator{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn alloc(self: *Allocator, size: usize) ![]u8 {
        return self.arena.alloc(u8, size);
    }

    pub fn reset(self: *Allocator) void {
        self.arena.deinit();
    }
};
```

#### String Operations

```zig
// std/core/string.zig
pub fn concat(allocator: Allocator, a: []const u8, b: []const u8) !Value {
    const result = try std.mem.concat(u8, &[_][]const u8{a, b});
    return Value{ .string = result };
}

pub fn to_string(allocator: Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .int => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        .string => |s| s,
        else => "unknown",
    };
}
```

#### Collections

```zig
// std/collections/list.zig
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            value: T,
            next: ?*Node,
        };

        allocator: Allocator,
        head: ?*Node,

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .head = null,
            };
        }

        pub fn cons(self: *Self, value: T) !void {
            const node = try self.allocator.alloc(Node, 1);
            node[0] = Node{
                .value = value,
                .next = self.head,
            };
            self.head = &node[0];
        }

        pub fn map(self: *Self, comptime U: type, f: fn (T) U) !List(U) {
            var result = List(U).init(self.allocator);
            var current = self.head;
            while (current) |node| {
                try result.cons(f(node.value));
                current = node.next;
            }
            return result;
        }
    };
}
```

### 3.6 Build System

#### build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Kō compiler executable
    const ko_exe = b.addExecutable(.{
        .name = "ko",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Link LLVM
    ko_exe.linkSystemLibrary("llvm");
    ko_exe.linkSystemLibrary("stdc++");

    b.installArtifact(ko_exe);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
```

### 3.7 Migration Plan

#### Phase 1: Core Infrastructure (Months 1-2)

1. Set up Zig project structure
2. Implement Lexer in Zig
3. Implement Parser in Zig
4. Port AST types to Zig
5. Basic error handling

#### Phase 2: Type System (Months 3-4)

1. Port type inference to Zig
2. Implement unification algorithm
3. Add trait/typeclass support
4. Add generics support

#### Phase 3: Module System (Month 5)

1. Implement hierarchical imports
2. Add visibility system
3. Implement content-addressed identity
4. Add import hooks

#### Phase 4: LLVM Backend (Months 6-7)

1. Set up LLVM bindings
2. Implement basic codegen
3. Add optimization passes
4. Support cross-compilation

#### Phase 5: Stdlib (Month 8)

1. Implement core types
2. Add string operations
3. Implement collections
4. Add I/O operations

#### Phase 6: Tooling (Months 9-10)

1. Package manager
2. Build system integration
3. LSP server
4. Debugger support

---

## Part 4: What to Steal from Other Languages

### 4.1 From Odin

- **`#config`** for compile-time configuration
- **`using`** for scope injection
- **No hidden control flow**
- **`context` parameter passing**
- **`bit_set` type**
- **`distinct` types**
- **`matrix` type**
- **`#partial switch`**

### 4.2 From Ruby

- **Blocks and Procs** (we have lambdas, similar)
- **`method_missing`** (could add to traits)
- **Enumerable module pattern**
- **Symbol atoms** `:name`
- **DSL-friendly syntax**
- **`require_relative`**

### 4.3 From OCaml

- **Module functors** (compile-time module composition)
- **Module signatures** (interfaces)
- **Polymorphic variants** (open tagged unions)
- **`include`** for module inclusion
- **First-class modules**
- **Pattern matching on exceptions**
- **Lazy evaluation**

### 4.4 From Zig

- **Modules as structs** (files are structs)
- **`@import`** turns files into values
- **`comptime`** for compile-time execution
- **Explicit allocation**
- **No hidden control flow**
- **C interop via headers**

### 4.5 From Rust

- **Traits** (we're adding these)
- **Pattern matching** (we already have)
- **Ownership/borrowing** (future consideration)
- **Cargo-style package management**
- **`cargo test`** testing framework

---

## Part 5: Timeline and Milestones

### Phase 1: Core Compiler (Completed)

- [x] Lexer in Zig
- [x] Parser in Zig
- [x] Type checker in Zig (HM inference)
- [x] LLVM codegen
- [x] JIT execution
- [x] AOT compilation
- [x] Reference counting
- [x] Partial application

### Phase 2: Language Features (Completed)

- [x] `::` infix constructor syntax (desugars to `Cons a b`)
- [x] Polymorphic println/print (type-directed runtime dispatch)
- [x] Multi-line lambda bodies (`\x -> \n expr`)
- [x] Auto-return 0 from `main` for all expression types
- [x] REPL pretty-printing (int, float, bool, char, string, unit, tuple, constructors)
- [x] LSP server (hover, completion, diagnostics)
- [x] **General recursion safety** — stack overflow detection with clear error message
- [x] **File-based imports** — `import foo` reads and compiles `foo.ko`, selective imports
- [x] **`?` operator** — postfix try for Result error propagation
- [x] **Result operations** — built-in functions (map, unwrap, fold, is_ok, is_err, and_then)
- [x] **expr_type_tags** — per-expression type tags for correct println output
- [ ] Closure codegen for multi-param lambdas (partial fix)
- [ ] Full decref for intermediate variables
- [ ] Fix multi-arg constructor pretty-printing in REPL

### Phase 3: Language Maturity (v0.3.0, In Progress)

- [ ] Staged compilation (`stage expr`)
- [ ] AST construction helpers (`code expr`)
- [ ] Record type syntax with field access
- [ ] Generics (monomorphization)
- [ ] Traits/typeclasses
- [ ] Module system v2 (hierarchical imports, first-class modules)
- [ ] Named/struct parameters

### Phase 4: Standard Library & Tooling (v0.4.0)

- [ ] Comprehensive standard library
- [ ] Package manager
- [ ] Build system integration
- [ ] Debugger support

### Phase 5: Polish and Release (v0.5.0)

- [ ] Documentation
- [ ] Examples and tutorials
- [ ] Performance optimization
- [ ] Security audit
- [ ] v1.0.0 release

---

## Part 6: Success Metrics

### Performance Targets

- **Compilation speed:** 10x faster than current Python implementation
- **Runtime performance:** Within 10% of C for most workloads
- **Binary size:** Smaller than C++ equivalents
- **Memory usage:** Lower than Go/Rust equivalents

### Quality Targets

- **Test coverage:** >90%
- **Documentation:** Complete API docs
- **Examples:** 50+ working examples
- **Tutorials:** 10+ tutorials

### Ecosystem Targets

- **Packages:** 100+ packages in first year
- **Contributors:** 50+ contributors
- **Adoption:** 1000+ users in first year

---

## Appendix A: Comparison with Other Languages

| Feature | Kō | Zig | Rust | Go | OCaml |
|---------|-----|-----|------|-----|-------|
| Memory Safety | Optional | No | Yes (borrow checker) | Yes (GC) | Yes (GC) |
| Error Handling | Result type | error!T | Result/panic | error return | exceptions |
| Module System | Content-addressed | Structs | Crates | Packages | Modules |
| Generics | Monomorphization | comptime | Monomorphization | No (interfaces) | Functors |
| Compile-time | comptime | comptime | macros | No | No |
| C Interop | Direct | Seamless | FFI | cgo | Ctypes |

---

## Appendix B: References

1. Janus Language - Content-addressed module import resolution (2026)
2. Modular Explicits - OCaml first-class modules research (2024)
3. Import Hooks - JavaScript TC39 proposal (2025)
4. HyperRes - Hypergraph dependency resolution (2025)
5. Package Calculus - Formal model of dependency resolution (2026)
6. Zig Documentation - Module system and comptime
7. Rust RFC - Namespaced crates (2025)
8. ZipML - Path-based type system for ML modules (2026)

---

*Document generated: 2026-06-20*  
*Last updated: 2026-07-12*  
*Status: v0.2.0-alpha Released*
