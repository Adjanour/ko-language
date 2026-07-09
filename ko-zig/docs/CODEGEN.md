# Kō Codegen — How It Works

This document explains the LLVM IR code generation in `src/codegen.zig`, line by line where needed.

## Overview

Codegen translates the Kō AST into **LLVM IR** (Intermediate Representation). LLVM then compiles this IR to machine code. The key insight: Kō is a high-level functional language, but at runtime everything is just **i64 values** — integers, pointers, and tags all squeezed into 64 bits.

**Pipeline position:**

```
Source → Lexer → Parser → AST → Typechecker → Codegen → LLVM IR → Machine code
```

**Two modes:**
- **JIT** (`ko --run`): LLVM compiles to memory, you call the function pointer directly
- **AOT** (`ko --emit-obj`): LLVM writes a `.o` file, you link with `ld`

## Core Data Structures

### `Codegen` (line 25)

The codegen state machine. Everything needed to translate Kō to LLVM IR:

```zig
pub const Codegen = struct {
    allocator: std.mem.Allocator,
    context: types.LLVMContextRef,     // LLVM context (owns all LLVM objects)
    module: types.LLVMModuleRef,       // the LLVM module (like a source file)
    builder: types.LLVMBuilderRef,     // cursor for inserting instructions
    named_values: std.StringHashMap(types.LLVMValueRef),  // variable name → LLVM value
    variable_types: std.StringHashMap([]const u8),  // variable name → record type name
    fn_types: std.StringHashMap(types.LLVMTypeRef),  // function name → LLVM function type
    fn_arity: std.StringHashMap(u32),  // function name → arity (param count)
    constructor_tags: std.StringHashMap(CtorInfo),  // constructor name → tag + arity
    record_types: std.StringHashMap(RecordInfo),    // record name → LLVM struct type + fields
    scope_heap_values: std.ArrayList(types.LLVMValueRef),  // heap values to decref on scope exit
};
```

### Key LLVM Concepts

Before diving in, here are the LLVM concepts you need:

| Concept | What it is | Kō analogy |
|---------|-----------|------------|
| **Module** | A source file — contains functions and globals | `.ko` file |
| **Function** | A function definition with parameters and a body | `fn add x y = x + y` |
| **Basic Block** | A sequence of instructions with one entry, one exit | A branch of an `if` |
| **Builder** | A cursor that inserts instructions at a point | The "write head" |
| **Value** | An SSA value — the result of an instruction | The return value of `x + y` |
| **Type** | An LLVM type — `i64`, `double`, `i1`, `ptr`, etc. | Kō's `Int`, `Float`, `Bool` |

**SSA form:** LLVM uses Static Single Assignment — each variable is assigned exactly once. No mutation. Instead of `x = x + 1`, you write `%x2 = add i64 %x1, 1`.

## Type Mapping: Kō → LLVM

The function `koTypeToLlvm` (line 92) converts Kō types to LLVM types:

```zig
pub fn koTypeToLlvm(self: *Codegen, ty: typecheck.Type) types.LLVMTypeRef {
    return switch (ty) {
        .int => core.LLVMInt64TypeInContext(self.context),      // Int → i64
        .float => core.LLVMDoubleTypeInContext(self.context),   // Float → double
        .bool => core.LLVMInt1TypeInContext(self.context),      // Bool → i1 (1-bit)
        .string => core.LLVMPointerTypeInContext(self.context, 0),  // String → i8*
        .char => core.LLVMInt8TypeInContext(self.context),      // Char → i8
        .unit => core.LLVMVoidTypeInContext(self.context),      // () → void
        .arrow => ptr_type,    // a → b → i64 (function pointers are i64)
        .tuple => struct_type, // (A, B) → { i64, i64 }
        .con => i64_type,      // List a → i64 (tag value or pointer)
        .record => struct_type, // { x: Int } → { i64 }
        .variable => i64_type,  // type var → i64 (erased at runtime)
        .@"ref" => ptr_type,    // Ref a → i8*
    };
}
```

