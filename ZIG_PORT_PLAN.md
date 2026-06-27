# Zig Port: Implementation Plan

> **Strategy:** Incremental migration, LLVM 22, stdlib in Kō, dual-compiler validation

---

## Status (June 2026)

### Completed
- **Phase 0**: Project setup, directory structure, build.zig
- **Phase 1**: Lexer (~693 lines) — all token types, indentation tracking
- **Phase 2**: Parser (~1155 lines) — full grammar implementation
- **Phase 3**: Typechecker (~999 lines) — Hindley-Milner inference, let-polymorphism
- **Phase 4**: Codegen (~1850 lines) — LLVM IR via kassane/llvm-zig bindings
  - JIT execution (MCJIT) and AOT compilation (object files + linking)
  - Sum types, records, tuples, lambdas, pattern matching
  - Built-in functions (println, print, inspect)
  - Reference counting for heap-allocated objects
  - Partial application (currying)
  - Module definitions with pub visibility
- **Testing**: 75 tests passing, 43 .ko test programs

### In Progress
- File-based imports
- General recursion safety

### Planned
- Closure codegen for multi-param lambdas
- Full decref for intermediate variables
- Standard library
- Better compiler diagnostics

---

## Zig Tokenizer Design Principles (from studying zig/src/tokenizer.zig)

### Key Techniques to Apply

**1. Zero-Allocation Architecture**
- Input: `[:0]const u8` (null-terminated slice, safe for bounds checking)
- Output: Tokens with `start`/`end` byte offsets into source
- No heap allocation during tokenization
- Caller extracts token text via `source[tok.loc.start..tok.loc.end]`

**2. State Machine with Labeled Switch**
```zig
// Zig uses continue :state for state transitions
state: switch (State.start) {
    .start => switch (self.source[self.index]) {
        'a'...'z', 'A'...'Z', '_' => {
            result.tag = .identifier;
            continue :state .identifier;
        },
        // ...
    },
    .identifier => {
        self.index += 1;
        switch (self.source[self.index]) {
            'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
            else => {
                // Check if it's a keyword
                const ident = self.source[result.loc.start..self.index];
                if (Token.getKeyword(ident)) |tag| {
                    result.tag = tag;
                }
            },
        }
    },
}
```

**3. Compile-Time Keyword Lookup**
```zig
pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "fn", .keyword_fn },
    .{ "let", .keyword_let },
    // O(1) lookup at comptime
});
```

**4. Single-Pass, No Backtracking**
- Each character consumed exactly once
- No lookahead beyond current character
- State machine tracks what we're building

**5. Error Recovery**
- Invalid tokens reset on newline
- Parser continues after errors for better diagnostics

---

## Language Ergonomics Principles

We should keep Kō functional at the core, but only preserve syntax that earns its keep.

### Non-Negotiables
- Expression-oriented first: prefer expressions that compose over statement-heavy control flow.
- Pattern matching stays central: it is the main way to inspect ADTs.
- Minimal ceremony in definitions: `fn`, `let`, `type`, `pub` should stay terse.
- Explicit module boundaries: imports and visibility should be obvious, not magical.
- No hidden control flow: if a feature changes evaluation, make that visible in syntax.

### Ergonomic Goals
- Named parameters for readability when argument order is unclear.
- Hyphenated identifiers for readable domain terms when they improve legibility.
- Standalone `_` for wildcards, not for generic underscore-heavy syntax.
- Constructors and values should be easy to distinguish by convention, not by trickery.
- Every convenience syntax must lower to a small, stable core representation.

### Data Model Direction
- Sum types use `type Expr = ...`.
- Records use `type Binding = { ... }`.
- Layout belongs to storage/container types, not the data type itself.
- Record patterns use `..` for intentional partial matches.
- `|>` stays the pipe operator for left-to-right flow.

### Things To Avoid
- Overloading a single token for too many meanings.
- Requiring users to remember parser-only exceptions.
- Syntax that looks clever but is hard to type, scan, or search.
- Features that force the typechecker to infer too much from too little.

### Charter Reference
The language direction is anchored in `LANGUAGE_CHARTER.md`. If a parser or syntax decision conflicts with that charter, we should treat it as a design problem, not an implementation accident.

