const std = @import("std");
const llvm = @import("llvm");
const core = llvm.core;
const types = llvm.types;
const engine = llvm.engine;
const target = llvm.target;
const target_machine = llvm.target_machine;
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");

const CtorInfo = struct { type_name: []const u8, tag: i64, arity: u32 };

const RecordFieldInfo = struct {
    name: []const u8,
    llvm_type: types.LLVMTypeRef,
    index: u32,
};

const RecordInfo = struct {
    name: []const u8,
    fields: []const RecordFieldInfo,
    llvm_type: types.LLVMTypeRef,
};

pub const Codegen = struct {
    allocator: std.mem.Allocator,
    context: types.LLVMContextRef,
    module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,
    named_values: std.StringHashMap(types.LLVMValueRef),
    variable_types: std.StringHashMap([]const u8), // variable name → record type name
    fn_types: std.StringHashMap(types.LLVMTypeRef),
    fn_arity: std.StringHashMap(u32), // function name → arity (number of params)
    constructor_tags: std.StringHashMap(CtorInfo),
    record_types: std.StringHashMap(RecordInfo),
    module_owned_by_jit: bool = false,
    current_fn_name: ?[]const u8 = null,
    current_fn_val: ?types.LLVMValueRef = null,
    current_module: ?[]const u8 = null,
    scope_heap_values: std.ArrayList(types.LLVMValueRef) = .empty, // heap-allocated values to decref on scope exit

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) Codegen {
        const ctx = core.LLVMContextCreate();
        const mod = core.LLVMModuleCreateWithNameInContext(module_name, ctx);
        // Set data layout so we can compute type sizes
        core.LLVMSetDataLayout(mod, "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128");
        return .{
            .allocator = allocator,
            .context = ctx,
            .module = mod,
            .builder = core.LLVMCreateBuilderInContext(ctx),
            .named_values = std.StringHashMap(types.LLVMValueRef).init(allocator),
            .variable_types = std.StringHashMap([]const u8).init(allocator),
            .fn_types = std.StringHashMap(types.LLVMTypeRef).init(allocator),
            .fn_arity = std.StringHashMap(u32).init(allocator),
            .constructor_tags = std.StringHashMap(CtorInfo).init(allocator),
            .record_types = std.StringHashMap(RecordInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.scope_heap_values.deinit(self.allocator);
        self.record_types.deinit();
        self.constructor_tags.deinit();
        self.fn_arity.deinit();
        self.fn_types.deinit();
        self.variable_types.deinit();
        self.named_values.deinit();
        core.LLVMDisposeBuilder(self.builder);
        if (!self.module_owned_by_jit) {
            core.LLVMDisposeModule(self.module);
        }
        core.LLVMContextDispose(self.context);
    }

    fn dupeZ(self: *Codegen, s: []const u8) ![*:0]const u8 {
        return try self.allocator.dupeZ(u8, s);
    }

    /// Compute the store size of an LLVM type as an i64 constant
    fn storeSize(self: *Codegen, ty: types.LLVMTypeRef) types.LLVMValueRef {
        const dl = target.LLVMGetModuleDataLayout(self.module);
        const size = target.LLVMStoreSizeOfType(dl, ty);
        return core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @intCast(size), 0);
    }

    // =========================================================================
    // Type mapping: Kō types → LLVM types
    // =========================================================================

    pub fn koTypeToLlvm(self: *Codegen, ty: typecheck.Type) types.LLVMTypeRef {
        return switch (ty) {
            .int => core.LLVMInt64TypeInContext(self.context),
            .float => core.LLVMDoubleTypeInContext(self.context),
            .bool => core.LLVMInt1TypeInContext(self.context),
            .string => core.LLVMPointerTypeInContext(self.context, 0),
            .char => core.LLVMInt8TypeInContext(self.context),
            .unit => core.LLVMVoidTypeInContext(self.context),
            .arrow => |a| blk: {
                _ = a;
                break :blk core.LLVMPointerTypeInContext(self.context, 0);
            },
            .tuple => |elems| blk: {
                var llvm_elems: [32]types.LLVMTypeRef = undefined;
                for (elems, 0..) |elem, i| {
                    llvm_elems[i] = self.koTypeToLlvm(elem.*);
                }
                break :blk core.LLVMStructTypeInContext(self.context, &llvm_elems, @intCast(elems.len), 0);
            },
            .con => |c| blk: {
                _ = c;
                break :blk core.LLVMInt64TypeInContext(self.context);
            },
            .record => |r| blk: {
                var field_types: [32]types.LLVMTypeRef = undefined;
                for (r.fields, 0..) |field, i| {
                    field_types[i] = self.koTypeToLlvm(field.ty);
                }
                break :blk core.LLVMStructTypeInContext(self.context, &field_types, @intCast(r.fields.len), 0);
            },
            .variable => core.LLVMInt64TypeInContext(self.context),
            .@"ref" => core.LLVMPointerTypeInContext(self.context, 0),
        };
    }

    // =========================================================================
    // Built-in function declarations (println, print)
    // =========================================================================

    pub fn declareBuiltins(self: *Codegen) void {
        const i64_type = core.LLVMInt64TypeInContext(self.context);
        const ptr_type = core.LLVMPointerTypeInContext(self.context, 0);

        var param_i64: [1]types.LLVMTypeRef = .{i64_type};

        // println(i64) -> i64 (returns 0)
        const println_type = core.LLVMFunctionType(i64_type, &param_i64, 1, 0);
        const println_fn = core.LLVMAddFunction(self.module, "println", println_type);
        _ = self.named_values.put("println", println_fn) catch {};

        // print(i64) -> i64 (returns 0)
        const print_type = core.LLVMFunctionType(i64_type, &param_i64, 1, 0);
        const print_fn = core.LLVMAddFunction(self.module, "print", print_type);
        _ = self.named_values.put("print", print_fn) catch {};

        // inspect(i64, i64, ptr) -> i64 (value, type_tag, name_ptr -> returns value)
        var inspect_params: [3]types.LLVMTypeRef = .{ i64_type, i64_type, ptr_type };
        const inspect_type = core.LLVMFunctionType(i64_type, &inspect_params, 3, 0);
        const inspect_fn = core.LLVMAddFunction(self.module, "inspect", inspect_type);
        _ = self.named_values.put("inspect", inspect_fn) catch {};

        // malloc(i64) -> ptr
        var malloc_params: [1]types.LLVMTypeRef = .{i64_type};
        const malloc_type = core.LLVMFunctionType(ptr_type, &malloc_params, 1, 0);
        const malloc_fn = core.LLVMAddFunction(self.module, "malloc", malloc_type);
        _ = self.named_values.put("malloc", malloc_fn) catch {};

        // free(ptr) -> void
        var free_params: [1]types.LLVMTypeRef = .{ptr_type};
        const free_type = core.LLVMFunctionType(core.LLVMVoidTypeInContext(self.context), &free_params, 1, 0);
        const free_fn = core.LLVMAddFunction(self.module, "free", free_type);
        _ = self.named_values.put("free", free_fn) catch {};

        // ko_alloc(i64) -> ptr — allocate with RC header, returns pointer to user data
        var ko_alloc_params: [1]types.LLVMTypeRef = .{i64_type};
        const ko_alloc_type = core.LLVMFunctionType(ptr_type, &ko_alloc_params, 1, 0);
        const ko_alloc_fn = core.LLVMAddFunction(self.module, "ko_alloc", ko_alloc_type);
        _ = self.named_values.put("ko_alloc", ko_alloc_fn) catch {};

        // ko_incref(ptr) -> ptr — increment refcount, return ptr
        var ko_incref_params: [1]types.LLVMTypeRef = .{ptr_type};
        const ko_incref_type = core.LLVMFunctionType(ptr_type, &ko_incref_params, 1, 0);
        const ko_incref_fn = core.LLVMAddFunction(self.module, "ko_incref", ko_incref_type);
        _ = self.named_values.put("ko_incref", ko_incref_fn) catch {};

        // ko_decref(ptr) -> void — decrement refcount, free if 0
        var ko_decref_params: [1]types.LLVMTypeRef = .{ptr_type};
        const ko_decref_type = core.LLVMFunctionType(core.LLVMVoidTypeInContext(self.context), &ko_decref_params, 1, 0);
        const ko_decref_fn = core.LLVMAddFunction(self.module, "ko_decref", ko_decref_type);
        _ = self.named_values.put("ko_decref", ko_decref_fn) catch {};
    }

    pub fn mapBuiltinsToNative(self: *Codegen, jit_engine: types.LLVMExecutionEngineRef) void {
        const println_fn = self.named_values.get("println") orelse return;
        const print_fn = self.named_values.get("print") orelse return;
        const inspect_fn = self.named_values.get("inspect") orelse return;
        engine.LLVMAddGlobalMapping(jit_engine, println_fn, @constCast(@ptrCast(&builtin_println)));
        engine.LLVMAddGlobalMapping(jit_engine, print_fn, @constCast(@ptrCast(&builtin_print)));
        engine.LLVMAddGlobalMapping(jit_engine, inspect_fn, @constCast(@ptrCast(&builtin_inspect)));

        // Map malloc/free to system implementations
        if (self.named_values.get("malloc")) |malloc_fn| {
            engine.LLVMAddGlobalMapping(jit_engine, malloc_fn, @constCast(@ptrCast(&malloc_wrapper)));
        }
        if (self.named_values.get("free")) |free_fn| {
            engine.LLVMAddGlobalMapping(jit_engine, free_fn, @constCast(@ptrCast(&free_wrapper)));
        }

        // Map RC functions to native implementations
        if (self.named_values.get("ko_alloc")) |ko_alloc_fn| {
            engine.LLVMAddGlobalMapping(jit_engine, ko_alloc_fn, @constCast(@ptrCast(&ko_alloc_wrapper)));
        }
        if (self.named_values.get("ko_incref")) |ko_incref_fn| {
            engine.LLVMAddGlobalMapping(jit_engine, ko_incref_fn, @constCast(@ptrCast(&ko_incref_wrapper)));
        }
        if (self.named_values.get("ko_decref")) |ko_decref_fn| {
            engine.LLVMAddGlobalMapping(jit_engine, ko_decref_fn, @constCast(@ptrCast(&ko_decref_wrapper)));
        }
    }

    // =========================================================================
    // Type definitions (sum types / ADTs)
    // =========================================================================

    /// Register type definitions (sum types and record types)
    pub fn registerTypeDef(self: *Codegen, type_def: parser.TypeDef) Error!void {
        switch (type_def.body) {
            .sum => |ctors| {
                for (ctors, 0..) |ctor, i| {
                    try self.constructor_tags.put(ctor.name, .{
                        .type_name = type_def.name,
                        .tag = @intCast(i),
                        .arity = @intCast(ctor.params.len),
                    });
                }
            },
            .record => |fields| {
                // Build LLVM struct type for this record
                var field_types: [32]types.LLVMTypeRef = undefined;
                var field_infos: [32]RecordFieldInfo = undefined;
                for (fields, 0..) |field, i| {
                    const llvm_ty = self.koTypeToLlvmFromTypeExpr(field.type_expr);
                    field_types[i] = llvm_ty;
                    field_infos[i] = .{
                        .name = field.name,
                        .llvm_type = llvm_ty,
                        .index = @intCast(i),
                    };
                }
                const struct_ty = core.LLVMStructTypeInContext(self.context, &field_types, @intCast(fields.len), 0);
                try self.record_types.put(type_def.name, .{
                    .name = type_def.name,
                    .fields = try self.allocator.dupe(RecordFieldInfo, field_infos[0..fields.len]),
                    .llvm_type = struct_ty,
                });
            },
        }
    }

    /// Convert a TypeExpr to an LLVM type (for record field types during registration)
    fn koTypeToLlvmFromTypeExpr(self: *Codegen, type_expr: parser.TypeExpr) types.LLVMTypeRef {
        return switch (type_expr) {
            .ident => |name| blk: {
                if (std.mem.eql(u8, name, "Int")) break :blk core.LLVMInt64TypeInContext(self.context);
                if (std.mem.eql(u8, name, "Float")) break :blk core.LLVMDoubleTypeInContext(self.context);
                if (std.mem.eql(u8, name, "Bool")) break :blk core.LLVMInt1TypeInContext(self.context);
                if (std.mem.eql(u8, name, "String")) break :blk core.LLVMPointerTypeInContext(self.context, 0);
                if (std.mem.eql(u8, name, "Char")) break :blk core.LLVMInt8TypeInContext(self.context);
                // Unknown type name — default to i64
                break :blk core.LLVMInt64TypeInContext(self.context);
            },
            .constructor => |name| blk: {
                // Named type (e.g., a sum type) — default to i64
                _ = name;
                break :blk core.LLVMInt64TypeInContext(self.context);
            },
            else => core.LLVMInt64TypeInContext(self.context),
        };
    }

    // =========================================================================
    // Expression codegen
    // =========================================================================

    pub fn codegenExpr(self: *Codegen, expr: *const parser.Expr) Error!types.LLVMValueRef {
        return switch (expr.*) {
            .int_literal => |val| core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(@as(i64, val)), 0),
            .float_literal => |val| core.LLVMConstReal(core.LLVMDoubleTypeInContext(self.context), val),
            .bool_literal => |val| core.LLVMConstInt(core.LLVMInt1TypeInContext(self.context), @intFromBool(val), 0),
            .char_literal => |val| blk: {
                // Char literal is a single character, represent as i64
                if (val.len == 0) break :blk core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0);
                break :blk core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), val[0], 0);
            },
            .string_literal => |val| blk: {
                // Create a global string constant and return a pointer to it
                const str_val = core.LLVMConstStringInContext(self.context, @ptrCast(val.ptr), @intCast(val.len), 0);
                const global = core.LLVMAddGlobal(self.module, core.LLVMTypeOf(str_val), "str");
                core.LLVMSetInitializer(global, str_val);
                core.LLVMSetGlobalConstant(global, 1);
                core.LLVMSetLinkage(global, .LLVMPrivateLinkage);
                // Return a pointer to the first element via GEP
                var indices: [1]types.LLVMValueRef = .{
                    core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0),
                };
                break :blk core.LLVMBuildGEP2(
                    self.builder,
                    core.LLVMInt8TypeInContext(self.context),
                    global,
                    &indices,
                    1,
                    "str_ptr",
                );
            },
            .identifier => |name| {
                if (self.named_values.get(name)) |val| return val;
                return error.UndefinedVariable;
            },
            .constructor => |name| {
                // Constructor used as a value (no args) — return its tag
                if (self.constructor_tags.get(name)) |info| {
                    return core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(info.tag), 0);
                }
                return error.UndefinedVariable;
            },
            .binary_op => |b| try self.codegenBinaryOp(b.op, b.left, b.right),
            .unary_op => |u| try self.codegenUnaryOp(u.op, u.expr),
            .fn_call => |call| try self.codegenFnCall(call),
            .if_expr => |i| try self.codegenIf(i),
            .block => |items| try self.codegenBlock(items),
            .let_expr => |l| try self.codegenLetExpr(l),
            .match_expr => |m| try self.codegenMatch(m.value, m.arms),
            .record_literal => |r| try self.codegenRecordLiteral(r.name, r.fields),
            .field_access => |fa| try self.codegenFieldAccess(fa.object, fa.field),
            .tuple => |elems| try self.codegenTuple(elems),
            .lambda => |lam| try self.codegenLambda(lam.params, lam.body),
            .comptime_expr => |inner| try self.codegenExpr(inner),
            .assign_expr => |a| try self.codegenAssign(a.target, a.value),
            .ref_expr => |inner| try self.codegenRefExpr(inner),
            else => error.NotYetImplemented,
        };
    }

    fn codegenBinaryOp(self: *Codegen, op: parser.BinaryOp, left: *const parser.Expr, right: *const parser.Expr) Error!types.LLVMValueRef {
        const l = try self.codegenExpr(left);
        const r = try self.codegenExpr(right);
        const name: [*:0]const u8 = switch (op) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "sdiv",
            .mod => "srem",
            .eq => "eq",
            .neq => "neq",
            .lt => "slt",
            .lte => "sle",
            .gt => "sgt",
            .gte => "sge",
            .and_op => "and",
            .or_op => "or",
            .pipe => "pipe",
        };

        return switch (op) {
            .add => core.LLVMBuildAdd(self.builder, l, r, name),
            .sub => core.LLVMBuildSub(self.builder, l, r, name),
            .mul => core.LLVMBuildMul(self.builder, l, r, name),
            .div => core.LLVMBuildSDiv(self.builder, l, r, name),
            .mod => core.LLVMBuildSRem(self.builder, l, r, name),
            .eq, .neq, .lt, .lte, .gt, .gte => blk: {
                const cmp = core.LLVMBuildICmp(self.builder, self.intPredicate(op), l, r, "cmp");
                break :blk core.LLVMBuildZExt(self.builder, cmp, core.LLVMInt64TypeInContext(self.context), "bool_ext");
            },
            .and_op => core.LLVMBuildAnd(self.builder, l, r, name),
            .or_op => core.LLVMBuildOr(self.builder, l, r, name),
            .pipe => return error.NotYetImplemented,
        };
    }

    fn intPredicate(self: *Codegen, op: parser.BinaryOp) types.LLVMIntPredicate {
        _ = self;
        return switch (op) {
            .eq => .LLVMIntEQ,
            .neq => .LLVMIntNE,
            .lt => .LLVMIntSLT,
            .lte => .LLVMIntSLE,
            .gt => .LLVMIntSGT,
            .gte => .LLVMIntSGE,
            else => unreachable,
        };
    }

    fn codegenUnaryOp(self: *Codegen, op: parser.UnaryOp, expr: *const parser.Expr) Error!types.LLVMValueRef {
        const val = try self.codegenExpr(expr);
        return switch (op) {
            .neg => core.LLVMBuildNeg(self.builder, val, "neg"),
            .not => core.LLVMBuildNot(self.builder, val, "not"),
            .ref => val,
            .deref => {
                const ptr = core.LLVMBuildIntToPtr(self.builder, val, core.LLVMPointerTypeInContext(self.context, 0), "deref_ptr");
                return core.LLVMBuildLoad2(self.builder, core.LLVMInt64TypeInContext(self.context), ptr, "deref");
            },
        };
    }

    fn codegenAssign(self: *Codegen, lhs: *const parser.Expr, value: *const parser.Expr) Error!types.LLVMValueRef {
        const ptr_val = try self.codegenExpr(lhs);
        const val = try self.codegenExpr(value);
        const ptr = core.LLVMBuildIntToPtr(self.builder, ptr_val, core.LLVMPointerTypeInContext(self.context, 0), "assign_ptr");
        _ = core.LLVMBuildStore(self.builder, val, ptr);
        return core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0);
    }

    fn codegenRefExpr(self: *Codegen, inner: *const parser.Expr) Error!types.LLVMValueRef {
        const val = try self.codegenExpr(inner);
        const i64_type = core.LLVMInt64TypeInContext(self.context);
        const size = core.LLVMConstInt(i64_type, 8, 0);
        var alloc_args: [1]types.LLVMValueRef = .{size};
        const alloc_fn = self.named_values.get("ko_alloc") orelse return error.UndefinedVariable;
        const alloc_fn_type = core.LLVMGlobalGetValueType(alloc_fn);
        const raw_ptr = core.LLVMBuildCall2(self.builder, alloc_fn_type, alloc_fn, &alloc_args, 1, "ref_alloc");
        self.scope_heap_values.append(self.allocator, raw_ptr) catch {};
        _ = core.LLVMBuildStore(self.builder, val, raw_ptr);
        return core.LLVMBuildPtrToInt(self.builder, raw_ptr, i64_type, "ref_val");
    }

    /// Create a global string constant and return a pointer to it as LLVMValueRef
    fn globalStringConstant(self: *Codegen, slice: []const u8) types.LLVMValueRef {
        const str_val = core.LLVMConstStringInContext(self.context, @ptrCast(slice.ptr), @intCast(slice.len), 0);
        const global = core.LLVMAddGlobal(self.module, core.LLVMTypeOf(str_val), "str");
        core.LLVMSetInitializer(global, str_val);
        core.LLVMSetGlobalConstant(global, 1);
        core.LLVMSetLinkage(global, .LLVMPrivateLinkage);
        var indices: [1]types.LLVMValueRef = .{
            core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0),
        };
        return core.LLVMBuildGEP2(
            self.builder,
            core.LLVMInt8TypeInContext(self.context),
            global,
            &indices,
            1,
            "str_ptr",
        );
    }

    /// Create a partial application closure for a global function called with fewer args than its arity.
    /// Generates a wrapper function and a closure struct: { fn_ptr, total_arity, applied_count, applied_args[] }
    /// Returns the closure pointer as i64 with bit 0 set (tag for partial application).
    fn createPartialApp(self: *Codegen, fn_name: []const u8, fn_val: types.LLVMValueRef, total_arity: u32, applied_args: []const types.LLVMValueRef) Error!types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);
        const applied_count: u32 = @intCast(applied_args.len);
        const remaining_arity = total_arity - applied_count;

        // Generate unique wrapper name
        const wrapper_name = try std.fmt.allocPrint(self.allocator, "partial_{s}_{d}", .{ fn_name, applied_count });
        defer self.allocator.free(wrapper_name);
        const wrapper_name_z = try self.dupeZ(wrapper_name);

        // Wrapper signature: (ptr %closure, i64 %remaining_arg_1, ..., i64 %remaining_arg_N) -> i64
        var param_types: [33]types.LLVMTypeRef = undefined;
        param_types[0] = core.LLVMPointerTypeInContext(self.context, 0); // closure pointer
        for (0..remaining_arity) |i| {
            param_types[i + 1] = i64_type;
        }
        const wrapper_type = core.LLVMFunctionType(i64_type, &param_types, @intCast(remaining_arity + 1), 0);
        const wrapper_fn = core.LLVMAddFunction(self.module, wrapper_name_z, wrapper_type);

        // Generate wrapper body
        const saved_block = core.LLVMGetInsertBlock(self.builder);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, wrapper_fn, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        // Load applied args from closure
        var loaded_applied: [32]types.LLVMValueRef = undefined;
        for (0..applied_count) |i| {
            const offset = core.LLVMConstInt(i64_type, 24 + i * 8, 0);
            const applied_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), core.LLVMGetParam(wrapper_fn, 0), @constCast(&[_]types.LLVMValueRef{offset}), 1, "applied_ptr");
            loaded_applied[i] = core.LLVMBuildLoad2(self.builder, i64_type, applied_ptr, "applied");
        }

        // Build call args: [applied_0, ..., applied_N, remaining_0, ..., remaining_M]
        var call_args: [33]types.LLVMValueRef = undefined;
        for (0..applied_count) |i| {
            call_args[i] = loaded_applied[i];
        }
        for (0..remaining_arity) |i| {
            call_args[applied_count + i] = core.LLVMGetParam(wrapper_fn, @intCast(i + 1));
        }

        // Call original function
        const fn_type = core.LLVMGlobalGetValueType(fn_val);
        const result = core.LLVMBuildCall2(self.builder, fn_type, fn_val, &call_args, @intCast(total_arity), "partial_result");
        _ = core.LLVMBuildRet(self.builder, result);

        // Restore builder position
        core.LLVMPositionBuilderAtEnd(self.builder, saved_block);

        // Create closure struct on heap: { fn_ptr, total_arity, applied_count, applied_args[] }
        const struct_size: u64 = 24 + applied_count * 8;
        const size_val = core.LLVMConstInt(i64_type, struct_size, 0);
        var alloc_args: [1]types.LLVMValueRef = .{size_val};
        const alloc_fn = self.named_values.get("ko_alloc") orelse return error.UndefinedVariable;
        const alloc_fn_type = core.LLVMGlobalGetValueType(alloc_fn);
        const closure_ptr = core.LLVMBuildCall2(self.builder, alloc_fn_type, alloc_fn, &alloc_args, 1, "closure");
        self.scope_heap_values.append(self.allocator, closure_ptr) catch {};

        // Store fn_ptr at offset 0
        const fn_ptr_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), closure_ptr, @constCast(&[_]types.LLVMValueRef{core.LLVMConstInt(i64_type, 0, 0)}), 1, "fn_ptr_ptr");
        _ = core.LLVMBuildStore(self.builder, wrapper_fn, fn_ptr_ptr);

        // Store total_arity at offset 8
        const arity_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), closure_ptr, @constCast(&[_]types.LLVMValueRef{core.LLVMConstInt(i64_type, 8, 0)}), 1, "arity_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(i64_type, total_arity, 0), arity_ptr);

        // Store applied_count at offset 16
        const count_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), closure_ptr, @constCast(&[_]types.LLVMValueRef{core.LLVMConstInt(i64_type, 16, 0)}), 1, "count_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(i64_type, applied_count, 0), count_ptr);

        // Store applied args at offsets 24+
        for (applied_args, 0..) |arg, i| {
            const offset = core.LLVMConstInt(i64_type, 24 + i * 8, 0);
            const applied_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), closure_ptr, @constCast(&[_]types.LLVMValueRef{offset}), 1, "applied_ptr");
            _ = core.LLVMBuildStore(self.builder, arg, applied_ptr);
        }

        // Return closure pointer with bit 0 set (tag for partial application)
        const closure_i64 = core.LLVMBuildPtrToInt(self.builder, closure_ptr, i64_type, "closure_as_int");
        return core.LLVMBuildOr(self.builder, closure_i64, core.LLVMConstInt(i64_type, 1, 0), "tagged_closure");
    }

    fn codegenFnCall(self: *Codegen, call: parser.FnCallExpr) Error!types.LLVMValueRef {
        // Check if this is a constructor call (e.g., Some 42)
        if (call.func.* == .constructor) {
            const name = call.func.constructor;
            if (self.constructor_tags.get(name)) |info| {
                // Zero-arg constructor: return the tag
                if (call.args.len == 0) {
                    return core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(info.tag), 0);
                }
                // Constructor with args: allocate tagged struct on heap, store tag + args
                const i64_type = core.LLVMInt64TypeInContext(self.context);
                // For single-arg constructors, pack the value with the tag
                if (call.args.len == 1) {
                    const arg_val = try self.codegenExpr(call.args[0]);
                    // Create { i64, <arg_type> } struct
                    const arg_type = core.LLVMTypeOf(arg_val);
                    var struct_fields: [2]types.LLVMTypeRef = .{ i64_type, arg_type };
                    const tagged_type = core.LLVMStructTypeInContext(self.context, &struct_fields, 2, 0);
                    // Allocate on heap via ko_alloc
                    const alloc_fn = self.named_values.get("ko_alloc") orelse return error.UndefinedVariable;
                    const alloc_fn_type = core.LLVMGlobalGetValueType(alloc_fn);
                    const size_val = self.storeSize(tagged_type);
                    var alloc_args: [1]types.LLVMValueRef = .{size_val};
                    const raw_ptr = core.LLVMBuildCall2(self.builder, alloc_fn_type, alloc_fn, &alloc_args, 1, "tagged_alloc");
                    self.scope_heap_values.append(self.allocator, raw_ptr) catch {};
                    // Store tag + value
                    const tag_val = core.LLVMConstInt(i64_type, @bitCast(info.tag), 0);
                    var tag_gep_indices: [2]types.LLVMValueRef = .{
                        core.LLVMConstInt(i64_type, 0, 0),
                        core.LLVMConstInt(i64_type, 0, 0),
                    };
                    const tag_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, raw_ptr, @ptrCast(&tag_gep_indices), 2, "tag_ptr");
                    _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);
                    var val_gep_indices: [2]types.LLVMValueRef = .{
                        core.LLVMConstInt(i64_type, 0, 0),
                        core.LLVMConstInt(i64_type, 1, 0),
                    };
                    const val_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, raw_ptr, @ptrCast(&val_gep_indices), 2, "val_ptr");
                    _ = core.LLVMBuildStore(self.builder, arg_val, val_ptr);
                    // Return pointer as i64
                    return core.LLVMBuildPtrToInt(self.builder, raw_ptr, i64_type, "tagged_ptr");
                }
                // Multi-arg constructors: allocate tagged struct on heap with tag + all args
                var struct_fields: [33]types.LLVMTypeRef = undefined;
                struct_fields[0] = i64_type;
                var arg_vals: [32]types.LLVMValueRef = undefined;
                for (call.args, 0..) |arg, i| {
                    const arg_val = try self.codegenExpr(arg);
                    struct_fields[i + 1] = core.LLVMTypeOf(arg_val);
                    arg_vals[i] = arg_val;
                }
                const tagged_type = core.LLVMStructTypeInContext(self.context, &struct_fields, @intCast(call.args.len + 1), 0);
                // Allocate on heap via ko_alloc
                const alloc_fn = self.named_values.get("ko_alloc") orelse return error.UndefinedVariable;
                const alloc_fn_type = core.LLVMGlobalGetValueType(alloc_fn);
                const size_val = self.storeSize(tagged_type);
                var alloc_args: [1]types.LLVMValueRef = .{size_val};
                const raw_ptr = core.LLVMBuildCall2(self.builder, alloc_fn_type, alloc_fn, &alloc_args, 1, "tagged_alloc");
                self.scope_heap_values.append(self.allocator, raw_ptr) catch {};
                // Store tag at index 0
                const tag_val = core.LLVMConstInt(i64_type, @bitCast(info.tag), 0);
                var tag_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 0, 0) };
                const tag_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, raw_ptr, @ptrCast(&tag_gep), 2, "tag_ptr");
                _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);
                // Store each arg at index 1..N
                for (0..call.args.len) |i| {
                    var val_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, i + 1, 0) };
                    const val_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, raw_ptr, @ptrCast(&val_gep), 2, "val_ptr");
                    _ = core.LLVMBuildStore(self.builder, arg_vals[i], val_ptr);
                }
                return core.LLVMBuildPtrToInt(self.builder, raw_ptr, i64_type, "tagged_ptr");
            }
        }

        // Check if this is a built-in call (println/print/inspect)
        if (call.func.* == .identifier) {
            const name = call.func.identifier;
            if (self.named_values.get(name)) |fn_val| {
                if (std.mem.eql(u8, name, "println") or std.mem.eql(u8, name, "print")) {
                    if (call.args.len == 1) {
                        const arg_val = try self.codegenExpr(call.args[0]);
                        var args: [1]types.LLVMValueRef = .{arg_val};
                        const fn_type = core.LLVMGlobalGetValueType(fn_val);
                        return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, 1, "builtin_call");
                    }
                }
                if (std.mem.eql(u8, name, "inspect")) {
                    if (call.args.len == 1) {
                        var arg_val = try self.codegenExpr(call.args[0]);
                        const arg_expr = call.args[0];
                        // String literals produce ptr, but inspect expects i64 — convert
                        if (arg_expr.* == .string_literal) {
                            arg_val = core.LLVMBuildPtrToInt(self.builder, arg_val, core.LLVMInt64TypeInContext(self.context), "str_as_int");
                        }
                        const type_tag: i64 = switch (arg_expr.*) {
                            .int_literal => 0,
                            .float_literal => 1,
                            .bool_literal => 2,
                            .char_literal => 3,
                            .string_literal => 4,
                            .constructor => 6,
                            .record_literal => 7,
                            .fn_call => 8,
                            .lambda => 8,
                            .tuple => 9,
                            .identifier => 100,
                            else => 100,
                        };
                        var name_ptr_val: types.LLVMValueRef = core.LLVMConstNull(core.LLVMPointerTypeInContext(self.context, 0));
                        if (arg_expr.* == .constructor) {
                            name_ptr_val = self.globalStringConstant(arg_expr.constructor);
                        } else if (arg_expr.* == .identifier) {
                            name_ptr_val = self.globalStringConstant(arg_expr.identifier);
                        } else if (arg_expr.* == .record_literal) {
                            name_ptr_val = self.globalStringConstant(arg_expr.record_literal.name);
                        }
                        const tag_val = core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(type_tag), 0);
                        var args: [3]types.LLVMValueRef = .{ arg_val, tag_val, name_ptr_val };
                        const fn_type = core.LLVMGlobalGetValueType(fn_val);
                        return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, 3, "inspect_call");
                    }
                }
            }
        }

        const fn_val = try self.codegenExpr(call.func);

        var args: [32]types.LLVMValueRef = undefined;
        var argc: c_uint = 0;
        for (call.args) |arg| {
            args[argc] = try self.codegenExpr(arg);
            argc += 1;
        }

        const i64_type = core.LLVMInt64TypeInContext(self.context);

        // Check if fn_val is a global function or an indirect pointer
        const is_global = core.LLVMIsAFunction(fn_val) != null;
        if (is_global) {
            // Look up the function's arity
            var fn_name: ?[]const u8 = null;
            // Try to find the name by checking named_values
            var name_iter = self.named_values.iterator();
            while (name_iter.next()) |entry| {
                if (entry.value_ptr.* == fn_val) {
                    fn_name = entry.key_ptr.*;
                    break;
                }
            }

            if (fn_name) |name| {
                if (self.fn_arity.get(name)) |arity| {
                    // Check if we have fewer args than the arity → partial application
                    if (argc < arity) {
                        return self.createPartialApp(name, fn_val, arity, args[0..argc]);
                    }
                    // Exact arity → direct call
                    if (argc == arity) {
                        const fn_type = core.LLVMGlobalGetValueType(fn_val);
                        return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, argc, "call");
                    }
                    // More args than arity → shouldn't happen with typechecker, but handle gracefully
                    // For now, just call with available args (may crash at runtime)
                    const fn_type = core.LLVMGlobalGetValueType(fn_val);
                    return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, argc, "call");
                }
            }
            // Fallback: direct call
            const fn_type = core.LLVMGlobalGetValueType(fn_val);
            return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, argc, "call");
        } else {
            // Check if bit 0 is set (partial application closure)
            // We need a runtime check: extract bit 0, branch accordingly
            const fn_entry_bb = core.LLVMGetInsertBlock(self.builder);
            const parent_fn = core.LLVMGetBasicBlockParent(fn_entry_bb);

            const partial_bb = core.LLVMAppendBasicBlockInContext(self.context, parent_fn, "partial_app");
            const direct_bb = core.LLVMAppendBasicBlockInContext(self.context, parent_fn, "direct_call");
            const merge_bb = core.LLVMAppendBasicBlockInContext(self.context, parent_fn, "call_merge");

            // Check bit 0
            const bit0_val = core.LLVMBuildAnd(self.builder, fn_val, core.LLVMConstInt(i64_type, 1, 0), "bit0");
            const is_partial_val = core.LLVMBuildICmp(self.builder, .LLVMIntNE, bit0_val, core.LLVMConstInt(i64_type, 0, 0), "is_partial");
            _ = core.LLVMBuildCondBr(self.builder, is_partial_val, partial_bb, direct_bb);

            // Partial application path
            core.LLVMPositionBuilderAtEnd(self.builder, partial_bb);
            // Clear bit 0 to get closure pointer
            // Clear bit 0 to get closure pointer (AND with ~1 = 0xFFFFFFFFFFFFFFFE)
            const mask = core.LLVMConstInt(i64_type, @bitCast(@as(i64, -2)), 0);
            const closure_i64 = core.LLVMBuildAnd(self.builder, fn_val, mask, "closure_raw");
            const closure_ptr = core.LLVMBuildIntToPtr(self.builder, closure_i64, core.LLVMPointerTypeInContext(self.context, 0), "closure_ptr");
            // Load fn_ptr from closure (offset 0)
            const fn_ptr_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), closure_ptr, @constCast(&[_]types.LLVMValueRef{core.LLVMConstInt(i64_type, 0, 0)}), 1, "fn_ptr_ptr");
            const loaded_fn_ptr = core.LLVMBuildLoad2(self.builder, core.LLVMPointerTypeInContext(self.context, 0), fn_ptr_ptr, "loaded_fn_ptr");
            // Build args: [closure_ptr, new_arg_0, ..., new_arg_N]
            var partial_args: [33]types.LLVMValueRef = undefined;
            partial_args[0] = closure_ptr;
            for (0..argc) |i| {
                partial_args[i + 1] = args[i];
            }
            var partial_param_types: [33]types.LLVMTypeRef = undefined;
            partial_param_types[0] = core.LLVMPointerTypeInContext(self.context, 0);
            for (0..argc) |i| {
                partial_param_types[i + 1] = i64_type;
            }
            const partial_fn_type = core.LLVMFunctionType(i64_type, &partial_param_types, @intCast(argc + 1), 0);
            const partial_result = core.LLVMBuildCall2(self.builder, partial_fn_type, loaded_fn_ptr, &partial_args, @intCast(argc + 1), "partial_call");
            _ = core.LLVMBuildBr(self.builder, merge_bb);

            // Direct call path (lambda)
            core.LLVMPositionBuilderAtEnd(self.builder, direct_bb);
            var param_types: [32]types.LLVMTypeRef = undefined;
            for (0..argc) |i| {
                param_types[i] = i64_type;
            }
            const fn_type = core.LLVMFunctionType(i64_type, &param_types, argc, 0);
            const fn_ptr = core.LLVMBuildIntToPtr(self.builder, fn_val, core.LLVMPointerTypeInContext(self.context, 0), "fn_ptr");
            const direct_result = core.LLVMBuildCall2(self.builder, fn_type, fn_ptr, &args, argc, "indirect_call");
            _ = core.LLVMBuildBr(self.builder, merge_bb);

            // Merge
            core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
            const phi = core.LLVMBuildPhi(self.builder, i64_type, "call_result");
            var incoming_vals: [2]types.LLVMValueRef = .{ partial_result, direct_result };
            var incoming_bbs: [2]types.LLVMBasicBlockRef = .{ partial_bb, direct_bb };
            core.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);
            return phi;
        }
    }

    fn codegenIf(self: *Codegen, if_expr: parser.IfExpr) Error!types.LLVMValueRef {
        const cond = try self.codegenExpr(if_expr.condition);
        const cond_bool = core.LLVMBuildICmp(self.builder, .LLVMIntNE, cond, core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0), "ifcond");

        const fn_val = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));

        const then_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "then");
        const else_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "else");
        const merge_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ifcont");

        _ = core.LLVMBuildCondBr(self.builder, cond_bool, then_bb, else_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
        const then_val = try self.codegenExpr(if_expr.then_branch);
        _ = core.LLVMBuildBr(self.builder, merge_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, else_bb);
        const else_val = if (if_expr.else_branch) |eb|
            try self.codegenExpr(eb)
        else
            core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0);
        _ = core.LLVMBuildBr(self.builder, merge_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        const phi = core.LLVMBuildPhi(self.builder, core.LLVMInt64TypeInContext(self.context), "iftmp");
        var incoming_vals: [2]types.LLVMValueRef = .{ then_val, else_val };
        var incoming_bbs: [2]types.LLVMBasicBlockRef = .{ then_bb, else_bb };
        core.LLVMAddIncoming(phi, &incoming_vals, &incoming_bbs, 2);

        return phi;
    }

    fn codegenBlock(self: *Codegen, items: []const *parser.Expr) Error!types.LLVMValueRef {
        var last = core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0);
        for (items) |item| {
            last = try self.codegenExpr(item);
        }
        return last;
    }

    fn codegenLetExpr(self: *Codegen, let: parser.LetExprExpr) Error!types.LLVMValueRef {
        const val = try self.codegenExpr(let.value);
        try self.named_values.put(let.name, val);
        // Track record type for field access
        if (let.value.* == .record_literal) {
            try self.variable_types.put(let.name, let.value.record_literal.name);
        }
        return try self.codegenExpr(let.body);
    }

    fn codegenRecordLiteral(self: *Codegen, name: []const u8, fields: []const parser.NamedArg) Error!types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);

        // Look up record type info — try bare name, then module-qualified, then suffix match
        var resolved_name = name;
        const info = self.record_types.get(name) orelse blk: {
            // Try all record types to find matching one by suffix
            var rt_iter = self.record_types.iterator();
            while (rt_iter.next()) |entry| {
                if (std.mem.endsWith(u8, entry.key_ptr.*, name) or std.mem.eql(u8, entry.key_ptr.*, name)) {
                    resolved_name = entry.key_ptr.*;
                    break :blk entry.value_ptr.*;
                }
            }
            return core.LLVMConstInt(i64_type, 0, 0);
        };

        // Compute size of record type
        const size_val = self.storeSize(info.llvm_type);

        // Allocate struct on heap via ko_alloc
        const alloc_fn = self.named_values.get("ko_alloc") orelse return error.UndefinedVariable;
        const fn_type = core.LLVMGlobalGetValueType(alloc_fn);
        var alloc_args: [1]types.LLVMValueRef = .{size_val};
        const raw_ptr = core.LLVMBuildCall2(self.builder, fn_type, alloc_fn, &alloc_args, 1, "record_alloc");
        self.scope_heap_values.append(self.allocator, raw_ptr) catch {};

        // Store each field (raw_ptr is already ptr type)
        for (fields, 0..) |field, i| {
            const field_val = try self.codegenExpr(field.value);
            // Find field index by name
            var field_idx: u32 = @intCast(i);
            for (info.fields, 0..) |fi, j| {
                if (std.mem.eql(u8, fi.name, field.name)) {
                    field_idx = @intCast(j);
                    break;
                }
            }
            var gep_indices: [2]types.LLVMValueRef = .{
                core.LLVMConstInt(i64_type, 0, 0),
                core.LLVMConstInt(i64_type, field_idx, 0),
            };
            const field_ptr = core.LLVMBuildGEP2(self.builder, info.llvm_type, raw_ptr, @ptrCast(&gep_indices), 2, "field_ptr");
            _ = core.LLVMBuildStore(self.builder, field_val, field_ptr);
        }

        // Return pointer as i64
        return core.LLVMBuildPtrToInt(self.builder, raw_ptr, i64_type, "record_ptr");
    }

    fn codegenFieldAccess(self: *Codegen, object: *const parser.Expr, field_name: []const u8) Error!types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);

        // Check for module-qualified names (e.g., Math.add)
        if (object.* == .identifier or object.* == .constructor) {
            const obj_name = switch (object.*) {
                .identifier => |n| n,
                .constructor => |n| n,
                else => unreachable,
            };
            const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ obj_name, field_name });
            if (self.named_values.get(combined)) |val| return val;
            if (self.fn_types.get(combined)) |_| {
                // Module function reference — return the function pointer
                if (self.named_values.get(combined)) |fn_val| return fn_val;
            }
        }

        // Get the object value (should be a record pointer as i64)
        const obj_val = try self.codegenExpr(object);

        // Determine the record type from variable tracking
        var record_name: ?[]const u8 = null;
        if (object.* == .identifier) {
            if (self.variable_types.get(object.identifier)) |tn| {
                record_name = tn;
            }
        }

        // Find the record type
        if (record_name) |rn| {
            if (self.record_types.get(rn)) |info| {
                for (info.fields, 0..) |fi, i| {
                    if (std.mem.eql(u8, fi.name, field_name)) {
                        const record_ptr = core.LLVMBuildIntToPtr(self.builder, obj_val, core.LLVMPointerTypeInContext(self.context, 0), "record_ptr");
                        var gep_indices: [2]types.LLVMValueRef = .{
                            core.LLVMConstInt(i64_type, 0, 0),
                            core.LLVMConstInt(i64_type, i, 0),
                        };
                        const field_ptr = core.LLVMBuildGEP2(self.builder, info.llvm_type, record_ptr, @ptrCast(&gep_indices), 2, "field_ptr");
                        return core.LLVMBuildLoad2(self.builder, fi.llvm_type, field_ptr, "field_val");
                    }
                }
            }
        }

        // Fallback: try all record types (for expressions that aren't simple identifiers)
        var iter = self.record_types.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.fields, 0..) |fi, i| {
                if (std.mem.eql(u8, fi.name, field_name)) {
                    const record_ptr = core.LLVMBuildIntToPtr(self.builder, obj_val, core.LLVMPointerTypeInContext(self.context, 0), "record_ptr");
                    if (record_ptr == null) return error.UndefinedVariable;
                    var gep_indices: [2]types.LLVMValueRef = .{
                        core.LLVMConstInt(i64_type, 0, 0),
                        core.LLVMConstInt(i64_type, i, 0),
                    };
                    const field_ptr = core.LLVMBuildGEP2(self.builder, entry.value_ptr.llvm_type, record_ptr, @ptrCast(&gep_indices), 2, "field_ptr");
                    if (field_ptr == null) return error.UndefinedVariable;
                    if (fi.llvm_type == null) return error.UndefinedVariable;
                    // Debug: dump the LLVM module to see IR state before crash
                    core.LLVMPositionBuilderAtEnd(self.builder, core.LLVMGetInsertBlock(self.builder));
                    return core.LLVMBuildLoad2(self.builder, fi.llvm_type, field_ptr, "field_val");
                }
            }
        }

        return error.NotYetImplemented;
    }

    fn codegenTuple(self: *Codegen, elems: []const *const parser.Expr) Error!types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);

        if (elems.len == 0) {
            return core.LLVMConstInt(i64_type, 0, 0);
        }

        if (elems.len == 1) {
            return try self.codegenExpr(elems[0]);
        }

        // For multi-element tuples, allocate raw bytes and store elements at i64 offsets
        const alloc_fn = self.named_values.get("ko_alloc") orelse return error.UndefinedVariable;
        const alloc_fn_type = core.LLVMGlobalGetValueType(alloc_fn);
        const size = core.LLVMConstInt(i64_type, elems.len * 8, 0);
        var alloc_args: [1]types.LLVMValueRef = .{size};
        const raw_ptr = core.LLVMBuildCall2(self.builder, alloc_fn_type, alloc_fn, &alloc_args, 1, "tuple_alloc");
        self.scope_heap_values.append(self.allocator, raw_ptr) catch {};

        for (elems, 0..) |elem, i| {
            const val = try self.codegenExpr(elem);
            // Use i8* GEP for byte-level offset
            const offset = core.LLVMConstInt(i64_type, i * 8, 0);
            const elem_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), raw_ptr, @constCast(&[_]types.LLVMValueRef{offset}), 1, "elem_off");
            _ = core.LLVMBuildStore(self.builder, val, elem_ptr);
        }
        return core.LLVMBuildPtrToInt(self.builder, raw_ptr, i64_type, "tuple_ptr");
    }

    fn codegenLambda(self: *Codegen, params: []const parser.Pattern, body: *const parser.Expr) Error!types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);

        // Save current builder position
        const saved_block = core.LLVMGetInsertBlock(self.builder);

        // Create anonymous function type
        var param_types: [32]types.LLVMTypeRef = undefined;
        for (params, 0..) |_, i| {
            param_types[i] = i64_type;
        }
        const fn_type = core.LLVMFunctionType(i64_type, &param_types, @intCast(params.len), 0);

        // Generate unique name
        const lambda_name_slice = try std.fmt.allocPrint(self.allocator, "lambda_{d}", .{@intFromPtr(body)});
        defer self.allocator.free(lambda_name_slice);
        const lambda_name = try self.dupeZ(lambda_name_slice);

        const func = core.LLVMAddFunction(self.module, lambda_name, fn_type);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, func, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        // Save and restore scope for lambda body
        const old_values = self.named_values;
        const old_var_types = self.variable_types;
        self.named_values = std.StringHashMap(types.LLVMValueRef).init(self.allocator);
        self.variable_types = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            self.variable_types.deinit();
            self.variable_types = old_var_types;
            self.named_values.deinit();
            self.named_values = old_values;
        }

        // Copy outer scope into lambda
        var iter = old_values.iterator();
        while (iter.next()) |entry_pair| {
            try self.named_values.put(entry_pair.key_ptr.*, entry_pair.value_ptr.*);
        }
        var vt_iter = old_var_types.iterator();
        while (vt_iter.next()) |entry_pair| {
            try self.variable_types.put(entry_pair.key_ptr.*, entry_pair.value_ptr.*);
        }

        // Add parameters
        for (params, 0..) |param, i| {
            const param_val = core.LLVMGetParam(func, @intCast(i));
            const param_name_z: [*:0]const u8 = switch (param) {
                .identifier => |n| try self.dupeZ(n),
                else => "arg",
            };
            core.LLVMSetValueName(param_val, param_name_z);
            try self.named_values.put(switch (param) {
                .identifier => |n| n,
                else => "arg",
            }, param_val);
        }

        // Codegen body
        const body_val = try self.codegenExpr(body);
        _ = core.LLVMBuildRet(self.builder, body_val);

        // Restore builder to the original position
        core.LLVMPositionBuilderAtEnd(self.builder, saved_block);

        // Return function pointer as i64
        return core.LLVMBuildPtrToInt(self.builder, func, i64_type, "fn_ptr");
    }

    fn codegenMatch(self: *Codegen, match_val_expr: *parser.Expr, arms: []const parser.MatchArm) Error!types.LLVMValueRef {
        const match_val = try self.codegenExpr(match_val_expr);
        const fn_val = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
        const i64_type = core.LLVMInt64TypeInContext(self.context);

        // Sort arms: zero-arity constructors first (raw value comparison),
        // then constructors with args (need to dereference to read tag).
        // This prevents crashes when a raw tag value (like Nil=1) is dereferenced.
        var sorted_indices: [32]usize = undefined;
        for (arms, 0..) |_, i| sorted_indices[i] = i;
        var changed = true;
        while (changed) {
            changed = false;
            for (0..arms.len - 1) |i| {
                const a = sorted_indices[i];
                const b = sorted_indices[i + 1];
                const a_zero = blk: {
                    if (arms[a].pattern == .constructor) {
                        if (self.constructor_tags.get(arms[a].pattern.constructor.name)) |info| {
                            break :blk info.arity == 0;
                        }
                    }
                    break :blk false;
                };
                const b_zero = blk: {
                    if (arms[b].pattern == .constructor) {
                        if (self.constructor_tags.get(arms[b].pattern.constructor.name)) |info| {
                            break :blk info.arity == 0;
                        }
                    }
                    break :blk false;
                };
                // Non-zero should come after zero
                if (!a_zero and b_zero) {
                    sorted_indices[i] = b;
                    sorted_indices[i + 1] = a;
                    changed = true;
                }
            }
        }

        var cmp_bbs: [32]types.LLVMBasicBlockRef = undefined;
        var body_bbs: [32]types.LLVMBasicBlockRef = undefined;
        for (0..arms.len) |i| {
            cmp_bbs[i] = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "cmp");
            body_bbs[i] = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "arm");
        }
        const merge_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "match_end");
        const unreachable_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "match_fail");

        // Branch from current (entry) block to first comparison block
        _ = core.LLVMBuildBr(self.builder, cmp_bbs[0]);

        // Unreachable default
        core.LLVMPositionBuilderAtEnd(self.builder, unreachable_bb);
        _ = core.LLVMBuildUnreachable(self.builder);

        // Build tag comparisons (in sorted order: zero-arg first)
        for (sorted_indices[0..arms.len], 0..) |arm_idx, i| {
            core.LLVMPositionBuilderAtEnd(self.builder, cmp_bbs[i]);
            const fallthrough = if (i + 1 < arms.len) cmp_bbs[i + 1] else unreachable_bb;
            switch (arms[arm_idx].pattern) {
                .constructor => |ctor| {
                    if (self.constructor_tags.get(ctor.name)) |info| {
                        // For constructors with args, extract tag from the struct
                        const actual_tag = if (info.arity > 0) blk: {
                            // Reconstruct tagged struct type to extract tag
                            var struct_fields: [33]types.LLVMTypeRef = undefined;
                            struct_fields[0] = i64_type;
                            for (0..info.arity) |j| {
                                struct_fields[j + 1] = i64_type;
                            }
                            const tagged_type = core.LLVMStructTypeInContext(self.context, &struct_fields, @intCast(info.arity + 1), 0);
                            const struct_ptr = core.LLVMBuildIntToPtr(self.builder, match_val, core.LLVMPointerTypeInContext(self.context, 0), "ctor_ptr");
                            var tag_gep: [2]types.LLVMValueRef = .{
                                core.LLVMConstInt(i64_type, 0, 0),
                                core.LLVMConstInt(i64_type, 0, 0),
                            };
                            const tag_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, struct_ptr, @ptrCast(&tag_gep), 2, "tag_ptr");
                            break :blk core.LLVMBuildLoad2(self.builder, i64_type, tag_ptr, "tag_val");
                        } else match_val;
                        const tag_const = core.LLVMConstInt(i64_type, @bitCast(info.tag), 0);
                        const cmp = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, actual_tag, tag_const, "cmp");
                        _ = core.LLVMBuildCondBr(self.builder, cmp, body_bbs[i], fallthrough);
                    }
                },
                .record => |rec| {
                    // Record pattern — extract fields and bind them
                    var resolved_name = rec.name;
                    if (self.record_types.get(rec.name) == null) {
                        // Try all record types to find matching one
                        var rt_iter = self.record_types.iterator();
                        while (rt_iter.next()) |entry| {
                            if (std.mem.endsWith(u8, entry.key_ptr.*, rec.name) or std.mem.eql(u8, entry.key_ptr.*, rec.name)) {
                                resolved_name = entry.key_ptr.*;
                                break;
                            }
                        }
                    }
                    if (self.record_types.get(resolved_name)) |info| {
                        const record_ptr = core.LLVMBuildIntToPtr(self.builder, match_val, core.LLVMPointerTypeInContext(self.context, 0), "rec_ptr");
                        for (rec.fields) |field| {
                            // Find field index by name
                            for (info.fields, 0..) |decl, di| {
                                if (std.mem.eql(u8, decl.name, field.name)) {
                                    var gep: [2]types.LLVMValueRef = .{
                                        core.LLVMConstInt(i64_type, 0, 0),
                                        core.LLVMConstInt(i64_type, di, 0),
                                    };
                                    const field_ptr = core.LLVMBuildGEP2(self.builder, info.llvm_type, record_ptr, @ptrCast(&gep), 2, "field_ptr");
                                    const field_val = core.LLVMBuildLoad2(self.builder, decl.llvm_type, field_ptr, "field_val");
                                    if (field.pattern) |sub_pat| {
                                        if (sub_pat.* == .identifier) {
                                            try self.named_values.put(sub_pat.identifier, field_val);
                                        }
                                    } else {
                                        try self.named_values.put(field.name, field_val);
                                    }
                                    break;
                                }
                            }
                        }
                    }
                    _ = core.LLVMBuildBr(self.builder, body_bbs[i]);
                },
                .wildcard => _ = core.LLVMBuildBr(self.builder, body_bbs[i]),
                else => _ = core.LLVMBuildBr(self.builder, merge_bb),
            }
        }

        // Codegen each arm body (in sorted order)
        var phi_vals: [32]types.LLVMValueRef = undefined;
        var phi_bbs: [32]types.LLVMBasicBlockRef = undefined;
        var phi_count: usize = 0;

        for (sorted_indices[0..arms.len], 0..) |arm_idx, i| {
            core.LLVMPositionBuilderAtEnd(self.builder, body_bbs[i]);
            const arm = arms[arm_idx];

            // Bind constructor pattern args (extract from tagged struct)
            if (arm.pattern == .constructor) {
                const ctor = arm.pattern.constructor;
                if (self.constructor_tags.get(ctor.name)) |info| {
                    if (ctor.args.len > 0 and info.arity > 0) {
                        // Reconstruct the tagged struct type
                        var struct_fields: [33]types.LLVMTypeRef = undefined;
                        struct_fields[0] = i64_type;
                        for (0..info.arity) |j| {
                            struct_fields[j + 1] = i64_type; // default to i64 for now
                        }
                        const tagged_type = core.LLVMStructTypeInContext(self.context, &struct_fields, @intCast(info.arity + 1), 0);
                        // Bitcast match_val back to tagged struct pointer
                        const record_ptr = core.LLVMBuildIntToPtr(self.builder, match_val, core.LLVMPointerTypeInContext(self.context, 0), "ctor_ptr");
                        // Extract each arg
                        for (ctor.args, 0..) |arg, j| {
                            if (arg == .identifier) {
                                var gep: [2]types.LLVMValueRef = .{
                                    core.LLVMConstInt(i64_type, 0, 0),
                                    core.LLVMConstInt(i64_type, j + 1, 0),
                                };
                                const field_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, record_ptr, @ptrCast(&gep), 2, "field_ptr");
                                const field_val = core.LLVMBuildLoad2(self.builder, i64_type, field_ptr, "field_val");
                                try self.named_values.put(arg.identifier, field_val);
                            }
                        }
                    }
                }
            }

            // Record pattern fields are already bound in the cmp block phase above

            const arm_val = try self.codegenExpr(arm.body);
            _ = core.LLVMBuildBr(self.builder, merge_bb);
            phi_vals[phi_count] = arm_val;
            phi_bbs[phi_count] = body_bbs[i];
            phi_count += 1;
        }

        // Merge block with phi
        core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        if (phi_count > 0) {
            const phi = core.LLVMBuildPhi(self.builder, i64_type, "result");
            core.LLVMAddIncoming(phi, @ptrCast(&phi_vals), @ptrCast(&phi_bbs), @intCast(phi_count));
            return phi;
        }
        return core.LLVMConstInt(i64_type, 0, 0);
    }

    // =========================================================================
    // Function declaration (forward declaration)
    // =========================================================================

    pub fn declareFn(self: *Codegen, fn_def: parser.FnDef) Error!types.LLVMValueRef {
        var param_types: [32]types.LLVMTypeRef = undefined;
        for (fn_def.params, 0..) |_, i| {
            param_types[i] = core.LLVMInt64TypeInContext(self.context);
        }

        const ret_type = core.LLVMInt64TypeInContext(self.context);
        const func_type = core.LLVMFunctionType(ret_type, &param_types, @intCast(fn_def.params.len), 0);
        const name_z = try self.dupeZ(fn_def.name);
        const func = core.LLVMAddFunction(self.module, name_z, func_type);

        // Register function and its type
        try self.named_values.put(fn_def.name, func);
        try self.fn_types.put(fn_def.name, func_type);
        try self.fn_arity.put(fn_def.name, @intCast(fn_def.params.len));

        return func;
    }

    // =========================================================================
    // Function codegen
    // =========================================================================

    pub fn codegenFn(self: *Codegen, fn_def: parser.FnDef) Error!types.LLVMValueRef {
        // Look up existing function declaration
        const func = self.named_values.get(fn_def.name) orelse return error.UndefinedVariable;

        // Set current function context for TCO
        const prev_fn_name = self.current_fn_name;
        const prev_fn_val = self.current_fn_val;
        self.current_fn_name = fn_def.name;
        self.current_fn_val = func;
        defer {
            self.current_fn_name = prev_fn_name;
            self.current_fn_val = prev_fn_val;
        }
        const old_values = self.named_values;
        const old_var_types = self.variable_types;
        const old_heap_values = self.scope_heap_values;
        self.named_values = std.StringHashMap(types.LLVMValueRef).init(self.allocator);
        self.variable_types = std.StringHashMap([]const u8).init(self.allocator);
        self.scope_heap_values = .empty;
        defer {
            self.scope_heap_values.deinit(self.allocator);
            self.scope_heap_values = old_heap_values;
            self.variable_types.deinit();
            self.variable_types = old_var_types;
            self.named_values.deinit();
            self.named_values = old_values;
        }

        // Copy outer scope (function declarations) into function scope
        var iter = old_values.iterator();
        while (iter.next()) |entry_pair| {
            try self.named_values.put(entry_pair.key_ptr.*, entry_pair.value_ptr.*);
        }
        var vt_iter = old_var_types.iterator();
        while (vt_iter.next()) |entry_pair| {
            try self.variable_types.put(entry_pair.key_ptr.*, entry_pair.value_ptr.*);
        }

        // Add parameters to named_values
        for (fn_def.params, 0..) |param, i| {
            const param_val = core.LLVMGetParam(func, @intCast(i));
            const param_name_z: [*:0]const u8 = switch (param.pattern) {
                .identifier => |n| try self.dupeZ(n),
                else => "arg",
            };
            core.LLVMSetValueName(param_val, param_name_z);
            try self.named_values.put(switch (param.pattern) {
                .identifier => |n| n,
                else => "arg",
            }, param_val);
        }

        // Register bare function name for recursive calls inside modules
        // e.g., Math.fact also available as fact inside the function body
        if (std.mem.indexOfScalar(u8, fn_def.name, '.')) |_| {
            const bare_name = fn_def.name[std.mem.lastIndexOfScalar(u8, fn_def.name, '.').? + 1 ..];
            try self.named_values.put(bare_name, func);
        }

        // Create entry basic block and position builder
        const entry = core.LLVMAppendBasicBlockInContext(self.context, func, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        // Check for tail-position self-recursive call (TCO)
        {
            // Case 1: body is directly a self-call
            if (fn_def.body.* == .fn_call) {
                const call = fn_def.body.fn_call;
                if (call.func.* == .identifier and std.mem.eql(u8, call.func.identifier, fn_def.name) and call.named_args.len == 0) {
                    var args: [32]types.LLVMValueRef = undefined;
                    var argc: c_uint = 0;
                    for (call.args) |arg| {
                        args[argc] = try self.codegenExpr(arg);
                        argc += 1;
                    }
                    const fn_type = self.fn_types.get(fn_def.name) orelse core.LLVMGlobalGetValueType(func);
                    const call_inst = core.LLVMBuildCall2(self.builder, fn_type, func, &args, argc, "tailcall");
                    core.LLVMSetTailCall(call_inst, 1);
                    _ = core.LLVMBuildRet(self.builder, call_inst);
                    return func;
                }
            }
            // Case 2: body is if_expr with self-call in else branch (common recursion pattern)
            if (fn_def.body.* == .if_expr) {
                const if_e = fn_def.body.if_expr;
                if (if_e.else_branch) |else_expr| {
                    const else_is_self = else_expr.* == .fn_call and
                        else_expr.fn_call.func.* == .identifier and
                        std.mem.eql(u8, else_expr.fn_call.func.identifier, fn_def.name) and
                        else_expr.fn_call.named_args.len == 0;

                    if (else_is_self) {
                        const cond_val = try self.codegenExpr(if_e.condition);
                        const then_bb = core.LLVMAppendBasicBlockInContext(self.context, func, "tco_then");
                        const else_bb = core.LLVMAppendBasicBlockInContext(self.context, func, "tco_else");
                        _ = core.LLVMBuildCondBr(self.builder, cond_val, then_bb, else_bb);

                        // Then branch (base case)
                        core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
                        const then_val = try self.codegenExpr(if_e.then_branch);
                        _ = core.LLVMBuildRet(self.builder, then_val);

                        // Else branch (tail-recursive call)
                        core.LLVMPositionBuilderAtEnd(self.builder, else_bb);
                        const else_call = else_expr.fn_call;
                        var args: [32]types.LLVMValueRef = undefined;
                        var argc: c_uint = 0;
                        for (else_call.args) |arg| {
                            args[argc] = try self.codegenExpr(arg);
                            argc += 1;
                        }
                        const fn_type = self.fn_types.get(fn_def.name) orelse core.LLVMGlobalGetValueType(func);
                        const call_inst = core.LLVMBuildCall2(self.builder, fn_type, func, &args, argc, "tailcall");
                        core.LLVMSetTailCall(call_inst, 1);
                        _ = core.LLVMBuildRet(self.builder, call_inst);
                        return func;
                    }
                }
            }
        } // end tco:

        const body_val = try self.codegenExpr(fn_def.body);

        // Decref all heap-allocated values except the return value
        if (self.scope_heap_values.items.len > 0) {
            const ko_decref_fn = self.named_values.get("ko_decref") orelse return error.UndefinedVariable;
            const decref_fn_type = core.LLVMGlobalGetValueType(ko_decref_fn);

            // Determine the underlying pointer of the return value (if it's a ptrtoint)
            var return_underlying_ptr: ?types.LLVMValueRef = null;
            if (core.LLVMIsAInstruction(body_val) != null) {
                if (core.LLVMGetInstructionOpcode(body_val) == .LLVMPtrToInt) {
                    return_underlying_ptr = core.LLVMGetOperand(body_val, 0);
                }
            }

            for (self.scope_heap_values.items) |heap_val| {
                // Skip the return value (direct match or underlying pointer of ptrtoint)
                if (heap_val == body_val) continue;
                if (return_underlying_ptr != null and heap_val == return_underlying_ptr.?) continue;
                // Only decref pointer values (heap-allocated)
                const val_type = core.LLVMTypeOf(heap_val);
                if (core.LLVMGetTypeKind(val_type) == .LLVMPointerTypeKind) {
                    _ = core.LLVMBuildCall2(self.builder, decref_fn_type, ko_decref_fn, @constCast(&[_]types.LLVMValueRef{heap_val}), 1, "");
                }
            }
        }

        _ = core.LLVMBuildRet(self.builder, body_val);

        return func;
    }

    // =========================================================================
    // Program codegen
    // =========================================================================

    pub fn codegenProgram(self: *Codegen, prog: parser.Program) Error!void {
        // Declare built-in functions first
        self.declareBuiltins();

        // Flatten module definitions into prefixed names
        var all_defs: std.ArrayList(parser.Definition) = .empty;
        defer all_defs.deinit(self.allocator);
        for (prog.definitions) |def| {
            try self.flattenDefinition(&all_defs, def, "");
        }

        // Register type definitions (sum types and records)
        for (all_defs.items) |def| {
            switch (def) {
                .type_def => |t| try self.registerTypeDef(t),
                else => {},
            }
        }

        // First pass: declare all function signatures so they're available for forward references
        for (all_defs.items) |def| {
            switch (def) {
                .fn_def => |f| {
                    _ = try self.declareFn(f);
                },
                else => {},
            }
        }

        // Second pass: codegen function bodies
        for (all_defs.items) |def| {
            switch (def) {
                .fn_def => |f| {
                    _ = try self.codegenFn(f);
                },
                else => {},
            }
        }

        core.LLVMDumpModule(self.module);
    }

    fn flattenDefinition(self: *Codegen, list: *std.ArrayList(parser.Definition), def: parser.Definition, prefix: []const u8) Error!void {
        switch (def) {
            .fn_def => |f| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, f.name })
                else
                    f.name;
                var fd = f;
                fd.name = prefixed_name;
                try list.append(self.allocator, .{ .fn_def = fd });
            },
            .type_def => |t| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, t.name })
                else
                    t.name;
                var td = t;
                td.name = prefixed_name;
                try list.append(self.allocator, .{ .type_def = td });
            },
            .module_def => |m| {
                const mod_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, m.name })
                else
                    m.name;
                for (m.definitions) |inner_def| {
                    try self.flattenDefinition(list, inner_def, mod_prefix);
                }
            },
            else => {},
        }
    }

    // =========================================================================
    // Output
    // =========================================================================

    pub fn dumpModule(self: *Codegen) void {
        core.LLVMDumpModule(self.module);
    }

    pub fn printModuleToString(self: *Codegen) ?[*:0]const u8 {
        return core.LLVMPrintModuleToString(self.module);
    }

    pub const Error = error{
        NotYetImplemented,
        UndefinedVariable,
        OutOfMemory,
    };
};