**Critical design decision:** Everything in Kō is an `i64` at runtime:
- Integers are direct i64 values
- Booleans are 0 or 1 (stored in i64)
- Pointers (strings, closures, records) are cast to i64
- Sum type tags are i64 values
- This makes the runtime uniform — no boxing/unboxing needed

## The Two-Pass Architecture

Codegen uses a **two-pass** approach for functions:

### Pass 1: Forward Declarations (`declareFn`)

Creates LLVM function declarations without bodies. This allows functions to call each other (mutual recursion):

```zig
// Pass 1: declare all functions
for (program.definitions) |def| {
    if (def == .fn_def) try self.declareFn(def);
}

// Pass 2: generate bodies
for (program.definitions) |def| {
    if (def == .fn_def) _ = try self.codegenFn(def);
}
```

`declareFn` creates:

```llvm
define i64 @add(i64 %x, i64 %y)  ; no body yet
```

And registers in `named_values`:

```zig
try self.named_values.put("add", fn_val);
try self.fn_arity.put("add", 2);
```

### Pass 2: Function Bodies (`codegenFn`)

Generates the actual instructions:

```zig
fn codegenFn(self: *Codegen, f: parser.FnDef) Error!types.LLVMValueRef {
    const fn_val = self.named_values.get(f.name);

    // Create entry basic block
    const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
    core.LLVMPositionBuilderAtEnd(self.builder, entry);

    // Map parameter names to LLVM values
    for (f.params, 0..) |param, i| {
        const param_val = core.LLVMGetParam(fn_val, @intCast(i));
        core.LLVMSetValueName(param_val, param_name_z);
        try self.named_values.put(param.name, param_val);
    }

    // Codegen the body
    const body_val = try self.codegenExpr(f.body);

    // Return the result
    _ = core.LLVMBuildRet(self.builder, body_val);
    return fn_val;
}
```

## Expression Codegen (`codegenExpr`, line 276)

This is the core recursive function. It translates any Kō expression to an LLVM value:

```zig
pub fn codegenExpr(self: *Codegen, expr: *const parser.Expr) Error!types.LLVMValueRef {
    return switch (expr.*) {
        .int_literal => |val| LLVMConstInt(i64, val, 0),
        .float_literal => |val| LLVMConstReal(double, val),
        .bool_literal => |val| LLVMConstInt(i1, val, 0),
        .identifier => |name| self.named_values.get(name),
        .binary_op => |b| try self.codegenBinaryOp(b.op, b.left, b.right),
        .fn_call => |call| try self.codegenFnCall(call),
        .if_expr => |i| try self.codegenIf(i),
        .match_expr => |m| try self.codegenMatch(m.value, m.arms),
        .lambda => |lam| try self.codegenLambda(lam.params, lam.body),
        // ... etc
    };
}
```

## Literals

The simplest codegen — constants map directly to LLVM constants:

```zig
.int_literal => |val| core.LLVMConstInt(i64_type, @bitCast(@as(i64, val)), 0),
.float_literal => |val| core.LLVMConstReal(double_type, val),
.bool_literal => |val| core.LLVMConstInt(i1_type, @intFromBool(val), 0),
.char_literal => |val| core.LLVMConstInt(i64_type, val[0], 0),  // first byte as i64
```

### String Literals (line 286)

Strings are global constants with a pointer returned:

```zig
.string_literal => |val| {
    // 1. Create LLVM string constant: [N x i8] "hello"
    const str_val = core.LLVMConstStringInContext(ctx, val.ptr, val.len, 0);

    // 2. Wrap in a global variable
    const global = core.LLVMAddGlobal(module, LLVMTypeOf(str_val), "str");
    core.LLVMSetInitializer(global, str_val);
    core.LLVMSetGlobalConstant(global, 1);
    core.LLVMSetLinkage(global, .LLVMPrivateLinkage);

    // 3. Return pointer to first element via GEP
    var indices = [1]LLVMValueRef{LLVMConstInt(i64, 0, 0)};
    return LLVMBuildGEP2(builder, i8_type, global, &indices, 1, "str_ptr");
}
```