### Syntax Freeze For Parser Port
Before parser work, keep these forms stable:
- `_` remains the wildcard token.
- Hyphenated identifiers remain legal.
- Numeric literals keep decimal, hex, binary, and octal forms.
- `#` comments and indentation-sensitive blocks stay as-is.
- Named parameters stay `~name:expr`.
- Visibility stays `pub` before `fn` / `type` / `let` / `module`.
- Record syntax stays braces-based.
- Record patterns keep `..` for partial matches.
- `|>` stays the pipe operator.

---

## Phase 0: Project Setup (Week 1)

### Directory Structure
```
ko-zig/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig           # Entry point
│   ├── lexer.zig          # Tokenizer
│   ├── parser.zig         # Recursive descent parser
│   ├── ast.zig            # AST node types
│   ├── typecheck.zig      # HM type inference
│   ├── codegen.zig        # LLVM codegen orchestrator
│   ├── codegen/
│   │   ├── llvm.zig       # LLVM IR generation
│   │   └── types.zig      # Type → LLVM type mapping
│   ├── module.zig         # Module system
│   ├── errors.zig         # Error types
│   └── util.zig           # Shared utilities
├── std/                   # Kō stdlib (written in Kō)
│   ├── math.ko
│   ├── string.ko
│   ├── list.ko
│   └── io.ko
├── tests/
│   ├── lexer_test.zig
│   ├── parser_test.zig
│   ├── typecheck_test.zig
│   └── codegen_test.zig
└── test_output/           # Expected outputs for validation
    └── *.expected
```

### build.zig Foundation
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Kō compiler
    const ko_exe = b.addExecutable(.{
        .name = "ko",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ko_exe.linkSystemLibrary("llvm-18");
    ko_exe.linkSystemLibrary("c++");
    b.installArtifact(ko_exe);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Integration tests (compare with Python compiler)
    const integ = b.addSystemCommand(&.{ "python3", "test_compare.sh" });
    const integ_step = b.step("integ", "Run integration tests");
    integ_step.dependOn(&integ.step);
}
```

---

## Phase 1: Lexer (Weeks 2-3)

### Zig Tokenizer Techniques to Apply

**1. Zero-Allocation Design**
- Tokenizer takes `[:0]const u8` (null-terminated slice)
- No heap allocation during tokenization
- Token locations stored as `start`/`end` byte offsets into source
- Extract token text via `source[tok.loc.start..tok.loc.end]`

**2. State Machine with `continue :state`**
- Uses Zig's labeled switch/continue for state transitions
- Single `while(true)` loop, breaks when token found
- State enum tracks what we're building (`.start`, `.identifier`, `.int`, etc.)
- No backtracking — each character consumed exactly once

**3. Token Structure**
```zig
pub const Token = struct {
    tag: Tag,        // Token type enum
    loc: Loc,        // { start: usize, end: usize }
};
```

**4. Compile-Time Keyword Map**
```zig
pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "fn", .keyword_fn },
    .{ "let", .keyword_let },
    // ...
});
```

**5. Location-Only Storage**
- Don't store token strings — store offsets
- Caller extracts text when needed
- Memory-efficient for large source files

### What to Port from Kō
- All 60+ token types from `lexer.py`
- Indentation tracking for newline significance
- String interpolation (if any)
- Comment handling

### Kō Lexer Design (Zig)
```zig
pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "fn", .keyword_fn },
        .{ "let", .keyword_let },
        .{ "if", .keyword_if },
        .{ "then", .keyword_then },
        .{ "else", .keyword_else },
        .{ "match", .keyword_match },
        .{ "type", .keyword_type },
        .{ "import", .keyword_import },
        .{ "package", .keyword_package },
        .{ "pub", .keyword_pub },
        .{ "module", .keyword_module },
        .{ "true", .keyword_true },
        .{ "false", .keyword_false },
        // ... all Kō keywords
    });
};