// =============================================================================
// JIT Execution
// =============================================================================

pub const Jit = struct {
    engine: types.LLVMExecutionEngineRef,

    pub fn init(mod: types.LLVMModuleRef, opt_level: u32) !Jit {
        // Initialize native target (required for MCJIT)
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmParser();
        _ = target.LLVMInitializeNativeAsmPrinter();

        // Link in MCJIT
        engine.LLVMLinkInMCJIT();

        // Create JIT compiler
        var jit_engine: types.LLVMExecutionEngineRef = undefined;
        var error_msg: [*c]u8 = null;
        const failed = engine.LLVMCreateJITCompilerForModule(&jit_engine, mod, opt_level, &error_msg);
        if (failed != 0) {
            if (error_msg) |msg| {
                std.debug.print("JIT error: {s}\n", .{std.mem.sliceTo(msg, 0)});
                core.LLVMDisposeMessage(@ptrCast(msg));
            }
            return error.JITError;
        }

        return .{ .engine = jit_engine };
    }

    pub fn deinit(self: *Jit) void {
        engine.LLVMDisposeExecutionEngine(self.engine);
    }

    pub fn runMain(self: *Jit) !i64 {
        const main_addr = engine.LLVMGetFunctionAddress(self.engine, "main");
        if (main_addr == 0) return error.UndefinedVariable;

        // Cast integer address to function pointer: i64 ()(void)
        const main_fn: *const fn () callconv(.c) i64 = @ptrFromInt(main_addr);
        return main_fn();
    }
};

