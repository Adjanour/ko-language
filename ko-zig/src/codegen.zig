const std = @import("std");
const llvm = @import("llvm");
const core = llvm.core;
const types = llvm.types;
const engine = llvm.engine;
const target = llvm.target;
const target_machine = llvm.target_machine;
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const comptime_mod = @import("comptime.zig");
const module_loader_mod = @import("module_loader.zig");
const stdlib = @import("stdlib.zig");
const stdlib_codegen = @import("stdlib_codegen.zig");

// LLVMConstStringInContext's DontNullTerminate parameter.
// ALWAYS pass 0 (false) — every Kō string must have a trailing zero.
// This ensures C functions like printf("%s", ...) never read past the end.
const NULL_TERMINATE = @as(c_uint, 0);

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
    constructor_fns: std.StringHashMap(types.LLVMValueRef), // constructor name → wrapper fn
    record_types: std.StringHashMap(RecordInfo),
    expr_type_tags: ?std.AutoHashMap(*const parser.Expr, i64) = null,
    module_owned_by_jit: bool = false,
    quiet: bool = false, // suppress IR dump (for REPL)
    current_fn_name: ?[]const u8 = null,
    current_fn_val: ?types.LLVMValueRef = null,
    current_module: ?[]const u8 = null,
    scope_heap_values: std.ArrayList(types.LLVMValueRef) = .empty, // heap-allocated values to decref on scope exit
    conditional_depth: usize = 0, // > 0 when inside if/else or match arm
    heap_allocas: std.AutoHashMap(types.LLVMValueRef, types.LLVMValueRef) = undefined, // heap value → alloca (for conditional allocs)
    consumed_heap_values: std.AutoHashMap(types.LLVMValueRef, void) = undefined, // values stored in parent structures (don't decref)
    comptime_world: comptime_mod.CompileTimeWorld = undefined,
    module_loader: ?*module_loader_mod.ModuleLoader = null,

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
            .constructor_fns = std.StringHashMap(types.LLVMValueRef).init(allocator),
            .record_types = std.StringHashMap(RecordInfo).init(allocator),
            .heap_allocas = std.AutoHashMap(types.LLVMValueRef, types.LLVMValueRef).init(allocator),
            .consumed_heap_values = std.AutoHashMap(types.LLVMValueRef, void).init(allocator),
            .comptime_world = comptime_mod.CompileTimeWorld.init(allocator),
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.comptime_world.deinit();
        self.consumed_heap_values.deinit();
        self.heap_allocas.deinit();
        self.scope_heap_values.deinit(self.allocator);
        self.record_types.deinit();
        self.constructor_fns.deinit();
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

    /// Box a zero-arg constructor: allocate a {i64} struct with the tag, return ptrtoint
    fn boxZeroArgCtor(self: *Codegen, tag: i64, i64_type: types.LLVMTypeRef) !types.LLVMValueRef {
        const tagged_type = core.LLVMStructTypeInContext(self.context, @constCast(&[_]types.LLVMTypeRef{i64_type}), 1, 0);
        const alloc_fn = self.named_values.get("ko_alloc") orelse return error.UndefinedVariable;
        const alloc_fn_type = core.LLVMGlobalGetValueType(alloc_fn);
        const size_val = self.storeSize(tagged_type);
        var alloc_args: [1]types.LLVMValueRef = .{size_val};
        const raw_ptr = core.LLVMBuildCall2(self.builder, alloc_fn_type, alloc_fn, &alloc_args, 1, "box_alloc");
        self.trackHeapAlloc(raw_ptr);
        const tag_val = core.LLVMConstInt(i64_type, @bitCast(tag), 0);
        var tag_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 0, 0) };
        const tag_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, raw_ptr, @ptrCast(&tag_gep), 2, "tag_ptr");
        _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);
        return core.LLVMBuildPtrToInt(self.builder, raw_ptr, i64_type, "boxed_ctor");
    }

    /// Emit ko_decref(ptr) call for a heap-allocated value.
    fn emitDecref(self: *Codegen, heap_val: types.LLVMValueRef) void {
        const ko_decref_fn = self.named_values.get("ko_decref") orelse return;
        const fn_type = core.LLVMGlobalGetValueType(ko_decref_fn);
        // heap_val is the raw pointer from ko_alloc (i64). Cast to ptr for decref.
        const ptr_val = core.LLVMBuildIntToPtr(self.builder, heap_val, core.LLVMPointerTypeInContext(self.context, 0), "decref_ptr");
        var args = [_]types.LLVMValueRef{ptr_val};
        _ = core.LLVMBuildCall2(self.builder, fn_type, ko_decref_fn, &args, 1, "");
    }

    /// Emit ko_incref(ptr) call for a heap-allocated value.
    fn emitIncref(self: *Codegen, heap_val: types.LLVMValueRef) void {
        const ko_incref_fn = self.named_values.get("ko_incref") orelse return;
        const fn_type = core.LLVMGlobalGetValueType(ko_incref_fn);
        const ptr_val = core.LLVMBuildIntToPtr(self.builder, heap_val, core.LLVMPointerTypeInContext(self.context, 0), "incref_ptr");
        var args = [_]types.LLVMValueRef{ptr_val};
        _ = core.LLVMBuildCall2(self.builder, fn_type, ko_incref_fn, &args, 1, "");
    }

    /// Track a heap allocation. If inside a conditional block, stores in an alloca
    /// so it's accessible from the exit block. Otherwise, just appends to scope_heap_values.
    fn trackHeapAlloc(self: *Codegen, heap_val: types.LLVMValueRef) void {
        self.scope_heap_values.append(self.allocator, heap_val) catch return;
        if (self.conditional_depth > 0) {
            // Create alloca in the ENTRY block so it's accessible from any block.
            // Initialize to 0 so untaken branches leave a null value (safe to null-check).
            const saved_block = core.LLVMGetInsertBlock(self.builder);
            const fn_val = core.LLVMGetBasicBlockParent(saved_block);
            const entry = core.LLVMGetFirstBasicBlock(fn_val);
            // Position BEFORE the first instruction to avoid placing allocas after terminators
            if (core.LLVMGetFirstInstruction(entry)) |first_inst| {
                core.LLVMPositionBuilder(self.builder, entry, first_inst);
            } else {
                core.LLVMPositionBuilderAtEnd(self.builder, entry);
            }
            const i64_type = core.LLVMInt64TypeInContext(self.context);
            const alloca = core.LLVMBuildAlloca(self.builder, i64_type, "heap_alloca");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(i64_type, 0, 0), alloca);
            core.LLVMPositionBuilderAtEnd(self.builder, saved_block);
            _ = core.LLVMBuildStore(self.builder, heap_val, alloca);
            self.heap_allocas.put(heap_val, alloca) catch {};
        }
    }

    /// Mark a heap value as consumed by a parent structure (constructor, tuple, record, closure).
    /// Consumed values are NOT decreffed at function exit — the parent owns them.
    fn markConsumed(self: *Codegen, heap_val: types.LLVMValueRef) void {
        self.consumed_heap_values.put(heap_val, {}) catch {};
    }
    fn emitDecrefAll(self: *Codegen) void {
        const items = self.scope_heap_values.items;
        for (items) |heap_val| {
            // Skip values consumed by parent structures
            if (self.consumed_heap_values.contains(heap_val)) continue;
            if (self.heap_allocas.get(heap_val)) |alloca| {
                // Conditional allocation: load from alloca, use select to avoid creating new blocks
                const i64_type = core.LLVMInt64TypeInContext(self.context);
                const loaded = core.LLVMBuildLoad2(self.builder, i64_type, alloca, "heap_loaded");
                const is_nonnull = core.LLVMBuildICmp(self.builder, .LLVMIntNE, loaded, core.LLVMConstInt(i64_type, 0, 0), "is_nonnull");
                const null_ptr = core.LLVMConstPointerNull(core.LLVMPointerTypeInContext(self.context, 0));
                const real_ptr = core.LLVMBuildIntToPtr(self.builder, loaded, core.LLVMPointerTypeInContext(self.context, 0), "decref_ptr");
                const selected_ptr = core.LLVMBuildSelect(self.builder, is_nonnull, real_ptr, null_ptr, "safe_ptr");
                const ko_decref_fn = self.named_values.get("ko_decref") orelse continue;
                const fn_type = core.LLVMGlobalGetValueType(ko_decref_fn);
                var args = [_]types.LLVMValueRef{selected_ptr};
                _ = core.LLVMBuildCall2(self.builder, fn_type, ko_decref_fn, &args, 1, "");
            } else {
                // Unconditional allocation: SSA value is valid at exit
                self.emitDecref(heap_val);
            }
        }
        // Clear the tracking lists
        self.scope_heap_values.shrinkRetainingCapacity(0);
        self.heap_allocas.clearRetainingCapacity();
        self.consumed_heap_values.clearRetainingCapacity();
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
            .ref => core.LLVMPointerTypeInContext(self.context, 0),
        };
    }

    // =========================================================================
    // Built-in function declarations (println, print)
    // =========================================================================

    pub fn declareBuiltins(self: *Codegen) void {
        const i64_type = core.LLVMInt64TypeInContext(self.context);
        const ptr_type = core.LLVMPointerTypeInContext(self.context, 0);

        // Generate stdlib functions as LLVM IR in the module
        var stdlib_cg = stdlib_codegen.StdlibCodegen.init(self.context, self.module, self.builder, self.allocator);
        stdlib_codegen.StdlibCodegen.generateAll(&stdlib_cg);

        // I/O externals (still need C runtime for these)
        // Look up functions already declared by StdlibCodegen, or create if not found
        // println_with_tag(i64, i64) -> i64
        const println_fn = core.LLVMGetNamedFunction(self.module, "println_with_tag") orelse blk: {
            var param_i64_tag: [2]types.LLVMTypeRef = .{ i64_type, i64_type };
            const println_type = core.LLVMFunctionType(i64_type, &param_i64_tag, 2, 0);
            break :blk core.LLVMAddFunction(self.module, "println_with_tag", println_type);
        };
        _ = self.named_values.put("println", println_fn) catch {};

        // print_with_tag(i64, i64) -> i64
        const print_fn = core.LLVMGetNamedFunction(self.module, "print_with_tag") orelse blk: {
            var param_i64_tag: [2]types.LLVMTypeRef = .{ i64_type, i64_type };
            const print_type = core.LLVMFunctionType(i64_type, &param_i64_tag, 2, 0);
            break :blk core.LLVMAddFunction(self.module, "print_with_tag", print_type);
        };
        _ = self.named_values.put("print", print_fn) catch {};

        // inspect(i64, i64, ptr, i64) -> i64
        const inspect_fn = core.LLVMGetNamedFunction(self.module, "inspect") orelse blk: {
            var inspect_params: [4]types.LLVMTypeRef = .{ i64_type, i64_type, ptr_type, i64_type };
            const inspect_type = core.LLVMFunctionType(i64_type, &inspect_params, 4, 0);
            break :blk core.LLVMAddFunction(self.module, "inspect", inspect_type);
        };
        _ = self.named_values.put("inspect", inspect_fn) catch {};

        // malloc/free externals — look up existing or create
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc") orelse blk: {
            var malloc_params: [1]types.LLVMTypeRef = .{i64_type};
            const malloc_type = core.LLVMFunctionType(ptr_type, &malloc_params, 1, 0);
            break :blk core.LLVMAddFunction(self.module, "malloc", malloc_type);
        };
        _ = self.named_values.put("malloc", malloc_fn) catch {};

        const free_fn = core.LLVMGetNamedFunction(self.module, "free") orelse blk: {
            var free_params: [1]types.LLVMTypeRef = .{ptr_type};
            const free_type = core.LLVMFunctionType(core.LLVMVoidTypeInContext(self.context), &free_params, 1, 0);
            break :blk core.LLVMAddFunction(self.module, "free", free_type);
        };
        _ = self.named_values.put("free", free_fn) catch {};

        // Register stdlib functions in named_values
        // (they were created by StdlibCodegen but we need to look them up)
        if (core.LLVMGetNamedFunction(self.module, "ko_alloc")) |fn_val|
            _ = self.named_values.put("ko_alloc", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_incref")) |fn_val|
            _ = self.named_values.put("ko_incref", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_decref")) |fn_val|
            _ = self.named_values.put("ko_decref", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_init_stack")) |fn_val|
            _ = self.named_values.put("ko_init_stack", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_check_stack")) |fn_val|
            _ = self.named_values.put("ko_check_stack", fn_val) catch {};

        // Int module
        if (core.LLVMGetNamedFunction(self.module, "ko_int_to_string")) |fn_val|
            _ = self.named_values.put("Int.toString", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_string_to_int")) |fn_val|
            _ = self.named_values.put("Int.fromString", fn_val) catch {};

        // String module
        if (core.LLVMGetNamedFunction(self.module, "ko_string_length")) |fn_val|
            _ = self.named_values.put("String.length", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_string_append")) |fn_val|
            _ = self.named_values.put("String.append", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_string_contains")) |fn_val|
            _ = self.named_values.put("String.contains", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_string_char_at")) |fn_val|
            _ = self.named_values.put("String.charAt", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_string_to_upper")) |fn_val|
            _ = self.named_values.put("String.toUpperCase", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_string_to_lower")) |fn_val|
            _ = self.named_values.put("String.toLowerCase", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_string_trim")) |fn_val|
            _ = self.named_values.put("String.trim", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_string_replace")) |fn_val|
            _ = self.named_values.put("String.replace", fn_val) catch {};

        // Math module (integer)
        if (core.LLVMGetNamedFunction(self.module, "ko_int_pow")) |fn_val|
            _ = self.named_values.put("Int.pow", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_int_gcd")) |fn_val|
            _ = self.named_values.put("Int.gcd", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_int_lcm")) |fn_val|
            _ = self.named_values.put("Int.lcm", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_int_factorial")) |fn_val|
            _ = self.named_values.put("Int.factorial", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_int_isqrt")) |fn_val|
            _ = self.named_values.put("Int.isqrt", fn_val) catch {};

        // Math module (float)
        if (core.LLVMGetNamedFunction(self.module, "ko_float_of_int")) |fn_val|
            _ = self.named_values.put("Float.ofInt", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_to_int")) |fn_val|
            _ = self.named_values.put("Float.toInt", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_sqrt")) |fn_val|
            _ = self.named_values.put("Float.sqrt", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_sin")) |fn_val|
            _ = self.named_values.put("Float.sin", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_cos")) |fn_val|
            _ = self.named_values.put("Float.cos", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_tan")) |fn_val|
            _ = self.named_values.put("Float.tan", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_log")) |fn_val|
            _ = self.named_values.put("Float.log", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_log2")) |fn_val|
            _ = self.named_values.put("Float.log2", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_log10")) |fn_val|
            _ = self.named_values.put("Float.log10", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_exp")) |fn_val|
            _ = self.named_values.put("Float.exp", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_floor")) |fn_val|
            _ = self.named_values.put("Float.floor", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_ceil")) |fn_val|
            _ = self.named_values.put("Float.ceil", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_abs")) |fn_val|
            _ = self.named_values.put("Float.abs", fn_val) catch {};
        if (core.LLVMGetNamedFunction(self.module, "ko_float_pow")) |fn_val|
            _ = self.named_values.put("Float.pow", fn_val) catch {};

        // Built-in constructors (True/False for Bool type)
        _ = self.constructor_tags.put("True", .{ .type_name = "Bool", .tag = 0, .arity = 0 }) catch {};
        _ = self.constructor_tags.put("False", .{ .type_name = "Bool", .tag = 1, .arity = 0 }) catch {};
        const bool_fn_type = core.LLVMFunctionType(i64_type, null, 0, 0);
        const true_fn = core.LLVMAddFunction(self.module, "True", bool_fn_type);
        _ = self.constructor_fns.put("True", true_fn) catch {};
        const false_fn = core.LLVMAddFunction(self.module, "False", bool_fn_type);
        _ = self.constructor_fns.put("False", false_fn) catch {};

        // Built-in Result constructors (Ok/Err for Result type)
        _ = self.constructor_tags.put("Ok", .{ .type_name = "Result", .tag = 0, .arity = 1 }) catch {};
        _ = self.constructor_tags.put("Err", .{ .type_name = "Result", .tag = 1, .arity = 1 }) catch {};
        var ok_params: [1]types.LLVMTypeRef = .{i64_type};
        const ok_fn_type = core.LLVMFunctionType(i64_type, &ok_params, 1, 0);
        const ok_fn = core.LLVMAddFunction(self.module, "Ok", ok_fn_type);
        _ = self.constructor_fns.put("Ok", ok_fn) catch {};
        const err_fn = core.LLVMAddFunction(self.module, "Err", ok_fn_type);
        _ = self.constructor_fns.put("Err", err_fn) catch {};

        // Result operations (built-in)
        {
            // Result.is_ok : Result a b -> Bool (i64 -> i64)
            var is_ok_params: [1]types.LLVMTypeRef = .{i64_type};
            const is_ok_type = core.LLVMFunctionType(i64_type, &is_ok_params, 1, 0);
            const is_ok_fn = core.LLVMAddFunction(self.module, "ko_result_is_ok", is_ok_type);
            _ = self.named_values.put("Result.is_ok", is_ok_fn) catch {};
        }
        {
            // Result.is_err : Result a b -> Bool (i64 -> i64)
            var is_err_params: [1]types.LLVMTypeRef = .{i64_type};
            const is_err_type = core.LLVMFunctionType(i64_type, &is_err_params, 1, 0);
            const is_err_fn = core.LLVMAddFunction(self.module, "ko_result_is_err", is_err_type);
            _ = self.named_values.put("Result.is_err", is_err_fn) catch {};
        }
        {
            // Result.unwrap : a -> Result a b -> a (i64, i64 -> i64)
            var unwrap_params: [2]types.LLVMTypeRef = .{ i64_type, i64_type };
            const unwrap_type = core.LLVMFunctionType(i64_type, &unwrap_params, 2, 0);
            const unwrap_fn = core.LLVMAddFunction(self.module, "ko_result_unwrap", unwrap_type);
            _ = self.named_values.put("Result.unwrap", unwrap_fn) catch {};
        }
        {
            // Result.map : (a -> b) -> Result a c -> Result b c (i64, i64 -> i64)
            var map_params: [2]types.LLVMTypeRef = .{ i64_type, i64_type };
            const map_type = core.LLVMFunctionType(i64_type, &map_params, 2, 0);
            const map_fn = core.LLVMAddFunction(self.module, "ko_result_map", map_type);
            _ = self.named_values.put("Result.map", map_fn) catch {};
        }
        {
            // Result.fold : (a -> c) -> (b -> c) -> Result a b -> c (i64, i64, i64 -> i64)
            var fold_params: [3]types.LLVMTypeRef = .{ i64_type, i64_type, i64_type };
            const fold_type = core.LLVMFunctionType(i64_type, &fold_params, 3, 0);
            const fold_fn = core.LLVMAddFunction(self.module, "ko_result_fold", fold_type);
            _ = self.named_values.put("Result.fold", fold_fn) catch {};
        }
        {
            // Result.and_then : (a -> Result b c) -> Result a c -> Result b c (i64, i64 -> i64)
            var abt_params: [2]types.LLVMTypeRef = .{ i64_type, i64_type };
            const abt_type = core.LLVMFunctionType(i64_type, &abt_params, 2, 0);
            const abt_fn = core.LLVMAddFunction(self.module, "ko_result_and_then", abt_type);
            _ = self.named_values.put("Result.and_then", abt_fn) catch {};
        }
    }

    pub fn mapBuiltinsToNative(self: *Codegen, jit_engine: types.LLVMExecutionEngineRef) void {
        // Only map external functions that need C runtime (I/O)
        // All other stdlib functions are now generated as LLVM IR in the module
        const println_fn = self.named_values.get("println") orelse return;
        const print_fn = self.named_values.get("print") orelse return;
        const inspect_fn = self.named_values.get("inspect") orelse return;
        engine.LLVMAddGlobalMapping(jit_engine, println_fn, @ptrCast(@constCast(&builtin_println_tag)));
        engine.LLVMAddGlobalMapping(jit_engine, print_fn, @ptrCast(@constCast(&builtin_print_tag)));
        engine.LLVMAddGlobalMapping(jit_engine, inspect_fn, @ptrCast(@constCast(&builtin_inspect_tag)));

        // Map malloc/free to system implementations
        if (self.named_values.get("malloc")) |malloc_fn| {
            engine.LLVMAddGlobalMapping(jit_engine, malloc_fn, @ptrCast(@constCast(&malloc_wrapper)));
        }
        if (self.named_values.get("free")) |free_fn| {
            engine.LLVMAddGlobalMapping(jit_engine, free_fn, @ptrCast(@constCast(&free_wrapper)));
        }
        // Map Result operations to native implementations
        if (self.named_values.get("Result.is_ok")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_result_is_ok)));
        }
        if (self.named_values.get("Result.is_err")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_result_is_err)));
        }
        if (self.named_values.get("Result.unwrap")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_result_unwrap)));
        }
        if (self.named_values.get("Result.map")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_result_map)));
        }
        if (self.named_values.get("Result.fold")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_result_fold)));
        }
        if (self.named_values.get("Result.and_then")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_result_and_then)));
        }
        // All other functions (RC, stack check, math, string, int) are now
        // generated as LLVM IR in the module — no mapping needed
        // Map C-backed string functions to native Zig implementations
        if (self.named_values.get("String.contains")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_string_contains)));
        }
        if (self.named_values.get("String.charAt")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_string_char_at)));
        }
        if (self.named_values.get("String.toUpperCase")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_string_to_upper)));
        }
        if (self.named_values.get("String.toLowerCase")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_string_to_lower)));
        }
        if (self.named_values.get("String.trim")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_string_trim)));
        }
        if (self.named_values.get("String.replace")) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @ptrCast(@constCast(&stdlib.ko_string_replace)));
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

                    // Generate wrapper function for this constructor
                    const arity = ctor.params.len;
                    var param_types: [32]types.LLVMTypeRef = undefined;
                    for (0..arity) |j| {
                        param_types[j] = core.LLVMInt64TypeInContext(self.context);
                    }
                    const fn_type = core.LLVMFunctionType(
                        core.LLVMInt64TypeInContext(self.context),
                        if (arity > 0) @ptrCast(&param_types) else null,
                        @intCast(arity),
                        0,
                    );
                    const name_z = try self.allocator.dupeZ(u8, ctor.name);
                    const wrapper_fn = core.LLVMAddFunction(self.module, name_z, fn_type);
                    try self.constructor_fns.put(ctor.name, wrapper_fn);
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
            .constructor => |c| blk: {
                // Named type (e.g., a sum type) — default to i64
                _ = c;
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
            .float_literal => |val| blk: {
                const double_val = core.LLVMConstReal(core.LLVMDoubleTypeInContext(self.context), val);
                const i64_type = core.LLVMInt64TypeInContext(self.context);
                break :blk core.LLVMConstBitCast(double_val, i64_type);
            },
            .bool_literal => |val| core.LLVMConstInt(core.LLVMInt1TypeInContext(self.context), @intFromBool(val), 0),
            .char_literal => |val| blk: {
                // Char literal includes quotes, strip them
                const inner = if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'')
                    val[1 .. val.len - 1]
                else
                    val;
                // Char literal is a single character, represent as i64
                if (inner.len == 0) break :blk core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0);
                break :blk core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), inner[0], 0);
            },
            .string_literal => |val| blk: {
                // Strip surrounding quotes from the literal
                const inner = if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"')
                    val[1 .. val.len - 1]
                else
                    val;
                // Create a global string constant and return a pointer to it
                const str_val = core.LLVMConstStringInContext(self.context, @ptrCast(inner.ptr), @intCast(inner.len), NULL_TERMINATE);
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
            .identifier => |id| {
                if (self.named_values.get(id.name)) |val| return val;
                if (self.current_module) |module_name| {
                    const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, id.name });
                    defer self.allocator.free(qualified);
                    if (self.named_values.get(qualified)) |val| return val;
                }
                return error.UndefinedVariable;
            },
            .constructor => |c| {
                if (self.constructor_tags.get(c.name)) |info| {
                    // Multi-arity constructors: return wrapper function pointer (callable)
                    if (info.arity > 0) {
                        if (self.constructor_fns.get(c.name)) |fn_val| {
                            return core.LLVMBuildPtrToInt(self.builder, fn_val, core.LLVMInt64TypeInContext(self.context), "ctor_fn_ptr");
                        }
                    }
                    // Zero-arity constructors: return raw tag (data value)
                    return core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(info.tag), 0);
                }
                return error.UndefinedVariable;
            },
            .binary_op => |b| try self.codegenBinaryOp(b.op, b.left, b.right),
            .unary_op => |u| try self.codegenUnaryOp(u.op, u.expr),
            .fn_call => |call| try self.codegenFnCall(call),
            .if_expr => |i| try self.codegenIf(i),
            .block => |b| try self.codegenBlock(b.items),
            .let_expr => |l| try self.codegenLetExpr(l),
            .match_expr => |m| try self.codegenMatch(m.value, m.arms),
            .record_literal => |r| try self.codegenRecordLiteral(r.name, r.fields),
            .field_access => |fa| try self.codegenFieldAccess(fa.object, fa.field),
            .tuple => |t| try self.codegenTuple(t.items),
            .lambda => |lam| try self.codegenLambda(lam.params, lam.body),
            .comptime_expr => |inner| blk: {
                // Try compile-time evaluation
                if (self.comptime_world.evaluate(inner)) |val| {
                    break :blk self.comptimeValueToLlvm(val);
                }
                // Fallback: runtime evaluation
                break :blk self.codegenExpr(inner);
            },
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
            .cons => "cons",
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
            .cons => blk: {
                // desugar: left :: right  →  Cons left right
                const ctor_fn = self.constructor_fns.get("Cons") orelse return error.UndefinedVariable;
                var args: [2]types.LLVMValueRef = .{ l, r };
                const fn_type = core.LLVMGlobalGetValueType(ctor_fn);
                const result = core.LLVMBuildCall2(self.builder, fn_type, ctor_fn, &args, 2, "cons");
                break :blk result;
            },
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
            .try_op => {
                // expr? : check if Result is Ok(0) or Err(1)
                // Result is a heap-allocated tagged struct: { tag(8 bytes), value(8 bytes) }
                // val is ptrtoint of the allocation
                const i64_type = core.LLVMInt64TypeInContext(self.context);
                const ptr_type = core.LLVMPointerTypeInContext(self.context, 0);
                var result_struct_fields: [2]types.LLVMTypeRef = .{ i64_type, i64_type };
                const result_struct = core.LLVMStructTypeInContext(self.context, @ptrCast(&result_struct_fields), 2, 0);

                // Convert i64 back to pointer
                const result_ptr = core.LLVMBuildIntToPtr(self.builder, val, ptr_type, "result_ptr");

                // Load the tag (first i64 at offset 0)
                var tag_gep_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 0, 0) };
                const tag_ptr = core.LLVMBuildGEP2(self.builder, result_struct, result_ptr, @ptrCast(&tag_gep_args), 2, "tag_ptr");
                const tag = core.LLVMBuildLoad2(self.builder, i64_type, tag_ptr, "tag");

                // Create blocks
                const current_fn = core.LLVMGetBasicBlockParent(core.LLVMGetInsertBlock(self.builder));
                const ok_bb = core.LLVMAppendBasicBlockInContext(self.context, current_fn, "try_ok");
                const err_bb = core.LLVMAppendBasicBlockInContext(self.context, current_fn, "try_err");
                const merge_bb = core.LLVMAppendBasicBlockInContext(self.context, current_fn, "try_merge");

                // tag == 0 → Ok, tag == 1 → Err
                const is_ok = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, tag, core.LLVMConstInt(i64_type, 0, 0), "is_ok");
                _ = core.LLVMBuildCondBr(self.builder, is_ok, ok_bb, err_bb);

                // Ok branch: load the value (second i64 at offset 1)
                core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
                var val_gep_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 1, 0) };
                const val_ptr = core.LLVMBuildGEP2(self.builder, result_struct, result_ptr, @ptrCast(&val_gep_args), 2, "val_ptr");
                const unwrapped = core.LLVMBuildLoad2(self.builder, i64_type, val_ptr, "ok_val");
                _ = core.LLVMBuildBr(self.builder, merge_bb);
                const ok_exit = core.LLVMGetInsertBlock(self.builder);

                // Err branch: return the error value (will be returned by the enclosing function)
                core.LLVMPositionBuilderAtEnd(self.builder, err_bb);
                var err_gep_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 1, 0) };
                const err_ptr = core.LLVMBuildGEP2(self.builder, result_struct, result_ptr, @ptrCast(&err_gep_args), 2, "err_ptr");
                const err_val = core.LLVMBuildLoad2(self.builder, i64_type, err_ptr, "err_val");
                // Wrap error in Err constructor (tag=1)
                const err_alloc_size = core.LLVMConstInt(i64_type, 16, 0);
                var err_alloc_args: [1]types.LLVMValueRef = .{err_alloc_size};
                const ko_alloc_fn = self.named_values.get("ko_alloc") orelse return error.UndefinedVariable;
                const ko_alloc_type = core.LLVMGlobalGetValueType(ko_alloc_fn);
                const err_raw = core.LLVMBuildCall2(self.builder, ko_alloc_type, ko_alloc_fn, &err_alloc_args, 1, "err_alloc");
                var err_tag_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 0, 0) };
                const err_tag_ptr = core.LLVMBuildGEP2(self.builder, result_struct, err_raw, @ptrCast(&err_tag_gep), 2, "err_tag_ptr");
                _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(i64_type, 1, 0), err_tag_ptr);
                var err_val_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 1, 0) };
                const err_val_ptr = core.LLVMBuildGEP2(self.builder, result_struct, err_raw, @ptrCast(&err_val_gep), 2, "err_val_ptr");
                _ = core.LLVMBuildStore(self.builder, err_val, err_val_ptr);
                const err_as_ptr = core.LLVMBuildPtrToInt(self.builder, err_raw, i64_type, "err_result");
                _ = core.LLVMBuildRet(self.builder, err_as_ptr);

                // Merge: phi between ok values
                core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
                var phi_vals: [1]types.LLVMValueRef = .{unwrapped};
                var phi_blocks: [1]types.LLVMBasicBlockRef = .{ok_exit};
                const phi = core.LLVMBuildPhi(self.builder, i64_type, "try_result");
                core.LLVMAddIncoming(phi, &phi_vals, &phi_blocks, 1);
                return phi;
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
        self.trackHeapAlloc(raw_ptr);
        _ = core.LLVMBuildStore(self.builder, val, raw_ptr);
        return core.LLVMBuildPtrToInt(self.builder, raw_ptr, i64_type, "ref_val");
    }

    /// Create a global string constant and return a pointer to it as LLVMValueRef
    fn globalStringConstant(self: *Codegen, slice: []const u8) types.LLVMValueRef {
        const str_val = core.LLVMConstStringInContext(self.context, @ptrCast(slice.ptr), @intCast(slice.len), NULL_TERMINATE);
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

        // Call original function — need to construct function type manually for let-bound lambdas
        var orig_param_types: [32]types.LLVMTypeRef = undefined;
        for (0..total_arity) |i| {
            orig_param_types[i] = i64_type;
        }
        const fn_type = core.LLVMFunctionType(i64_type, &orig_param_types, total_arity, 0);
        const fn_ptr = core.LLVMBuildIntToPtr(self.builder, fn_val, core.LLVMPointerTypeInContext(self.context, 0), "orig_fn_ptr");
        const result = core.LLVMBuildCall2(self.builder, fn_type, fn_ptr, &call_args, @intCast(total_arity), "partial_result");
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
        self.trackHeapAlloc(closure_ptr);

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
            // Mark heap values stored in the closure as consumed (closure takes ownership)
            if (self.scope_heap_values.items.len > 0) {
                for (self.scope_heap_values.items) |hv| {
                    if (hv == arg) {
                        self.markConsumed(arg);
                        break;
                    }
                }
            }
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
            const name = call.func.constructor.name;
            if (self.constructor_tags.get(name)) |info| {
                // Zero-arg constructor: return the tag
                if (call.args.len == 0) {
                    return core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(info.tag), 0);
                }
                // Constructor with args: allocate tagged struct on heap, store tag + args
                const i64_type = core.LLVMInt64TypeInContext(self.context);
                // For single-arg constructors, pack the value with the tag
                if (call.args.len == 1) {
                    var arg_val = try self.codegenExpr(call.args[0]);
                    // Box zero-arg constructor args: wrap raw tag in a heap-allocated struct
                    if (call.args[0].* == .constructor) {
                        if (self.constructor_tags.get(call.args[0].constructor.name)) |arg_info| {
                            if (arg_info.arity == 0) {
                                arg_val = try self.boxZeroArgCtor(arg_info.tag, i64_type);
                            }
                        }
                    }
                    // Mark heap values stored in the constructor as consumed (parent takes ownership)
                    if (self.scope_heap_values.items.len > 0) {
                        for (self.scope_heap_values.items) |hv| {
                            if (hv == arg_val) {
                                self.markConsumed(arg_val);
                                break;
                            }
                        }
                    }
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
                    self.trackHeapAlloc(raw_ptr);
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
                    var arg_val = try self.codegenExpr(arg);
                    // Box zero-arg constructor args: wrap raw tag in a heap-allocated struct
                    if (arg.* == .constructor) {
                        if (self.constructor_tags.get(arg.constructor.name)) |arg_info| {
                            if (arg_info.arity == 0) {
                                arg_val = try self.boxZeroArgCtor(arg_info.tag, i64_type);
                            }
                        }
                    }
                    // Mark heap values stored in the constructor as consumed (parent takes ownership)
                    if (self.scope_heap_values.items.len > 0) {
                        for (self.scope_heap_values.items) |hv| {
                            if (hv == arg_val) {
                                self.markConsumed(arg_val);
                                break;
                            }
                        }
                    }
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
                self.trackHeapAlloc(raw_ptr);
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
            const name = call.func.identifier.name;
            if (self.named_values.get(name)) |fn_val| {
                if (std.mem.eql(u8, name, "println") or std.mem.eql(u8, name, "print")) {
                    if (call.args.len == 1) {
                        var arg_val = try self.codegenExpr(call.args[0]);
                        const arg_expr = call.args[0];
                        const i64_type = core.LLVMInt64TypeInContext(self.context);
                        // String/char literals produce ptr, but the C function expects i64 — convert
                        if (arg_expr.* == .string_literal) {
                            arg_val = core.LLVMBuildPtrToInt(self.builder, arg_val, i64_type, "str_as_int");
                        }
                        // Use inferred type tag from typechecker when available
                        const type_tag: i64 = if (self.expr_type_tags) |tags|
                            tags.get(arg_expr) orelse 100
                        else switch (arg_expr.*) {
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
                        // Float values (including via identifiers) need bitcast to i64
                        if (type_tag == 1) {
                            arg_val = core.LLVMBuildBitCast(self.builder, arg_val, i64_type, "float_as_int");
                        }
                        const tag_val = core.LLVMConstInt(i64_type, @bitCast(type_tag), 0);
                        var args: [2]types.LLVMValueRef = .{ arg_val, tag_val };
                        const fn_type = core.LLVMGlobalGetValueType(fn_val);
                        return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, 2, "builtin_call");
                    }
                }
                if (std.mem.eql(u8, name, "inspect")) {
                    if (call.args.len == 1) {
                        var arg_val = try self.codegenExpr(call.args[0]);
                        const arg_expr = call.args[0];
                        const i64_type = core.LLVMInt64TypeInContext(self.context);
                        // String literals produce ptr, but inspect expects i64 — convert
                        if (arg_expr.* == .string_literal) {
                            arg_val = core.LLVMBuildPtrToInt(self.builder, arg_val, i64_type, "str_as_int");
                        }
                        // Use inferred type tag from typechecker when available
                        const type_tag: i64 = if (self.expr_type_tags) |tags|
                            tags.get(arg_expr) orelse 100
                        else switch (arg_expr.*) {
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
                        // Float values (including via identifiers) need bitcast to i64
                        if (type_tag == 1) {
                            arg_val = core.LLVMBuildBitCast(self.builder, arg_val, i64_type, "float_as_int");
                        }
                        var name_ptr_val: types.LLVMValueRef = core.LLVMConstNull(core.LLVMPointerTypeInContext(self.context, 0));
                        if (arg_expr.* == .constructor) {
                            name_ptr_val = self.globalStringConstant(arg_expr.constructor.name);
                        } else if (arg_expr.* == .identifier) {
                            name_ptr_val = self.globalStringConstant(arg_expr.identifier.name);
                        } else if (arg_expr.* == .record_literal) {
                            name_ptr_val = self.globalStringConstant(arg_expr.record_literal.name);
                        }
                        const tag_val = core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(type_tag), 0);
                        const raw_zero = core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0);
                        var args: [4]types.LLVMValueRef = .{ arg_val, tag_val, name_ptr_val, raw_zero };
                        const fn_type = core.LLVMGlobalGetValueType(fn_val);
                        return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, 4, "inspect_call");
                    }
                }
            }
        }

        // Comptime function call interception:
        // If the callee is an identifier for a comptime function and all args
        // are evaluable at compile time, fold the call at compile time.
        if (call.func.* == .identifier) {
            const name = call.func.identifier.name;
            if (self.comptime_world.functions.get(name)) |fn_def| {
                if (fn_def.is_comptime and call.args.len == fn_def.params.len) {
                    var comptime_args: [32]comptime_mod.ComptimeValue = undefined;
                    var all_comptime = true;
                    for (call.args, 0..) |arg, i| {
                        if (self.comptime_world.evaluate(arg)) |val| {
                            comptime_args[i] = val;
                        } else {
                            all_comptime = false;
                            break;
                        }
                    }
                    if (all_comptime) {
                        if (self.comptime_world.callComptimeFn(fn_def, comptime_args[0..call.args.len])) |val| {
                            return self.comptimeValueToLlvm(val);
                        }
                    }
                }
            }
        }

        const fn_val = try self.codegenExpr(call.func);
        const i64_type = core.LLVMInt64TypeInContext(self.context);

        var args: [32]types.LLVMValueRef = undefined;
        var argc: c_uint = 0;
        for (call.args) |arg| {
            var arg_val = try self.codegenExpr(arg);
            // If arg is a function pointer, convert to i64 (all Kō values are i64)
            if (core.LLVMIsAFunction(arg_val) != null) {
                arg_val = core.LLVMBuildPtrToInt(self.builder, arg_val, i64_type, "fn_as_int");
            }
            args[argc] = arg_val;
            argc += 1;
        }

        // Check if fn_val is a global function or an indirect pointer
        const is_global = core.LLVMIsAFunction(fn_val) != null;

        // For global functions, convert arguments based on parameter types
        // (e.g., builtins like Float.sqrt expect double, not i64)
        if (is_global) {
            const fn_type = core.LLVMGlobalGetValueType(fn_val);
            // Get parameter types
            const param_count = core.LLVMCountParamTypes(fn_type);
            var param_types: [32]types.LLVMTypeRef = undefined;
            core.LLVMGetParamTypes(fn_type, &param_types);
            var i: c_uint = 0;
            while (i < argc and i < param_count) : (i += 1) {
                const param_type = param_types[i];
                // If param is double but arg is i64, bitcast
                if (core.LLVMGetTypeKind(param_type) == .LLVMDoubleTypeKind and
                    core.LLVMGetTypeKind(core.LLVMTypeOf(args[i])) == .LLVMIntegerTypeKind)
                {
                    args[i] = core.LLVMBuildBitCast(self.builder, args[i], param_type, "float_arg");
                }
                // If param is i64 but arg is double, bitcast
                if (core.LLVMGetTypeKind(param_type) == .LLVMIntegerTypeKind and
                    core.LLVMGetTypeKind(core.LLVMTypeOf(args[i])) == .LLVMDoubleTypeKind)
                {
                    args[i] = core.LLVMBuildBitCast(self.builder, args[i], param_type, "int_arg");
                }
            }
        }

        // Try to resolve the function name for arity lookup (works for both global and let-bound lambdas)
        var resolved_name: ?[]const u8 = null;
        if (is_global) {
            var name_iter = self.named_values.iterator();
            while (name_iter.next()) |entry| {
                if (entry.value_ptr.* == fn_val) {
                    resolved_name = entry.key_ptr.*;
                    break;
                }
            }
        } else if (call.func.* == .identifier) {
            resolved_name = call.func.identifier.name;
        }

        if (is_global) {
            if (resolved_name) |name| {
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
                    const fn_type = core.LLVMGlobalGetValueType(fn_val);
                    return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, argc, "call");
                }
            }
            // Fallback: direct call
            const fn_type = core.LLVMGlobalGetValueType(fn_val);
            return core.LLVMBuildCall2(self.builder, fn_type, fn_val, &args, argc, "call");
        } else {
            // For let-bound lambdas with known arity, create partial application if needed
            if (resolved_name) |name| {
                if (self.fn_arity.get(name)) |arity| {
                    if (argc < arity) {
                        // Create a partial application closure for let-bound lambda
                        return self.createPartialApp(name, fn_val, arity, args[0..argc]);
                    }
                }
            }
            // Runtime check: bit 0 = partial application closure, bit 0 = 0 = raw function pointer
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

        // Track that we're inside a conditional branch
        self.conditional_depth += 1;
        defer self.conditional_depth -= 1;

        core.LLVMPositionBuilderAtEnd(self.builder, then_bb);
        const then_val = try self.codegenExpr(if_expr.then_branch);
        const then_exit = core.LLVMGetInsertBlock(self.builder);
        _ = core.LLVMBuildBr(self.builder, merge_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, else_bb);
        const else_val = if (if_expr.else_branch) |eb|
            try self.codegenExpr(eb)
        else
            core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0);
        const else_exit = core.LLVMGetInsertBlock(self.builder);
        _ = core.LLVMBuildBr(self.builder, merge_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        const phi = core.LLVMBuildPhi(self.builder, core.LLVMInt64TypeInContext(self.context), "iftmp");
        var incoming_vals: [2]types.LLVMValueRef = .{ then_val, else_val };
        var incoming_bbs: [2]types.LLVMBasicBlockRef = .{ then_exit, else_exit };
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
        if (let.pattern) |pat| {
            // Tuple destructuring: extract each element and bind to names
            if (pat == .tuple) {
                const i64_type = core.LLVMInt64TypeInContext(self.context);
                const tuple_patterns = pat.tuple;
                for (tuple_patterns, 0..) |tp, j| {
                    if (tp == .identifier) {
                        var elem_gep: [2]types.LLVMValueRef = .{
                            core.LLVMConstInt(i64_type, 0, 0),
                            core.LLVMConstInt(i64_type, j, 0),
                        };
                        const tuple_ptr_type = core.LLVMArrayType(i64_type, @intCast(tuple_patterns.len));
                        const tuple_ptr = core.LLVMBuildIntToPtr(self.builder, val, core.LLVMPointerTypeInContext(self.context, 0), "tuple_ptr");
                        const elem_ptr = core.LLVMBuildGEP2(self.builder, tuple_ptr_type, tuple_ptr, @ptrCast(&elem_gep), 2, "elem_ptr");
                        const elem_val = core.LLVMBuildLoad2(self.builder, i64_type, elem_ptr, "elem_val");
                        try self.named_values.put(tp.identifier, elem_val);
                    }
                }
            }
        } else {
            try self.named_values.put(let.name, val);
            // Track record type for field access
            if (let.value.* == .record_literal) {
                try self.variable_types.put(let.name, let.value.record_literal.name);
            }
            // Track lambda arity for partial application support
            if (let.value.* == .lambda) {
                try self.fn_arity.put(let.name, @intCast(let.value.lambda.params.len));
            }
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
        self.trackHeapAlloc(raw_ptr);

        // Store each field (raw_ptr is already ptr type)
        for (fields, 0..) |field, i| {
            const field_val = try self.codegenExpr(field.value);
            // Mark heap values stored in the record as consumed (parent takes ownership)
            if (self.scope_heap_values.items.len > 0) {
                for (self.scope_heap_values.items) |hv| {
                    if (hv == field_val) {
                        self.markConsumed(field_val);
                        break;
                    }
                }
            }
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

    fn comptimeValueToLlvm(self: *Codegen, val: comptime_mod.ComptimeValue) types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);
        return switch (val) {
            .int => |i| core.LLVMConstInt(i64_type, @bitCast(i), 0),
            .float => |f| blk: {
                const double_val = core.LLVMConstReal(core.LLVMDoubleTypeInContext(self.context), f);
                break :blk core.LLVMConstBitCast(double_val, i64_type);
            },
            .bool_val => |b| core.LLVMConstInt(core.LLVMInt1TypeInContext(self.context), @intFromBool(b), 0),
            .char => |c| core.LLVMConstInt(i64_type, c, 0),
            .string => |s| blk: {
                // Create global string constant
                const str_val = core.LLVMConstStringInContext(self.context, @ptrCast(s.ptr), @intCast(s.len), NULL_TERMINATE);
                const global = core.LLVMAddGlobal(self.module, core.LLVMTypeOf(str_val), "str");
                core.LLVMSetInitializer(global, str_val);
                core.LLVMSetGlobalConstant(global, 1);
                core.LLVMSetLinkage(global, .LLVMPrivateLinkage);
                var indices: [1]types.LLVMValueRef = .{core.LLVMConstInt(i64_type, 0, 0)};
                break :blk core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), global, @ptrCast(&indices), 1, "str_ptr");
            },
            .unit => core.LLVMConstInt(i64_type, 0, 0),
        };
    }

    fn codegenFieldAccess(self: *Codegen, object: *const parser.Expr, field_name: []const u8) Error!types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);

        // Check for module-qualified names (e.g., Math.add)
        if (object.* == .identifier or object.* == .constructor) {
            const obj_name = switch (object.*) {
                .identifier => |n| n.name,
                .constructor => |n| n.name,
                else => unreachable,
            };
            const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ obj_name, field_name });
            if (self.named_values.get(combined)) |val| return val;
            if (self.fn_types.get(combined)) |_| {
                // Module function reference — return the function pointer
                if (self.named_values.get(combined)) |fn_val| return fn_val;
            }
            // Check for module-qualified constructor (e.g., colors.Red)
            if (self.constructor_tags.get(combined)) |info| {
                return core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(info.tag), 0);
            }
        }

        // Get the object value (should be a record pointer as i64)
        const obj_val = try self.codegenExpr(object);

        // Determine the record type from variable tracking
        var record_name: ?[]const u8 = null;
        if (object.* == .identifier) {
            if (self.variable_types.get(object.identifier.name)) |tn| {
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
        self.trackHeapAlloc(raw_ptr);

        for (elems, 0..) |elem, i| {
            const val = try self.codegenExpr(elem);
            // Mark heap values stored in the tuple as consumed (parent takes ownership)
            if (self.scope_heap_values.items.len > 0) {
                for (self.scope_heap_values.items) |hv| {
                    if (hv == val) {
                        self.markConsumed(val);
                        break;
                    }
                }
            }
            // Use i8* GEP for byte-level offset
            const offset = core.LLVMConstInt(i64_type, i * 8, 0);
            const elem_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), raw_ptr, @constCast(&[_]types.LLVMValueRef{offset}), 1, "elem_off");
            _ = core.LLVMBuildStore(self.builder, val, elem_ptr);
        }
        return core.LLVMBuildPtrToInt(self.builder, raw_ptr, i64_type, "tuple_ptr");
    }

    // =========================================================================
    // Closure conversion helpers
    // =========================================================================

    /// Collect free variable names from an expression that are in `bound` set
    fn collectFreeVars(expr: *const parser.Expr, bound: *std.StringHashMap(void), free_vars: *std.StringHashMap(void)) void {
        switch (expr.*) {
            .identifier => |id| {
                if (!bound.contains(id.name)) {
                    free_vars.put(id.name, {}) catch {};
                }
            },
            .constructor => {},
            .int_literal, .float_literal, .bool_literal, .string_literal, .char_literal => {},
            .binary_op => |b| {
                collectFreeVars(b.left, bound, free_vars);
                collectFreeVars(b.right, bound, free_vars);
            },
            .unary_op => |u| collectFreeVars(u.expr, bound, free_vars),
            .fn_call => |call| {
                collectFreeVars(call.func, bound, free_vars);
                for (call.args) |arg| collectFreeVars(arg, bound, free_vars);
                for (call.named_args) |na| collectFreeVars(na.value, bound, free_vars);
            },
            .lambda => |lam| {
                var inner_bound = std.StringHashMap(void).init(bound.allocator);
                defer inner_bound.deinit();
                var iter = bound.iterator();
                while (iter.next()) |e| inner_bound.put(e.key_ptr.*, {}) catch {};
                for (lam.params) |p| {
                    if (p == .identifier) inner_bound.put(p.identifier, {}) catch {};
                }
                collectFreeVars(lam.body, &inner_bound, free_vars);
            },
            .let_expr => |le| {
                collectFreeVars(le.value, bound, free_vars);
                var inner_bound = std.StringHashMap(void).init(bound.allocator);
                defer inner_bound.deinit();
                var iter = bound.iterator();
                while (iter.next()) |e| inner_bound.put(e.key_ptr.*, {}) catch {};
                inner_bound.put(le.name, {}) catch {};
                collectFreeVars(le.body, &inner_bound, free_vars);
            },
            .if_expr => |ie| {
                collectFreeVars(ie.condition, bound, free_vars);
                collectFreeVars(ie.then_branch, bound, free_vars);
                if (ie.else_branch) |eb| collectFreeVars(eb, bound, free_vars);
            },
            .match_expr => |me| {
                collectFreeVars(me.value, bound, free_vars);
                for (me.arms) |arm| {
                    var arm_bound = std.StringHashMap(void).init(bound.allocator);
                    defer arm_bound.deinit();
                    var iter = bound.iterator();
                    while (iter.next()) |e| arm_bound.put(e.key_ptr.*, {}) catch {};
                    if (arm.pattern == .constructor) {
                        for (arm.pattern.constructor.args) |arg| {
                            if (arg == .identifier) arm_bound.put(arg.identifier, {}) catch {};
                        }
                    } else if (arm.pattern == .identifier) {
                        arm_bound.put(arm.pattern.identifier, {}) catch {};
                    }
                    collectFreeVars(arm.body, &arm_bound, free_vars);
                }
            },
            .block => |b| {
                var inner_bound = std.StringHashMap(void).init(bound.allocator);
                defer inner_bound.deinit();
                var iter = bound.iterator();
                while (iter.next()) |e| inner_bound.put(e.key_ptr.*, {}) catch {};
                for (b.items) |item| {
                    collectFreeVars(item, &inner_bound, free_vars);
                }
            },
            .tuple => |t| {
                for (t.items) |item| collectFreeVars(item, bound, free_vars);
            },
            .field_access => |fa| collectFreeVars(fa.object, bound, free_vars),
            .record_literal => |r| {
                for (r.fields) |f| collectFreeVars(f.value, bound, free_vars);
            },
            .comptime_expr => |ce| collectFreeVars(ce, bound, free_vars),
            .assign_expr => |ae| {
                collectFreeVars(ae.target, bound, free_vars);
                collectFreeVars(ae.value, bound, free_vars);
            },
            .ref_expr => |re| collectFreeVars(re, bound, free_vars),
            .pat_record => {},
        }
    }

    fn codegenLambda(self: *Codegen, params: []const parser.Pattern, body: *const parser.Expr) Error!types.LLVMValueRef {
        const i64_type = core.LLVMInt64TypeInContext(self.context);

        // Detect free variables in the lambda body
        var param_names = std.StringHashMap(void).init(self.allocator);
        defer param_names.deinit();
        for (params) |p| {
            if (p == .identifier) param_names.put(p.identifier, {}) catch {};
        }
        var free_vars = std.StringHashMap(void).init(self.allocator);
        defer free_vars.deinit();
        collectFreeVars(body, &param_names, &free_vars);

        const has_captures = free_vars.count() > 0;

        // Collect captured variable names and their values in a deterministic order
        var captured_names: std.ArrayList([]const u8) = .empty;
        defer captured_names.deinit(self.allocator);
        var captured_values: std.ArrayList(types.LLVMValueRef) = .empty;
        defer captured_values.deinit(self.allocator);

        if (has_captures) {
            var fiter = free_vars.iterator();
            while (fiter.next()) |entry| {
                if (self.named_values.get(entry.key_ptr.*)) |val| {
                    captured_names.append(self.allocator, entry.key_ptr.*) catch {};
                    captured_values.append(self.allocator, val) catch {};
                }
            }
        }

        // Save current builder position
        const saved_block = core.LLVMGetInsertBlock(self.builder);

        // Create function type: if closures, extra param for closure_ptr
        const extra_params: usize = if (has_captures) 1 else 0;
        var param_types: [33]types.LLVMTypeRef = undefined;
        if (has_captures) {
            param_types[0] = core.LLVMPointerTypeInContext(self.context, 0); // closure_ptr
        }
        for (params, 0..) |_, i| {
            param_types[extra_params + i] = i64_type;
        }
        const total_params = @as(c_uint, @intCast(extra_params + params.len));
        const fn_type = core.LLVMFunctionType(i64_type, &param_types[0], total_params, 0);

        // Generate unique name
        const lambda_name_slice = try std.fmt.allocPrint(self.allocator, "lambda_{d}", .{@intFromPtr(body)});
        defer self.allocator.free(lambda_name_slice);
        const lambda_name = try self.dupeZ(lambda_name_slice);

        const func = core.LLVMAddFunction(self.module, lambda_name, fn_type);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, func, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        // Stack overflow check
        if (self.named_values.get("ko_check_stack")) |check_fn| {
            const check_type = core.LLVMGlobalGetValueType(check_fn);
            _ = core.LLVMBuildCall2(self.builder, check_type, check_fn, null, 0, "");
        }

        // Save and restore scope
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

        // Copy outer scope (for global functions, builtins, etc.)
        var iter = old_values.iterator();
        while (iter.next()) |entry_pair| {
            try self.named_values.put(entry_pair.key_ptr.*, entry_pair.value_ptr.*);
        }
        var vt_iter = old_var_types.iterator();
        while (vt_iter.next()) |entry_pair| {
            try self.variable_types.put(entry_pair.key_ptr.*, entry_pair.value_ptr.*);
        }

        // If we have captures, load them from the closure struct
        if (has_captures) {
            const closure_ptr = core.LLVMGetParam(func, 0);
            core.LLVMSetValueName(closure_ptr, "closure_ptr");
            const i8_type = core.LLVMInt8TypeInContext(self.context);

            // Closure layout: [ fn_ptr(8) | captured_0(8) | captured_1(8) | ... ]
            // Offset starts at 8 (skip fn_ptr)
            for (captured_names.items, 0..) |name, i| {
                const offset_val: i64 = @intCast(8 + i * 8);
                const offset = core.LLVMConstInt(i64_type, @bitCast(offset_val), 0);
                const elem_ptr = core.LLVMBuildGEP2(self.builder, i8_type, closure_ptr, @constCast(&[_]types.LLVMValueRef{offset}), 1, "cap_ptr");
                const loaded = core.LLVMBuildLoad2(self.builder, i64_type, elem_ptr, "cap_val");
                try self.named_values.put(name, loaded);
            }
        }

        // Add parameters
        for (params, 0..) |param, i| {
            const param_val = core.LLVMGetParam(func, @intCast(extra_params + i));
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

        // Restore builder
        core.LLVMPositionBuilderAtEnd(self.builder, saved_block);

        if (!has_captures) {
            // No captures: return raw function pointer (bit 0 = 0)
            return core.LLVMBuildPtrToInt(self.builder, func, i64_type, "fn_ptr");
        }

        // Has captures: create closure struct on heap
        // Layout: { fn_ptr, captured_0, captured_1, ... }
        const alloc_fn = self.named_values.get("ko_alloc") orelse return error.UndefinedVariable;
        const alloc_fn_type = core.LLVMGlobalGetValueType(alloc_fn);
        const struct_size = 8 + 8 * @as(i64, @intCast(captured_names.items.len));
        const alloc_size = core.LLVMConstInt(i64_type, @bitCast(struct_size), 0);
        const closure_ptr = core.LLVMBuildCall2(self.builder, alloc_fn_type, alloc_fn, @constCast(&[_]types.LLVMValueRef{alloc_size}), 1, "closure");
        self.trackHeapAlloc(closure_ptr);

        const i8_type = core.LLVMInt8TypeInContext(self.context);

        // Store fn_ptr at offset 0
        const fn_ptr_as_int = core.LLVMBuildPtrToInt(self.builder, func, i64_type, "fn_ptr_int");
        const fn_ptr_ptr = core.LLVMBuildGEP2(self.builder, i8_type, closure_ptr, @constCast(&[_]types.LLVMValueRef{core.LLVMConstInt(i64_type, 0, 0)}), 1, "fn_ptr_ptr");
        _ = core.LLVMBuildStore(self.builder, fn_ptr_as_int, fn_ptr_ptr);

        // Store captured values at offsets 8, 16, 24, ...
        for (captured_values.items, 0..) |cap_val, i| {
            // Mark heap values captured by the closure as consumed (closure takes ownership)
            if (self.scope_heap_values.items.len > 0) {
                for (self.scope_heap_values.items) |hv| {
                    if (hv == cap_val) {
                        self.markConsumed(cap_val);
                        break;
                    }
                }
            }
            const offset_val2: i64 = @intCast(8 + i * 8);
            const offset = core.LLVMConstInt(i64_type, @bitCast(offset_val2), 0);
            const cap_ptr = core.LLVMBuildGEP2(self.builder, i8_type, closure_ptr, @constCast(&[_]types.LLVMValueRef{offset}), 1, "cap_ptr");
            _ = core.LLVMBuildStore(self.builder, cap_val, cap_ptr);
        }

        // Return closure pointer with bit 0 set (tag for closure)
        const closure_i64 = core.LLVMBuildPtrToInt(self.builder, closure_ptr, i64_type, "closure_as_int");
        return core.LLVMBuildOr(self.builder, closure_i64, core.LLVMConstInt(i64_type, 1, 0), "tagged_closure");
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
                        const tag_const = core.LLVMConstInt(i64_type, @bitCast(info.tag), 0);
                        if (info.arity == 0) {
                            // Zero-arg constructor: could be raw tag (e.g., Nil = 1)
                            // or boxed pointer (when used as argument to another ctor).
                            // Use branching to avoid dereferencing a raw tag:
                            //   if (val < 4096) -> compare val directly against tag
                            //   else -> dereference, read tag, compare
                            const threshold = core.LLVMConstInt(i64_type, 4096, 0);
                            const is_raw = core.LLVMBuildICmp(self.builder, .LLVMIntULT, match_val, threshold, "is_raw");
                            const raw_cmp_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "raw_cmp_bb");
                            const boxed_cmp_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "boxed_cmp_bb");
                            _ = core.LLVMBuildCondBr(self.builder, is_raw, raw_cmp_bb, boxed_cmp_bb);
                            // Raw path: compare match_val against tag directly (no deref)
                            core.LLVMPositionBuilderAtEnd(self.builder, raw_cmp_bb);
                            const raw_cmp = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, match_val, tag_const, "raw_cmp");
                            _ = core.LLVMBuildCondBr(self.builder, raw_cmp, body_bbs[i], fallthrough);
                            // Boxed path: dereference and read tag at offset 0
                            core.LLVMPositionBuilderAtEnd(self.builder, boxed_cmp_bb);
                            const boxed_struct_type = core.LLVMStructTypeInContext(self.context, @constCast(&[_]types.LLVMTypeRef{i64_type}), 1, 0);
                            const boxed_ptr = core.LLVMBuildIntToPtr(self.builder, match_val, core.LLVMPointerTypeInContext(self.context, 0), "boxed_ptr");
                            var boxed_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 0, 0) };
                            const boxed_tag_ptr = core.LLVMBuildGEP2(self.builder, boxed_struct_type, boxed_ptr, @ptrCast(&boxed_gep), 2, "boxed_tag_ptr");
                            const boxed_tag = core.LLVMBuildLoad2(self.builder, i64_type, boxed_tag_ptr, "boxed_tag_val");
                            const boxed_cmp = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, boxed_tag, tag_const, "boxed_cmp");
                            _ = core.LLVMBuildCondBr(self.builder, boxed_cmp, body_bbs[i], fallthrough);
                        } else {
                            // Multi-arg constructor: value is a heap pointer, tag is at offset 0
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
                            const actual_tag = core.LLVMBuildLoad2(self.builder, i64_type, tag_ptr, "tag_val");
                            const cmp = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, actual_tag, tag_const, "cmp");
                            _ = core.LLVMBuildCondBr(self.builder, cmp, body_bbs[i], fallthrough);
                        }
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
                .literal => |lit| {
                    // Compare match_val against literal value
                    const lit_val = switch (lit) {
                        .int => |v| core.LLVMConstInt(i64_type, @bitCast(v), 0),
                        .bool => |v| core.LLVMConstInt(i64_type, if (v) 1 else 0, 0),
                        .char => |v| core.LLVMConstInt(i64_type, v[0], 0),
                        else => {
                            // Non-comparable literals just fall through (like wildcard)
                            _ = core.LLVMBuildBr(self.builder, body_bbs[i]);
                            continue;
                        },
                    };
                    const cmp = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, match_val, lit_val, "lit_cmp");
                    _ = core.LLVMBuildCondBr(self.builder, cmp, body_bbs[i], fallthrough);
                },
                .tuple => {
                    // Tuple patterns: just bind all (simplified — no field extraction for now)
                    _ = core.LLVMBuildBr(self.builder, body_bbs[i]);
                },
                .identifier => |name| {
                    // Identifier pattern: bind the value
                    try self.named_values.put(name, match_val);
                    _ = core.LLVMBuildBr(self.builder, body_bbs[i]);
                },
            }
        }

        // Codegen each arm body (in sorted order)
        var phi_vals: [32]types.LLVMValueRef = undefined;
        var phi_bbs: [32]types.LLVMBasicBlockRef = undefined;
        var phi_count: usize = 0;

        // Track that we're inside conditional branches (match arms)
        self.conditional_depth += 1;
        defer self.conditional_depth -= 1;

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

            // Bind tuple pattern fields
            if (arm.pattern == .tuple) {
                const tuple_patterns = arm.pattern.tuple;
                // match_val is a ptrtoint of the tuple allocation
                // Tuple layout: [N x i64] at offset 1 (after the count header)
                for (tuple_patterns, 0..) |tp, j| {
                    if (tp == .identifier) {
                        // Extract element j from the tuple
                        var elem_gep: [2]types.LLVMValueRef = .{
                            core.LLVMConstInt(i64_type, 0, 0),
                            core.LLVMConstInt(i64_type, j, 0),
                        };
                        const tuple_ptr_type = core.LLVMArrayType(i64_type, @intCast(tuple_patterns.len));
                        const tuple_ptr = core.LLVMBuildIntToPtr(self.builder, match_val, core.LLVMPointerTypeInContext(self.context, 0), "tuple_ptr");
                        const elem_ptr = core.LLVMBuildGEP2(self.builder, tuple_ptr_type, tuple_ptr, @ptrCast(&elem_gep), 2, "elem_ptr");
                        const elem_val = core.LLVMBuildLoad2(self.builder, i64_type, elem_ptr, "elem_val");
                        try self.named_values.put(tp.identifier, elem_val);
                    }
                }
            }

            var arm_val = try self.codegenExpr(arm.body);
            // Box zero-arg constructors returned from match arms
            // (e.g., `| Nil => Nil` in map — without boxing, Nil returns raw tag 1
            // which segfaults when the caller tries to pattern-match it as a pointer)
            if (arm.body.* == .constructor) {
                if (self.constructor_tags.get(arm.body.constructor.name)) |info| {
                    if (info.arity == 0) {
                        arm_val = try self.boxZeroArgCtor(info.tag, i64_type);
                    }
                }
            }
            // Record the block where the builder ended up AFTER codegen'ing the arm body.
            // This may differ from body_bbs[i] if the arm body contains function calls
            // (which create intermediate basic blocks like call_merge).
            const arm_exit_bb = core.LLVMGetInsertBlock(self.builder);
            _ = core.LLVMBuildBr(self.builder, merge_bb);
            phi_vals[phi_count] = arm_val;
            phi_bbs[phi_count] = arm_exit_bb;
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
    // Constructor wrapper codegen
    // =========================================================================

    fn codegenConstructorFn(self: *Codegen, wrapper_fn: types.LLVMValueRef, info: CtorInfo) Error!void {
        const i64_type = core.LLVMInt64TypeInContext(self.context);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, wrapper_fn, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        if (info.arity == 0) {
            // Zero-arg: return raw tag
            const tag_val = core.LLVMConstInt(i64_type, @bitCast(info.tag), 0);
            _ = core.LLVMBuildRet(self.builder, tag_val);
        } else {
            // Multi-arg: allocate tagged struct, store tag + args, return pointer
            var struct_fields: [33]types.LLVMTypeRef = undefined;
            struct_fields[0] = i64_type;
            for (0..info.arity) |j| {
                struct_fields[j + 1] = i64_type;
            }
            const tagged_type = core.LLVMStructTypeInContext(self.context, &struct_fields, @intCast(info.arity + 1), 0);

            // Allocate via ko_alloc (RC-aware)
            const struct_size = core.LLVMConstInt(i64_type, @bitCast(@as(i64, @intCast((info.arity + 1) * 8))), 0);
            const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
            var alloc_args: [1]types.LLVMValueRef = .{struct_size};
            const ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 1, "ctor_ptr");
            const struct_ptr = core.LLVMBuildBitCast(self.builder, ptr, core.LLVMPointerTypeInContext(self.context, 0), "tagged_ptr");

            // Store tag at offset 0
            var tag_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, 0, 0) };
            const tag_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, struct_ptr, @ptrCast(&tag_gep), 2, "tag_ptr");
            const tag_val = core.LLVMConstInt(i64_type, @bitCast(info.tag), 0);
            _ = core.LLVMBuildStore(self.builder, tag_val, tag_ptr);

            // Store each argument at offset 1, 2, ...
            for (0..info.arity) |j| {
                var arg_gep: [2]types.LLVMValueRef = .{ core.LLVMConstInt(i64_type, 0, 0), core.LLVMConstInt(i64_type, @intCast(j + 1), 0) };
                const arg_ptr = core.LLVMBuildGEP2(self.builder, tagged_type, struct_ptr, @ptrCast(&arg_gep), 2, "arg_ptr");
                const param = core.LLVMGetParam(wrapper_fn, @intCast(j));
                _ = core.LLVMBuildStore(self.builder, param, arg_ptr);
            }

            // Return pointer as i64
            _ = core.LLVMBuildRet(self.builder, core.LLVMBuildPtrToInt(self.builder, struct_ptr, i64_type, "ptr_as_int"));
        }
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

        // Stack overflow detection: init at main entry, check at every other function entry
        if (std.mem.eql(u8, fn_def.name, "main")) {
            if (self.named_values.get("ko_init_stack")) |init_fn| {
                const init_type = core.LLVMGlobalGetValueType(init_fn);
                _ = core.LLVMBuildCall2(self.builder, init_type, init_fn, null, 0, "");
            }
        } else {
            if (self.named_values.get("ko_check_stack")) |check_fn| {
                const check_type = core.LLVMGlobalGetValueType(check_fn);
                _ = core.LLVMBuildCall2(self.builder, check_type, check_fn, null, 0, "");
            }
        }

        // Check for tail-position self-recursive call (TCO)
        {
            // Case 1: body is directly a self-call
            if (fn_def.body.* == .fn_call) {
                const call = fn_def.body.fn_call;
                if (call.func.* == .identifier and std.mem.eql(u8, call.func.identifier.name, fn_def.name) and call.named_args.len == 0) {
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
                        std.mem.eql(u8, else_expr.fn_call.func.identifier.name, fn_def.name) and
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

        // Decref all heap values not consumed by parent structures
        if (self.scope_heap_values.items.len > 0) {
            self.emitDecrefAll();
        }

        // For main(): auto-return 0 unless body is a direct expression
        if (std.mem.eql(u8, fn_def.name, "main")) {
            const returns_value = switch (fn_def.body.*) {
                .int_literal => true,
                .float_literal => true,
                .bool_literal => true,
                .char_literal => true,
                .string_literal => true,
                .identifier => true,
                .constructor => true,
                .binary_op => true,
                .unary_op => true,
                .if_expr => |ie| ie.else_branch != null,
                .fn_call => true,
                .lambda => true,
                .tuple => true,
                .record_literal => true,
                .field_access => true,
                .match_expr => true,
                .let_expr => true,
                .block => true,
                .ref_expr => true,
                .assign_expr => true,
                else => false,
            };
            if (returns_value) {
                _ = core.LLVMBuildRet(self.builder, body_val);
            } else {
                _ = core.LLVMBuildRet(self.builder, core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), 0, 0));
            }
        } else {
            _ = core.LLVMBuildRet(self.builder, body_val);
        }

        return func;
    }

    // =========================================================================
    // Program codegen
    // =========================================================================

    pub fn codegenProgram(self: *Codegen, prog: parser.Program) Error!void {
        // Declare built-in functions first
        self.declareBuiltins();

        // Process imports: load, parse, and codegen imported modules
        if (self.module_loader) |loader| {
            for (prog.imports) |imp| {
                const mod = loader.loadModule(imp.path) catch |err| {
                    std.log.err("Failed to load module: {}", .{err});
                    continue;
                } orelse {
                    std.log.err("Module not found: {s}", .{std.mem.join(self.allocator, "/", imp.path) catch "unknown"});
                    continue;
                };
                const module_name = imp.alias orelse imp.path[imp.path.len - 1];
                const prev_current_module = self.current_module;
                self.current_module = module_name;
                defer self.current_module = prev_current_module;

                // Register imported type definitions
                for (mod.program.definitions) |def| {
                    if (def == .type_def) {
                        const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, def.type_def.name });
                        var td = def.type_def;
                        td.name = prefixed;
                        try self.registerTypeDef(td);
                    }
                }

                // Flatten imported module definitions with qualified names
                var imported_defs: std.ArrayList(parser.Definition) = .empty;
                defer imported_defs.deinit(self.allocator);
                for (mod.program.definitions) |def| {
                    try self.flattenDefinition(&imported_defs, def, module_name);
                }

                // Register constructors from imported types
                for (mod.program.definitions) |def| {
                    if (def == .type_def) {
                        switch (def.type_def.body) {
                            .sum => |ctors| {
                                for (ctors, 0..) |ctor, tag| {
                                    // Register qualified name (e.g., colors.Red)
                                    const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, ctor.name });
                                    try self.constructor_tags.put(prefixed, .{
                                        .type_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, def.type_def.name }),
                                        .tag = @intCast(tag),
                                        .arity = @intCast(ctor.params.len),
                                    });
                                    // Also register unqualified name so imported code can use it
                                    try self.constructor_tags.put(ctor.name, .{
                                        .type_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, def.type_def.name }),
                                        .tag = @intCast(tag),
                                        .arity = @intCast(ctor.params.len),
                                    });
                                }
                            },
                            else => {},
                        }
                    }
                }

                // First pass: declare imported function signatures
                for (imported_defs.items) |def| {
                    if (def == .fn_def) {
                        _ = try self.declareFn(def.fn_def);
                    }
                }

                // Second pass: codegen imported function bodies
                for (imported_defs.items) |def| {
                    if (def == .fn_def) {
                        _ = try self.codegenFn(def.fn_def);
                    }
                }
            }
        }

        // Flatten module definitions into prefixed names
        var all_defs: std.ArrayList(parser.Definition) = .empty;
        defer all_defs.deinit(self.allocator);
        for (prog.definitions) |def| {
            try self.flattenDefinition(&all_defs, def, "");
        }

        // Register type definitions (sum types and records)
        for (all_defs.items) |def| {
            switch (def) {
                .type_def => |t| {
                    try self.registerTypeDef(t);
                    // Populate comptime world with constructor info
                    switch (t.body) {
                        .sum => |ctors| {
                            for (ctors, 0..) |ctor, tag| {
                                try self.comptime_world.constructors.put(ctor.name, .{
                                    .type_name = t.name,
                                    .tag = @intCast(tag),
                                    .arity = @intCast(ctor.params.len),
                                });
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        // First pass: declare all function signatures so they're available for forward references
        for (all_defs.items) |def| {
            switch (def) {
                .fn_def => |f| {
                    _ = try self.declareFn(f);
                    // Store comptime function bodies in the world
                    if (f.is_comptime) {
                        try self.comptime_world.functions.put(f.name, f);
                    }
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

        // Third pass: codegen constructor wrapper function bodies
        var ctor_iter = self.constructor_tags.iterator();
        while (ctor_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;
            if (self.constructor_fns.get(name)) |wrapper_fn| {
                // Skip if already codegen'd (e.g., imported constructors)
                const existing_bb = core.LLVMGetBasicBlockParent(core.LLVMGetEntryBasicBlock(wrapper_fn));
                _ = existing_bb;
                // Only codegen if the function has no blocks yet (fresh declaration)
                if (core.LLVMCountBasicBlocks(wrapper_fn) == 0) {
                    try self.codegenConstructorFn(wrapper_fn, info);
                }
            }
        }
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

fn builtin_println_tag(val: i64, type_tag: i64) callconv(.c) i64 {
    _ = builtin_inspect_tag(val, type_tag, null, 1);
    std.debug.print("\n", .{});
    return 0;
}

fn builtin_print_tag(val: i64, type_tag: i64) callconv(.c) i64 {
    _ = builtin_inspect_tag(val, type_tag, null, 1);
    return 0;
}

// Type tags for inspect:
// 0=int, 1=float, 2=bool, 3=char, 4=string, 5=unit,
// 6=constructor, 7=record, 8=function, 9=tuple, 100=unknown
// raw=1: user output (no quotes on strings/chars); raw=0: debug output (with quotes)
fn builtin_inspect_tag(val: i64, type_tag: i64, name_ptr: ?[*:0]const u8, raw: i64) callconv(.c) i64 {
    switch (type_tag) {
        0 => std.debug.print("{d}", .{val}),
        1 => {
            const f: f64 = @bitCast(val);
            std.debug.print("{d}", .{f});
        },
        2 => {
            if (val == 0) {
                std.debug.print("True", .{});
            } else {
                std.debug.print("False", .{});
            }
        },
        3 => {
            const ch: u8 = @intCast(val);
            if (raw != 0) {
                std.debug.print("{c}", .{ch});
            } else {
                std.debug.print("'{c}'", .{ch});
            }
        },
        4 => {
            const ptr: [*]const u8 = @ptrFromInt(@as(usize, @bitCast(val)));
            var len: usize = 0;
            while (ptr[len] != 0) : (len += 1) {}
            if (raw != 0) {
                std.debug.print("{s}", .{ptr[0..len]});
            } else {
                std.debug.print("\"{s}\"", .{ptr[0..len]});
            }
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
    const rc_ptr: *i64 = @ptrCast(@alignCast(raw));
    rc_ptr.* = 1;
    const user_data: [*]u8 = @ptrFromInt(@intFromPtr(raw) + RC_OFFSET);
    return user_data;
}

fn ko_incref_wrapper(ptr: ?[*]u8) callconv(.c) ?[*]u8 {
    if (ptr == null) return null;
    const p = ptr.?;
    const rc_ptr: *i64 = @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(@intFromPtr(p) - RC_OFFSET))));
    rc_ptr.* += 1;
    return p;
}

fn ko_decref_wrapper(ptr: ?[*]u8) callconv(.c) void {
    if (ptr == null) return;
    const p = ptr.?;
    const rc_ptr: *i64 = @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(@intFromPtr(p) - RC_OFFSET))));
    rc_ptr.* -= 1;
    if (rc_ptr.* <= 0) {
        free(@ptrCast(rc_ptr));
    }
}

// Stack overflow detection — reimplemented in Zig for JIT mapping.
// The C version in ko_runtime.c is used for AOT compilation.
const DEFAULT_STACK_LIMIT = 8 * 1024 * 1024; // 8MB

threadlocal var ko_stack_base: ?*anyopaque = null;
threadlocal var ko_stack_limit: usize = DEFAULT_STACK_LIMIT;

fn ko_init_stack_impl() callconv(.c) void {
    // Get current stack frame address (stack grows downward on x86_64)
    const sp = @as(*anyopaque, @ptrFromInt(@frameAddress()));
    ko_stack_base = sp;

    // Check for user-configured limit via getenv
    // For simplicity, use a fixed 8MB limit in JIT mode
    ko_stack_limit = DEFAULT_STACK_LIMIT;
}

fn ko_check_stack_impl() callconv(.c) void {
    if (ko_stack_base == null) return; // not initialized yet

    const current = @as(*anyopaque, @ptrFromInt(@frameAddress()));
    const base_addr = @intFromPtr(ko_stack_base.?);
    const current_addr = @intFromPtr(current);

    // Stack grows downward: base > current. Distance = base - current.
    if (base_addr > current_addr) {
        const distance = base_addr - current_addr;
        if (distance > ko_stack_limit) {
            // In JIT mode, we can't easily call fprintf/exit from here.
            // Write directly to stderr and abort.
            const msg = "ko: stack overflow (depth > 8MB)\nhint: rewrite recursion as iteration\n";
            _ = std.os.linux.write(2, msg.ptr, msg.len);
            std.c.abort();
        }
    }
}

// Zig wrapper for ko_init_stack (same signature, used for JIT mapping)
fn ko_init_stack_wrapper() callconv(.c) void {
    ko_init_stack_impl();
}

// Zig wrapper for ko_check_stack (same signature, used for JIT mapping)
fn ko_check_stack_wrapper() callconv(.c) void {
    ko_check_stack_impl();
}