pub const Tokenizer = struct {
    source: [:0]const u8,
    index: usize,
    indent_stack: [64]u32,  // Track indentation levels
    indent_pos: usize,

    pub fn init(source: [:0]const u8) Tokenizer {
        return .{
            .source = source,
            .index = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0,
            .indent_stack = .{0} ** 64,
            .indent_pos = 0,
        };
    }

    pub fn next(self: *Tokenizer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{ .start = self.index, .end = undefined },
        };

        state: switch (State.start) {
            .start => switch (self.source[self.index]) {
                0 => {
                    if (self.index == self.source.len) {
                        return .{ .tag = .eof, .loc = .{ .start = self.index, .end = self.index } };
                    }
                    continue :state .invalid;
                },
                ' ', '\t' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '\n' => {
                    // Handle indentation-sensitive newlines
                    self.index += 1;
                    result.tag = .newline;
                    continue :state .newline_indent;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '0'...'9' => {
                    result.tag = .number;
                    self.index += 1;
                    continue :state .number;
                },
                '"' => {
                    result.tag = .string;
                    continue :state .string;
                },
                '#' => continue :state .comment,
                // Single-char tokens
                '(' => { result.tag = .lparen; self.index += 1; },
                ')' => { result.tag = .rparen; self.index += 1; },
                '{' => { result.tag = .lbrace; self.index += 1; },
                '}' => { result.tag = .rbrace; self.index += 1; },
                '[' => { result.tag = .lbracket; self.index += 1; },
                ']' => { result.tag = .rbracket; self.index += 1; },
                ',' => { result.tag = .comma; self.index += 1; },
                ';' => { result.tag = .semicolon; self.index += 1; },
                ':' => { result.tag = .colon; self.index += 1; },
                '.' => { result.tag = .dot; self.index += 1; },
                '~' => { result.tag = .tilde; self.index += 1; },
                '_' => { result.tag = .underscore; self.index += 1; },
                // Multi-char operators
                '=' => continue :state .equal,
                '!' => continue :state .bang,
                '<' => continue :state .angle_left,
                '>' => continue :state .angle_right,
                '+' => continue :state .plus,
                '-' => continue :state .minus,
                '*' => continue :state .star,
                '/' => continue :state .slash,
                '|' => continue :state .pipe,
                '\\' => continue :state .lambda,
                else => continue :state .invalid,
            },

            .identifier => {
                self.index += 1;
                switch (self.source[self.index]) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                    else => {
                        const ident = self.source[result.loc.start..self.index];
                        if (Token.getKeyword(ident)) |tag| {
                            result.tag = tag;
                        }
                    },
                }
            },

            .number => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '0'...'9', '_', '.' => continue :state .number,
                    else => {},
                }
            },

            .string => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    '\\' => continue :state .string_backslash,
                    '"' => self.index += 1,
                    else => continue :state .string,
                }
            },

            .comment => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0, '\n' => {
                        // Skip comment, continue to next token
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    else => continue :state .comment,
                }
            },

            .equal => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => { result.tag = .eqeq; self.index += 1; },
                    '>' => { result.tag = .fat_arrow; self.index += 1; },
                    else => result.tag = .equal,
                }
            },

            .angle_left => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => { result.tag = .lte; self.index += 1; },
                    '-' => { result.tag = .pipe_gt; self.index += 1; },
                    else => result.tag = .lt,
                }
            },

            // ... more states
        }

        result.loc.end = self.index;
        return result;
    }
};
```

### Validation
- Run `python3 ko.py --tokenize test.ko` on all examples
- Run `zig build` lexer tests
- Compare token streams match exactly

---

## Phase 2: Parser (Weeks 3-5)

### What to Port
- All AST node types from `parser.py`
- Indentation-sensitive parsing
- Pratt parsing for operator precedence
- Pattern matching syntax
- Module/import syntax
- Named parameters
- Result type syntax

### AST Representation (Zig)
```zig
pub const Expr = union(enum) {
    int_literal: i64,
    float_literal: f64,
    string_literal: []const u8,
    bool_literal: bool,
    ident: []const u8,
    
    binary_op: struct {
        op: BinaryOp,
        left: *Expr,
        right: *Expr,
    },
    
    fn_call: struct {
        func: *Expr,
        positional_args: []Expr,
        named_args: []NamedArg,
    },
    
    lambda: struct {
        params: []Param,
        body: *Expr,
    },
    
    match_expr: struct {
        subject: *Expr,
        arms: []MatchArm,
    },
    
    if_expr: struct {
        condition: *Expr,
        then_branch: *Expr,
        else_branch: ?*Expr,
    },
    
    let_expr: struct {
        name: []const u8,
        value: *Expr,
        body: *Expr,
    },
    
    // ... etc
};