// =============================================================================
// AOT Compilation (Object File Emission)
// =============================================================================

pub const Aot = struct {
    tm: types.LLVMTargetMachineRef,
    dl: types.LLVMTargetDataRef,

    pub fn init() !Aot {
        // Initialize native target
        _ = target.LLVMInitializeNativeTarget();
        _ = target.LLVMInitializeNativeAsmParser();
        _ = target.LLVMInitializeNativeAsmPrinter();

        // Get default target triple
        const triple_raw = target_machine.LLVMGetDefaultTargetTriple();
        defer core.LLVMDisposeMessage(@ptrCast(triple_raw));

        // Get target from triple
        var t: types.LLVMTargetRef = undefined;
        var error_msg: [*c]u8 = null;
        if (target_machine.LLVMGetTargetFromTriple(triple_raw, &t, &error_msg) != 0) {
            if (error_msg) |msg| {
                std.debug.print("Target error: {s}\n", .{std.mem.sliceTo(msg, 0)});
                core.LLVMDisposeMessage(@ptrCast(msg));
            }
            return error.TargetError;
        }

        // Create target machine: generic CPU, no special features, PIC relocation
        const tm = target_machine.LLVMCreateTargetMachine(
            t,
            triple_raw,
            "x86-64",
            "",
            .LLVMCodeGenLevelDefault,
            .LLVMRelocPIC,
            .LLVMCodeModelDefault,
        );

        const dl = target_machine.LLVMCreateTargetDataLayout(tm);

        return .{ .tm = tm, .dl = dl };
    }

    pub fn deinit(self: *Aot) void {
        target_machine.LLVMDisposeTargetMachine(self.tm);
        target.LLVMDisposeTargetData(self.dl);
    }

    pub fn emitObjectFile(self: *Aot, mod: types.LLVMModuleRef, filename: [*:0]const u8) !void {
        target.LLVMSetModuleDataLayout(mod, self.dl);

        var error_msg: [*c]u8 = null;
        if (target_machine.LLVMTargetMachineEmitToFile(self.tm, mod, @ptrCast(filename), .LLVMObjectFile, &error_msg) != 0) {
            if (error_msg) |msg| {
                std.debug.print("Emit error: {s}\n", .{std.mem.sliceTo(msg, 0)});
                core.LLVMDisposeMessage(@ptrCast(msg));
            }
            return error.EmitError;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "codegen: init and cleanup" {
    var cg = Codegen.init(std.testing.allocator, "test");
    defer cg.deinit();
    cg.dumpModule();
}

test "codegen: int literal" {
    var cg = Codegen.init(std.testing.allocator, "test");
    defer cg.deinit();

    const int_type = core.LLVMInt64TypeInContext(cg.context);
    const val = core.LLVMConstInt(int_type, 42, 0);
    const str = core.LLVMPrintValueToString(val);
    defer core.LLVMDisposeMessage(str);
    try std.testing.expectEqualStrings("i64 42", std.mem.sliceTo(str, 0));
}

test "codegen: simple function" {
    // fn add x y = x + y
    var cg = Codegen.init(std.testing.allocator, "test");
    defer cg.deinit();

    const i64_type = core.LLVMInt64TypeInContext(cg.context);
    const fn_type = core.LLVMFunctionType(i64_type, &.{ i64_type, i64_type }, 2, 0);
    const func = core.LLVMAddFunction(cg.module, "add", fn_type);
    const bb = core.LLVMAppendBasicBlockInContext(cg.context, func, "entry");
    core.LLVMPositionBuilderAtEnd(cg.builder, bb);

    const param0 = core.LLVMGetParam(func, 0);
    const param1 = core.LLVMGetParam(func, 1);
    core.LLVMSetValueName2(param0, "x", 1);
    core.LLVMSetValueName2(param1, "y", 1);

    const result = core.LLVMBuildAdd(cg.builder, param0, param1, "result");
    _ = core.LLVMBuildRet(cg.builder, result);

    cg.dumpModule();

    const ir = cg.printModuleToString();
    defer if (ir) |r| core.LLVMDisposeMessage(r);
    try std.testing.expect(ir != null);
}

test "codegen: end-to-end simple function call" {
    const source =
        \\fn add x y = x + y
        \\
        \\fn main = add 3 4
    ;
    var cg = Codegen.init(std.testing.allocator, "test");
    defer cg.deinit();

    var p = try parser.Parser.init(std.testing.allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    try cg.codegenProgram(prog);

    const ir = cg.printModuleToString();
    defer if (ir) |r| core.LLVMDisposeMessage(r);
    const ir_str = std.mem.sliceTo(ir.?, 0);

    try std.testing.expect(std.mem.containsAtLeast(u8, ir_str, 1, "define i64 @add(i64 %x, i64 %y)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ir_str, 1, "define i64 @main()"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ir_str, 1, "call i64 @add(i64 3, i64 4)"));
}

test "codegen: end-to-end arithmetic" {
    const source =
        \\fn main = 10 + 3 * 2
    ;
    var cg = Codegen.init(std.testing.allocator, "test");
    defer cg.deinit();

    var p = try parser.Parser.init(std.testing.allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    try cg.codegenProgram(prog);

    const ir = cg.printModuleToString();
    defer if (ir) |r| core.LLVMDisposeMessage(r);
    const ir_str = std.mem.sliceTo(ir.?, 0);

    try std.testing.expect(std.mem.containsAtLeast(u8, ir_str, 1, "define i64 @main()"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ir_str, 1, "mul i64 3, 2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ir_str, 1, "add i64 10,"));
}

test "codegen: end-to-end multiple functions with forward ref" {
    const source =
        \\fn main = double 21
        \\
        \\fn double x = x * 2
    ;
    var cg = Codegen.init(std.testing.allocator, "test");
    defer cg.deinit();

    var p = try parser.Parser.init(std.testing.allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    try cg.codegenProgram(prog);

    const ir = cg.printModuleToString();
    defer if (ir) |r| core.LLVMDisposeMessage(r);
    const ir_str = std.mem.sliceTo(ir.?, 0);

    try std.testing.expect(std.mem.containsAtLeast(u8, ir_str, 1, "call i64 @double(i64 21)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, ir_str, 1, "mul i64 %x, 2"));
}

test "jit: execute simple main" {
    const source =
        \\fn main = 42
    ;
    var cg = Codegen.init(std.testing.allocator, "test");
    defer cg.deinit();

    var p = try parser.Parser.init(std.testing.allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    try cg.codegenProgram(prog);

    var jit = try Jit.init(cg.module, 0);
    defer jit.deinit();

    const result = try jit.runMain();
    try std.testing.expectEqual(@as(i64, 42), result);
}

// =============================================================================
// C-callable built-in implementations
// =============================================================================

fn builtin_println(val: i64) callconv(.c) i64 {
    std.debug.print("{d}\n", .{val});
    return 0;
}

fn builtin_print(val: i64) callconv(.c) i64 {
    std.debug.print("{d}", .{val});
    return 0;
}

// Type tags for inspect:
// 0=int, 1=float, 2=bool, 3=char, 4=string, 5=unit,
// 6=constructor, 7=record, 8=function, 9=tuple, 100=unknown
fn builtin_inspect(val: i64, type_tag: i64, name_ptr: ?[*:0]const u8) callconv(.c) i64 {
    switch (type_tag) {
        0 => std.debug.print("{d}", .{val}),
        1 => {
            const f: f64 = @bitCast(val);
            std.debug.print("{d}", .{f});
        },
        2 => {
            if (val == 0) {
                std.debug.print("False", .{});
            } else {
                std.debug.print("True", .{});
            }
        },
        3 => {
            const ch: u8 = @intCast(val);
            std.debug.print("'{c}'", .{ch});
        },
        4 => {
            const ptr: [*]const u8 = @ptrFromInt(@as(usize, @bitCast(val)));
            var len: usize = 0;
            while (ptr[len] != 0) : (len += 1) {}
            std.debug.print("\"{s}\"", .{ptr[0..len]});
        },
        5 => std.debug.print("()", .{}),
        6 => {
            if (name_ptr) |name| {
                var len: usize = 0;
                while (name[len] != 0) : (len += 1) {}
                std.debug.print("{s}", .{name[0..len]});
            } else {
                std.debug.print("Constructor({d})", .{val});
            }
        },
        7 => {
            if (name_ptr) |name| {
                var len: usize = 0;
                while (name[len] != 0) : (len += 1) {}
                std.debug.print("{s} {{ ... }}", .{name[0..len]});
            } else {
                std.debug.print("Record({d})", .{val});
            }
        },
        8 => std.debug.print("<fn>", .{}),
        9 => std.debug.print("({d})", .{val}),
        else => std.debug.print("{d}", .{val}),
    }
    return val;
}

extern fn malloc(usize) callconv(.c) ?*anyopaque;
extern fn free(?*anyopaque) callconv(.c) void;

fn malloc_wrapper(size: i64) callconv(.c) ?[*]u8 {
    const ptr = malloc(@intCast(size)) orelse return null;
    return @ptrCast(ptr);
}

fn free_wrapper(ptr: ?[*]u8) callconv(.c) void {
    free(@ptrCast(ptr));
}

// ============================================================
// Reference counting wrappers for JIT
// ============================================================
const RC_OFFSET = 8;

fn ko_alloc_wrapper(user_size: i64) callconv(.c) ?[*]u8 {
    const raw = malloc(@intCast(@as(u64, @intCast(user_size)) + RC_OFFSET)) orelse return null;
    const rc_ptr: *i64 = @alignCast(@ptrCast(raw));
    rc_ptr.* = 1;
    const user_data: [*]u8 = @ptrFromInt(@intFromPtr(raw) + RC_OFFSET);
    return user_data;
}

fn ko_incref_wrapper(ptr: ?[*]u8) callconv(.c) ?[*]u8 {
    if (ptr == null) return null;
    const p = ptr.?;
    const rc_ptr: *i64 = @alignCast(@ptrCast(@as([*]u8, @ptrFromInt(@intFromPtr(p) - RC_OFFSET))));
    rc_ptr.* += 1;
    return p;
}

fn ko_decref_wrapper(ptr: ?[*]u8) callconv(.c) void {
    if (ptr == null) return;
    const p = ptr.?;
    const rc_ptr: *i64 = @alignCast(@ptrCast(@as([*]u8, @ptrFromInt(@intFromPtr(p) - RC_OFFSET))));
    rc_ptr.* -= 1;
    if (rc_ptr.* <= 0) {
        free(@ptrCast(rc_ptr));
    }
}
