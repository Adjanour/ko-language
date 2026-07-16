# Kō Compiler Engineer's Handbook

A practical guide for adding language features to the Kō compiler.

---

## Table of Contents

1. [The Pipeline](#the-pipeline)
2. [Adding a New Token/Operator](#adding-a-new-tokenoperator)
3. [Adding a New Keyword](#adding-a-new-keyword)
4. [Adding a Builtin Function](#adding-a-builtin-function)
5. [Adding a New AST Node](#adding-a-new-ast-node)
6. [The Typechecker Deep Dive](#the-typechecker-deep-dive)
7. [The Codegen Deep Dive](#the-codegen-deep-dive)
8. [Testing at Each Stage](#testing-at-each-stage)
9. [Common Pitfalls](#common-pitfalls)

---

## The Pipeline

```
               Source (.ko)
                  |
                  v
+---------------------------------------------+
| LEXER (src/lexer.zig)                       |
| Source string -> Token stream               |
| Handles: whitespace, INDENT/DEDENT,         |
|          keywords, operators, literals      |
+---------------------------------------------+
                  |  Token[]
                  v
+---------------------------------------------+
| PARSER (src/parser.zig)                     |
| Token stream -> AST (src/ast.zig types)     |
| Recursive descent, significant whitespace   |
| Entry: parse_program() -> Program           |
+---------------------------------------------+
                  |  Program { imports, definitions, package }
                  v
+---------------------------------------------+
| TYPECHECKER (src/typecheck.zig)             |
| AST -> Hindley-Milner type inference        |
| Entry: inferProgram()                       |
| Produces: expr_type_tags (expr -> tag)      |
+---------------------------------------------+
                  |  Typed AST + type annotations
                  v
+---------------------------------------------+
| CODEGEN (src/codegen.zig +                  |
|          src/stdlib_codegen.zig)            |
| Typed AST -> LLVM IR                        |
| Two-pass: declareFn -> codegenFn            |
| Entry: codegenProgram()                     |
+---------------------------------------------+
                  |  LLVM Module
                  v
+---------------------------------------------+
| EXECUTION                                   |
| JIT: LLVM MCJIT (mapBuiltinsToNative)       |
| AOT: Object file -> ld -> executable        |
+---------------------------------------------+
```

### Data Flow Between Stages

| Stage | Input | Output | Key Struct |
|-------|-------|--------|------------|
| Lexer | `[]const u8` | `Token[]` | `Tokenizer` |
| Parser | `Token[]` | `Program` | `Parser` |
| Typechecker | `Program` | `expr_type_tags` | `Inferer` |
| Codegen | `Program` + tags | `LLVMModule` | `Codegen` |
| JIT | `LLVMModule` | execution | `Jit` |

---

## Adding a New Token/Operator

### Step 1: Lexer (`src/lexer.zig`)

Find the `Token.Tag` enum (line ~12). Add your new token:

```zig
// In Token.Tag enum:
my_operator,  // e.g., ??: or !!
```

Add the lexeme to `lexeme()` (line ~91):

```zig
.my_operator => "??:",
```

Add human name to `humanName()` (line ~166):

```zig
.my_operator => "operator ??:",
```

If it's a keyword (not an operator), add to the `keywords` map (line ~241):

```zig
"mykeyword" => .keyword_mykeyword,
```

Add scanning logic in `Tokenizer.next()` (line ~326):

```zig
'?' => {
    if (self.peek() == '?') {
        self.pos += 1;
        return self.makeToken(.my_operator, start);
    }
    return self.makeToken(.question, start);
},
```

### Step 2: AST (`src/ast.zig`)

If it's a binary operator, add to `BinaryOp` enum (line ~72):

```zig
pub const BinaryOp = enum {
    // ... existing ops ...
    my_op,
};
```

If it's a unary operator, add to `UnaryOp` enum (line ~90).

If it's an entirely new expression form, add to the `Expr` union (line ~98) and update `getLoc()`/`setLoc()`.

### Step 3: Parser (`src/parser.zig`)

Add parsing at the correct precedence level. The expression parser chain (outermost to innermost):

1. `parse_expr` -> `parse_assign` (`:=`)
2. `parse_pipe` (`|>`)
3. `parse_cons` (`::`, right-associative)
4. `parse_or` (`||`, `or`)
5. `parse_and` (`&&`, `and`)
6. `parse_equality` (`==`, `!=`)
7. `parse_compare` (`<`, `<=`, `>`, `>=`)
8. `parse_term` (`+`, `-`)
9. `parse_factor` (`*`, `/`, `%`)
10. `parse_unary` (`-`, `not`, `!`, `ref`)
11. `parse_postfix` (`.`, function application, `?`)
12. `parse_primary` (literals, identifiers, etc.)

### Step 4: Typechecker (`src/typecheck.zig`)

Add inference in `inferBinary()` (line ~1100). Find the switch on `.op`:

```zig
.my_op => blk: {
    try self.unify(left, try self.newType(.int));
    try self.unify(right, try self.newType(.int));
    break :blk try self.newType(.int);
},
```

### Step 5: Codegen (`src/codegen.zig`)

Add IR generation in `codegenBinaryOp()` (line ~680):

```zig
.my_op => blk: {
    const result = core.LLVMBuild...(self.builder, l, r, "my_op");
    break :blk result;
},
```

### Step 6: Test

```bash
echo 'fn main = println (5 ??: 3)' > /tmp/test_myop.ko
ko --run /tmp/test_myop.ko
ko --emit-ir /tmp/test_myop.ll /tmp/test_myop.ko
zig build test --summary all
```

---

## Adding a New Keyword

### Step 1: Lexer

Add to `Token.Tag`:

```zig
keyword_foo,
```

Add to `keywords` map:

```zig
"foo" => .keyword_foo,
```

Add lexeme and humanName entries.

### Step 2: Parser

Add to `top_level_stops` if it terminates blocks at the top level:

```zig
const top_level_stops: []const Token.Tag = &.{
    // ... existing ...
    .keyword_foo,
};
```

Add parsing in `parse_program()` or `parse_primary()`.

---

## Adding a Builtin Function

This is the most common task. Builtins are functions available without importing (like `println`, `Int.pow`).

### Step 1: Typechecker (`src/typecheck.zig`)

Find `inferProgram()` (line ~592). Add type scheme registration:

```zig
// Example: my_fn : Int -> Int -> Int
const a = try self.newVarType("a");
const b = try self.newVarType("b");
const result = try self.newVarType("c");
const inner = try self.allocator.create(Type);
inner.* = .{ .arrow = .{ .from = b, .to = result } };
const fn_type = try self.allocator.create(Type);
fn_type.* = .{ .arrow = .{ .from = a, .to = inner } };

const quantified = try self.allocator.alloc(usize, 3);
quantified[0] = a.variable.id;
quantified[1] = b.variable.id;
quantified[2] = result.variable.id;

try self.global.set("my_fn", .{ .quantified = quantified, .body = fn_type });
```

For simpler cases (monomorphic):

```zig
const fn_type = try self.allocator.create(Type);
fn_type.* = .{ .arrow = .{ .from = try self.newType(.int), .to = try self.newType(.int) } };
try self.global.set("my_fn", .{ .quantified = &.{}, .body = fn_type });
```

### Step 2: Stdlib Codegen (`src/stdlib_codegen.zig`)

Add a new codegen method:

```zig
pub fn codegenMyFn(self: *StdlibCodegen) void {
    var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
    const fn_val = self.createFunction("my_fn", self.i64Type(), &params);
    const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
    core.LLVMPositionBuilderAtEnd(self.builder, entry);

    const a = core.LLVMGetParam(fn_val, 0);
    const b = core.LLVMGetParam(fn_val, 1);
    const result = core.LLVMBuildAdd(self.builder, a, b, "result");
    self.buildRet(result);
}
```

Call it from `generateAll()`.

### Step 3: Codegen Registration (`src/codegen.zig`)

In `declareBuiltins()` (line ~254), register the function:

```zig
const my_fn = core.LLVMGetNamedFunction(self.module, "my_fn") orelse blk: {
    var params: [2]types.LLVMTypeRef = .{ i64_type, i64_type };
    const fn_type = core.LLVMFunctionType(i64_type, &params, 2, 0);
    break :blk core.LLVMAddFunction(self.module, "my_fn", fn_type);
};
_ = self.named_values.put("my_fn", my_fn) catch {};
```

### Step 4: Test

```bash
echo 'fn main = println (my_fn 3 4)' > /tmp/test_builtin.ko
ko --run /tmp/test_builtin.ko
zig build test --summary all
```

---

## Adding a New AST Node

### Step 1: AST (`src/ast.zig`)

Add to the `Expr` union:

```zig
pub const Expr = union(enum) {
    // ... existing ...
    my_node: struct {
        value: *Expr,
        loc: Loc,
    },
};
```

Update `getLoc()` and `setLoc()` for the new variant.

### Step 2: Parser

Add parsing logic:

```zig
fn parse_my_node(self: *Parser) Error!*Expr {
    const start = self.current().loc;
    _ = self.advance();
    const value = try self.parse_expr();
    return try self.newExpr(.{ .my_node = .{ .value = value, .loc = start } }, start);
}
```

### Step 3: Typechecker

Add case in `inferExpr()`:

```zig
.my_node => |n| {
    const inner = try self.inferExpr(env, n.value);
    return inner;
},
```

### Step 4: Codegen

Add case in `codegenExpr()`:

```zig
.my_node => |n| {
    const val = try self.codegenExpr(n.value);
    return val;
},
```

---

## The Typechecker Deep Dive

### Key Concepts

**Types** (`Type` union in `src/typecheck.zig`):

```zig
pub const Type = union(enum) {
    int, float, bool, char, string, unit,
    con: struct { name: []const u8, args: []*Type },
    arrow: struct { from: *Type, to: *Type },
    tuple: []*Type,
    record: RecordType,
    ref: *Type,
    variable: *TypeVar,
};
```

**Type Variables**: Mutable references that get unified (resolved) during inference.

**Schemes**: `Scheme { quantified: usize[], body: *Type }` -- polymorphic types with bound variables.

**Environments**: `Env` maps names to schemes. Scoped (child envs shadow parents).

### The Inference Flow

1. `inferProgram()` -- registers builtins, then infers each definition
2. `inferDef()` -- for `fn`, creates type vars for params, infers body
3. `inferExpr()` -- dispatches on AST node, returns inferred type
4. `unify()` -- constrains two types to be equal (resolves variables)

### Adding Type Constraints

```zig
// "This expression must be Int"
try self.unify(inferred_type, try self.newType(.int));

// "This expression must be a function from Int to Bool"
const expected = try self.allocator.create(Type);
expected.* = .{ .arrow = .{
    .from = try self.newType(.int),
    .to = try self.newType(.bool),
} };
try self.unify(inferred_type, expected);
```

### Runtime Type Tags

`typeToTag()` maps types to integer tags for runtime dispatch:

| Tag | Type |
|-----|------|
| 0 | Int |
| 1 | Float |
| 2 | Bool |
| 3 | Char |
| 4 | String |
| 5 | Unit `()` |
| 6 | Constructor (sum types) |
| 7 | Record |
| 8 | Function |
| 9 | Tuple |
| 100 | Variable/Ref (unknown) |

---

## The Codegen Deep Dive

### LLVM Value Representation

All Kō values are `i64` in LLVM:

| Kō Type | LLVM Representation |
|---------|---------------------|
| Int | `i64` (raw value) |
| Float | `i64` (bitcast from double) |
| Bool | `i64` (0 or 1) |
| Char | `i64` (ASCII code) |
| String | `i8*` pointer -> `i64` (ptrtoint) |
| Unit | `i64` (0) |
| Constructor (0-arg) | `i64` (tag value) |
| Constructor (N-arg) | `i64` (ptrtoint of heap struct) |
| Function | `i64` (function pointer or closure pointer) |

### Memory Layout

**Heap-allocated structs** (constructors with args):

```
[ i64 tag ][ i64 arg1 ][ i64 arg2 ]...
^
pointer returned by ko_alloc (what codegen sees)
```

**Closure struct** (partial application):

```
[ fn_ptr total_arity applied_count applied_args... ]
```

### Reference Counting

All heap allocations use `ko_alloc` which sets rc=1. Functions must:

- Call `emitIncref()` when storing values in parent structures
- Call `markConsumed()` to skip decref at function exit
- Call `ko_decref()` on values they own but don't return

### Two-Pass Codegen

1. **Pass 1** (`declareFn`): Creates LLVM function declarations, registers in `named_values`
2. **Pass 2** (`codegenFn`): Generates function bodies

This allows forward references (functions calling functions defined later).

---

## Testing at Each Stage

### Test File Organization

```
src/tests.zig          -- All Zig tests (lexer, parser, typechecker, codegen)
src/tests_ko/          -- .ko test programs (47+ files)
  01_literal.ko        -- Basic literals
  15_sum_type.ko       -- User-defined types
  44_cons_operator.ko  -- List operations
  50_comptime_lists.ko -- Compile-time evaluation
```

### Adding a New Test

1. Write `.ko` file in `src/tests_ko/` (must have trailing newline)
2. Add `@embedFile` entry in `tests.zig` parser test section
3. Verify it parses: `ko your_test.ko` (should show "Parsed: N definitions")
4. Run full suite: `zig build test --summary all`

### Test Commands

```bash
# Full test suite (ALWAYS use --summary all)
zig build test --summary all

# JIT-execute a program
ko --run file.ko

# Dump LLVM IR to stdout
ko file.ko

# Emit LLVM IR to file
ko --emit-ir out.ll file.ko

# Emit object file
ko --emit-obj out.o file.ko

# Emit linked executable
ko --emit-exe out file.ko
```

### Testing a New Feature

1. **Lexer test**: Add token test in `tests.zig` lexer section
2. **Parser test**: Add `.ko` file, add `@embedFile` entry
3. **Typechecker test**: Add `testInfer()` call in `tests.zig`
4. **Codegen test**: Use `ko --run` or `ko --emit-ir`
5. **Integration test**: Full `.ko` program that exercises the feature

---

## Common Pitfalls

### Lexer

- `@embedFile` returns null-terminated `*const [N:0]u8` -- do NOT append `++ "\x00"`
- `#` comments must fully disappear from token stream
- Indentation can emit multiple `dedent` tokens -- queue them

### Parser

- `parse_block` from `parse_fn_def` vs `parse_let_expr_in_block` -- use `allow_let_in_body` flag
- Field access binds tighter than function application: `println pt.x` = `println(pt.x)`
- `inspect Some(42)` without parens is parsed as `(inspect Some)(42)` -- use parens

### Typechecker

- `next_type_id` starts at 2 (Bool=0, Result=1) -- must match codegen
- `registerTypeDef` called from multiple passes -- guard with `if (!type_ids.contains(name))`
- Imported module types may not propagate to main inferer

### Codegen

- `LLVMBuildCall2` needs function type from `LLVMGlobalGetValueType`, NOT `LLVMTypeOf`
- String literals include quotes -- strip them in codegen
- Float literals produce `double` -- bitcast to `i64` for builtins
- `trackHeapAlloc` stores `ptrtoint` (i64), NOT raw pointer
- `emitDecrefAll` must skip return value (caller takes ownership)
- Allocas for conditional allocations must be before entry block terminator
- `LLVMAddGlobalMapping` doesn't override functions with bodies in MCJIT

### Testing

- Always use `zig build test --summary all` -- default output is misleading
- Every `.ko` test must parse before it can test typecheck/codegen
- Use `ArenaAllocator` wrapping `std.testing.allocator` for parser/typechecker tests
- Never use `page_allocator` for tests (bypasses leak detection)