pub const Definition = union(enum) {
    fn_def: FnDef,
    type_def: TypeDef,
    let_binding: LetBinding,
    import: Import,
    package: Package,
};
```

### Validation
- Parse all 22 example programs
- Compare AST output with Python parser
- Run parser unit tests

---

## Phase 3: Type Checker (Weeks 5-8)

### What to Port
- Hindley-Milner type inference
- Unification algorithm
- Type environment
- Built-in type registration
- ADT type checking
- Pattern match exhaustiveness

### Key Types (Zig)
```zig
pub const Type = union(enum) {
    int,
    float,
    bool,
    string,
    unit,
    fn_type: struct {
        param: *Type,
        result: *Type,
    },
    type_var: struct {
        id: u32,
    },
    constructor: struct {
        name: []const u8,
        args: []Type,
    },
    tuple: []Type,
};

pub const TypeEnv = struct {
    parent: ?*TypeEnv,
    bindings: std.StringHashMap(TypeScheme),
    
    pub fn lookup(self: *TypeEnv, name: []const u8) ?Type {
        if (self.bindings.get(name)) |scheme| 
            return scheme.instantiate();
        if (self.parent) |p| 
            return p.lookup(name);
        return null;
    }
};
```

### Validation
- Run type inference on all examples
- Compare types with Python typechecker
- Test error messages match

---

## Phase 4: Module System (Weeks 8-9)

### What to Port
- Import resolution
- Hierarchical paths
- Selective imports
- Alias imports
- Visibility (pub/private)
- Package detection

### Key Design Decisions
- **Content hashing:** Use BLAKE3 for module identity (future)
- **Import hooks:** Defer to later phase
- **First-class modules:** Defer to later phase

### Validation
- Test all import patterns from `examples/20_modules.ko`
- Test package detection
- Test selective/alias imports

---

## Phase 5: LLVM Codegen (Weeks 9-12)

### LLVM C API Bindings (Zig)
```zig
const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/Transforms/PassManagerBuilder.h");
    @cInclude("llvm-c/ExecutionEngine.h");
});

pub const LLVMCodegen = struct {
    ctx: c.LLVMContextRef,
    module: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,
    target_data: c.LLVMTargetDataRef,
    
    pub fn init(module_name: [*:0]const u8) LLVMCodegen {
        return .{
            .ctx = c.LLVMContextCreate(),
            .module = c.LLVMModuleCreateWithName(module_name),
            .builder = c.LLVMCreateBuilderInContext(c.LLVMContextCreate()),
            .target_data = null,
        };
    }
    
    pub fn generate_function(self: *LLVMCodegen, fn_def: *FnDef) !c.LLVMValueRef {
        // Create function type
        // Create basic blocks
        // Generate code for body
        // Return function value
    }
};
```

### Optimization Passes
```zig
pub fn optimize(module: c.LLVMModuleRef, level: OptimizationLevel) void {
    const pm = c.LLVMCreatePassManager();
    
    switch (level) {
        .None => {},
        .Basic => {
            c.LLVMAddConstantPropagationPass(pm);
            c.LLVMAddInstructionCombiningPass(pm);
        },
        .Aggressive => {
            c.LLVMAddConstantPropagationPass(pm);
            c.LLVMAddInstructionCombiningPass(pm);
            c.LLVMAddCFGPassthroughPass(pm);
            c.LLVMAddDeadCodeEliminationPass(pm);
            c.LLVMAddGlobalOptimizerPass(pm);
            c.LLVMAddFunctionInliningPass(pm);
        },
    }
    
    c.LLVMRunPassManager(pm, module);
    c.LLVMDisposePassManager(pm);
}
```

### Validation
- Compile all 22 examples with LLVM
- Run outputs, compare with C backend
- Benchmark compilation speed

---

## Phase 6: Stdlib in Kō (Week 12)

### Write Stdlib in Kō
Since user wants stdlib in Kō, we need to write the stdlib modules in Kō itself, not in C or Zig.

**std/math.ko**
```ko
package std.math

pub PI = 3.14159265358979
pub E = 2.71828182845905

