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
    constructor_tags: std.StringHashMap(CtorInfo),
    record_types: std.StringHashMap(RecordInfo),
    module_owned_by_jit: bool = false,
    current_fn_name: ?[]const u8 = null,
    current_fn_val: ?types.LLVMValueRef = null,

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) Codegen {
        const ctx = core.LLVMContextCreate();
        return .{
            .allocator = allocator,
            .context = ctx,
            .module = core.LLVMModuleCreateWithNameInContext(module_name, ctx),
            .builder = core.LLVMCreateBuilderInContext(ctx),
            .named_values = std.StringHashMap(types.LLVMValueRef).init(allocator),
            .variable_types = std.StringHashMap([]const u8).init(allocator),
            .fn_types = std.StringHashMap(types.LLVMTypeRef).init(allocator),
            .constructor_tags = std.StringHashMap(CtorInfo).init(allocator),
            .record_types = std.StringHashMap(RecordInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.record_types.deinit();
        self.constructor_tags.deinit();
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
    }

    pub fn mapBuiltinsToNative(self: *Codegen, jit_engine: types.LLVMExecutionEngineRef) void {
        const println_fn = self.named_values.get("println") orelse return;
        const print_fn = self.named_values.get("print") orelse return;
        const inspect_fn = self.named_values.get("inspect") orelse return;
        engine.LLVMAddGlobalMapping(jit_engine, println_fn, @constCast(@ptrCast(&builtin_println)));
        engine.LLVMAddGlobalMapping(jit_engine, print_fn, @constCast(@ptrCast(&builtin_print)));
        engine.LLVMAddGlobalMapping(jit_engine, inspect_fn, @constCast(@ptrCast(&builtin_inspect)));
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
            .deref => core.LLVMBuildLoad2(self.builder, core.LLVMInt64TypeInContext(self.context), val, "deref"),
        };
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

    fn codegenFnCall(self: *Codegen, call: parser.FnCallExpr) Error!types.LLVMValueRef {
        // Check if this is a constructor call (e.g., Some 42)
        if (call.func.* == .constructor) {
            const name = call.func.constructor;
            if (self.constructor_tags.get(name)) |info| {
                // Zero-arg constructor: return the tag
                if (call.args.len == 0) {
                    return core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(info.tag), 0);
                }
                // Constructor with args: allocate tagged struct, store tag + args
                const i64_type = core.LLVMInt64TypeInContext(self.context);
                // For single-arg constructors, pack the value with the tag
                if (call.args.len == 1) {
                    const arg_val = try self.codegenExpr(call.args[0]);
                    // Create { i64, <arg_type> } struct
                    const arg_type = core.LLVMTypeOf(arg_val);
                    var struct_fields: [2]types.LLVMTypeRef = .{ i64_type, arg_type };
                    const tagged_type = core.LLVMStructTypeInContext(self.context, &struct_fields, 2, 0);
                    // Allocate and store tag + value
                    const alloc = core.LLVMBuildAlloca(self.builder, tagged_type, "tagged");
                    const tag_val = core.LLVMConstInt(i64_type, @bitCast(info.tag), 0);
                    var tag_gep_indices: [2]types.LLVMValueRef = .{
                        core.LLVMConstInt(i64_type, 0, 0),
                        core.LLVMConstInt(i64_type, 0, 0),
                    };
                    const tag_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, alloc, @ptrCast(&tag_gep_indices), 2, "tag_ptr");
                    _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);
                    var val_gep_indices: [2]types.LLVMValueRef = .{
                        core.LLVMConstInt(i64_type, 0, 0),
                        core.LLVMConstInt(i64_type, 1, 0),
                    };
                    const val_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, alloc, @ptrCast(&val_gep_indices), 2, "val_ptr");
                    _ = core.LLVMBuildStore(self.builder, arg_val, val_ptr);
                    // Return pointer as i64
                    return core.LLVMBuildPtrToInt(self.builder, alloc, i64_type, "tagged_ptr");
                }
                // Multi-arg constructors: allocate tagged struct with tag + all args
                var struct_fields: [33]types.LLVMTypeRef = undefined;
                struct_fields[0] = i64_type;
                var arg_vals: [32]types.LLVMValueRef = undefined;
                for (call.args, 0..) |arg, i| {
                    const arg_val = try self.codegenExpr(arg);
                    struct_fields[i + 1] = core.LLVMTypeOf(arg_val);
                    arg_vals[i] = arg_val;
                }
                const tagged_type = core.LLVMStructTypeInContext(self.context, &struct_fields, @intCast(call.args.len + 1), 0);
                const alloc = core.LLVMBuildAlloca(self.builder, tagged_type, "tagged");
                // Store tag at index 0
                const tag_val = core.LLVMConstInt(i64_type, @bitCast(info.tag), 0);
                var tag_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 0, 0) };
                const tag_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, alloc, @ptrCast(&tag_gep), 2, "tag_ptr");
                _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);
                // Store each arg at index 1..N
                for (0..call.args.len) |i| {
                    var val_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, i + 1, 0) };
                    const val_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, alloc, @ptrCast(&val_gep), 2, "val_ptr");
                    _ = core.LLVMBuildStore(self.builder, arg_vals[i], val_ptr);
                }
                return core.LLVMBuildPtrToInt(self.builder, alloc, i64_type, "tagged_ptr");
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

        // Check if fn_val is a global function or an indirect pointer
        const is_global = core.LLVMIsAFunction(fn_val) != null;
        if (is_global) {
            const fn_type = core.LLVMGlobalGetValueType(fn_val);
            return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, argc, "call");
        } else {
            // Indirect call: fn_val is a pointer (i64) to a function
            const i64_type = core.LLVMInt64TypeInContext(self.context);
            var param_types: [32]types.LLVMTypeRef = undefined;
            for (0..argc) |i| {
                param_types[i] = i64_type;
            }
            const fn_type = core.LLVMFunctionType(i64_type, &param_types, argc, 0);
            const fn_ptr = core.LLVMBuildIntToPtr(self.builder, fn_val, core.LLVMPointerTypeInContext(self.context, 0), "fn_ptr");
            return core.LLVMBuildCall2(self.builder, fn_type, fn_ptr, &args, argc, "indirect_call");
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

        // Look up record type info
        const info = self.record_types.get(name) orelse {
            // Unknown record type — return 0 as fallback
            return core.LLVMConstInt(i64_type, 0, 0);
        };

        // Allocate struct on stack
        const alloc = core.LLVMBuildAlloca(self.builder, info.llvm_type, "record");

        // Store each field
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
            const field_ptr = core.LLVMBuildGEP2(self.builder, info.llvm_type, alloc, @ptrCast(&gep_indices), 2, "field_ptr");
            _ = core.LLVMBuildStore(self.builder, field_val, field_ptr);
        }

        // Return pointer as i64
        return core.LLVMBuildPtrToInt(self.builder, alloc, i64_type, "record_ptr");
    }

    fn codegenFieldAccess(self: *Codegen, object: *const parser.Expr, field_name: []const u8) Error!types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);

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
                        const record_ptr = core.LLVMBuildIntToPtr(self.builder, obj_val, info.llvm_type, "record_ptr");
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
                    const record_ptr = core.LLVMBuildIntToPtr(self.builder, obj_val, entry.value_ptr.llvm_type, "record_ptr");
                    var gep_indices: [2]types.LLVMValueRef = .{
                        core.LLVMConstInt(i64_type, 0, 0),
                        core.LLVMConstInt(i64_type, i, 0),
                    };
                    const field_ptr = core.LLVMBuildGEP2(self.builder, entry.value_ptr.llvm_type, record_ptr, @ptrCast(&gep_indices), 2, "field_ptr");
                    return core.LLVMBuildLoad2(self.builder, fi.llvm_type, field_ptr, "field_val");
                }
            }
        }

        return error.NotYetImplemented;
    }

    fn codegenTuple(self: *Codegen, elems: []const *const parser.Expr) Error!types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);

        if (elems.len == 0) {
            // Unit tuple ()
            return core.LLVMConstInt(i64_type, 0, 0);
        }

        // For single-element tuple, just return the element
        if (elems.len == 1) {
            return try self.codegenExpr(elems[0]);
        }

        // For multi-element tuples, create a struct
        var elem_types: [32]types.LLVMTypeRef = undefined;
        var elem_vals: [32]types.LLVMValueRef = undefined;
        for (elems, 0..) |elem, i| {
            const val = try self.codegenExpr(elem);
            elem_types[i] = core.LLVMTypeOf(val);
            elem_vals[i] = val;
        }
        const tuple_type = core.LLVMStructTypeInContext(self.context, &elem_types, @intCast(elems.len), 0);
        const alloc = core.LLVMBuildAlloca(self.builder, tuple_type, "tuple");
        for (elem_vals, 0..) |val, i| {
            var gep_indices: [2]types.LLVMValueRef = .{
                core.LLVMConstInt(i64_type, 0, 0),
                core.LLVMConstInt(i64_type, i, 0),
            };
            const elem_ptr = core.LLVMBuildGEP2(self.builder, tuple_type, alloc, @ptrCast(&gep_indices), 2, "elem_ptr");
            _ = core.LLVMBuildStore(self.builder, val, elem_ptr);
        }
        return core.LLVMBuildPtrToInt(self.builder, alloc, i64_type, "tuple_ptr");
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

        var cmp_bbs: [32]types.LLVMBasicBlockRef = undefined;
        var body_bbs: [32]types.LLVMBasicBlockRef = undefined;
        for (arms, 0..) |_, i| {
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

        // Build tag comparisons
        for (arms, 0..) |arm, i| {
            core.LLVMPositionBuilderAtEnd(self.builder, cmp_bbs[i]);
            const fallthrough = if (i + 1 < arms.len) cmp_bbs[i + 1] else unreachable_bb;
            switch (arm.pattern) {
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
                            const struct_ptr = core.LLVMBuildIntToPtr(self.builder, match_val, tagged_type, "ctor_ptr");
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
                .wildcard => _ = core.LLVMBuildBr(self.builder, body_bbs[i]),
                else => _ = core.LLVMBuildBr(self.builder, merge_bb),
            }
        }

        // Codegen each arm body
        var phi_vals: [32]types.LLVMValueRef = undefined;
        var phi_bbs: [32]types.LLVMBasicBlockRef = undefined;
        var phi_count: usize = 0;

        for (arms, 0..) |arm, i| {
            core.LLVMPositionBuilderAtEnd(self.builder, body_bbs[i]);

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
                        const record_ptr = core.LLVMBuildIntToPtr(self.builder, match_val, tagged_type, "ctor_ptr");
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

        const entry = core.LLVMAppendBasicBlockInContext(self.context, func, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        // Save and restore named_values and variable_types for function scope
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
        _ = core.LLVMBuildRet(self.builder, body_val);

        return func;
    }

    // =========================================================================
    // Program codegen
    // =========================================================================

    pub fn codegenProgram(self: *Codegen, prog: parser.Program) Error!void {
        // Declare built-in functions first
        self.declareBuiltins();

        // Register type definitions (sum types)
        for (prog.definitions) |def| {
            switch (def) {
                .type_def => |t| try self.registerTypeDef(t),
                else => {},
            }
        }

        // First pass: declare all function signatures so they're available for forward references
        for (prog.definitions) |def| {
            switch (def) {
                .fn_def => |f| {
                    _ = try self.declareFn(f);
                },
                else => {},
            }
        }

        // Second pass: codegen function bodies
        for (prog.definitions) |def| {
            switch (def) {
                .fn_def => |f| {
                    _ = try self.codegenFn(f);
                },
                else => {},
            }
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