**Why GEP?** `LLVMConstStringInContext` returns `[N x i8]` (an array), but we need `i8*` (a pointer). GEP (Get Element Pointer) computes the address of the first element.

## Binary Operations (line 335)

```zig
fn codegenBinaryOp(self: *Codegen, op: BinaryOp, left: *Expr, right: *Expr) !LLVMValueRef {
    const l = try self.codegenExpr(left);   // codegen left operand
    const r = try self.codegenExpr(right);  // codegen right operand

    return switch (op) {
        .add => LLVMBuildAdd(builder, l, r, "add"),       // %add = add i64 %l, %r
        .sub => LLVMBuildSub(builder, l, r, "sub"),       // %sub = sub i64 %l, %r
        .mul => LLVMBuildMul(builder, l, r, "mul"),       // %mul = mul i64 %l, %r
        .div => LLVMBuildSDiv(builder, l, r, "sdiv"),     // %sdiv = sdiv i64 %l, %r
        .mod => LLVMBuildSRem(builder, l, r, "srem"),     // %srem = srem i64 %l, %r
        .eq => {
            const cmp = LLVMBuildICmp(builder, LLVMIntEQ, l, r, "cmp");  // %cmp = icmp eq i64 %l, %r
            return LLVMBuildZExt(builder, cmp, i64, "bool_ext");         // %ext = zext i1 %cmp to i64
        },
        // ... etc
    };
}
```

**Note on comparisons:** LLVM's `icmp` returns `i1` (1-bit), but Kō uses i64 for everything. So we zero-extend (`zext`) the i1 to i64.

## If Expressions (line 754)

If expressions use **phi nodes** to merge values from different branches:

```
         ┌──────────────┐
         │  if cond     │
         │  br cond     │
         │    then_bb   │
         │    else_bb   │
         └──────┬───────┘
                │
    ┌───────────┴───────────┐
    ▼                       ▼
┌──────────┐          ┌──────────┐
│ then_bb  │          │ else_bb  │
│ then_val │          │ else_val │
│ br merge │          │ br merge │
└────┬─────┘          └────┬─────┘
     │                     │
     └─────────┬───────────┘
               ▼
         ┌───────────┐
         │ merge_bb  │
         │ phi(      │
         │   then_val│
         │   else_val│
         │ )         │
         └───────────┘
```

**Code:**

```zig
fn codegenIf(self: *Codegen, if_expr: IfExpr) !LLVMValueRef {
    // 1. Codegen condition
    const cond = try self.codegenExpr(if_expr.condition);
    // Compare to 0 (false)
    const cond_bool = LLVMBuildICmp(builder, LLVMIntNE, cond, const_int(0), "ifcond");

    // 2. Create basic blocks
    const then_bb = LLVMAppendBasicBlock(fn_val, "then");
    const else_bb = LLVMAppendBasicBlock(fn_val, "else");
    const merge_bb = LLVMAppendBasicBlock(fn_val, "ifcont");

    // 3. Conditional branch
    LLVMBuildCondBr(builder, cond_bool, then_bb, else_bb);

    // 4. Codegen then branch
    PositionBuilderAtEnd(builder, then_bb);
    const then_val = try self.codegenExpr(if_expr.then_branch);
    LLVMBuildBr(builder, merge_bb);  // jump to merge

    // 5. Codegen else branch
    PositionBuilderAtEnd(builder, else_bb);
    const else_val = try self.codegenExpr(if_expr.else_branch);
    LLVMBuildBr(builder, merge_bb);  // jump to merge

    // 6. Merge with phi
    PositionBuilderAtEnd(builder, merge_bb);
    const phi = LLVMBuildPhi(builder, i64_type, "iftmp");
    LLVMAddIncoming(phi, &.{then_val, else_val}, &.{then_bb, else_bb}, 2);
    return phi;
}
```