pub fn sin x = #_builtin_sin x
pub fn cos x = #_builtin_cos x
pub fn sqrt x = #_builtin_sqrt x
```

**std/string.ko**
```ko
package std.string

pub fn len s = #_builtin_string_len s
pub fn concat a b = #_builtin_string_concat a b
pub fn substr s start end = #_builtin_string_substr s start end
```

**std/list.ko**
```ko
package std.list

type List a = Cons a (List a) | Nil

pub fn map f xs =
  match xs
    Cons h t -> Cons (f h) (map f t)
    Nil -> Nil

pub fn fold f acc xs =
  match xs
    Cons h t -> fold f (f acc h) t
    Nil -> acc
```

### Key Decision: #_builtin_ prefix
- Kō stdlib functions use `#_builtin_` prefix for C/LLVM intrinsics
- The compiler recognizes these and generates direct calls
- No C runtime.h needed — everything goes through LLVM

### Validation
- Kō stdlib compiles to LLVM IR
- Functions work correctly when called from Kō programs
- All 22 examples still work

---

## Phase 7: Dual-Compiler Validation (Week 13)

### test_compare.sh
```bash
#!/bin/bash
PYTHON_KO="python3 ../ko.py"
ZIG_KO="./zig-out/bin/ko"

PASS=0
FAIL=0

for example in ../examples/*.ko; do
    name=$(basename "$example" .ko)
    
    # Compile with Python
    $PYTHON_KO "$example" "/tmp/py_$name" 2>/dev/null
    PY_OUT=$(/tmp/py_$name 2>&1)
    
    # Compile with Zig
    $ZIG_KO "$example" "/tmp/zig_$name" 2>/dev/null
    ZIG_OUT=$(/tmp/zig_$name 2>&1)
    
    if [ "$PY_OUT" = "$ZIG_OUT" ]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        echo "  Python: $PY_OUT"
        echo "  Zig:    $ZIG_OUT"
        FAIL=$((FAIL + 1))
    fi
done

echo "Results: $PASS passed, $FAIL failed"
```

---

## Phase 8: Performance Benchmarks (Week 14)

### Benchmarks to Run
1. **Compilation speed:** Time to compile all examples
2. **Binary performance:** Runtime of generated executables
3. **Memory usage:** Peak RSS during compilation
4. **Binary size:** Size of generated executables

### Expected Improvements
| Metric | Python | Zig (expected) |
|--------|--------|----------------|
| Compile time | ~0.5s | ~0.01s (50x faster) |
| Runtime | ~1.0s | ~0.1s (10x faster) |
| Binary size | N/A | ~100KB |
| Memory | ~50MB | ~5MB |

---

## Timeline Summary

| Phase | Weeks | Deliverable |
|-------|-------|-------------|
| 0. Setup | 1 | Project structure, build.zig |
| 1. Lexer | 2-3 | Tokenizer |
| 2. Parser | 3-5 | Recursive descent parser |
| 3. Type Checker | 5-8 | HM type inference |
| 4. Module System | 8-9 | Import resolution |
| 5. LLVM Codegen | 9-12 | LLVM IR generation |
| 6. Stdlib | 12 | Kō stdlib |
| 7. Validation | 13 | Dual-compiler tests |
| 8. Benchmarks | 14 | Performance metrics |

**Total: ~14 weeks (3.5 months)**

---

## Risk Mitigation

### Risk 1: LLVM Bindings Complexity
- **Mitigation:** Start with simple programs, build up gradually
- **Fallback:** Use C codegen first, add LLVM later

### Risk 2: Type System Port
- **Mitigation:** Port unit tests alongside code
- **Fallback:** Simplify type system if needed

### Risk 3: Module System
- **Mitigation:** Start with basic imports, add features incrementally
- **Fallback:** Defer content-addressed identity to v2.0

### Risk 4: Stdlib in Kō
- **Mitigation:** Write minimal stdlib first (math, string, io)
- **Fallback:** Keep C runtime.h as temporary solution

---

## Next Steps

1. **Create `ko-zig/` directory structure**
2. **Set up `build.zig` with LLVM 18**
3. **Port Lexer from `lexer.py`**
4. **Write lexer tests**
5. **Validate against Python lexer**

Ready to start Phase 0?