**What's a phi node?** In SSA form, a value can only be defined once. A phi node says "if we came from then_bb, use then_val; if we came from else_bb, use else_val." LLVM handles the routing.

## Function Calls (line 523)

### Constructor Calls

For `Cons 42 Nil`:

```zig
if (call.func.* == .constructor) {
    const info = self.constructor_tags.get(name);

    // Zero-arg: return tag directly
    if (call.args.len == 0) {
        return LLVMConstInt(i64, info.tag, 0);  // Nil → 0
    }

    // Single-arg: allocate { i64 tag, i64 payload }
    const tagged_type = LLVMStructTypeInContext(ctx, &.{i64_type, arg_type}, 2, 0);
    const raw_ptr = call_ko_alloc(storeSize(tagged_type));  // heap allocate
    // Store tag at index 0
    LLVMBuildStore(builder, tag_val, GEP(tagged_type, raw_ptr, 0));
    // Store value at index 1
    LLVMBuildStore(builder, arg_val, GEP(tagged_type, raw_ptr, 1));
    // Return pointer as i64
    return LLVMBuildPtrToInt(builder, raw_ptr, i64);
}
```

### Regular Function Calls

```zig
const fn_val = try self.codegenExpr(call.func);
var args: [32]LLVMValueRef = undefined;
for (call.args, 0..) |arg, i| {
    args[i] = try self.codegenExpr(arg);
}

// Get function type and build call
const fn_type = core.LLVMGlobalGetValueType(fn_val);
return LLVMBuildCall2(builder, fn_type, fn_val, &args, argc, "call");
```

### Partial Application (line 441)

When calling a function with fewer args than its arity, Kō creates a **closure**:

```zig
fn createPartialApp(self: *Codegen, fn_name: []const u8, fn_val: LLVMValueRef, total_arity: u32, applied_args: []const LLVMValueRef) !LLVMValueRef {
    // 1. Generate a wrapper function
    //    wrapper(closure_ptr, remaining_args...) → loads applied args, calls original
    const wrapper_fn = LLVMAddFunction(module, wrapper_name, wrapper_type);
    // ... wrapper body loads applied args from closure struct, calls original

    // 2. Allocate closure struct on heap
    //    Layout: { fn_ptr, total_arity, applied_count, applied_args[] }
    const closure_ptr = call_ko_alloc(24 + applied_count * 8);

    // 3. Store fields
    LLVMBuildStore(builder, wrapper_fn, GEP(closure_ptr, 0));    // fn_ptr
    LLVMBuildStore(builder, total_arity, GEP(closure_ptr, 8));   // total_arity
    LLVMBuildStore(builder, applied_count, GEP(closure_ptr, 16)); // applied_count
    for (applied_args) |arg, i| {
        LLVMBuildStore(builder, arg, GEP(closure_ptr, 24 + i*8)); // applied_args
    }

    // 4. Return pointer with bit 0 set (tag for partial application)
    const closure_i64 = LLVMBuildPtrToInt(builder, closure_ptr, i64);
    return LLVMBuildOr(builder, closure_i64, const_int(1, 0));  // set bit 0
}
```

**The bit-0 tag:** Function values are i64. Aligned pointers have bit 0 = 0. So:
- Bit 0 = 0 → raw function pointer (direct call)
- Bit 0 = 1 → closure pointer (indirect call through wrapper)

### Indirect Calls (line 694)

When calling a value that might be a function pointer OR a closure:

```zig
// Check bit 0
const bit0 = LLVMBuildAnd(builder, fn_val, const_int(1), "bit0");
const is_partial = LLVMBuildICmp(builder, LLVMIntNE, bit0, const_int(0), "is_partial");
LLVMBuildCondBr(builder, is_partial, partial_bb, direct_bb);

// Partial application path
PositionBuilderAtEnd(builder, partial_bb);
const closure_ptr = LLVMBuildIntToPtr(builder, fn_val & ~1, ptr_type);
const wrapper_ptr = load(GEP(closure_ptr, 0));  // load fn_ptr from closure
const result = LLVMBuildCall2(builder, wrapper_type, wrapper_ptr, closure_args);
LLVMBuildBr(builder, merge_bb);

// Direct call path
PositionBuilderAtEnd(builder, direct_bb);
const fn_ptr = LLVMBuildIntToPtr(builder, fn_val, ptr_type);
const result = LLVMBuildCall2(builder, fn_type, fn_ptr, args);
LLVMBuildBr(builder, merge_bb);

// Merge
PositionBuilderAtEnd(builder, merge_bb);
const phi = LLVMBuildPhi(builder, i64, "call_result");
LLVMAddIncoming(phi, &.{partial_result, direct_result}, &.{partial_bb, direct_bb}, 2);
```

## Match Expressions (line 1022)

Pattern matching on sum types uses a chain of comparison blocks:

```
match x
  | Nil => 0
  | Cons h t => h
```

Compiles to:

```
entry:
  %tag = and i64 %x, 1          ; extract tag (or shift, depending on representation)
  %is_nil = icmp eq i64 %tag, 0
  br i1 %is_nil, label %arm_0, label %cmp_1

arm_0:                           ; Nil branch
  br label %merge

cmp_1:                           ; Check Cons tag
  %is_cons = icmp eq i64 %tag, 1
  br i1 %is_cons, label %arm_1, label %unreachable

arm_1:                           ; Cons branch
  ; extract payload: h = load from (x + 8)
  %h_ptr = getelementptr i8, ptr %x_ptr, i64 8
  %h = load i64, ptr %h_ptr
  br label %merge

unreachable:
  call void @llvm.trap()
  unreachable

merge:
  %result = phi i64 [ 0, %arm_0 ], [ %h, %arm_1 ]
  ret i64 %result
```

**Key pattern:**
1. Create cmp blocks, body blocks, merge block
2. For each arm: compare tag, branch to body or next cmp
3. In each body: codegen the arm body, branch to merge
4. In merge: phi node merges all arm results

## Sum Types (ADTs)

### Representation

All sum types are `i64` at runtime:

| Constructor | Representation |
|-------------|---------------|
| `Nil` (0 args) | The integer `0` (tag) |
| `True` (0 args) | The integer `1` (tag) |
| `Cons x xs` (2 args) | Pointer to `{ i64 tag, i64 x, i64 xs }` on heap |

### Constructor Codegen (line 524)

```zig
// Zero-arg: return tag directly
if (call.args.len == 0) {
    return LLVMConstInt(i64, info.tag, 0);
}

// Single-arg: allocate tagged struct
if (call.args.len == 1) {
    const tagged_type = LLVMStructTypeInContext(ctx, &.{i64_type, arg_type}, 2, 0);
    const raw_ptr = call_ko_alloc(storeSize(tagged_type));
    LLVMBuildStore(builder, tag_val, GEP(raw_ptr, 0, 0));     // tag
    LLVMBuildStore(builder, arg_val, GEP(raw_ptr, 0, 1));     // value
    return LLVMBuildPtrToInt(builder, raw_ptr, i64);
}
```

## Records

### Registration (line 216)

For `type Point = { x: Int, y: Int }`:

```zig
// Create LLVM struct type
const struct_ty = LLVMStructTypeInContext(ctx, &.{i64_type, i64_type}, 2, 0);

// Store in record_types map
try self.record_types.put("Point", .{
    .name = "Point",
    .fields = &.{
        .{ .name = "x", .llvm_type = i64_type, .index = 0 },
        .{ .name = "y", .llvm_type = i64_type, .index = 1 },
    },
    .llvm_type = struct_ty,
});
```

### Record Literals (line 804)

For `{ x = 1, y = 2 }`:

```zig
fn codegenRecordLiteral(self: *Codegen, name: []const u8, fields: []const NamedArg) !LLVMValueRef {
    const info = self.record_types.get(name);

    // Allocate struct on heap
    const size_val = self.storeSize(info.llvm_type);
    const raw_ptr = call_ko_alloc(size_val);

    // Store each field at its index
    for (fields, 0..) |field, i| {
        const field_val = try self.codegenExpr(field.value);
        var gep_indices = [2]LLVMValueRef{ const_int(0), const_int(field_idx) };
        const field_ptr = LLVMBuildGEP2(builder, info.llvm_type, raw_ptr, &gep_indices, 2, "field_ptr");
        LLVMBuildStore(builder, field_val, field_ptr);
    }

    // Return pointer as i64
    return LLVMBuildPtrToInt(builder, raw_ptr, i64);
}
```

### Field Access (line 854)

For `point.x`:

```zig
fn codegenFieldAccess(self: *Codegen, object: *Expr, field_name: []const u8) !LLVMValueRef {
    // 1. Codegen the object (should be an i64 pointer)
    const obj_val = try self.codegenExpr(object);

    // 2. Look up the record type from variable tracking
    const record_name = self.variable_types.get(object.identifier);

    // 3. Find the field index
    const info = self.record_types.get(record_name);
    for (info.fields) |fi, i| {
        if (std.mem.eql(u8, fi.name, field_name)) {
            // 4. Convert i64 back to pointer, GEP to field, load
            const record_ptr = LLVMBuildIntToPtr(builder, obj_val, ptr_type, "record_ptr");
            var gep_indices = [2]LLVMValueRef{ const_int(0), const_int(i) };
            const field_ptr = LLVMBuildGEP2(builder, info.llvm_type, record_ptr, &gep_indices, 2, "field_ptr");
            return LLVMBuildLoad2(builder, fi.llvm_type, field_ptr, "field_val");
        }
    }
}
```

## Tuples (line 924)

Tuples are heap-allocated arrays of i64 values:

```zig
fn codegenTuple(self: *Codegen, elems: []const *Expr) !LLVMValueRef {
    if (elems.len == 0) return const_int(0);  // () → 0
    if (elems.len == 1) return try self.codegenExpr(elems[0]);  // (x,) → x

    // Allocate: N * 8 bytes
    const size = const_int(elems.len * 8);
    const raw_ptr = call_ko_alloc(size);

    // Store each element at byte offset i * 8
    for (elems, 0..) |elem, i| {
        const val = try self.codegenExpr(elem);
        const offset = const_int(i * 8);
        const elem_ptr = LLVMBuildGEP2(builder, i8_type, raw_ptr, &offset, 1, "elem_off");
        LLVMBuildStore(builder, val, elem_ptr);
    }

    return LLVMBuildPtrToInt(builder, raw_ptr, i64);
}
```

## Lambdas (line 953)

Lambdas become anonymous LLVM functions:

```zig
fn codegenLambda(self: *Codegen, params: []const Pattern, body: *Expr) !LLVMValueRef {
    // 1. Create function type: (i64, i64, ...) -> i64
    const fn_type = LLVMFunctionType(i64_type, &param_types, params.len, 0);

    // 2. Create anonymous function
    const func = LLVMAddFunction(module, "lambda_12345", fn_type);
    const entry = LLVMAppendBasicBlock(func, "entry");
    PositionBuilderAtEnd(builder, entry);

    // 3. Save outer scope, create new scope for lambda body
    const old_values = self.named_values;
    self.named_values = StringHashMap.init(allocator);
    // Copy outer scope into lambda (captures)
    var iter = old_values.iterator();
    while (iter.next()) |entry| {
        try self.named_values.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // 4. Add parameters
    for (params, 0..) |param, i| {
        const param_val = LLVMGetParam(func, @intCast(i));
        LLVMSetValueName(param_val, param_name_z);
        try self.named_values.put(param.name, param_val);
    }

    // 5. Codegen body
    const body_val = try self.codegenExpr(body);
    LLVMBuildRet(builder, body_val);

    // 6. Restore outer scope
    self.named_values.deinit();
    self.named_values = old_values;

    // 7. Return function pointer as i64
    return LLVMBuildPtrToInt(builder, func, i64);
}
```

**Note:** This is a simplified closure model. Currently, lambdas capture the entire outer scope by copying. A more efficient model would only capture used variables.

## Reference Counting

### Memory Layout

```
[ i64 rc ][ ... user data ... ]
^         ^
|         pointer returned by ko_alloc (what codegen sees)
raw malloc ptr
```

### Runtime Functions (in `ko_runtime.c`)

- `ko_alloc(user_size)` — allocate with RC header (rc=1), return pointer to user data
- `ko_incref(ptr)` — increment RC, return ptr
- `ko_decref(ptr)` — decrement RC, free if rc<=0

### Codegen Integration

All heap allocations use `ko_alloc`:

```zig
const alloc_fn = self.named_values.get("ko_alloc");
const raw_ptr = LLVMBuildCall2(builder, alloc_fn_type, alloc_fn, &alloc_args, 1, "alloc");
```

Scope-exit decref tracks heap values:

```zig
// Track for later decref
self.scope_heap_values.append(raw_ptr);

// Before function return, decref all tracked values except return value
for (self.scope_heap_values.items) |val| {
    if (val != return_val) {
        LLVMBuildCall2(builder, decref_type, decref_fn, &.{val}, 1, "");
    }
}
```

## JIT Execution (line ~1700)

```zig
pub fn codegenProgram(self: *Codegen, program: Program) !void {
    // ... declare and codegen all functions ...

    // Initialize LLVM JIT
    _ = LLVMInitializeNativeTarget();
    _ = LLVMInitializeNativeAsmParser();
    _ = LLVMInitializeNativeAsmPrinter();
    LLVMLinkInMCJIT();

    // Create JIT engine (takes ownership of module)
    var engine: LLVMExecutionEngineRef = undefined;
    LLVMCreateJITCompilerForModule(&engine, self.module, 2, 0);
    self.module_owned_by_jit = true;

    // Map C functions to LLVM symbols
    self.mapBuiltinsToNative(engine);

    // Get function pointer for "main"
    const fn_addr = LLVMGetFunctionAddress(engine, "main");
    const main_fn: *const fn () callconv(.c) i64 = @ptrFromInt(fn_addr);
    const result = main_fn();
}
```

## AOT Compilation (line ~1750)

```zig
pub fn emitObjectFile(self: *Codegen, filename: []const u8) !void {
    // Get target triple
    const triple = LLVMGetDefaultTargetTriple();

    // Create target machine
    var t: LLVMTargetRef = undefined;
    LLVMGetTargetFromTriple(triple, &t, &error_msg);
    const tm = LLVMCreateTargetMachine(t, triple, "x86-64", "",
        .LLVMCodeGenLevelDefault, .LLVMRelocPIC, .LLVMCodeModelDefault);

    // Set data layout
    const dl = LLVMCreateTargetDataLayout(tm);
    LLVMSetModuleDataLayout(self.module, dl);

    // Emit object file
    LLVMTargetMachineEmitToFile(tm, self.module, filename, .LLVMObjectFile, &err);
}
```

## Summary: What Happens for `fn add x y = x + y`

```
1. declareFn:
   → define i64 @add(i64 %x, i64 %y)

2. codegenFn:
   → entry block:
     %x = parameter 0
     %y = parameter 1
     %add = add i64 %x, %y
     ret i64 %add

3. JIT: get function pointer for @add, call it with (3, 4) → returns 7
   AOT: write .o file, link with ld → executable
```

## Summary: What Happens for `match x | Nil => 0 | Cons h t => h`

```
1. Extract tag from x (and with mask, or shift)
2. Compare tag to 0 (Nil):
   - equal → jump to Nil arm, return 0
   - not equal → compare tag to 1 (Cons):
     - equal → jump to Cons arm
       - extract h from x+8 (load from offset)
       - return h
     - not equal → unreachable (trap)
3. Merge: phi(0 from Nil, h from Cons)
```
