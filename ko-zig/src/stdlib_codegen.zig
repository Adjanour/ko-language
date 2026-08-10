// stdlib_codegen.zig — Generates LLVM IR for stdlib functions
//
// Instead of calling external C functions, we generate the LLVM IR directly
// in the module. This eliminates the need for ko_runtime.c entirely.
//
// For functions that need system calls (malloc, printf), we declare them
// as external and link against libc at link time.

const std = @import("std");
const llvm = @import("llvm");
const core = llvm.core;
const types = llvm.types;

pub const StdlibCodegen = struct {
    context: types.LLVMContextRef,
    module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,
    allocator: std.mem.Allocator,

    pub fn init(ctx: types.LLVMContextRef, mod: types.LLVMModuleRef, builder: types.LLVMBuilderRef, alloc: std.mem.Allocator) StdlibCodegen {
        return .{
            .context = ctx,
            .module = mod,
            .builder = builder,
            .allocator = alloc,
        };
    }

    // ============================================================
    // Helpers
    // ============================================================

    fn i64Type(self: *StdlibCodegen) types.LLVMTypeRef {
        return core.LLVMInt64TypeInContext(self.context);
    }

    fn i8Type(self: *StdlibCodegen) types.LLVMTypeRef {
        return core.LLVMInt8TypeInContext(self.context);
    }

    fn i1Type(self: *StdlibCodegen) types.LLVMTypeRef {
        return core.LLVMInt1TypeInContext(self.context);
    }

    fn ptrType(self: *StdlibCodegen) types.LLVMTypeRef {
        return core.LLVMPointerTypeInContext(self.context, 0);
    }

    fn voidType(self: *StdlibCodegen) types.LLVMTypeRef {
        return core.LLVMVoidTypeInContext(self.context);
    }

    fn doubleType(self: *StdlibCodegen) types.LLVMTypeRef {
        return core.LLVMDoubleTypeInContext(self.context);
    }

    fn createFunction(self: *StdlibCodegen, name: [*:0]const u8, ret_type: types.LLVMTypeRef, param_types: []const types.LLVMTypeRef) types.LLVMValueRef {
        const fn_type = core.LLVMFunctionType(ret_type, @ptrCast(@constCast(param_types.ptr)), @intCast(param_types.len), 0);
        return core.LLVMAddFunction(self.module, name, fn_type);
    }

    fn getOrDeclareExternCFunction(self: *StdlibCodegen, name: [*:0]const u8) types.LLVMValueRef {
        if (core.LLVMGetNamedFunction(self.module, name)) |existing| {
            return existing;
        }
        // All our C-backed string functions have the same signature: (ptr, ...) -> i64 or ptr
        // We'll create a generic variadic declaration and let LLVM handle the actual types
        const i64_type = self.i64Type();
        const ptr_type = self.ptrType();
        // Create a function type with 3 ptr params (max needed by string functions)
        var param_types: [3]types.LLVMTypeRef = .{ ptr_type, ptr_type, ptr_type };
        // Determine return type based on function name
        const name_slice: []const u8 = std.mem.sliceTo(name, 0);
        const ret_type = if (std.mem.eql(u8, name_slice, "ko_string_contains") or
            std.mem.eql(u8, name_slice, "ko_string_char_at") or
            std.mem.eql(u8, name_slice, "ko_string_split"))
            i64_type
        else
            ptr_type;
        const fn_type = core.LLVMFunctionType(ret_type, &param_types, 3, 1); // variadic
        return core.LLVMAddFunction(self.module, name, fn_type);
    }

    fn buildBranch(self: *StdlibCodegen, dest: types.LLVMBasicBlockRef) void {
        _ = core.LLVMBuildBr(self.builder, dest);
    }

    fn buildCondBranch(self: *StdlibCodegen, cond: types.LLVMValueRef, then_bb: types.LLVMBasicBlockRef, else_bb: types.LLVMBasicBlockRef) void {
        _ = core.LLVMBuildCondBr(self.builder, cond, then_bb, else_bb);
    }

    fn buildRet(self: *StdlibCodegen, val: types.LLVMValueRef) void {
        _ = core.LLVMBuildRet(self.builder, val);
    }

    fn buildRetVoid(self: *StdlibCodegen) void {
        _ = core.LLVMBuildRetVoid(self.builder);
    }

    fn globalStringConstant(self: *StdlibCodegen, str: [*:0]const u8) types.LLVMValueRef {
        const str_val = core.LLVMConstStringInContext(self.context, @ptrCast(str), @intCast(std.mem.len(str)), 0);
        const global = core.LLVMAddGlobal(self.module, core.LLVMTypeOf(str_val), "str");
        core.LLVMSetInitializer(global, str_val);
        core.LLVMSetGlobalConstant(global, 1);
        core.LLVMSetLinkage(global, .LLVMPrivateLinkage);
        var indices: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        return core.LLVMBuildGEP2(self.builder, self.i8Type(), global, @ptrCast(&indices), 1, "str_ptr");
    }

    // ============================================================
    // KoString runtime functions
    // ============================================================

    /// KoString memory layout (32-byte header, compatible with ko_decref):
    /// [i64 rc][i64 type_tag=4][i64 byte_length][i64 bitmap=0][i8... data]
    /// Strings have no heap fields, so the generic header's arity slot carries
    /// the byte length instead — that keeps the header at 32 bytes so ko_decref
    /// can walk strings and constructors with the same offsets.
    /// rc=0 means immortal (string literal), never freed
    /// rc>0 means managed, decremented by ko_decref
    /// The value passed around IS the data pointer (malloc ptr + 32); header
    /// fields are read at negative offsets: rc -32, tag -24, len -16, bitmap -8.
    pub fn codegenKoStringFromCstr(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_from_cstr", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const null_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "null_check");
        const alloc = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "alloc");
        const done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const cstr = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(cstr, "cstr");

        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, cstr, core.LLVMConstNull(self.ptrType()), "is_null");
        self.buildCondBranch(is_null, done, null_check);

        core.LLVMPositionBuilderAtEnd(self.builder, null_check);
        const strlen_fn = core.LLVMGetNamedFunction(self.module, "strlen");
        var strlen_args: [1]types.LLVMValueRef = .{cstr};
        const len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strlen_fn), strlen_fn, &strlen_args, 1, "len");
        const header_size = core.LLVMConstInt(self.i64Type(), 32, 0);
        const one = core.LLVMConstInt(self.i64Type(), 1, 0);
        const alloc_size = core.LLVMBuildAdd(self.builder, core.LLVMBuildAdd(self.builder, header_size, len, "tmp"), one, "alloc_size");
        self.buildBranch(alloc);

        core.LLVMPositionBuilderAtEnd(self.builder, alloc);
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{alloc_size};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");
        const rc_ptr = core.LLVMBuildBitCast(self.builder, buf, core.LLVMPointerTypeInContext(self.context, 0), "rc_ptr");

        const zero = core.LLVMConstInt(self.i64Type(), 0, 0);
        const one_i64 = core.LLVMConstInt(self.i64Type(), 1, 0);
        const type_tag_4 = core.LLVMConstInt(self.i64Type(), 4, 0);

        var idx0: [1]types.LLVMValueRef = .{zero};
        _ = core.LLVMBuildStore(self.builder, one_i64, core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&idx0)), 1, "rc_slot"));
        var idx1: [1]types.LLVMValueRef = .{one};
        _ = core.LLVMBuildStore(self.builder, type_tag_4, core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&idx1)), 1, "tag_slot"));
        // Strings carry no heap fields, so the arity slot holds the byte length.
        // That keeps the header at 32 bytes and ko_decref generic.
        var idx2: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 2, 0)};
        _ = core.LLVMBuildStore(self.builder, len, core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&idx2)), 1, "len_slot"));
        var idx3: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 3, 0)};
        _ = core.LLVMBuildStore(self.builder, zero, core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&idx3)), 1, "bitmap_slot"));

        const data_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(@constCast(&.{core.LLVMConstInt(self.i64Type(), 32, 0)})), 1, "data_ptr");
        const copy_len = core.LLVMBuildAdd(self.builder, len, one, "copy_len");
        const memcpy_fn = core.LLVMGetNamedFunction(self.module, "memcpy");
        var memcpy_args: [3]types.LLVMValueRef = .{ data_ptr, cstr, copy_len };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_args, 3, "");
        self.buildBranch(done);

        core.LLVMPositionBuilderAtEnd(self.builder, done);
        const result = core.LLVMBuildPhi(self.builder, self.ptrType(), "result");
        var phi_vals: [2]types.LLVMValueRef = .{ core.LLVMConstNull(self.ptrType()), data_ptr };
        var phi_blocks: [2]types.LLVMBasicBlockRef = .{ entry, alloc };
        core.LLVMAddIncoming(result, &phi_vals, @ptrCast(@constCast(&phi_blocks)), 2);
        self.buildRet(result);
    }

    pub fn codegenKoStringAlloc(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.i64Type() };
        const fn_val = self.createFunction("ko_string_alloc", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const data = core.LLVMGetParam(fn_val, 0);
        const len = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(data, "data");
        core.LLVMSetValueName(len, "len");

        const header_size = core.LLVMConstInt(self.i64Type(), 32, 0);
        const one = core.LLVMConstInt(self.i64Type(), 1, 0);
        const alloc_size = core.LLVMBuildAdd(self.builder, core.LLVMBuildAdd(self.builder, header_size, len, "tmp"), one, "alloc_size");
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{alloc_size};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");
        const rc_ptr = core.LLVMBuildBitCast(self.builder, buf, core.LLVMPointerTypeInContext(self.context, 0), "rc_ptr");

        const zero = core.LLVMConstInt(self.i64Type(), 0, 0);
        const one_i64 = core.LLVMConstInt(self.i64Type(), 1, 0);
        const type_tag_4 = core.LLVMConstInt(self.i64Type(), 4, 0);

        var idx0: [1]types.LLVMValueRef = .{zero};
        _ = core.LLVMBuildStore(self.builder, one_i64, core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&idx0)), 1, "rc_slot"));
        var idx1: [1]types.LLVMValueRef = .{one};
        _ = core.LLVMBuildStore(self.builder, type_tag_4, core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&idx1)), 1, "tag_slot"));
        // Byte length lives in the arity slot — see codegenKoStringFromCstr.
        var idx2: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 2, 0)};
        _ = core.LLVMBuildStore(self.builder, len, core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&idx2)), 1, "len_slot"));
        var idx3: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 3, 0)};
        _ = core.LLVMBuildStore(self.builder, zero, core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&idx3)), 1, "bitmap_slot"));

        const data_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(@constCast(&.{core.LLVMConstInt(self.i64Type(), 32, 0)})), 1, "data_ptr");
        const memcpy_fn = core.LLVMGetNamedFunction(self.module, "memcpy");
        var memcpy_args: [3]types.LLVMValueRef = .{ data_ptr, data, len };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_args, 3, "");
        // NUL-terminate: `data` carries no terminator of its own (unlike
        // ko_string_from_cstr, which copies len + 1), and printf needs one.
        // alloc_size already reserves this byte.
        var nul_idx: [1]types.LLVMValueRef = .{len};
        const nul_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), data_ptr, @ptrCast(&nul_idx), 1, "nul_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i8Type(), 0, 0), nul_ptr);
        self.buildRet(data_ptr);
    }

    pub fn codegenKoStringIncref(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_incref", self.voidType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const check_rc = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_rc");
        const increment = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "increment");
        const done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const str = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(str, "str");

        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, str, core.LLVMConstNull(self.ptrType()), "is_null");
        self.buildCondBranch(is_null, done, check_rc);

        core.LLVMPositionBuilderAtEnd(self.builder, check_rc);
        const rc_ptr_raw = core.LLVMBuildGEP2(self.builder, self.i8Type(), str, @ptrCast(@constCast(&.{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -32)), 0)})), 1, "rc_ptr_raw");
        const rc_ptr = core.LLVMBuildBitCast(self.builder, rc_ptr_raw, core.LLVMPointerTypeInContext(self.context, 0), "rc_ptr");
        var load_gep: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        const rc_slot = core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&load_gep)), 1, "rc_slot");
        const rc = core.LLVMBuildLoad2(self.builder, self.i64Type(), rc_slot, "rc");
        const is_immortal = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, rc, core.LLVMConstInt(self.i64Type(), 0, 0), "is_immortal");
        self.buildCondBranch(is_immortal, done, increment);

        core.LLVMPositionBuilderAtEnd(self.builder, increment);
        const new_rc = core.LLVMBuildAdd(self.builder, rc, core.LLVMConstInt(self.i64Type(), 1, 0), "new_rc");
        _ = core.LLVMBuildStore(self.builder, new_rc, rc_slot);
        self.buildBranch(done);

        core.LLVMPositionBuilderAtEnd(self.builder, done);
        self.buildRetVoid();
    }

    pub fn codegenKoStringDecref(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_decref", self.voidType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const check_rc = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_rc");
        const free_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "free_bb");
        const done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const str = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(str, "str");

        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, str, core.LLVMConstNull(self.ptrType()), "is_null");
        self.buildCondBranch(is_null, done, check_rc);

        core.LLVMPositionBuilderAtEnd(self.builder, check_rc);
        const rc_ptr_raw = core.LLVMBuildGEP2(self.builder, self.i8Type(), str, @ptrCast(@constCast(&.{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -32)), 0)})), 1, "rc_ptr_raw");
        const rc_ptr = core.LLVMBuildBitCast(self.builder, rc_ptr_raw, core.LLVMPointerTypeInContext(self.context, 0), "rc_ptr");
        var load_gep: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        const rc_slot = core.LLVMBuildGEP2(self.builder, self.i64Type(), rc_ptr, @ptrCast(@constCast(&load_gep)), 1, "rc_slot");
        const rc = core.LLVMBuildLoad2(self.builder, self.i64Type(), rc_slot, "rc");
        const is_immortal = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, rc, core.LLVMConstInt(self.i64Type(), 0, 0), "is_immortal");
        self.buildCondBranch(is_immortal, done, free_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, free_bb);
        const new_rc = core.LLVMBuildSub(self.builder, rc, core.LLVMConstInt(self.i64Type(), 1, 0), "new_rc");
        _ = core.LLVMBuildStore(self.builder, new_rc, rc_slot);
        const should_free = core.LLVMBuildICmp(self.builder, .LLVMIntSLE, new_rc, core.LLVMConstInt(self.i64Type(), 0, 0), "should_free");
        const do_free_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "do_free");
        self.buildCondBranch(should_free, do_free_bb, done);

        core.LLVMPositionBuilderAtEnd(self.builder, do_free_bb);
        const free_fn = core.LLVMGetNamedFunction(self.module, "free");
        var free_args: [1]types.LLVMValueRef = .{rc_ptr_raw};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(free_fn), free_fn, &free_args, 1, "");
        self.buildBranch(done);

        core.LLVMPositionBuilderAtEnd(self.builder, done);
        self.buildRetVoid();
    }

    pub fn codegenKoStringData(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_data", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const str = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(str, "str");
        // A KoString value already points at its bytes; the header sits behind it
        // at negative offsets. So the data pointer is the value itself.
        self.buildRet(str);
    }

    pub fn codegenKoStringByteLength(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_byte_length", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const str = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(str, "str");
        const len_ptr_raw = core.LLVMBuildGEP2(self.builder, self.i8Type(), str, @ptrCast(@constCast(&.{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -16)), 0)})), 1, "len_ptr_raw");
        const len_ptr = core.LLVMBuildBitCast(self.builder, len_ptr_raw, core.LLVMPointerTypeInContext(self.context, 0), "len_ptr");
        var load_gep: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        const len_slot = core.LLVMBuildGEP2(self.builder, self.i64Type(), len_ptr, @ptrCast(@constCast(&load_gep)), 1, "len_slot");
        const len = core.LLVMBuildLoad2(self.builder, self.i64Type(), len_slot, "len");
        self.buildRet(len);
    }

    // ============================================================
    // External declarations (system calls we can't generate IR for)
    // ============================================================

    pub fn declareExternals(self: *StdlibCodegen) void {
        // malloc(i64) -> ptr
        var malloc_params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const malloc_type = core.LLVMFunctionType(self.ptrType(), &malloc_params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "malloc", malloc_type);

        // realloc(ptr, i64) -> ptr
        var realloc_params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.i64Type() };
        const realloc_type = core.LLVMFunctionType(self.ptrType(), &realloc_params, 2, 0);
        _ = core.LLVMAddFunction(self.module, "realloc", realloc_type);

        // memset(ptr, i32, i64) -> ptr
        var memset_params: [3]types.LLVMTypeRef = .{ self.ptrType(), core.LLVMInt32TypeInContext(self.context), self.i64Type() };
        const memset_type = core.LLVMFunctionType(self.ptrType(), &memset_params, 3, 0);
        _ = core.LLVMAddFunction(self.module, "memset", memset_type);

        // free(ptr) -> void
        var free_params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const free_type = core.LLVMFunctionType(self.voidType(), &free_params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "free", free_type);

        // printf(ptr, ...) -> i64 (variadic, but we only use fixed args)
        var printf_params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const printf_type = core.LLVMFunctionType(self.i64Type(), &printf_params, 1, 1);
        _ = core.LLVMAddFunction(self.module, "printf", printf_type);

        // memcpy(ptr, ptr, i64) -> ptr
        var memcpy_params: [3]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType(), self.i64Type() };
        const memcpy_type = core.LLVMFunctionType(self.ptrType(), &memcpy_params, 3, 0);
        _ = core.LLVMAddFunction(self.module, "memcpy", memcpy_type);

        // strlen(ptr) -> i64
        var strlen_params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const strlen_type = core.LLVMFunctionType(self.i64Type(), &strlen_params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "strlen", strlen_type);

        // snprintf(ptr, i64, ptr, ...) -> i64
        var snprintf_params: [3]types.LLVMTypeRef = .{ self.ptrType(), self.i64Type(), self.ptrType() };
        const snprintf_type = core.LLVMFunctionType(self.i64Type(), &snprintf_params, 3, 1);
        _ = core.LLVMAddFunction(self.module, "snprintf", snprintf_type);

        // strtoll(ptr, ptr, i64) -> i64
        var strtoll_params: [3]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType(), self.i64Type() };
        const strtoll_type = core.LLVMFunctionType(self.i64Type(), &strtoll_params, 3, 0);
        _ = core.LLVMAddFunction(self.module, "strtoll", strtoll_type);

        // strtod(ptr, ptr) -> double
        var strtod_params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const strtod_type = core.LLVMFunctionType(self.doubleType(), &strtod_params, 2, 0);
        _ = core.LLVMAddFunction(self.module, "strtod", strtod_type);

        // abort() -> void
        var empty_params: [0]types.LLVMTypeRef = .{};
        const abort_type = core.LLVMFunctionType(self.voidType(), &empty_params, 0, 0);
        _ = core.LLVMAddFunction(self.module, "abort", abort_type);

        // fprintf(ptr, ptr, ...) -> i64 (variadic)
        var fprintf_params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fprintf_type = core.LLVMFunctionType(self.i64Type(), &fprintf_params, 2, 1);
        _ = core.LLVMAddFunction(self.module, "fprintf", fprintf_type);

        // fflush(ptr) -> i64 — NULL flushes every open stream.
        var fflush_params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fflush_type = core.LLVMFunctionType(self.i64Type(), &fflush_params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "fflush", fflush_type);

        // stderr (global variable)
        const stderr_global = core.LLVMAddGlobal(self.module, self.ptrType(), "stderr");
        core.LLVMSetLinkage(stderr_global, .LLVMExternalLinkage);

        // strstr(ptr, ptr) -> ptr
        var strstr_params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const strstr_type = core.LLVMFunctionType(self.ptrType(), &strstr_params, 2, 0);
        _ = core.LLVMAddFunction(self.module, "strstr", strstr_type);

        // strcmp(ptr, ptr) -> i32
        var strcmp_params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const strcmp_type = core.LLVMFunctionType(core.LLVMInt32TypeInContext(self.context), &strcmp_params, 2, 0);
        _ = core.LLVMAddFunction(self.module, "strcmp", strcmp_type);

        // strncmp(ptr, ptr, i64) -> i32
        var strncmp_params: [3]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType(), self.i64Type() };
        const strncmp_type = core.LLVMFunctionType(core.LLVMInt32TypeInContext(self.context), &strncmp_params, 3, 0);
        _ = core.LLVMAddFunction(self.module, "strncmp", strncmp_type);

        // toupper(i32) -> i32
        var toupper_params: [1]types.LLVMTypeRef = .{core.LLVMInt32TypeInContext(self.context)};
        const toupper_type = core.LLVMFunctionType(core.LLVMInt32TypeInContext(self.context), &toupper_params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "toupper", toupper_type);

        // tolower(i32) -> i32
        var tolower_params: [1]types.LLVMTypeRef = .{core.LLVMInt32TypeInContext(self.context)};
        const tolower_type = core.LLVMFunctionType(core.LLVMInt32TypeInContext(self.context), &tolower_params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "tolower", tolower_type);

        // The ctype predicates backing Char.is*: all i32 -> i32.
        for ([_][*:0]const u8{ "isalpha", "isdigit", "isalnum", "isspace", "isupper", "islower" }) |name| {
            var ctype_params: [1]types.LLVMTypeRef = .{core.LLVMInt32TypeInContext(self.context)};
            const ctype_ty = core.LLVMFunctionType(core.LLVMInt32TypeInContext(self.context), &ctype_params, 1, 0);
            _ = core.LLVMAddFunction(self.module, name, ctype_ty);
        }

        // isspace(i32) -> i32
        var isspace_params: [1]types.LLVMTypeRef = .{core.LLVMInt32TypeInContext(self.context)};
        const isspace_type = core.LLVMFunctionType(core.LLVMInt32TypeInContext(self.context), &isspace_params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "isspace", isspace_type);

        // inspect_list_tail(i64 tail, i64 raw, i64 elem_tag) -> void (forward declaration for inspect)
        {
            var ilt_params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
            const ilt_type = core.LLVMFunctionType(self.voidType(), &ilt_params, 3, 0);
            _ = core.LLVMAddFunction(self.module, "inspect_list_tail", ilt_type);
        }

        // LLVM intrinsics for stack check
        var frameaddr_params: [1]types.LLVMTypeRef = .{core.LLVMInt32TypeInContext(self.context)};
        const frameaddr_type = core.LLVMFunctionType(self.ptrType(), &frameaddr_params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "llvm.frameaddress.p0", frameaddr_type);
    }

    // ============================================================
    // Integer math functions
    // ============================================================

    pub fn codegenIntPow(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_int_pow", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_check");
        const loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const base = core.LLVMGetParam(fn_val, 0);
        const exp = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(base, "base");
        core.LLVMSetValueName(exp, "exp");

        // if exp < 0, return 0
        const is_neg = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, exp, core.LLVMConstInt(self.i64Type(), 0, 0), "is_neg");
        self.buildCondBranch(is_neg, done, loop_check);

        // loop_check: while exp > 0
        core.LLVMPositionBuilderAtEnd(self.builder, loop_check);
        const exp_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "exp");
        const result_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "result");
        const base_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "base");
        const is_pos = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, exp_phi, core.LLVMConstInt(self.i64Type(), 0, 0), "is_pos");
        self.buildCondBranch(is_pos, loop_body, done);

        // loop_body: result *= base; base *= base; exp >>= 1
        core.LLVMPositionBuilderAtEnd(self.builder, loop_body);
        const exp_and1 = core.LLVMBuildAnd(self.builder, exp_phi, core.LLVMConstInt(self.i64Type(), 1, 0), "exp_and1");
        const is_odd = core.LLVMBuildICmp(self.builder, .LLVMIntNE, exp_and1, core.LLVMConstInt(self.i64Type(), 0, 0), "is_odd");
        const new_result = core.LLVMBuildMul(self.builder, result_phi, base_phi, "new_result");
        const result_if_odd = core.LLVMBuildSelect(self.builder, is_odd, new_result, result_phi, "result_if_odd");
        const new_base = core.LLVMBuildMul(self.builder, base_phi, base_phi, "new_base");
        const new_exp = core.LLVMBuildAShr(self.builder, exp_phi, core.LLVMConstInt(self.i64Type(), 1, 0), "new_exp");
        self.buildBranch(loop_check);

        // Add incoming values to phi nodes
        var result_vals: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 1, 0), result_if_odd };
        var exp_vals: [2]types.LLVMValueRef = .{ exp, new_exp };
        var base_vals: [2]types.LLVMValueRef = .{ base, new_base };
        var blocks: [2]types.LLVMBasicBlockRef = .{ entry, loop_body };
        core.LLVMAddIncoming(result_phi, &result_vals, @ptrCast(&blocks), 2);
        core.LLVMAddIncoming(exp_phi, &exp_vals, @ptrCast(&blocks), 2);
        core.LLVMAddIncoming(base_phi, &base_vals, @ptrCast(&blocks), 2);

        // done: return result
        core.LLVMPositionBuilderAtEnd(self.builder, done);
        const final_result = core.LLVMBuildPhi(self.builder, self.i64Type(), "final_result");
        var final_vals: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 0, 0), result_phi };
        var final_blocks: [2]types.LLVMBasicBlockRef = .{ entry, loop_check };
        core.LLVMAddIncoming(final_result, &final_vals, @ptrCast(&final_blocks), 2);
        self.buildRet(final_result);
    }

    pub fn codegenIntGcd(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_int_gcd", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_check");
        const loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(a, "a");
        core.LLVMSetValueName(b, "b");

        // x = abs(a), y = abs(b)
        const neg_a = core.LLVMBuildNeg(self.builder, a, "neg_a");
        const is_a_neg = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, a, core.LLVMConstInt(self.i64Type(), 0, 0), "is_a_neg");
        const x = core.LLVMBuildSelect(self.builder, is_a_neg, neg_a, a, "x");
        const neg_b = core.LLVMBuildNeg(self.builder, b, "neg_b");
        const is_b_neg = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, b, core.LLVMConstInt(self.i64Type(), 0, 0), "is_b_neg");
        const y = core.LLVMBuildSelect(self.builder, is_b_neg, neg_b, b, "y");

        self.buildBranch(loop_check);

        // loop_check: while y != 0
        core.LLVMPositionBuilderAtEnd(self.builder, loop_check);
        const x_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "x");
        const y_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "y");
        const is_y_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, y_phi, core.LLVMConstInt(self.i64Type(), 0, 0), "is_y_zero");
        self.buildCondBranch(is_y_zero, done, loop_body);

        // loop_body: t = y; y = x % y; x = t
        core.LLVMPositionBuilderAtEnd(self.builder, loop_body);
        const new_y = core.LLVMBuildSRem(self.builder, x_phi, y_phi, "new_y");
        self.buildBranch(loop_check);

        var x_vals: [2]types.LLVMValueRef = .{ x, y_phi };
        var y_vals: [2]types.LLVMValueRef = .{ y, new_y };
        var gcd_blocks: [2]types.LLVMBasicBlockRef = .{ entry, loop_body };
        core.LLVMAddIncoming(x_phi, &x_vals, @ptrCast(&gcd_blocks), 2);
        core.LLVMAddIncoming(y_phi, &y_vals, @ptrCast(&gcd_blocks), 2);

        // done: return x
        core.LLVMPositionBuilderAtEnd(self.builder, done);
        self.buildRet(x_phi);
    }

    pub fn codegenIntLcm(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_int_lcm", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const check_zero = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_zero");
        const compute = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "compute");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(a, "a");
        core.LLVMSetValueName(b, "b");

        // if a == 0 or b == 0, return 0
        const is_a_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, a, core.LLVMConstInt(self.i64Type(), 0, 0), "is_a_zero");
        const is_b_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, b, core.LLVMConstInt(self.i64Type(), 0, 0), "is_b_zero");
        const is_zero = core.LLVMBuildOr(self.builder, is_a_zero, is_b_zero, "is_zero");
        self.buildCondBranch(is_zero, compute, check_zero);

        core.LLVMPositionBuilderAtEnd(self.builder, check_zero);
        self.buildBranch(compute);

        // return abs(a / gcd(a, b)) * b
        core.LLVMPositionBuilderAtEnd(self.builder, compute);
        const gcd_fn = core.LLVMGetNamedFunction(self.module, "ko_int_gcd");
        var gcd_args: [2]types.LLVMValueRef = .{ a, b };
        const gcd_val = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(gcd_fn), gcd_fn, &gcd_args, 2, "gcd_val");
        const div_result = core.LLVMBuildSDiv(self.builder, a, gcd_val, "div_result");
        const neg_div = core.LLVMBuildNeg(self.builder, div_result, "neg_div");
        const is_neg = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, div_result, core.LLVMConstInt(self.i64Type(), 0, 0), "is_neg");
        const abs_div = core.LLVMBuildSelect(self.builder, is_neg, neg_div, div_result, "abs_div");
        const result = core.LLVMBuildMul(self.builder, abs_div, b, "result");
        self.buildRet(result);
    }

    pub fn codegenIntFactorial(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_int_factorial", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_check");
        const loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const n = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(n, "n");

        // if n < 0, return 0
        const is_neg = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, n, core.LLVMConstInt(self.i64Type(), 0, 0), "is_neg");
        self.buildCondBranch(is_neg, done, loop_check);

        // loop_check: while i <= n
        core.LLVMPositionBuilderAtEnd(self.builder, loop_check);
        const i_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "i");
        const result_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "result");
        const is_le = core.LLVMBuildICmp(self.builder, .LLVMIntSLE, i_phi, n, "is_le");
        self.buildCondBranch(is_le, loop_body, done);

        // loop_body: result *= i; i++
        core.LLVMPositionBuilderAtEnd(self.builder, loop_body);
        const new_result = core.LLVMBuildMul(self.builder, result_phi, i_phi, "new_result");
        const new_i = core.LLVMBuildAdd(self.builder, i_phi, core.LLVMConstInt(self.i64Type(), 1, 0), "new_i");
        self.buildBranch(loop_check);

        var fact_result_vals: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 1, 0), new_result };
        var fact_i_vals: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 2, 0), new_i };
        var fact_blocks: [2]types.LLVMBasicBlockRef = .{ entry, loop_body };
        core.LLVMAddIncoming(result_phi, &fact_result_vals, @ptrCast(&fact_blocks), 2);
        core.LLVMAddIncoming(i_phi, &fact_i_vals, @ptrCast(&fact_blocks), 2);

        // done: return result
        core.LLVMPositionBuilderAtEnd(self.builder, done);
        const final_result = core.LLVMBuildPhi(self.builder, self.i64Type(), "final_result");
        var fact_final_vals: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 0, 0), result_phi };
        var fact_final_blocks: [2]types.LLVMBasicBlockRef = .{ entry, loop_check };
        core.LLVMAddIncoming(final_result, &fact_final_vals, @ptrCast(&fact_final_blocks), 2);
        self.buildRet(final_result);
    }

    pub fn codegenIntIsqrt(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_int_isqrt", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_check");
        const loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const n = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(n, "n");

        // if n <= 0, return 0
        const is_le_zero = core.LLVMBuildICmp(self.builder, .LLVMIntSLE, n, core.LLVMConstInt(self.i64Type(), 0, 0), "is_le_zero");

        // init_y = (n + 1) / 2 (compute in entry block before branching)
        const init_y = core.LLVMBuildSDiv(self.builder, core.LLVMBuildAdd(self.builder, n, core.LLVMConstInt(self.i64Type(), 1, 0), "n_plus_1"), core.LLVMConstInt(self.i64Type(), 2, 0), "init_y");

        self.buildCondBranch(is_le_zero, done, loop_check);

        // x = n, y = (x + 1) / 2
        core.LLVMPositionBuilderAtEnd(self.builder, loop_check);
        const x_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "x");
        const y_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "y");
        const is_y_lt_x = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, y_phi, x_phi, "is_y_lt_x");
        self.buildCondBranch(is_y_lt_x, loop_body, done);

        // loop_body: x = y; y = (x + n/x) / 2
        core.LLVMPositionBuilderAtEnd(self.builder, loop_body);
        const n_div_x = core.LLVMBuildSDiv(self.builder, n, y_phi, "n_div_x");
        const sum = core.LLVMBuildAdd(self.builder, y_phi, n_div_x, "sum");
        const new_y = core.LLVMBuildSDiv(self.builder, sum, core.LLVMConstInt(self.i64Type(), 2, 0), "new_y");
        self.buildBranch(loop_check);

        var isqrt_x_vals: [2]types.LLVMValueRef = .{ n, y_phi };
        var isqrt_y_vals: [2]types.LLVMValueRef = .{ init_y, new_y };
        var isqrt_blocks: [2]types.LLVMBasicBlockRef = .{ entry, loop_body };
        core.LLVMAddIncoming(x_phi, &isqrt_x_vals, @ptrCast(&isqrt_blocks), 2);
        core.LLVMAddIncoming(y_phi, &isqrt_y_vals, @ptrCast(&isqrt_blocks), 2);

        // done: return x
        core.LLVMPositionBuilderAtEnd(self.builder, done);
        const final_x = core.LLVMBuildPhi(self.builder, self.i64Type(), "final_x");
        var isqrt_final_vals: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 0, 0), x_phi };
        var isqrt_final_blocks: [2]types.LLVMBasicBlockRef = .{ entry, loop_check };
        core.LLVMAddIncoming(final_x, &isqrt_final_vals, @ptrCast(&isqrt_final_blocks), 2);
        self.buildRet(final_x);
    }

    // ============================================================
    // Checked arithmetic: Int -> Int -> Result Overflow/DivisionByZero Int
    // ============================================================

    fn codegenCheckedArithOverflow(self: *StdlibCodegen, ko_name: [*:0]const u8, intrinsic_name: [*:0]const u8) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction(ko_name, self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const overflow_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "overflow");
        const ok_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ok");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(a, "a");
        core.LLVMSetValueName(b, "b");

        // Declare the overflow intrinsic: (i64, i64) -> { i64, i1 }
        var intrinsic = core.LLVMGetNamedFunction(self.module, intrinsic_name);
        if (intrinsic == null) {
            var intrinsic_params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
            var struct_fields: [2]types.LLVMTypeRef = .{ self.i64Type(), core.LLVMInt1TypeInContext(self.context) };
            const result_struct = core.LLVMStructTypeInContext(self.context, @ptrCast(&struct_fields), 2, 0);
            const intrinsic_type = core.LLVMFunctionType(result_struct, &intrinsic_params, 2, 0);
            intrinsic = core.LLVMAddFunction(self.module, intrinsic_name, intrinsic_type);
        }
        var call_args: [2]types.LLVMValueRef = .{ a, b };
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(intrinsic), intrinsic, &call_args, 2, "arith_result");
        const sum = core.LLVMBuildExtractValue(self.builder, result, 0, "sum");
        const overflow = core.LLVMBuildExtractValue(self.builder, result, 1, "overflow_flag");
        self.buildCondBranch(overflow, overflow_bb, ok_bb);

        // Overflow branch: Err Overflow — box Overflow tag (0) into {0, 0}, then Err it
        core.LLVMPositionBuilderAtEnd(self.builder, overflow_bb);
        {
            // Box Overflow: alloc 16 bytes, store tag=0 at offset 0
            const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
            var box_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
            const box_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &box_args, 2, "overflow_box");
            var tag_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), box_ptr, @ptrCast(&tag_gep_idx), 1, "tag_ptr");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), tag_ptr);
            const boxed_overflow = core.LLVMBuildPtrToInt(self.builder, box_ptr, self.i64Type(), "boxed_overflow");
            // Err(boxed_overflow): alloc 16 bytes, tag=1 at offset 0, value at offset 1
            var err_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
            const err_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &err_args, 2, "err_ptr");
            var err_tag_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const err_tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), err_ptr, @ptrCast(&err_tag_gep_idx), 1, "err_tag_ptr");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 1, 0), err_tag_ptr);
            var err_val_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
            const err_val_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), err_ptr, @ptrCast(&err_val_gep_idx), 1, "err_val_ptr");
            _ = core.LLVMBuildStore(self.builder, boxed_overflow, err_val_ptr);
            _ = core.LLVMBuildRet(self.builder, core.LLVMBuildPtrToInt(self.builder, err_ptr, self.i64Type(), "err_result"));
        }

        // Ok branch: Ok(sum)
        core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
        {
            const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
            var ok_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
            const ok_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &ok_args, 2, "ok_ptr");
            var tag_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ok_ptr, @ptrCast(&tag_gep_idx), 1, "tag_ptr");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), tag_ptr);
            var val_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
            const val_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ok_ptr, @ptrCast(&val_gep_idx), 1, "val_ptr");
            _ = core.LLVMBuildStore(self.builder, sum, val_ptr);
            _ = core.LLVMBuildRet(self.builder, core.LLVMBuildPtrToInt(self.builder, ok_ptr, self.i64Type(), "ok_result"));
        }
    }

    fn codegenCheckedDivMod(self: *StdlibCodegen, ko_name: [*:0]const u8, is_mod: bool) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction(ko_name, self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const div_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "div");
        const err_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "err");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(a, "a");
        core.LLVMSetValueName(b, "b");

        const is_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, b, core.LLVMConstInt(self.i64Type(), 0, 0), "is_zero");
        self.buildCondBranch(is_zero, err_bb, div_bb);

        // Division/modulo branch: Ok(a / b) or Ok(a % b)
        core.LLVMPositionBuilderAtEnd(self.builder, div_bb);
        const quot = if (is_mod)
            core.LLVMBuildSRem(self.builder, a, b, "rem")
        else
            core.LLVMBuildSDiv(self.builder, a, b, "div");
        {
            const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
            var ok_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
            const ok_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &ok_args, 2, "ok_ptr");
            var tag_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ok_ptr, @ptrCast(&tag_gep_idx), 1, "tag_ptr");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), tag_ptr);
            var val_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
            const val_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ok_ptr, @ptrCast(&val_gep_idx), 1, "val_ptr");
            _ = core.LLVMBuildStore(self.builder, quot, val_ptr);
            _ = core.LLVMBuildRet(self.builder, core.LLVMBuildPtrToInt(self.builder, ok_ptr, self.i64Type(), "ok_result"));
        }

        // Error branch: Err DivisionByZero — box DivisionByZero tag (0), then Err it
        core.LLVMPositionBuilderAtEnd(self.builder, err_bb);
        {
            const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
            // Box DivisionByZero: alloc 16 bytes, store tag=0 at offset 0
            var box_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
            const box_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &box_args, 2, "divbyzero_box");
            var tag_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), box_ptr, @ptrCast(&tag_gep_idx), 1, "tag_ptr");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), tag_ptr);
            const boxed_err = core.LLVMBuildPtrToInt(self.builder, box_ptr, self.i64Type(), "boxed_divbyzero");
            // Err(boxed_err): alloc 16 bytes, tag=1 at offset 0, value at offset 1
            var err_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
            const err_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &err_args, 2, "err_ptr");
            var err_tag_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const err_tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), err_ptr, @ptrCast(&err_tag_gep_idx), 1, "err_tag_ptr");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 1, 0), err_tag_ptr);
            var err_val_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
            const err_val_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), err_ptr, @ptrCast(&err_val_gep_idx), 1, "err_val_ptr");
            _ = core.LLVMBuildStore(self.builder, boxed_err, err_val_ptr);
            _ = core.LLVMBuildRet(self.builder, core.LLVMBuildPtrToInt(self.builder, err_ptr, self.i64Type(), "err_result"));
        }
    }

    fn codegenIntNegChecked(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_int_neg_checked", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const ok_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ok");
        const overflow_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "overflow");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const a = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(a, "a");

        // Overflow if a == INT64_MIN (-9223372036854775808)
        const int64_min = core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -9223372036854775808)), 0);
        const is_min = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, a, int64_min, "is_min");
        self.buildCondBranch(is_min, overflow_bb, ok_bb);

        // Ok: return negated value
        core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
        const neg = core.LLVMBuildNeg(self.builder, a, "neg");
        {
            const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
            var ok_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
            const ok_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &ok_args, 2, "ok_ptr");
            var tag_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ok_ptr, @ptrCast(&tag_gep_idx), 1, "tag_ptr");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), tag_ptr);
            var val_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
            const val_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ok_ptr, @ptrCast(&val_gep_idx), 1, "val_ptr");
            _ = core.LLVMBuildStore(self.builder, neg, val_ptr);
            _ = core.LLVMBuildRet(self.builder, core.LLVMBuildPtrToInt(self.builder, ok_ptr, self.i64Type(), "ok_result"));
        }

        // Overflow: Err Overflow
        core.LLVMPositionBuilderAtEnd(self.builder, overflow_bb);
        {
            const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
            var box_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
            const box_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &box_args, 2, "overflow_box");
            var tag_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), box_ptr, @ptrCast(&tag_gep_idx), 1, "tag_ptr");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), tag_ptr);
            const boxed_overflow = core.LLVMBuildPtrToInt(self.builder, box_ptr, self.i64Type(), "boxed_overflow");
            var err_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
            const err_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &err_args, 2, "err_ptr");
            var err_tag_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const err_tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), err_ptr, @ptrCast(&err_tag_gep_idx), 1, "err_tag_ptr");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 1, 0), err_tag_ptr);
            var err_val_gep_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
            const err_val_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), err_ptr, @ptrCast(&err_val_gep_idx), 1, "err_val_ptr");
            _ = core.LLVMBuildStore(self.builder, boxed_overflow, err_val_ptr);
            _ = core.LLVMBuildRet(self.builder, core.LLVMBuildPtrToInt(self.builder, err_ptr, self.i64Type(), "err_result"));
        }
    }

    fn codegenIntDivOr(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_int_div_or", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const default_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "default");
        const div_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "div");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);
        const default = core.LLVMGetParam(fn_val, 2);
        core.LLVMSetValueName(a, "a");
        core.LLVMSetValueName(b, "b");
        core.LLVMSetValueName(default, "default");

        const is_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, b, core.LLVMConstInt(self.i64Type(), 0, 0), "is_zero");
        self.buildCondBranch(is_zero, default_bb, div_bb);

        // default_bb: return default
        core.LLVMPositionBuilderAtEnd(self.builder, default_bb);
        _ = core.LLVMBuildRet(self.builder, default);

        // div_bb: return a / b
        core.LLVMPositionBuilderAtEnd(self.builder, div_bb);
        const quot = core.LLVMBuildSDiv(self.builder, a, b, "div");
        _ = core.LLVMBuildRet(self.builder, quot);
    }

    // ============================================================
    // String functions
    // ============================================================

    pub fn codegenStringLength(self: *StdlibCodegen) void {
        // ko_string_length(str: ptr) -> i64
        // Returns the byte length of a KoString (O(1) via byte_length field)
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_length", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const str = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(str, "str");

        // Call ko_string_byte_length(str)
        const ko_string_byte_length_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var args: [1]types.LLVMValueRef = .{str};
        const len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ko_string_byte_length_fn), ko_string_byte_length_fn, &args, 1, "len");
        self.buildRet(len);
    }

    pub fn codegenStringAppend(self: *StdlibCodegen) void {
        // ko_string_append(a: KoString, b: KoString) -> KoString
        // Concatenates two KoStrings and returns a new KoString
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fn_val = self.createFunction("ko_string_append", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(a, "a");
        core.LLVMSetValueName(b, "b");

        // Get lengths using KoString functions
        const ko_string_byte_length_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        const ko_string_data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");

        // len_a = ko_string_byte_length(a)
        var len_a_args: [1]types.LLVMValueRef = .{a};
        const len_a = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ko_string_byte_length_fn), ko_string_byte_length_fn, &len_a_args, 1, "len_a");

        // len_b = ko_string_byte_length(b)
        var len_b_args: [1]types.LLVMValueRef = .{b};
        const len_b = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ko_string_byte_length_fn), ko_string_byte_length_fn, &len_b_args, 1, "len_b");

        // total = len_a + len_b
        const total = core.LLVMBuildAdd(self.builder, len_a, len_b, "total");

        // buf = malloc(total + 1)
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{core.LLVMBuildAdd(self.builder, total, core.LLVMConstInt(self.i64Type(), 1, 0), "alloc_size")};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");

        // data_a = ko_string_data(a)
        var data_a_args: [1]types.LLVMValueRef = .{a};
        const data_a = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ko_string_data_fn), ko_string_data_fn, &data_a_args, 1, "data_a");

        // memcpy(buf, data_a, len_a)
        const memcpy_fn = core.LLVMGetNamedFunction(self.module, "memcpy");
        var memcpy_args: [3]types.LLVMValueRef = .{ buf, data_a, len_a };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_args, 3, "");

        // data_b = ko_string_data(b)
        var data_b_args: [1]types.LLVMValueRef = .{b};
        const data_b = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ko_string_data_fn), ko_string_data_fn, &data_b_args, 1, "data_b");

        // memcpy(buf + len_a, data_b, len_b)
        var buf_offset_idx: [1]types.LLVMValueRef = .{len_a};
        const buf_offset = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(&buf_offset_idx), 1, "buf_offset");
        var memcpy_args2: [3]types.LLVMValueRef = .{ buf_offset, data_b, len_b };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_args2, 3, "");

        // buf[total] = 0 (null terminator)
        var last_ptr_idx: [1]types.LLVMValueRef = .{total};
        const last_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(&last_ptr_idx), 1, "last_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i8Type(), 0, 0), last_ptr);

        // Create KoString from the buffer
        const ko_string_alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_string_alloc");
        var alloc_args: [2]types.LLVMValueRef = .{ buf, total };
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ko_string_alloc_fn), ko_string_alloc_fn, &alloc_args, 2, "result");

        self.buildRet(result);
    }

    pub fn codegenStringEq(self: *StdlibCodegen) void {
        // ko_string_eq(a: ptr, b: ptr) -> i64
        // Returns 1 if strings are equal, 0 otherwise
        // Uses ko_string_byte_length for fast O(1) length check,
        // then ko_string_data + strncmp for comparison
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fn_val = self.createFunction("ko_string_eq", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const check_len = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_len");
        const compare = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "compare");
        const done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(a, "a");
        core.LLVMSetValueName(b, "b");

        // Fast path: if pointers are equal, strings are equal
        const ptr_eq = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, a, b, "ptr_eq");
        self.buildCondBranch(ptr_eq, done, check_len);

        // Get lengths via ko_string_byte_length
        core.LLVMPositionBuilderAtEnd(self.builder, check_len);
        const byte_len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var len_a_args: [1]types.LLVMValueRef = .{a};
        const len_a = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &len_a_args, 1, "len_a");
        var len_b_args: [1]types.LLVMValueRef = .{b};
        const len_b = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &len_b_args, 1, "len_b");

        // Fast path: if lengths differ, strings are not equal
        const len_eq = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, len_a, len_b, "len_eq");
        self.buildCondBranch(len_eq, compare, done);

        // Get data pointers via ko_string_data
        core.LLVMPositionBuilderAtEnd(self.builder, compare);
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var data_a_args: [1]types.LLVMValueRef = .{a};
        const data_a = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &data_a_args, 1, "data_a");
        var data_b_args: [1]types.LLVMValueRef = .{b};
        const data_b = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &data_b_args, 1, "data_b");

        // Compare data with strncmp
        const strncmp_fn = core.LLVMGetNamedFunction(self.module, "strncmp");
        var strncmp_args: [3]types.LLVMValueRef = .{ data_a, data_b, len_a };
        const cmp_result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strncmp_fn), strncmp_fn, &strncmp_args, 3, "cmp");
        const zero_i32 = core.LLVMConstInt(core.LLVMInt32TypeInContext(self.context), 0, 0);
        const is_eq = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, cmp_result, zero_i32, "is_eq");
        const result = core.LLVMBuildZExt(self.builder, is_eq, self.i64Type(), "result");
        self.buildBranch(done);

        // done: phi for results
        core.LLVMPositionBuilderAtEnd(self.builder, done);
        const phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "eq_result");
        const one = core.LLVMConstInt(self.i64Type(), 1, 0);
        const zero = core.LLVMConstInt(self.i64Type(), 0, 0);
        var phi_vals: [3]types.LLVMValueRef = .{ one, zero, result };
        var phi_blocks: [3]types.LLVMBasicBlockRef = .{ entry, check_len, compare };
        core.LLVMAddIncoming(phi, @ptrCast(@constCast(&phi_vals)), @ptrCast(@constCast(&phi_blocks)), 3);
        self.buildRet(phi);
    }

    // ============================================================
    // Additional String functions (C-backed)
    // ============================================================

    pub fn codegenStringContains(self: *StdlibCodegen) void {
        // ko_string_contains(haystack: ptr, needle: ptr) -> i64
        // Returns 1 if needle is found in haystack, 0 otherwise
        // Uses ko_string_data to extract data pointers before calling strstr
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fn_val = self.createFunction("ko_string_contains", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const haystack = core.LLVMGetParam(fn_val, 0);
        const needle = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(haystack, "haystack");
        core.LLVMSetValueName(needle, "needle");

        // Get data pointers via ko_string_data
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var haystack_data_args: [1]types.LLVMValueRef = .{haystack};
        const haystack_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &haystack_data_args, 1, "haystack_data");
        var needle_data_args: [1]types.LLVMValueRef = .{needle};
        const needle_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &needle_data_args, 1, "needle_data");

        // result_ptr = strstr(haystack_data, needle_data)
        const strstr_fn = core.LLVMGetNamedFunction(self.module, "strstr");
        var strstr_args: [2]types.LLVMValueRef = .{ haystack_data, needle_data };
        const result_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strstr_fn), strstr_fn, &strstr_args, 2, "result_ptr");

        // is_found = (result_ptr != null)
        const null_ptr = core.LLVMConstPointerNull(self.ptrType());
        const is_found = core.LLVMBuildICmp(self.builder, .LLVMIntNE, result_ptr, null_ptr, "is_found");

        // Convert i1 to i64
        const result = core.LLVMBuildZExt(self.builder, is_found, self.i64Type(), "result");
        self.buildRet(result);
    }

    pub fn codegenStringCharAt(self: *StdlibCodegen) void {
        // ko_string_char_at(str: ptr, index: i64) -> i64
        // Returns the character at index, or -1 if out of bounds
        // Uses ko_string_byte_length (O(1)) and ko_string_data for bounds check and access
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.i64Type() };
        const fn_val = self.createFunction("ko_string_char_at", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const oob_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "oob");
        const ok_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ok");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const str = core.LLVMGetParam(fn_val, 0);
        const index = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(str, "str");
        core.LLVMSetValueName(index, "index");

        // len = ko_string_byte_length(str) — O(1)
        const byte_len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var len_args: [1]types.LLVMValueRef = .{str};
        const len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &len_args, 1, "len");

        // in_bounds = (index >= 0) && (index < len)
        const is_nonneg = core.LLVMBuildICmp(self.builder, .LLVMIntSGE, index, core.LLVMConstInt(self.i64Type(), 0, 0), "is_nonneg");
        const is_lt_len = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, index, len, "is_lt_len");
        const in_bounds = core.LLVMBuildAnd(self.builder, is_nonneg, is_lt_len, "in_bounds");
        self.buildCondBranch(in_bounds, ok_bb, oob_bb);

        // oob_bb: return -1
        core.LLVMPositionBuilderAtEnd(self.builder, oob_bb);
        const neg1 = core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -1)), 0);
        self.buildRet(neg1);

        // ok_bb: get data pointer via ko_string_data, then data[index]
        core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var data_args: [1]types.LLVMValueRef = .{str};
        const data_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &data_args, 1, "data_ptr");
        var idx_args: [1]types.LLVMValueRef = .{index};
        const char_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), data_ptr, @ptrCast(&idx_args), 1, "char_ptr");
        const char_val = core.LLVMBuildLoad2(self.builder, self.i8Type(), char_ptr, "char_val");
        const char_i64 = core.LLVMBuildSExt(self.builder, char_val, self.i64Type(), "char_i64");
        self.buildRet(char_i64);
    }

    pub fn codegenStringToUpper(self: *StdlibCodegen) void {
        // ko_string_to_upper(str: ptr) -> ptr
        // Allocates new KoString with all characters uppercased
        // Uses ko_string_byte_length (O(1)) and ko_string_data for source access
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_to_upper", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_check");
        const loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const loop_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const str = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(str, "str");

        // Get length via ko_string_byte_length — O(1)
        const byte_len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var len_args: [1]types.LLVMValueRef = .{str};
        const len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &len_args, 1, "len");

        // Allocate temp buffer for uppercase characters (len + 1 for null terminator)
        const alloc_size = core.LLVMBuildAdd(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "alloc_size");
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{alloc_size};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");

        // Get source data pointer via ko_string_data
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var data_args: [1]types.LLVMValueRef = .{str};
        const src_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &data_args, 1, "src_data");

        self.buildBranch(loop_check);

        // loop_check: create phi, compare, condBr
        core.LLVMPositionBuilderAtEnd(self.builder, loop_check);
        const i_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "i");
        var phi_vals_entry: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        var phi_bbs_entry: [1]types.LLVMBasicBlockRef = .{entry};
        core.LLVMAddIncoming(i_phi, @ptrCast(@constCast(&phi_vals_entry)), @ptrCast(@constCast(&phi_bbs_entry)), 1);

        const cmp = core.LLVMBuildICmp(self.builder, .LLVMIntUGE, i_phi, len, "cmp");
        self.buildCondBranch(cmp, loop_done, loop_body);

        // loop_body: toupper, store, increment, branch back
        core.LLVMPositionBuilderAtEnd(self.builder, loop_body);

        var i_gep_args: [1]types.LLVMValueRef = .{i_phi};
        const char_src = core.LLVMBuildGEP2(self.builder, self.i8Type(), src_data, @ptrCast(&i_gep_args), 1, "char_src");
        const char_val = core.LLVMBuildLoad2(self.builder, self.i8Type(), char_src, "char_val");

        const char_i32 = core.LLVMBuildSExt(self.builder, char_val, core.LLVMInt32TypeInContext(self.context), "char_i32");
        const toupper_fn = core.LLVMGetNamedFunction(self.module, "toupper");
        var toupper_args: [1]types.LLVMValueRef = .{char_i32};
        const upper_i32 = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(toupper_fn), toupper_fn, &toupper_args, 1, "upper_i32");
        const upper_i8 = core.LLVMBuildTrunc(self.builder, upper_i32, self.i8Type(), "upper_i8");

        const char_dst = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(&i_gep_args), 1, "char_dst");
        _ = core.LLVMBuildStore(self.builder, upper_i8, char_dst);

        const next_i = core.LLVMBuildAdd(self.builder, i_phi, core.LLVMConstInt(self.i64Type(), 1, 0), "next_i");
        self.buildBranch(loop_check);

        // Add loop_body incoming to phi (must be after loop_check's terminator and loop_body's terminator)
        var phi_vals2: [1]types.LLVMValueRef = .{next_i};
        var phi_bbs2: [1]types.LLVMBasicBlockRef = .{loop_body};
        core.LLVMAddIncoming(i_phi, @ptrCast(@constCast(&phi_vals2)), @ptrCast(@constCast(&phi_bbs2)), 1);

        // loop_done: null-terminate and wrap in KoString via ko_string_alloc
        core.LLVMPositionBuilderAtEnd(self.builder, loop_done);
        var len_gep_args: [1]types.LLVMValueRef = .{len};
        const null_dst = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(&len_gep_args), 1, "null_dst");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i8Type(), 0, 0), null_dst);

        // Wrap in KoString: ko_string_alloc(buf, len)
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_string_alloc");
        var alloc_args: [2]types.LLVMValueRef = .{ buf, len };
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "result");
        self.buildRet(result);
    }

    pub fn codegenStringToLower(self: *StdlibCodegen) void {
        // ko_string_to_lower(str: ptr) -> ptr
        // Allocates new KoString with all characters lowercased
        // Uses ko_string_byte_length (O(1)) and ko_string_data for source access
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_to_lower", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_check");
        const loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const loop_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const str = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(str, "str");

        // Get length via ko_string_byte_length — O(1)
        const byte_len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var len_args: [1]types.LLVMValueRef = .{str};
        const len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &len_args, 1, "len");

        // Allocate temp buffer for lowercase characters (len + 1 for null terminator)
        const alloc_size = core.LLVMBuildAdd(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "alloc_size");
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{alloc_size};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");

        // Get source data pointer via ko_string_data
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var data_args: [1]types.LLVMValueRef = .{str};
        const src_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &data_args, 1, "src_data");

        self.buildBranch(loop_check);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_check);
        const i_param = core.LLVMBuildPhi(self.builder, self.i64Type(), "i");
        var phi_vals_entry: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        var phi_bbs_entry: [1]types.LLVMBasicBlockRef = .{entry};
        core.LLVMAddIncoming(i_param, @ptrCast(@constCast(&phi_vals_entry)), @ptrCast(@constCast(&phi_bbs_entry)), 1);

        const cmp = core.LLVMBuildICmp(self.builder, .LLVMIntUGE, i_param, len, "cmp");
        self.buildCondBranch(cmp, loop_done, loop_body);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_body);

        var i_gep_args: [1]types.LLVMValueRef = .{i_param};
        const char_src = core.LLVMBuildGEP2(self.builder, self.i8Type(), src_data, @ptrCast(&i_gep_args), 1, "char_src");
        const char_val = core.LLVMBuildLoad2(self.builder, self.i8Type(), char_src, "char_val");

        const char_i32 = core.LLVMBuildSExt(self.builder, char_val, core.LLVMInt32TypeInContext(self.context), "char_i32");
        const tolower_fn = core.LLVMGetNamedFunction(self.module, "tolower");
        var tolower_args: [1]types.LLVMValueRef = .{char_i32};
        const lower_i32 = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(tolower_fn), tolower_fn, &tolower_args, 1, "lower_i32");
        const lower_i8 = core.LLVMBuildTrunc(self.builder, lower_i32, self.i8Type(), "lower_i8");

        const char_dst = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(&i_gep_args), 1, "char_dst");
        _ = core.LLVMBuildStore(self.builder, lower_i8, char_dst);

        const next_i = core.LLVMBuildAdd(self.builder, i_param, core.LLVMConstInt(self.i64Type(), 1, 0), "next_i");
        self.buildBranch(loop_check);

        var phi_vals2: [1]types.LLVMValueRef = .{next_i};
        var phi_bbs2: [1]types.LLVMBasicBlockRef = .{loop_body};
        core.LLVMAddIncoming(i_param, @ptrCast(@constCast(&phi_vals2)), @ptrCast(@constCast(&phi_bbs2)), 1);

        // loop_done: null-terminate and wrap in KoString via ko_string_alloc
        core.LLVMPositionBuilderAtEnd(self.builder, loop_done);
        var len_gep_args: [1]types.LLVMValueRef = .{len};
        const null_dst = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(&len_gep_args), 1, "null_dst");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i8Type(), 0, 0), null_dst);

        // Wrap in KoString: ko_string_alloc(buf, len)
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_string_alloc");
        var alloc_args: [2]types.LLVMValueRef = .{ buf, len };
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "result");
        self.buildRet(result);
    }

    pub fn codegenStringTrim(self: *StdlibCodegen) void {
        // ko_string_trim(str: ptr) -> ptr
        // Allocates new KoString with leading/trailing whitespace removed
        // Uses ko_string_byte_length (O(1)) and ko_string_data for source access
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_trim", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const find_start = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "find_start");
        const find_start_loop = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "find_start_loop");
        const find_end = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "find_end");
        const find_end_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "find_end_check");
        const find_end_decrement = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "find_end_decrement");
        const copy = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "copy");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const str = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(str, "str");

        // Get source data pointer via ko_string_data
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var data_args: [1]types.LLVMValueRef = .{str};
        const src_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &data_args, 1, "src_data");

        const start_0 = core.LLVMConstInt(self.i64Type(), 0, 0);
        self.buildBranch(find_start);

        // find_start: check if data[start] is space
        core.LLVMPositionBuilderAtEnd(self.builder, find_start);
        const start = core.LLVMBuildPhi(self.builder, self.i64Type(), "start");
        var start_phi_vals_entry: [1]types.LLVMValueRef = .{start_0};
        var start_phi_bbs_entry: [1]types.LLVMBasicBlockRef = .{entry};
        core.LLVMAddIncoming(start, @ptrCast(@constCast(&start_phi_vals_entry)), @ptrCast(@constCast(&start_phi_bbs_entry)), 1);

        var start_gep_args: [1]types.LLVMValueRef = .{start};
        const char_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), src_data, @ptrCast(&start_gep_args), 1, "char_ptr");
        const char_val = core.LLVMBuildLoad2(self.builder, self.i8Type(), char_ptr, "char_val");

        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, char_val, core.LLVMConstInt(self.i8Type(), 0, 0), "is_null");

        const char_i32 = core.LLVMBuildSExt(self.builder, char_val, core.LLVMInt32TypeInContext(self.context), "char_i32");
        const isspace_fn = core.LLVMGetNamedFunction(self.module, "isspace");
        var isspace_args: [1]types.LLVMValueRef = .{char_i32};
        const space_result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(isspace_fn), isspace_fn, &isspace_args, 1, "space_result");
        const is_space = core.LLVMBuildICmp(self.builder, .LLVMIntNE, space_result, core.LLVMConstInt(core.LLVMInt32TypeInContext(self.context), 0, 0), "is_space");

        const is_space_or_null = core.LLVMBuildOr(self.builder, is_space, is_null, "is_space_or_null");
        self.buildCondBranch(is_space_or_null, find_start_loop, find_end);

        // find_start_loop: start++
        core.LLVMPositionBuilderAtEnd(self.builder, find_start_loop);
        const next_start = core.LLVMBuildAdd(self.builder, start, core.LLVMConstInt(self.i64Type(), 1, 0), "next_start");
        self.buildBranch(find_start);

        var start_phi_vals_loop: [1]types.LLVMValueRef = .{next_start};
        var start_phi_bbs_loop: [1]types.LLVMBasicBlockRef = .{find_start_loop};
        core.LLVMAddIncoming(start, @ptrCast(@constCast(&start_phi_vals_loop)), @ptrCast(@constCast(&start_phi_bbs_loop)), 1);

        // find_end: get len via ko_string_byte_length, compute end_init
        core.LLVMPositionBuilderAtEnd(self.builder, find_end);
        const byte_len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var len_args: [1]types.LLVMValueRef = .{str};
        const len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &len_args, 1, "len");
        const end_init = core.LLVMBuildSub(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "end_init");
        self.buildBranch(find_end_check);

        // find_end_check: phi, check if data[end] is space
        // We scan backwards past trailing spaces, then stop at the first non-space.
        core.LLVMPositionBuilderAtEnd(self.builder, find_end_check);
        const end = core.LLVMBuildPhi(self.builder, self.i64Type(), "end");
        var end_phi_vals_entry: [1]types.LLVMValueRef = .{end_init};
        var end_phi_bbs_entry: [1]types.LLVMBasicBlockRef = .{find_end};
        core.LLVMAddIncoming(end, @ptrCast(@constCast(&end_phi_vals_entry)), @ptrCast(@constCast(&end_phi_bbs_entry)), 1);

        var end_gep_args: [1]types.LLVMValueRef = .{end};
        const end_char_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), src_data, @ptrCast(&end_gep_args), 1, "end_char_ptr");
        const end_char = core.LLVMBuildLoad2(self.builder, self.i8Type(), end_char_ptr, "end_char");

        const end_char_i32 = core.LLVMBuildSExt(self.builder, end_char, core.LLVMInt32TypeInContext(self.context), "end_char_i32");
        var end_isspace_args: [1]types.LLVMValueRef = .{end_char_i32};
        const end_space = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(isspace_fn), isspace_fn, &end_isspace_args, 1, "end_space");
        const end_is_space = core.LLVMBuildICmp(self.builder, .LLVMIntNE, end_space, core.LLVMConstInt(core.LLVMInt32TypeInContext(self.context), 0, 0), "end_is_space");

        // Stop when we find a non-space character OR go past start
        const end_lt_start = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, end, start, "end_lt_start");
        const should_stop = core.LLVMBuildOr(self.builder, end_lt_start, core.LLVMBuildNot(self.builder, end_is_space, "end_is_not_space"), "should_stop");
        self.buildCondBranch(should_stop, copy, find_end_decrement);

        // find_end_decrement: end--, branch back to find_end_check
        core.LLVMPositionBuilderAtEnd(self.builder, find_end_decrement);
        const prev_end = core.LLVMBuildSub(self.builder, end, core.LLVMConstInt(self.i64Type(), 1, 0), "prev_end");
        self.buildBranch(find_end_check);

        var end_phi_vals_loop: [1]types.LLVMValueRef = .{prev_end};
        var end_phi_bbs_loop: [1]types.LLVMBasicBlockRef = .{find_end_decrement};
        core.LLVMAddIncoming(end, @ptrCast(@constCast(&end_phi_vals_loop)), @ptrCast(@constCast(&end_phi_bbs_loop)), 1);

        // copy: copy_len = end - start + 1, malloc, memcpy, null-terminate
        core.LLVMPositionBuilderAtEnd(self.builder, copy);

        const end_plus1 = core.LLVMBuildAdd(self.builder, end, core.LLVMConstInt(self.i64Type(), 1, 0), "end_plus1");
        const copy_len_raw = core.LLVMBuildSub(self.builder, end_plus1, start, "copy_len_raw");
        const copy_len = core.LLVMBuildSelect(self.builder, end_lt_start, core.LLVMConstInt(self.i64Type(), 0, 0), copy_len_raw, "copy_len");

        const alloc_size = core.LLVMBuildAdd(self.builder, copy_len, core.LLVMConstInt(self.i64Type(), 1, 0), "alloc_size");

        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{alloc_size};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");

        const memcpy_fn = core.LLVMGetNamedFunction(self.module, "memcpy");
        var start_gep2: [1]types.LLVMValueRef = .{start};
        const src = core.LLVMBuildGEP2(self.builder, self.i8Type(), src_data, @ptrCast(&start_gep2), 1, "src");
        var memcpy_args: [3]types.LLVMValueRef = .{ buf, src, copy_len };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_args, 3, "");

        var copy_len_gep: [1]types.LLVMValueRef = .{copy_len};
        const null_dst = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(&copy_len_gep), 1, "null_dst");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i8Type(), 0, 0), null_dst);

        // Wrap in KoString: ko_string_alloc(buf, copy_len)
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_string_alloc");
        var alloc_args: [2]types.LLVMValueRef = .{ buf, copy_len };
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "result");
        self.buildRet(result);
    }

    pub fn codegenStringReplace(self: *StdlibCodegen) void {
        // ko_string_replace(str: ptr, from: ptr, to: ptr) -> ptr
        // Replaces all occurrences of `from` with `to` in `str`
        // Returns a new KoString with the replacements applied
        var params: [3]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType(), self.ptrType() };
        const fn_val = self.createFunction("ko_string_replace", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_check");
        const loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const loop_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const str = core.LLVMGetParam(fn_val, 0);
        const from = core.LLVMGetParam(fn_val, 1);
        const to = core.LLVMGetParam(fn_val, 2);
        core.LLVMSetValueName(str, "str");
        core.LLVMSetValueName(from, "from");
        core.LLVMSetValueName(to, "to");

        // Get data pointers via ko_string_data
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var str_data_args: [1]types.LLVMValueRef = .{str};
        const str_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &str_data_args, 1, "str_data");
        var from_data_args: [1]types.LLVMValueRef = .{from};
        const from_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &from_data_args, 1, "from_data");
        var to_data_args: [1]types.LLVMValueRef = .{to};
        const to_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &to_data_args, 1, "to_data");

        const strstr_fn = core.LLVMGetNamedFunction(self.module, "strstr");
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        const memcpy_fn = core.LLVMGetNamedFunction(self.module, "memcpy");

        // Allocas must be in the entry block (before any terminator)
        const result_buf_alloca = core.LLVMBuildAlloca(self.builder, self.ptrType(), "result_buf");
        const result_len_alloca = core.LLVMBuildAlloca(self.builder, self.i64Type(), "result_len");
        const current_alloca = core.LLVMBuildAlloca(self.builder, self.ptrType(), "current");

        _ = core.LLVMBuildStore(self.builder, str_data, current_alloca);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), result_len_alloca);

        // Allocate initial result buffer
        const byte_len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var str_len_args: [1]types.LLVMValueRef = .{str};
        const str_len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &str_len_args, 1, "str_len");
        const extra_space = core.LLVMConstInt(self.i64Type(), 64, 0);
        const buf_size = core.LLVMBuildAdd(self.builder, core.LLVMBuildMul(self.builder, str_len, core.LLVMConstInt(self.i64Type(), 2, 0), "str_len_x2"), extra_space, "buf_size");
        var malloc_args: [1]types.LLVMValueRef = .{buf_size};
        const init_buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "init_buf");
        _ = core.LLVMBuildStore(self.builder, init_buf, result_buf_alloca);

        // from_len = ko_string_byte_length(from)
        var from_len_args: [1]types.LLVMValueRef = .{from};
        const from_len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &from_len_args, 1, "from_len");

        // to_len = ko_string_byte_length(to)
        var to_len_args: [1]types.LLVMValueRef = .{to};
        const to_len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &to_len_args, 1, "to_len");

        // If from is empty, return str unchanged (this is the LAST instruction in entry block)
        const from_empty = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, from_len, core.LLVMConstInt(self.i64Type(), 0, 0), "from_empty");
        self.buildCondBranch(from_empty, loop_done, loop_check);

        // loop_check: find = strstr(current, from_data)
        core.LLVMPositionBuilderAtEnd(self.builder, loop_check);
        const current = core.LLVMBuildLoad2(self.builder, self.ptrType(), current_alloca, "current");
        var strstr_args: [2]types.LLVMValueRef = .{ current, from_data };
        const found = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strstr_fn), strstr_fn, &strstr_args, 2, "found");

        const not_found = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, found, core.LLVMConstPointerNull(self.ptrType()), "not_found");
        self.buildCondBranch(not_found, loop_done, loop_body);

        // loop_body: append prefix (current..found) and replacement (to_data)
        core.LLVMPositionBuilderAtEnd(self.builder, loop_body);

        // prefix_len = found - current
        const prefix_len = core.LLVMBuildPtrDiff2(self.builder, self.i8Type(), found, current, "prefix_len");

        // result_ptr = result_buf + result_len
        const result_len = core.LLVMBuildLoad2(self.builder, self.i64Type(), result_len_alloca, "result_len");
        var result_len_gep: [1]types.LLVMValueRef = .{result_len};
        const result_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), init_buf, @ptrCast(&result_len_gep), 1, "result_ptr");

        // memcpy(result_ptr, current, prefix_len)
        var memcpy_prefix_args: [3]types.LLVMValueRef = .{ result_ptr, current, prefix_len };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_prefix_args, 3, "");

        // memcpy(result_ptr + prefix_len, to_data, to_len)
        var prefix_gep: [1]types.LLVMValueRef = .{prefix_len};
        const to_dst = core.LLVMBuildGEP2(self.builder, self.i8Type(), result_ptr, @ptrCast(&prefix_gep), 1, "to_dst");
        var memcpy_to_args: [3]types.LLVMValueRef = .{ to_dst, to_data, to_len };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_to_args, 3, "");

        // result_len += prefix_len + to_len
        const new_result_len = core.LLVMBuildAdd(self.builder, core.LLVMBuildAdd(self.builder, result_len, prefix_len, "sum1"), to_len, "new_result_len");
        _ = core.LLVMBuildStore(self.builder, new_result_len, result_len_alloca);

        // current = found + from_len
        var from_len_gep: [1]types.LLVMValueRef = .{from_len};
        const new_current = core.LLVMBuildGEP2(self.builder, self.i8Type(), found, @ptrCast(&from_len_gep), 1, "new_current");
        _ = core.LLVMBuildStore(self.builder, new_current, current_alloca);

        self.buildBranch(loop_check);

        // loop_done: append remaining (current..end), null-terminate, return
        core.LLVMPositionBuilderAtEnd(self.builder, loop_done);

        const remaining = core.LLVMBuildLoad2(self.builder, self.ptrType(), current_alloca, "remaining");
        // remaining_len = end of original data - remaining pointer
        const str_data_end = core.LLVMBuildGEP2(self.builder, self.i8Type(), str_data, @ptrCast(@constCast(&.{str_len})), 1, "str_data_end");
        const remaining_len = core.LLVMBuildPtrDiff2(self.builder, self.i8Type(), str_data_end, remaining, "remaining_len");

        const final_len = core.LLVMBuildLoad2(self.builder, self.i64Type(), result_len_alloca, "final_len");

        // Check if we need a new buffer or can use existing
        const need_grow = core.LLVMBuildICmp(self.builder, .LLVMIntUGT, core.LLVMBuildAdd(self.builder, final_len, remaining_len, "total_need"), buf_size, "need_grow");

        const result_buf_final = core.LLVMBuildLoad2(self.builder, self.ptrType(), result_buf_alloca, "result_buf_final");

        // Append remaining: result_buf + final_len
        var final_len_gep: [1]types.LLVMValueRef = .{final_len};
        const append_dst = core.LLVMBuildGEP2(self.builder, self.i8Type(), result_buf_final, @ptrCast(&final_len_gep), 1, "append_dst");

        // memcpy(append_dst, remaining, remaining_len)
        var memcpy_remain_args: [3]types.LLVMValueRef = .{ append_dst, remaining, remaining_len };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_remain_args, 3, "");

        _ = need_grow; // TODO: realloc if needed

        // Wrap in KoString: ko_string_alloc(result_buf_final, final_len)
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_string_alloc");
        var alloc_args: [2]types.LLVMValueRef = .{ result_buf_final, final_len };
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "result");
        self.buildRet(result);
    }

    pub fn codegenStringSplit(self: *StdlibCodegen) void {
        // ko_string_split(str: ptr, delimiter: ptr) -> i64 (list pointer)
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        _ = self.createFunction("ko_string_split", self.i64Type(), &params);
    }

    // ============================================================
    // String prefix/suffix/search builtins
    // ============================================================

    pub fn codegenStringStartsWith(self: *StdlibCodegen) void {
        // ko_string_starts_with(str: ptr, prefix: ptr) -> i64
        // Returns 1 if str starts with prefix, 0 otherwise
        // Uses ko_string_byte_length (O(1)) and ko_string_data for comparison
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fn_val = self.createFunction("ko_string_starts_with", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const str = core.LLVMGetParam(fn_val, 0);
        const prefix = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(str, "str");
        core.LLVMSetValueName(prefix, "prefix");

        // prefix_len = ko_string_byte_length(prefix)
        const byte_len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var prefix_len_args: [1]types.LLVMValueRef = .{prefix};
        const prefix_len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &prefix_len_args, 1, "prefix_len");

        // Get data pointers via ko_string_data
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var str_data_args: [1]types.LLVMValueRef = .{str};
        const str_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &str_data_args, 1, "str_data");
        var prefix_data_args: [1]types.LLVMValueRef = .{prefix};
        const prefix_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &prefix_data_args, 1, "prefix_data");

        // result = strncmp(str_data, prefix_data, prefix_len) == 0
        const strncmp_fn = core.LLVMGetNamedFunction(self.module, "strncmp");
        var strncmp_args: [3]types.LLVMValueRef = .{ str_data, prefix_data, prefix_len };
        const cmp_result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strncmp_fn), strncmp_fn, &strncmp_args, 3, "cmp_result");
        const zero_i32 = core.LLVMConstInt(core.LLVMInt32TypeInContext(self.context), 0, 0);
        const is_match = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, cmp_result, zero_i32, "is_match");
        const result = core.LLVMBuildZExt(self.builder, is_match, self.i64Type(), "result");
        self.buildRet(result);
    }

    pub fn codegenStringEndsWith(self: *StdlibCodegen) void {
        // ko_string_ends_with(str: ptr, suffix: ptr) -> i64
        // Returns 1 if str ends with suffix, 0 otherwise
        // Uses ko_string_byte_length (O(1)) and ko_string_data for comparison
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fn_val = self.createFunction("ko_string_ends_with", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const str = core.LLVMGetParam(fn_val, 0);
        const suffix = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(str, "str");
        core.LLVMSetValueName(suffix, "suffix");

        // Get lengths via ko_string_byte_length — O(1)
        const byte_len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var str_len_args: [1]types.LLVMValueRef = .{str};
        const str_len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &str_len_args, 1, "str_len");
        var suffix_len_args: [1]types.LLVMValueRef = .{suffix};
        const suffix_len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &suffix_len_args, 1, "suffix_len");

        // If suffix_len > str_len, return 0
        const cmp_len = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, suffix_len, str_len, "cmp_len");

        // offset = str_len - suffix_len
        const offset = core.LLVMBuildSub(self.builder, str_len, suffix_len, "offset");

        // Get data pointers via ko_string_data
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var str_data_args: [1]types.LLVMValueRef = .{str};
        const str_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &str_data_args, 1, "str_data");
        var suffix_data_args: [1]types.LLVMValueRef = .{suffix};
        const suffix_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &suffix_data_args, 1, "suffix_data");

        // result_ptr = str_data + offset (GEP into str_data)
        var gep_idx: [1]types.LLVMValueRef = .{offset};
        const result_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), str_data, &gep_idx, 1, "result_ptr");

        // cmp = strncmp(result_ptr, suffix_data, suffix_len) == 0
        const strncmp_fn = core.LLVMGetNamedFunction(self.module, "strncmp");
        var strncmp_args: [3]types.LLVMValueRef = .{ result_ptr, suffix_data, suffix_len };
        const cmp_result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strncmp_fn), strncmp_fn, &strncmp_args, 3, "cmp_result");
        const zero_i32 = core.LLVMConstInt(core.LLVMInt32TypeInContext(self.context), 0, 0);
        const suffix_matches = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, cmp_result, zero_i32, "suffix_matches");

        // If str_len < suffix_len, return 0; else return suffix_matches
        const zero = core.LLVMConstInt(self.i64Type(), 0, 0);
        const suffix_i64 = core.LLVMBuildZExt(self.builder, suffix_matches, self.i64Type(), "suffix_i64");
        const result = core.LLVMBuildSelect(self.builder, cmp_len, zero, suffix_i64, "result_ext");
        self.buildRet(result);
    }

    pub fn codegenStringSubstring(self: *StdlibCodegen) void {
        // ko_string_substring(str: ptr, start: i64, len: i64) -> ptr
        // Returns a new KoString from start for len bytes
        // Uses ko_string_byte_length (O(1)) and ko_string_data for source access
        var params: [3]types.LLVMTypeRef = .{ self.ptrType(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_string_substring", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const str = core.LLVMGetParam(fn_val, 0);
        const start = core.LLVMGetParam(fn_val, 1);
        const len = core.LLVMGetParam(fn_val, 2);
        core.LLVMSetValueName(str, "str");
        core.LLVMSetValueName(start, "start");
        core.LLVMSetValueName(len, "len");

        // Get length via ko_string_byte_length — O(1)
        const byte_len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length");
        var str_len_args: [1]types.LLVMValueRef = .{str};
        const str_len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(byte_len_fn), byte_len_fn, &str_len_args, 1, "str_len");

        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        const memcpy_fn = core.LLVMGetNamedFunction(self.module, "memcpy");

        // Clamp start to [0, str_len]
        const start_negative = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, start, core.LLVMConstInt(self.i64Type(), 0, 0), "start_neg");
        const clamped_start = core.LLVMBuildSelect(self.builder, start_negative, core.LLVMConstInt(self.i64Type(), 0, 0), start, "clamped_start");
        const start_too_big = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, clamped_start, str_len, "start_big");
        const safe_start = core.LLVMBuildSelect(self.builder, start_too_big, str_len, clamped_start, "safe_start");

        // available = str_len - safe_start
        const available = core.LLVMBuildSub(self.builder, str_len, safe_start, "available");

        // actual_len = min(len, available)
        const len_too_big = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, len, available, "len_big");
        const actual_len = core.LLVMBuildSelect(self.builder, len_too_big, available, len, "actual_len");

        // If actual_len < 0, set to 0
        const len_negative = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, actual_len, core.LLVMConstInt(self.i64Type(), 0, 0), "len_neg");
        const final_len = core.LLVMBuildSelect(self.builder, len_negative, core.LLVMConstInt(self.i64Type(), 0, 0), actual_len, "final_len");

        // alloc_size = final_len + 1 (for null terminator)
        const one = core.LLVMConstInt(self.i64Type(), 1, 0);
        const alloc_size = core.LLVMBuildAdd(self.builder, final_len, one, "alloc_size");

        // buf = malloc(alloc_size)
        var malloc_args: [1]types.LLVMValueRef = .{alloc_size};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");

        // Get source data pointer via ko_string_data
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var data_args: [1]types.LLVMValueRef = .{str};
        const src_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &data_args, 1, "src_data");

        // src_ptr = src_data + safe_start
        var src_gep: [1]types.LLVMValueRef = .{safe_start};
        const src_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), src_data, &src_gep, 1, "src_ptr");

        // memcpy(buf, src_ptr, final_len)
        var memcpy_args: [3]types.LLVMValueRef = .{ buf, src_ptr, final_len };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_args, 3, "");

        // buf[final_len] = '\0'
        var null_gep: [1]types.LLVMValueRef = .{final_len};
        const null_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, &null_gep, 1, "null_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i8Type(), 0, 0), null_ptr);

        // Wrap in KoString: ko_string_alloc(buf, final_len)
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_string_alloc");
        var alloc_args: [2]types.LLVMValueRef = .{ buf, final_len };
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "result");
        self.buildRet(result);
    }

    pub fn codegenStringIndexOf(self: *StdlibCodegen) void {
        // ko_string_index_of(haystack: ptr, needle: ptr) -> i64
        // Returns the index of the first occurrence, or -1 if not found
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fn_val = self.createFunction("ko_string_index_of", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const haystack = core.LLVMGetParam(fn_val, 0);
        const needle = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(haystack, "haystack");
        core.LLVMSetValueName(needle, "needle");

        // Get data pointers via ko_string_data
        const data_fn = core.LLVMGetNamedFunction(self.module, "ko_string_data");
        var haystack_data_args: [1]types.LLVMValueRef = .{haystack};
        const haystack_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &haystack_data_args, 1, "haystack_data");
        var needle_data_args: [1]types.LLVMValueRef = .{needle};
        const needle_data = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(data_fn), data_fn, &needle_data_args, 1, "needle_data");

        const strstr_fn = core.LLVMGetNamedFunction(self.module, "strstr");

        // result_ptr = strstr(haystack_data, needle_data)
        var strstr_args: [2]types.LLVMValueRef = .{ haystack_data, needle_data };
        const result_ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strstr_fn), strstr_fn, &strstr_args, 2, "result_ptr");

        // is_not_found = (result_ptr == null)
        const null_ptr = core.LLVMConstPointerNull(self.ptrType());
        const is_not_found = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, result_ptr, null_ptr, "is_not_found");

        // not_found_result = -1
        const neg1 = core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -1)), 0);

        // found_index = result_ptr - haystack_data
        const found_index = core.LLVMBuildPtrDiff2(self.builder, self.i8Type(), result_ptr, haystack_data, "found_index");

        // result = is_not_found ? -1 : found_index
        const result = core.LLVMBuildSelect(self.builder, is_not_found, neg1, found_index, "result");
        self.buildRet(result);
    }

    // ============================================================
    // Float conversion functions
    // ============================================================

    pub fn codegenFloatOfInt(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_float_of_int", self.doubleType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        const result = core.LLVMBuildSIToFP(self.builder, val, self.doubleType(), "result");
        self.buildRet(result);
    }

    pub fn codegenFloatToInt(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.doubleType()};
        const fn_val = self.createFunction("ko_float_to_int", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        const result = core.LLVMBuildFPToSI(self.builder, val, self.i64Type(), "result");
        self.buildRet(result);
    }

    // ============================================================
    // Float math functions using LLVM intrinsics
    // ============================================================

    pub fn codegenFloatUnaryIntrinsic(self: *StdlibCodegen, ko_name: [*:0]const u8, intrinsic_name: [*:0]const u8) void {
        var params: [1]types.LLVMTypeRef = .{self.doubleType()};
        const fn_val = self.createFunction(ko_name, self.doubleType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);

        // Declare intrinsic if not already declared
        var intrinsic = core.LLVMGetNamedFunction(self.module, intrinsic_name);
        if (intrinsic == null) {
            var intrinsic_params: [1]types.LLVMTypeRef = .{self.doubleType()};
            const intrinsic_type = core.LLVMFunctionType(self.doubleType(), &intrinsic_params, 1, 0);
            intrinsic = core.LLVMAddFunction(self.module, intrinsic_name, intrinsic_type);
        }

        var args: [1]types.LLVMValueRef = .{val};
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(intrinsic), intrinsic, &args, 1, "result");
        self.buildRet(result);
    }

    pub fn codegenFloatBinaryIntrinsic(self: *StdlibCodegen, ko_name: [*:0]const u8, intrinsic_name: [*:0]const u8) void {
        var params: [2]types.LLVMTypeRef = .{ self.doubleType(), self.doubleType() };
        const fn_val = self.createFunction(ko_name, self.doubleType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);

        // Declare intrinsic if not already declared
        var intrinsic = core.LLVMGetNamedFunction(self.module, intrinsic_name);
        if (intrinsic == null) {
            var intrinsic_params: [2]types.LLVMTypeRef = .{ self.doubleType(), self.doubleType() };
            const intrinsic_type = core.LLVMFunctionType(self.doubleType(), &intrinsic_params, 2, 0);
            intrinsic = core.LLVMAddFunction(self.module, intrinsic_name, intrinsic_type);
        }

        var args: [2]types.LLVMValueRef = .{ a, b };
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(intrinsic), intrinsic, &args, 2, "result");
        self.buildRet(result);
    }

    pub fn codegenAllFloatMath(self: *StdlibCodegen) void {
        self.codegenFloatUnaryIntrinsic("ko_float_sqrt", "llvm.sqrt.f64");
        self.codegenFloatUnaryIntrinsic("ko_float_sin", "llvm.sin.f64");
        self.codegenFloatUnaryIntrinsic("ko_float_cos", "llvm.cos.f64");
        self.codegenFloatUnaryIntrinsic("ko_float_exp", "llvm.exp.f64");
        self.codegenFloatUnaryIntrinsic("ko_float_log", "llvm.log.f64");
        self.codegenFloatUnaryIntrinsic("ko_float_log2", "llvm.log2.f64");
        self.codegenFloatUnaryIntrinsic("ko_float_log10", "llvm.log10.f64");
        self.codegenFloatUnaryIntrinsic("ko_float_floor", "llvm.floor.f64");
        self.codegenFloatUnaryIntrinsic("ko_float_ceil", "llvm.ceil.f64");
        self.codegenFloatUnaryIntrinsic("ko_float_abs", "llvm.fabs.f64");
        self.codegenFloatBinaryIntrinsic("ko_float_pow", "llvm.pow.f64");
        self.codegenFloatTan();
    }

    fn codegenFloatTan(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.doubleType()};
        const fn_val = self.createFunction("ko_float_tan", self.doubleType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);

        // sin(val)
        var sin_intrinsic = core.LLVMGetNamedFunction(self.module, "llvm.sin.f64");
        if (sin_intrinsic == null) {
            var sin_params: [1]types.LLVMTypeRef = .{self.doubleType()};
            const sin_type = core.LLVMFunctionType(self.doubleType(), &sin_params, 1, 0);
            sin_intrinsic = core.LLVMAddFunction(self.module, "llvm.sin.f64", sin_type);
        }
        var sin_args: [1]types.LLVMValueRef = .{val};
        const sin_val = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(sin_intrinsic), sin_intrinsic, &sin_args, 1, "sin_val");

        // cos(val)
        var cos_intrinsic = core.LLVMGetNamedFunction(self.module, "llvm.cos.f64");
        if (cos_intrinsic == null) {
            var cos_params: [1]types.LLVMTypeRef = .{self.doubleType()};
            const cos_type = core.LLVMFunctionType(self.doubleType(), &cos_params, 1, 0);
            cos_intrinsic = core.LLVMAddFunction(self.module, "llvm.cos.f64", cos_type);
        }
        var cos_args: [1]types.LLVMValueRef = .{val};
        const cos_val = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(cos_intrinsic), cos_intrinsic, &cos_args, 1, "cos_val");

        // tan = sin / cos
        const result = core.LLVMBuildFDiv(self.builder, sin_val, cos_val, "tan_val");
        self.buildRet(result);
    }

    // ============================================================
    // Float constants (zero-arg functions returning f64 as i64)
    // ============================================================

    fn codegenFloatConstants(self: *StdlibCodegen) void {
        self.codegenFloatConst("ko_float_pi", std.math.pi);
        self.codegenFloatConst("ko_float_e", std.math.e);
        self.codegenFloatConst("ko_float_infinity", std.math.inf(f64));
        self.codegenFloatConst("ko_float_nan", std.math.nan(f64));
        self.codegenFloatConst("ko_float_max_value", std.math.floatMax(f64));
        self.codegenFloatConst("ko_float_min_value", -std.math.floatMax(f64));
        self.codegenFloatConst("ko_float_epsilon", std.math.floatEps(f64));
    }

    fn codegenFloatConst(self: *StdlibCodegen, name: [*:0]const u8, value: f64) void {
        const fn_val = self.createFunction(name, self.i64Type(), &.{});
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const double_val = core.LLVMConstReal(self.doubleType(), value);
        const i64_val = core.LLVMConstBitCast(double_val, self.i64Type());
        self.buildRet(i64_val);
    }

    // ============================================================
    // Float predicates (unary functions returning i64 0/1)
    // ============================================================

    fn codegenFloatPredicates(self: *StdlibCodegen) void {
        self.codegenFloatIsNan();
        self.codegenFloatIsInfinite();
        self.codegenFloatIsFinite();
        self.codegenFloatSign();
    }

    fn codegenFloatIsNan(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_float_is_nan", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const i64_val = core.LLVMGetParam(fn_val, 0);
        const double_val = core.LLVMBuildBitCast(self.builder, i64_val, self.doubleType(), "dbl");
        const nan_val = core.LLVMConstReal(self.doubleType(), std.math.nan(f64));
        const cmp = core.LLVMBuildFCmp(self.builder, .LLVMRealUNE, double_val, nan_val, "is_nan");
        const result = core.LLVMBuildZExt(self.builder, cmp, self.i64Type(), "result");
        self.buildRet(result);
    }

    fn codegenFloatIsInfinite(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_float_is_infinite", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const i64_val = core.LLVMGetParam(fn_val, 0);
        const double_val = core.LLVMBuildBitCast(self.builder, i64_val, self.doubleType(), "dbl");
        const pos_inf = core.LLVMConstReal(self.doubleType(), std.math.inf(f64));
        const neg_inf = core.LLVMConstReal(self.doubleType(), -std.math.inf(f64));
        const pos_cmp = core.LLVMBuildFCmp(self.builder, .LLVMRealOEQ, double_val, pos_inf, "eq_pos");
        const neg_cmp = core.LLVMBuildFCmp(self.builder, .LLVMRealOEQ, double_val, neg_inf, "eq_neg");
        const cmp = core.LLVMBuildOr(self.builder, pos_cmp, neg_cmp, "is_inf");
        const result = core.LLVMBuildZExt(self.builder, cmp, self.i64Type(), "result");
        self.buildRet(result);
    }

    fn codegenFloatIsFinite(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_float_is_finite", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const i64_val = core.LLVMGetParam(fn_val, 0);
        const double_val = core.LLVMBuildBitCast(self.builder, i64_val, self.doubleType(), "dbl");
        // x == x (NaN check) && !isinf(x)
        const self_cmp = core.LLVMBuildFCmp(self.builder, .LLVMRealOEQ, double_val, double_val, "eq_self");
        const pos_inf = core.LLVMConstReal(self.doubleType(), std.math.inf(f64));
        const neg_inf = core.LLVMConstReal(self.doubleType(), -std.math.inf(f64));
        const pos_inf_cmp = core.LLVMBuildFCmp(self.builder, .LLVMRealOEQ, double_val, pos_inf, "eq_pos");
        const neg_inf_cmp = core.LLVMBuildFCmp(self.builder, .LLVMRealOEQ, double_val, neg_inf, "eq_neg");
        const inf_cmp = core.LLVMBuildOr(self.builder, pos_inf_cmp, neg_inf_cmp, "is_inf");
        const not_inf = core.LLVMBuildNot(self.builder, inf_cmp, "not_inf");
        const cmp = core.LLVMBuildAnd(self.builder, self_cmp, not_inf, "is_finite");
        const result = core.LLVMBuildZExt(self.builder, cmp, self.i64Type(), "result");
        self.buildRet(result);
    }

    fn codegenFloatSign(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_float_sign", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const i64_val = core.LLVMGetParam(fn_val, 0);
        const double_val = core.LLVMBuildBitCast(self.builder, i64_val, self.doubleType(), "dbl");
        const zero = core.LLVMConstReal(self.doubleType(), 0.0);
        const one = core.LLVMConstInt(self.i64Type(), 1, 0);
        const neg_one = core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -1)), 0);
        const zero_i64 = core.LLVMConstInt(self.i64Type(), 0, 0);
        const gt = core.LLVMBuildFCmp(self.builder, .LLVMRealOGT, double_val, zero, "gt");
        const lt = core.LLVMBuildFCmp(self.builder, .LLVMRealOLT, double_val, zero, "lt");
        const select_neg = core.LLVMBuildSelect(self.builder, lt, neg_one, zero_i64, "neg_or_zero");
        const select_pos = core.LLVMBuildSelect(self.builder, gt, one, select_neg, "result");
        self.buildRet(select_pos);
    }

    // ============================================================
    // Int toString (using snprintf)
    // ============================================================

    pub fn codegenIntToString(self: *StdlibCodegen) void {
        // ko_int_to_string(val: i64) -> ptr
        // Converts integer to KoString using snprintf
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_int_to_string", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(val, "val");

        // buf = malloc(32) — temporary buffer for snprintf
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 32, 0)};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");

        // snprintf(buf, 32, "%ld", val) — returns number of characters written
        const snprintf_fn = core.LLVMGetNamedFunction(self.module, "snprintf");
        const fmt_str = self.globalStringConstant("%ld");
        var snprintf_args: [4]types.LLVMValueRef = .{ buf, core.LLVMConstInt(self.i64Type(), 32, 0), fmt_str, val };
        const written_len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(snprintf_fn), snprintf_fn, &snprintf_args, 4, "written_len");

        // Wrap in KoString: ko_string_alloc(buf, written_len)
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_string_alloc");
        var alloc_args: [2]types.LLVMValueRef = .{ buf, written_len };
        const result = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "result");
        self.buildRet(result);
    }

    /// Emit `name(val: param_ty) -> KoString*` as snprintf into a scratch buffer
    /// wrapped by ko_string_alloc. `fmt` must consume exactly one argument.
    /// Formats match println_with_tag so `"${x}"` and `println x` agree.
    fn emitToStringVia(
        self: *StdlibCodegen,
        name: [*:0]const u8,
        param_ty: types.LLVMTypeRef,
        fmt: [*:0]const u8,
        buf_size: u64,
        transform: enum { none, bitcast_double, trunc_i8 },
    ) void {
        var params: [1]types.LLVMTypeRef = .{param_ty};
        const fn_val = self.createFunction(name, self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const raw = core.LLVMGetParam(fn_val, 0);
        const val = switch (transform) {
            .none => raw,
            .bitcast_double => core.LLVMBuildBitCast(self.builder, raw, self.doubleType(), "f"),
            // `%c` reads an int from the varargs, so the i8 a Kō Char lowers to
            // has to be widened rather than passed at its own width.
            .trunc_i8 => core.LLVMBuildSExt(self.builder, raw, core.LLVMInt32TypeInContext(self.context), "c"),
        };

        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), buf_size, 0)};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");

        const snprintf_fn = core.LLVMGetNamedFunction(self.module, "snprintf");
        var args: [4]types.LLVMValueRef = .{ buf, core.LLVMConstInt(self.i64Type(), buf_size, 0), self.globalStringConstant(fmt), val };
        const written = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(snprintf_fn), snprintf_fn, &args, 4, "written");

        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_string_alloc");
        var alloc_args: [2]types.LLVMValueRef = .{ buf, written };
        self.buildRet(core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "result"));
    }

    /// Char predicates and case conversion. Chars are i64 at the Kō level, so
    /// each wrapper truncates to the i32 the ctype functions take and widens the
    /// result back. `ord`/`chr` are pure representation changes and need no
    /// runtime function at all — see lowerCharOp.
    pub fn codegenCharOps(self: *StdlibCodegen) void {
        const pairs = [_]struct { ko: [*:0]const u8, libc: [*:0]const u8, boolean: bool }{
            .{ .ko = "ko_char_is_alpha", .libc = "isalpha", .boolean = true },
            .{ .ko = "ko_char_is_digit", .libc = "isdigit", .boolean = true },
            .{ .ko = "ko_char_is_alnum", .libc = "isalnum", .boolean = true },
            .{ .ko = "ko_char_is_space", .libc = "isspace", .boolean = true },
            .{ .ko = "ko_char_is_upper", .libc = "isupper", .boolean = true },
            .{ .ko = "ko_char_is_lower", .libc = "islower", .boolean = true },
            .{ .ko = "ko_char_to_upper", .libc = "toupper", .boolean = false },
            .{ .ko = "ko_char_to_lower", .libc = "tolower", .boolean = false },
        };
        const i32_ty = core.LLVMInt32TypeInContext(self.context);
        for (pairs) |p| {
            var params: [1]types.LLVMTypeRef = .{self.i64Type()};
            const fn_val = self.createFunction(p.ko, self.i64Type(), &params);
            const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
            core.LLVMPositionBuilderAtEnd(self.builder, entry);

            const ch = core.LLVMBuildTrunc(self.builder, core.LLVMGetParam(fn_val, 0), i32_ty, "ch");
            const libc_fn = core.LLVMGetNamedFunction(self.module, p.libc) orelse unreachable;
            var args: [1]types.LLVMValueRef = .{ch};
            const res = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(libc_fn), libc_fn, &args, 1, "res");

            // The ctype predicates return any nonzero value for true, not 1.
            const normalized = if (p.boolean)
                core.LLVMBuildZExt(self.builder, core.LLVMBuildICmp(self.builder, .LLVMIntNE, res, core.LLVMConstInt(i32_ty, 0, 0), "is_set"), self.i64Type(), "out")
            else
                core.LLVMBuildSExt(self.builder, res, self.i64Type(), "out");
            self.buildRet(normalized);
        }
    }

    // Parameter types must be the LLVM types the LIR uses for these Kō types —
    // double, i8, i1 — not the i64 the older runtime helpers take, or the call
    // site and the body disagree about the argument's width.
    pub fn codegenFloatToString(self: *StdlibCodegen) void {
        self.emitToStringVia("ko_float_to_string", self.doubleType(), "%f", 64, .none);
    }

    pub fn codegenCharToString(self: *StdlibCodegen) void {
        self.emitToStringVia("ko_char_to_string", self.i8Type(), "%c", 8, .trunc_i8);
    }

    pub fn codegenBoolToString(self: *StdlibCodegen) void {
        // "True"/"False", matching println rather than the lowercase C spelling.
        var params: [1]types.LLVMTypeRef = .{core.LLVMInt1TypeInContext(self.context)};
        const fn_val = self.createFunction("ko_bool_to_string", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const is_true = core.LLVMGetParam(fn_val, 0);
        const text = core.LLVMBuildSelect(self.builder, is_true, self.globalStringConstant("True"), self.globalStringConstant("False"), "text");
        const len = core.LLVMBuildSelect(self.builder, is_true, core.LLVMConstInt(self.i64Type(), 4, 0), core.LLVMConstInt(self.i64Type(), 5, 0), "len");

        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_string_alloc");
        var alloc_args: [2]types.LLVMValueRef = .{ text, len };
        self.buildRet(core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "result"));
    }

    // ============================================================
    // String to int (using strtoll)
    // ============================================================

    pub fn codegenStringToInt(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fn_val = self.createFunction("ko_string_to_int", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const str = core.LLVMGetParam(fn_val, 0);
        const out = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(str, "str");
        core.LLVMSetValueName(out, "out");

        // null checks
        const is_str_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, str, core.LLVMConstNull(self.ptrType()), "is_str_null");
        const is_out_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, out, core.LLVMConstNull(self.ptrType()), "is_out_null");
        const is_null = core.LLVMBuildOr(self.builder, is_str_null, is_out_null, "is_null");

        const null_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "null_return");
        const compute_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "compute");
        self.buildCondBranch(is_null, null_block, compute_block);

        core.LLVMPositionBuilderAtEnd(self.builder, null_block);
        self.buildRet(core.LLVMConstInt(self.i64Type(), 0, 0));

        core.LLVMPositionBuilderAtEnd(self.builder, compute_block);
        // strtoll(str, NULL, 10)
        const strtoll_fn = core.LLVMGetNamedFunction(self.module, "strtoll");
        const null_ptr = core.LLVMConstNull(self.ptrType());
        var strtoll_args: [3]types.LLVMValueRef = .{ str, null_ptr, core.LLVMConstInt(self.i64Type(), 10, 0) };
        const parsed = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strtoll_fn), strtoll_fn, &strtoll_args, 3, "parsed");

        // *out = parsed
        _ = core.LLVMBuildStore(self.builder, parsed, out);

        // return 1 (success)
        self.buildRet(core.LLVMConstInt(self.i64Type(), 1, 0));
    }

    /// `String.toInt` / `String.toFloat`, returning `Maybe`.
    ///
    /// The Maybe is built here in the constructor layout lowerConstructorApply
    /// emits — arity-0 `Nothing` is the bare tag 1, and `Just x` is a heap
    /// `{tag, payload}` with type_tag 1 — so the result matches a Maybe the
    /// compiler built and can be pattern-matched like one.
    ///
    /// Parsing is stricter than the older ko_string_to_int, which used strtoll
    /// with a null end pointer and so reported success for "abc" (value 0) and
    /// for trailing junk like "12x". Here anything left unconsumed is Nothing.
    fn emitStringToMaybe(self: *StdlibCodegen, name: [*:0]const u8, is_float: bool) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction(name, self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const parse_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "parse");
        const just_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "just");
        const nothing_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "nothing");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const str = core.LLVMGetParam(fn_val, 0);
        const end_slot = core.LLVMBuildAlloca(self.builder, self.ptrType(), "end_slot");
        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, str, core.LLVMConstNull(self.ptrType()), "is_null");
        _ = core.LLVMBuildCondBr(self.builder, is_null, nothing_bb, parse_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, parse_bb);
        const parsed = blk: {
            if (is_float) {
                const strtod_fn = core.LLVMGetNamedFunction(self.module, "strtod") orelse unreachable;
                var args: [2]types.LLVMValueRef = .{ str, end_slot };
                const d = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strtod_fn), strtod_fn, &args, 2, "d");
                break :blk core.LLVMBuildBitCast(self.builder, d, self.i64Type(), "bits");
            }
            const strtoll_fn = core.LLVMGetNamedFunction(self.module, "strtoll") orelse unreachable;
            var args: [3]types.LLVMValueRef = .{ str, end_slot, core.LLVMConstInt(self.i64Type(), 10, 0) };
            break :blk core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strtoll_fn), strtoll_fn, &args, 3, "n");
        };
        const end = core.LLVMBuildLoad2(self.builder, self.ptrType(), end_slot, "end");
        // Nothing unless strtoll/strtod consumed at least one character and
        // stopped exactly at the NUL.
        const consumed_none = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, end, str, "consumed_none");
        const last = core.LLVMBuildLoad2(self.builder, self.i8Type(), end, "last");
        const has_trailing = core.LLVMBuildICmp(self.builder, .LLVMIntNE, last, core.LLVMConstInt(self.i8Type(), 0, 0), "has_trailing");
        const bad = core.LLVMBuildOr(self.builder, consumed_none, has_trailing, "bad");
        _ = core.LLVMBuildCondBr(self.builder, bad, nothing_bb, just_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, just_bb);
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
        var alloc_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
        const cell = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "cell");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), cell); // Just = tag 0
        var payload_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const payload = core.LLVMBuildGEP2(self.builder, self.i8Type(), cell, &payload_idx, 1, "payload");
        _ = core.LLVMBuildStore(self.builder, parsed, payload);
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, cell, self.i64Type(), "just"));

        core.LLVMPositionBuilderAtEnd(self.builder, nothing_bb);
        self.buildRet(core.LLVMConstInt(self.i64Type(), 1, 0)); // Nothing = tag 1
    }

    pub fn codegenStringToMaybe(self: *StdlibCodegen) void {
        self.emitStringToMaybe("ko_string_to_maybe_int", false);
        self.emitStringToMaybe("ko_string_to_maybe_float", true);
    }

    // ============================================================
    // Array
    //
    // Layout follows the KoString convention: the value is a pointer to the
    // elements, with the 32-byte header behind it, so ko_decref stays generic.
    //
    //   [-32] refcount
    //   [-24] type_tag: 11 = scalar elements, 12 = heap elements
    //   [-16] length
    //   [ -8] capacity
    //   [  0] elements, i64 each, contiguous
    //
    // The element kind lives in the type tag rather than the field bitmap: an
    // array is homogeneous, so one bit says everything, and that leaves the
    // fourth header word free for the capacity push needs. ko_decref branches
    // on tag 12 to decref elements, the same way it already branches on tag 10
    // for closures.
    //
    // Arrays are passed around as i64 (ptrtoint), like constructors and tuples.
    // ============================================================

    const array_tag_scalar: u64 = 11;
    const array_tag_heap: u64 = 12;

    /// Load a header word at `offset` (negative) from an array's element pointer.
    fn arrayHeaderPtr(self: *StdlibCodegen, ptr: types.LLVMValueRef, offset: i64, name: [*:0]const u8) types.LLVMValueRef {
        var idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(offset), 0)};
        const p = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&idx), 1, name);
        return core.LLVMBuildBitCast(self.builder, p, self.ptrType(), name);
    }

    fn arrayLoadLen(self: *StdlibCodegen, ptr: types.LLVMValueRef) types.LLVMValueRef {
        return core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayHeaderPtr(ptr, -16, "len_ptr"), "len");
    }

    fn arrayLoadCap(self: *StdlibCodegen, ptr: types.LLVMValueRef) types.LLVMValueRef {
        return core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayHeaderPtr(ptr, -8, "cap_ptr"), "cap");
    }

    /// Address of element `idx`, unchecked.
    fn arrayElemPtr(self: *StdlibCodegen, ptr: types.LLVMValueRef, idx: types.LLVMValueRef) types.LLVMValueRef {
        const off = core.LLVMBuildMul(self.builder, idx, core.LLVMConstInt(self.i64Type(), 8, 0), "elem_off");
        var gep_idx: [1]types.LLVMValueRef = .{off};
        const p = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&gep_idx), 1, "elem_p");
        return core.LLVMBuildBitCast(self.builder, p, self.ptrType(), "elem_ptr");
    }

    /// Emit `if (idx < 0 || idx >= len) panic(msg)`, continuing in a fresh block.
    fn arrayBoundsCheck(
        self: *StdlibCodegen,
        fn_val: types.LLVMValueRef,
        idx: types.LLVMValueRef,
        len: types.LLVMValueRef,
        msg: [*:0]const u8,
    ) void {
        const bad_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "oob");
        const ok_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "in_bounds");
        const too_low = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, idx, core.LLVMConstInt(self.i64Type(), 0, 0), "too_low");
        const too_high = core.LLVMBuildICmp(self.builder, .LLVMIntSGE, idx, len, "too_high");
        self.buildCondBranch(core.LLVMBuildOr(self.builder, too_low, too_high, "oob_cond"), bad_bb, ok_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, bad_bb);
        const panic_fn = core.LLVMGetNamedFunction(self.module, "ko_panic_str") orelse unreachable;
        var panic_args: [1]types.LLVMValueRef = .{self.globalStringConstant(msg)};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(panic_fn), panic_fn, &panic_args, 1, "");
        _ = core.LLVMBuildUnreachable(self.builder);

        core.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
    }

    /// ko_array_alloc(len, cap, type_tag) -> i64
    /// Allocates with the given capacity and sets length; elements are zeroed.
    fn codegenArrayAlloc(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_array_alloc", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);

        const len = core.LLVMGetParam(fn_val, 0);
        const cap_in = core.LLVMGetParam(fn_val, 1);
        const tag = core.LLVMGetParam(fn_val, 2);

        // Capacity of zero would make push's doubling stay at zero forever.
        const is_zero = core.LLVMBuildICmp(self.builder, .LLVMIntSLE, cap_in, core.LLVMConstInt(self.i64Type(), 0, 0), "cap_zero");
        const cap = core.LLVMBuildSelect(self.builder, is_zero, core.LLVMConstInt(self.i64Type(), 8, 0), cap_in, "cap");

        const bytes = core.LLVMBuildMul(self.builder, cap, core.LLVMConstInt(self.i64Type(), 8, 0), "bytes");
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
        var alloc_args: [2]types.LLVMValueRef = .{ bytes, tag };
        const ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "arr");

        _ = core.LLVMBuildStore(self.builder, len, self.arrayHeaderPtr(ptr, -16, "len_ptr"));
        _ = core.LLVMBuildStore(self.builder, cap, self.arrayHeaderPtr(ptr, -8, "cap_ptr"));

        // Zero the elements so a partially filled array never exposes garbage
        // to ko_decref_array, which would treat it as a pointer.
        const memset_fn = core.LLVMGetNamedFunction(self.module, "memset") orelse unreachable;
        var memset_args: [3]types.LLVMValueRef = .{ ptr, core.LLVMConstInt(core.LLVMInt32TypeInContext(self.context), 0, 0), bytes };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memset_fn), memset_fn, &memset_args, 3, "");

        self.buildRet(core.LLVMBuildPtrToInt(self.builder, ptr, self.i64Type(), "handle"));
    }

    /// ko_array_length(arr) -> i64
    fn codegenArrayLength(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_array_length", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "arr");
        self.buildRet(self.arrayLoadLen(ptr));
    }

    /// Apply a Kō function value to one argument, returning the result.
    ///
    /// Two representations share the slot: bit 0 set means a closure, whose
    /// slot 0 holds the real function pointer and which passes itself as the
    /// first argument; bit 0 clear means a bare function pointer taking the
    /// argument alone. This mirrors ko_result_map in stdlib.zig and the bit
    /// that lir_lower sets when passing an arrow-typed value to a runtime call.
    fn emitClosureCall1(
        self: *StdlibCodegen,
        fn_val: types.LLVMValueRef,
        callee: types.LLVMValueRef,
        arg: types.LLVMValueRef,
        name: [*:0]const u8,
    ) types.LLVMValueRef {
        const closure_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "call_closure");
        const raw_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "call_raw");
        const join_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "call_join");

        const bit = core.LLVMBuildAnd(self.builder, callee, core.LLVMConstInt(self.i64Type(), 1, 0), "closure_bit");
        const is_closure = core.LLVMBuildICmp(self.builder, .LLVMIntNE, bit, core.LLVMConstInt(self.i64Type(), 0, 0), "is_closure");
        self.buildCondBranch(is_closure, closure_bb, raw_bb);

        var params2: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn2_ty = core.LLVMFunctionType(self.i64Type(), &params2, 2, 0);
        var params1: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn1_ty = core.LLVMFunctionType(self.i64Type(), &params1, 1, 0);

        core.LLVMPositionBuilderAtEnd(self.builder, closure_bb);
        const cl_int = core.LLVMBuildAnd(self.builder, callee, core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -2)), 0), "cl_int");
        const cl_ptr = core.LLVMBuildIntToPtr(self.builder, cl_int, self.ptrType(), "cl_ptr");
        const slot0 = core.LLVMBuildLoad2(self.builder, self.i64Type(), cl_ptr, "slot0");
        const cl_fn = core.LLVMBuildIntToPtr(self.builder, slot0, self.ptrType(), "cl_fn");
        var cl_args: [2]types.LLVMValueRef = .{ cl_int, arg };
        const cl_res = core.LLVMBuildCall2(self.builder, fn2_ty, cl_fn, &cl_args, 2, "cl_res");
        self.buildBranch(join_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, raw_bb);
        const raw_fn = core.LLVMBuildIntToPtr(self.builder, callee, self.ptrType(), "raw_fn");
        var raw_args: [1]types.LLVMValueRef = .{arg};
        const raw_res = core.LLVMBuildCall2(self.builder, fn1_ty, raw_fn, &raw_args, 1, "raw_res");
        self.buildBranch(join_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, join_bb);
        const phi = core.LLVMBuildPhi(self.builder, self.i64Type(), name);
        var vals: [2]types.LLVMValueRef = .{ cl_res, raw_res };
        var bbs: [2]types.LLVMBasicBlockRef = .{ closure_bb, raw_bb };
        core.LLVMAddIncoming(phi, &vals, &bbs, 2);
        return phi;
    }

    /// ko_array_fill(arr, value) -> i64 (unit)
    /// Writes `value` into every slot up to the array's length. Used by
    /// Array.make, where the allocation already carries the final length.
    fn codegenArrayFill(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_array_fill", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "arr");
        const value = core.LLVMGetParam(fn_val, 1);
        const len = self.arrayLoadLen(ptr);
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, len, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        _ = core.LLVMBuildStore(self.builder, value, self.arrayElemPtr(ptr, i));
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(core.LLVMConstInt(self.i64Type(), 0, 0));
    }

    /// ko_array_is_empty(arr) -> i64 (0/1)
    fn codegenArrayIsEmpty(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_array_is_empty", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "arr");
        const is_empty = core.LLVMBuildICmp(self.builder, .LLVMIntSLE, self.arrayLoadLen(ptr), core.LLVMConstInt(self.i64Type(), 0, 0), "is_empty");
        self.buildRet(core.LLVMBuildZExt(self.builder, is_empty, self.i64Type(), "out"));
    }

    /// ko_array_get(arr, idx) -> i64
    fn codegenArrayGet(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_array_get", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "arr");
        const idx = core.LLVMGetParam(fn_val, 1);
        self.arrayBoundsCheck(fn_val, idx, self.arrayLoadLen(ptr), "Array.get: index out of bounds");
        self.buildRet(core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(ptr, idx), "elem"));
    }

    /// ko_array_set(arr, idx, value) -> i64 (unit)
    fn codegenArraySet(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_array_set", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "arr");
        const idx = core.LLVMGetParam(fn_val, 1);
        self.arrayBoundsCheck(fn_val, idx, self.arrayLoadLen(ptr), "Array.set: index out of bounds");
        _ = core.LLVMBuildStore(self.builder, core.LLVMGetParam(fn_val, 2), self.arrayElemPtr(ptr, idx));
        self.buildRet(core.LLVMConstInt(self.i64Type(), 0, 0));
    }

    /// ko_array_push(arr, value) -> i64
    /// Returns the array, which moves when it grows.
    fn codegenArrayPush(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_array_push", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const grow_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "grow");
        const store_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "store");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr0 = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "arr");
        const value = core.LLVMGetParam(fn_val, 1);
        const len = self.arrayLoadLen(ptr0);
        const cap = self.arrayLoadCap(ptr0);
        const full = core.LLVMBuildICmp(self.builder, .LLVMIntSGE, len, cap, "full");
        self.buildCondBranch(full, grow_bb, store_bb);

        // realloc the whole block, header included, and double the capacity.
        core.LLVMPositionBuilderAtEnd(self.builder, grow_bb);
        const new_cap = core.LLVMBuildMul(self.builder, cap, core.LLVMConstInt(self.i64Type(), 2, 0), "new_cap");
        const new_bytes = core.LLVMBuildAdd(
            self.builder,
            core.LLVMBuildMul(self.builder, new_cap, core.LLVMConstInt(self.i64Type(), 8, 0), "elem_bytes"),
            core.LLVMConstInt(self.i64Type(), 32, 0),
            "new_bytes",
        );
        const base = self.arrayHeaderPtr(ptr0, -32, "base");
        const realloc_fn = core.LLVMGetNamedFunction(self.module, "realloc") orelse unreachable;
        var realloc_args: [2]types.LLVMValueRef = .{ base, new_bytes };
        const new_base = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(realloc_fn), realloc_fn, &realloc_args, 2, "new_base");
        var fwd: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 32, 0)};
        const grown = core.LLVMBuildGEP2(self.builder, self.i8Type(), new_base, @ptrCast(&fwd), 1, "grown");
        _ = core.LLVMBuildStore(self.builder, new_cap, self.arrayHeaderPtr(grown, -8, "cap_ptr"));
        self.buildBranch(store_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, store_bb);
        const ptr = core.LLVMBuildPhi(self.builder, self.ptrType(), "ptr");
        var incoming: [2]types.LLVMValueRef = .{ ptr0, grown };
        var blocks: [2]types.LLVMBasicBlockRef = .{ entry, grow_bb };
        core.LLVMAddIncoming(ptr, &incoming, &blocks, 2);
        _ = core.LLVMBuildStore(self.builder, value, self.arrayElemPtr(ptr, len));
        const new_len = core.LLVMBuildAdd(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "new_len");
        _ = core.LLVMBuildStore(self.builder, new_len, self.arrayHeaderPtr(ptr, -16, "len_ptr"));
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, ptr, self.i64Type(), "handle"));
    }

    /// ko_array_pop(arr) -> i64, a Maybe in the constructor layout.
    fn codegenArrayPop(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_array_pop", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const empty_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "empty");
        const some_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "some");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "arr");
        const len = self.arrayLoadLen(ptr);
        const is_empty = core.LLVMBuildICmp(self.builder, .LLVMIntSLE, len, core.LLVMConstInt(self.i64Type(), 0, 0), "is_empty");
        self.buildCondBranch(is_empty, empty_bb, some_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, empty_bb);
        self.buildRet(core.LLVMConstInt(self.i64Type(), 1, 0)); // Nothing

        core.LLVMPositionBuilderAtEnd(self.builder, some_bb);
        const last = core.LLVMBuildSub(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "last");
        const value = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(ptr, last), "value");
        _ = core.LLVMBuildStore(self.builder, last, self.arrayHeaderPtr(ptr, -16, "len_ptr"));
        // The element leaves the array still owning nothing: the Just cell takes
        // over the reference the slot held, so no incref and no decref here.
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
        var alloc_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
        const cell = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "cell");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), cell); // Just
        var payload_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const payload = core.LLVMBuildGEP2(self.builder, self.i8Type(), cell, &payload_idx, 1, "payload");
        _ = core.LLVMBuildStore(self.builder, value, payload);
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, cell, self.i64Type(), "just"));
    }

    /// ko_decref_array(ptr) — decref each element. Only reached for tag 12,
    /// where the elements are heap values. Does not free the block itself;
    /// ko_decref does that, as it does for closures.
    fn codegenDecrefArray(self: *StdlibCodegen) void {
        // Already declared before ko_decref so that its call site could be built.
        const fn_val = core.LLVMGetNamedFunction(self.module, "ko_decref_array").?;
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const next_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "next");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMGetParam(fn_val, 0);
        const len = self.arrayLoadLen(ptr);
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, len, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const raw = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(ptr, i), "elem");
        // A nullary constructor is a bare tag, not a pointer — `Nothing` is the
        // integer 1 — so an Array (Maybe a) holds a mix of pointers and small
        // integers. Reading a header 32 bytes below address 1 would fault, so
        // anything below a page is left alone.
        const is_ptr = core.LLVMBuildICmp(self.builder, .LLVMIntUGT, raw, core.LLVMConstInt(self.i64Type(), 4096, 0), "is_ptr");
        const do_decref_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "do_decref");
        self.buildCondBranch(is_ptr, do_decref_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, do_decref_bb);
        const elem_ptr = core.LLVMBuildIntToPtr(self.builder, raw, self.ptrType(), "elem_ptr");
        const decref_fn = core.LLVMGetNamedFunction(self.module, "ko_decref") orelse unreachable;
        var decref_args: [1]types.LLVMValueRef = .{elem_ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(decref_fn), decref_fn, &decref_args, 1, "");
        self.buildBranch(next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRetVoid();
    }

    /// Allocate an array by calling ko_array_alloc, returning the element pointer.
    fn emitArrayAllocPtr(self: *StdlibCodegen, len: types.LLVMValueRef, cap: types.LLVMValueRef, tag: types.LLVMValueRef) types.LLVMValueRef {
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_array_alloc") orelse unreachable;
        var args: [3]types.LLVMValueRef = .{ len, cap, tag };
        const handle = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &args, 3, "new_arr");
        return core.LLVMBuildIntToPtr(self.builder, handle, self.ptrType(), "new_ptr");
    }

    /// ko_array_map(f, arr, out_tag) -> i64
    fn codegenArrayMap(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_array_map", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const f = core.LLVMGetParam(fn_val, 0);
        const src = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 1), self.ptrType(), "src");
        const len = self.arrayLoadLen(src);
        const dst = self.emitArrayAllocPtr(len, len, core.LLVMGetParam(fn_val, 2));
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, len, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const elem = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(src, i), "elem");
        const mapped = self.emitClosureCall1(fn_val, f, elem, "mapped");
        // emitClosureCall1 leaves the builder in its join block, so the index
        // has to be reloaded rather than reusing `i` across the branch.
        const i_cur = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_cur");
        _ = core.LLVMBuildStore(self.builder, mapped, self.arrayElemPtr(dst, i_cur));
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i_cur, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, dst, self.i64Type(), "handle"));
    }

    /// ko_array_filter(f, arr, out_tag) -> i64
    fn codegenArrayFilter(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_array_filter", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const keep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "keep");
        const next_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "next");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const f = core.LLVMGetParam(fn_val, 0);
        const src = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 1), self.ptrType(), "src");
        const len = self.arrayLoadLen(src);
        // Capacity for the worst case (everything kept); the length is fixed up
        // at the end so the result reports what actually survived.
        const dst = self.emitArrayAllocPtr(core.LLVMConstInt(self.i64Type(), 0, 0), len, core.LLVMGetParam(fn_val, 2));
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        const n_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "n");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), n_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, len, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const elem = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(src, i), "elem");
        const verdict = self.emitClosureCall1(fn_val, f, elem, "verdict");
        // A Bool-returning Kō function returns i1, so only the low bit of the
        // return register is defined; the rest is whatever was there. Testing
        // the whole word would accept every element.
        const bit = core.LLVMBuildAnd(self.builder, verdict, core.LLVMConstInt(self.i64Type(), 1, 0), "verdict_bit");
        const truthy = core.LLVMBuildICmp(self.builder, .LLVMIntNE, bit, core.LLVMConstInt(self.i64Type(), 0, 0), "truthy");
        self.buildCondBranch(truthy, keep_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, keep_bb);
        const i_keep = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_keep");
        const kept = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(src, i_keep), "kept");
        const n = core.LLVMBuildLoad2(self.builder, self.i64Type(), n_slot, "n_val");
        _ = core.LLVMBuildStore(self.builder, kept, self.arrayElemPtr(dst, n));
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, n, core.LLVMConstInt(self.i64Type(), 1, 0), "n_next"), n_slot);
        self.buildBranch(next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
        const i_n = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_n");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i_n, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        const final_n = core.LLVMBuildLoad2(self.builder, self.i64Type(), n_slot, "final_n");
        _ = core.LLVMBuildStore(self.builder, final_n, self.arrayHeaderPtr(dst, -16, "len_ptr"));
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, dst, self.i64Type(), "handle"));
    }

    /// ko_array_foldl(f, init, arr) / ko_array_foldr(f, init, arr) -> i64.
    /// `f` is curried, so each step is two applications.
    fn codegenArrayFold(self: *StdlibCodegen, name: [*:0]const u8, is_left: bool) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction(name, self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const f = core.LLVMGetParam(fn_val, 0);
        const src = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 2), self.ptrType(), "src");
        const len = self.arrayLoadLen(src);
        const acc_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "acc");
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        _ = core.LLVMBuildStore(self.builder, core.LLVMGetParam(fn_val, 1), acc_slot);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, len, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        // foldr walks the same counter from the far end, so both share one loop.
        const idx = if (is_left) i else core.LLVMBuildSub(
            self.builder,
            core.LLVMBuildSub(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "last"),
            i,
            "rev_idx",
        );
        const elem = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(src, idx), "elem");
        const acc = core.LLVMBuildLoad2(self.builder, self.i64Type(), acc_slot, "acc_val");
        // foldl is `f acc x`; foldr is `f x acc`.
        const first = if (is_left) acc else elem;
        const second = if (is_left) elem else acc;
        const partial = self.emitClosureCall1(fn_val, f, first, "partial");
        // Applying a curried two-argument function to one argument yields
        // another closure, but as a bare pointer — the tag bit is only set when
        // a function value crosses into a runtime call. Set it so the second
        // application takes the closure path rather than calling the pointer.
        const partial_tagged = core.LLVMBuildOr(self.builder, partial, core.LLVMConstInt(self.i64Type(), 1, 0), "partial_tagged");
        const stepped = self.emitClosureCall1(fn_val, partial_tagged, second, "stepped");
        _ = core.LLVMBuildStore(self.builder, stepped, acc_slot);
        const i_cur = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_cur");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i_cur, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(core.LLVMBuildLoad2(self.builder, self.i64Type(), acc_slot, "result"));
    }

    /// ko_array_reverse(arr, out_tag) -> i64
    fn codegenArrayReverse(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_array_reverse", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const src = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "src");
        const len = self.arrayLoadLen(src);
        const dst = self.emitArrayAllocPtr(len, len, core.LLVMGetParam(fn_val, 1));
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, len, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const elem = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(src, i), "elem");
        const mirror = core.LLVMBuildSub(
            self.builder,
            core.LLVMBuildSub(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "last"),
            i,
            "mirror",
        );
        _ = core.LLVMBuildStore(self.builder, elem, self.arrayElemPtr(dst, mirror));
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, dst, self.i64Type(), "handle"));
    }

    /// Insertion sort over a copy of the array.
    ///
    /// `use_cmp` selects the ordering: a Kō comparator returning negative /
    /// zero / positive (ko_array_sort_with), or the natural signed order of the
    /// i64 payload (ko_array_sort). The latter is only registered for
    /// `Array Int` — the payload of a Float is its bit pattern and of a String
    /// its address, neither of which sorts meaningfully.
    ///
    /// Insertion sort keeps this to two loops of LLVM builder calls. It is
    /// O(n²); swapping in a better algorithm is a self-contained change.
    fn codegenArraySortImpl(self: *StdlibCodegen, name: [*:0]const u8, use_cmp: bool) void {
        const nparams: c_uint = if (use_cmp) 3 else 2;
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_type = core.LLVMFunctionType(self.i64Type(), &params, nparams, 0);
        const fn_val = core.LLVMAddFunction(self.module, name, fn_type);

        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const copy_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "copy");
        const copy_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "copy_body");
        const outer_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "outer");
        const outer_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "outer_body");
        const inner_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "inner");
        const inner_test = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "inner_test");
        const inner_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "inner_body");
        const place_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "place");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const cmp_fn = if (use_cmp) core.LLVMGetParam(fn_val, 0) else null;
        const arr_param: c_uint = if (use_cmp) 1 else 0;
        const tag_param: c_uint = if (use_cmp) 2 else 1;
        const src = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, arr_param), self.ptrType(), "src");
        const len = self.arrayLoadLen(src);
        const dst = self.emitArrayAllocPtr(len, len, core.LLVMGetParam(fn_val, tag_param));

        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        const j_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "j");
        const v_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "v");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(copy_bb);

        // Copy the source into the destination, then sort in place.
        core.LLVMPositionBuilderAtEnd(self.builder, copy_bb);
        const ci = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "ci");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, ci, len, "more"), copy_body, outer_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, copy_body);
        const cv = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(src, ci), "cv");
        _ = core.LLVMBuildStore(self.builder, cv, self.arrayElemPtr(dst, ci));
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, ci, core.LLVMConstInt(self.i64Type(), 1, 0), "ci_next"), i_slot);
        self.buildBranch(copy_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, outer_bb);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 1, 0), i_slot);
        self.buildBranch(inner_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, inner_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, len, "outer_more"), outer_body, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, outer_body);
        const v = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(dst, i), "v_val");
        _ = core.LLVMBuildStore(self.builder, v, v_slot);
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildSub(self.builder, i, core.LLVMConstInt(self.i64Type(), 1, 0), "j_init"), j_slot);
        self.buildBranch(inner_test);

        core.LLVMPositionBuilderAtEnd(self.builder, inner_test);
        const j = core.LLVMBuildLoad2(self.builder, self.i64Type(), j_slot, "j_val");
        const j_ok = core.LLVMBuildICmp(self.builder, .LLVMIntSGE, j, core.LLVMConstInt(self.i64Type(), 0, 0), "j_ok");
        const shift_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "shift_check");
        self.buildCondBranch(j_ok, shift_bb, place_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, shift_bb);
        const jv = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(dst, j), "jv");
        const vv = core.LLVMBuildLoad2(self.builder, self.i64Type(), v_slot, "vv");
        const greater = blk: {
            if (use_cmp) {
                const partial = self.emitClosureCall1(fn_val, cmp_fn.?, jv, "cmp_partial");
                const tagged = core.LLVMBuildOr(self.builder, partial, core.LLVMConstInt(self.i64Type(), 1, 0), "cmp_tagged");
                const ord = self.emitClosureCall1(fn_val, tagged, vv, "ord");
                break :blk core.LLVMBuildICmp(self.builder, .LLVMIntSGT, ord, core.LLVMConstInt(self.i64Type(), 0, 0), "greater");
            }
            break :blk core.LLVMBuildICmp(self.builder, .LLVMIntSGT, jv, vv, "greater");
        };
        self.buildCondBranch(greater, inner_body, place_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, inner_body);
        const j2 = core.LLVMBuildLoad2(self.builder, self.i64Type(), j_slot, "j2");
        const jv2 = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(dst, j2), "jv2");
        _ = core.LLVMBuildStore(self.builder, jv2, self.arrayElemPtr(dst, core.LLVMBuildAdd(self.builder, j2, core.LLVMConstInt(self.i64Type(), 1, 0), "j_plus")));
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildSub(self.builder, j2, core.LLVMConstInt(self.i64Type(), 1, 0), "j_next"), j_slot);
        self.buildBranch(inner_test);

        core.LLVMPositionBuilderAtEnd(self.builder, place_bb);
        const jf = core.LLVMBuildLoad2(self.builder, self.i64Type(), j_slot, "jf");
        const vf = core.LLVMBuildLoad2(self.builder, self.i64Type(), v_slot, "vf");
        _ = core.LLVMBuildStore(self.builder, vf, self.arrayElemPtr(dst, core.LLVMBuildAdd(self.builder, jf, core.LLVMConstInt(self.i64Type(), 1, 0), "jf_plus")));
        const i_next = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_cur2");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i_next, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(inner_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, dst, self.i64Type(), "handle"));
    }

    pub fn codegenArrayOps(self: *StdlibCodegen) void {
        self.codegenArrayAlloc();
        self.codegenArrayLength();
        self.codegenArrayIsEmpty();
        self.codegenArrayFill();
        self.codegenArrayGet();
        self.codegenArraySet();
        self.codegenArrayPush();
        self.codegenArrayPop();
        self.codegenArrayMap();
        self.codegenArrayFilter();
        self.codegenArrayFold("ko_array_foldl", true);
        self.codegenArrayFold("ko_array_foldr", false);
        self.codegenArrayReverse();
        self.codegenArraySortImpl("ko_array_sort", false);
        self.codegenArraySortImpl("ko_array_sort_with", true);
        self.codegenDecrefArray();
    }

    // ============================================================
    // Map
    //
    // Open addressing with linear probing. Same header convention as Array,
    // with two words of the payload reserved before the buckets:
    //
    //   [-32] refcount
    //   [-24] type_tag = 13
    //   [-16] length (live entries)
    //   [ -8] capacity (bucket count, always a power of two)
    //   [  0] key_tag — which hash and equality to use
    //   [  8] flags: bit 0 = keys are heap, bit 1 = values are heap
    //   [ 16] buckets: capacity × { state, key, value }, 24 bytes each
    //
    // The key tag and the heap flags live in the map rather than being passed
    // in because ko_decref sees only the pointer: at teardown there is no call
    // site left to read a static type from.
    //
    // Linear probing rather than the doc's separate chaining: buckets stay in
    // one allocation, so there are no per-entry nodes to allocate, walk, or
    // free, and the whole map is one ko_alloc.
    // ============================================================

    const map_type_tag: u64 = 13;
    const map_bucket_bytes: u64 = 24;
    const map_header_words: u64 = 16;

    /// ko_hash(val, type_tag) -> i64
    ///
    /// Scalars are run through a bit mixer rather than used directly: linear
    /// probing clusters badly when hashes are sequential, which is exactly what
    /// identity-hashed integer keys are.
    fn codegenHash(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_hash", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const string_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "string");
        const scalar_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "scalar");
        const float_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "float");
        const mix_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "mix");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "fnv_loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "fnv_body");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "fnv_done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        const tag = core.LLVMGetParam(fn_val, 1);
        const is_string = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, tag, core.LLVMConstInt(self.i64Type(), 4, 0), "is_string");
        self.buildCondBranch(is_string, string_bb, scalar_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, scalar_bb);
        const is_float = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, tag, core.LLVMConstInt(self.i64Type(), 1, 0), "is_float");
        self.buildCondBranch(is_float, float_bb, mix_bb);

        // -0.0 and 0.0 must hash alike, since they compare equal.
        core.LLVMPositionBuilderAtEnd(self.builder, float_bb);
        const neg_zero = core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, @bitCast(@as(u64, 0x8000000000000000)))), 0);
        const is_neg_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, val, neg_zero, "is_neg_zero");
        const norm = core.LLVMBuildSelect(self.builder, is_neg_zero, core.LLVMConstInt(self.i64Type(), 0, 0), val, "norm");
        self.buildBranch(mix_bb);

        // splitmix64 finalizer.
        core.LLVMPositionBuilderAtEnd(self.builder, mix_bb);
        const raw = core.LLVMBuildPhi(self.builder, self.i64Type(), "raw");
        var raw_vals: [2]types.LLVMValueRef = .{ val, norm };
        var raw_bbs: [2]types.LLVMBasicBlockRef = .{ scalar_bb, float_bb };
        core.LLVMAddIncoming(raw, &raw_vals, &raw_bbs, 2);
        var h = raw;
        h = core.LLVMBuildXor(self.builder, h, core.LLVMBuildLShr(self.builder, h, core.LLVMConstInt(self.i64Type(), 30, 0), "s1"), "x1");
        h = core.LLVMBuildMul(self.builder, h, core.LLVMConstInt(self.i64Type(), @bitCast(@as(u64, 0xbf58476d1ce4e5b9)), 0), "m1");
        h = core.LLVMBuildXor(self.builder, h, core.LLVMBuildLShr(self.builder, h, core.LLVMConstInt(self.i64Type(), 27, 0), "s2"), "x2");
        h = core.LLVMBuildMul(self.builder, h, core.LLVMConstInt(self.i64Type(), @bitCast(@as(u64, 0x94d049bb133111eb)), 0), "m2");
        h = core.LLVMBuildXor(self.builder, h, core.LLVMBuildLShr(self.builder, h, core.LLVMConstInt(self.i64Type(), 31, 0), "s3"), "x3");
        self.buildRet(h);

        // FNV-1a over the string's bytes.
        core.LLVMPositionBuilderAtEnd(self.builder, string_bb);
        const sptr = core.LLVMBuildIntToPtr(self.builder, val, self.ptrType(), "sptr");
        const len_fn = core.LLVMGetNamedFunction(self.module, "ko_string_byte_length") orelse unreachable;
        var len_args: [1]types.LLVMValueRef = .{sptr};
        const slen = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(len_fn), len_fn, &len_args, 1, "slen");
        const hv_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "hv");
        const si_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "si");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), @bitCast(@as(u64, 0xcbf29ce484222325)), 0), hv_slot);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), si_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const si = core.LLVMBuildLoad2(self.builder, self.i64Type(), si_slot, "si_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, si, slen, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        var byte_idx: [1]types.LLVMValueRef = .{si};
        const byte_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), sptr, @ptrCast(&byte_idx), 1, "byte_ptr");
        const byte = core.LLVMBuildZExt(self.builder, core.LLVMBuildLoad2(self.builder, self.i8Type(), byte_ptr, "byte"), self.i64Type(), "byte64");
        const hv = core.LLVMBuildLoad2(self.builder, self.i64Type(), hv_slot, "hv_val");
        const xored = core.LLVMBuildXor(self.builder, hv, byte, "xored");
        const scaled = core.LLVMBuildMul(self.builder, xored, core.LLVMConstInt(self.i64Type(), 0x100000001b3, 0), "scaled");
        _ = core.LLVMBuildStore(self.builder, scaled, hv_slot);
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, si, core.LLVMConstInt(self.i64Type(), 1, 0), "si_next"), si_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(core.LLVMBuildLoad2(self.builder, self.i64Type(), hv_slot, "hv_final"));
    }

    /// ko_key_eq(a, b, type_tag) -> i64 (0/1)
    /// Strings compare by content; everything else by payload bits, which is
    /// the value for scalars.
    fn codegenKeyEq(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_key_eq", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const string_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "string");
        const raw_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "raw");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);
        const tag = core.LLVMGetParam(fn_val, 2);
        const is_string = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, tag, core.LLVMConstInt(self.i64Type(), 4, 0), "is_string");
        self.buildCondBranch(is_string, string_bb, raw_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, string_bb);
        const eq_fn = core.LLVMGetNamedFunction(self.module, "ko_string_eq") orelse unreachable;
        var eq_args: [2]types.LLVMValueRef = .{
            core.LLVMBuildIntToPtr(self.builder, a, self.ptrType(), "ap"),
            core.LLVMBuildIntToPtr(self.builder, b, self.ptrType(), "bp"),
        };
        self.buildRet(core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(eq_fn), eq_fn, &eq_args, 2, "seq"));

        core.LLVMPositionBuilderAtEnd(self.builder, raw_bb);
        const same = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, a, b, "same");
        self.buildRet(core.LLVMBuildZExt(self.builder, same, self.i64Type(), "out"));
    }

    fn mapLoadLen(self: *StdlibCodegen, ptr: types.LLVMValueRef) types.LLVMValueRef {
        return core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayHeaderPtr(ptr, -16, "mlen_ptr"), "mlen");
    }

    fn mapLoadCap(self: *StdlibCodegen, ptr: types.LLVMValueRef) types.LLVMValueRef {
        return core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayHeaderPtr(ptr, -8, "mcap_ptr"), "mcap");
    }

    /// Address of word `word` (0=state, 1=key, 2=value) of bucket `idx`.
    fn mapSlotPtr(self: *StdlibCodegen, ptr: types.LLVMValueRef, idx: types.LLVMValueRef, word: u64) types.LLVMValueRef {
        const base = core.LLVMBuildMul(self.builder, idx, core.LLVMConstInt(self.i64Type(), map_bucket_bytes, 0), "bucket_off");
        const off = core.LLVMBuildAdd(self.builder, base, core.LLVMConstInt(self.i64Type(), map_header_words + word * 8, 0), "slot_off");
        var gep_idx: [1]types.LLVMValueRef = .{off};
        const p = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&gep_idx), 1, "slot_p");
        return core.LLVMBuildBitCast(self.builder, p, self.ptrType(), "slot_ptr");
    }

    fn mapLoadKeyTag(self: *StdlibCodegen, ptr: types.LLVMValueRef) types.LLVMValueRef {
        return core.LLVMBuildLoad2(self.builder, self.i64Type(), ptr, "key_tag");
    }

    fn mapFlagsPtr(self: *StdlibCodegen, ptr: types.LLVMValueRef) types.LLVMValueRef {
        var idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const p = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&idx), 1, "flags_p");
        return core.LLVMBuildBitCast(self.builder, p, self.ptrType(), "flags_ptr");
    }

    /// ko_map_new(capacity, key_tag, flags) -> i64
    fn codegenMapNew(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_new", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const round_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "round");
        const alloc_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "alloc");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const want = core.LLVMGetParam(fn_val, 0);
        const cap_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "cap");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 8, 0), cap_slot);
        self.buildBranch(round_bb);

        // Capacity must be a power of two so `hash & (cap-1)` is the bucket.
        core.LLVMPositionBuilderAtEnd(self.builder, round_bb);
        const cur = core.LLVMBuildLoad2(self.builder, self.i64Type(), cap_slot, "cur");
        const too_small = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, cur, want, "too_small");
        const grow_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "round_grow");
        self.buildCondBranch(too_small, grow_bb, alloc_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, grow_bb);
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildMul(self.builder, cur, core.LLVMConstInt(self.i64Type(), 2, 0), "dbl"), cap_slot);
        self.buildBranch(round_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, alloc_bb);
        const cap = core.LLVMBuildLoad2(self.builder, self.i64Type(), cap_slot, "cap_val");
        const bytes = core.LLVMBuildAdd(
            self.builder,
            core.LLVMBuildMul(self.builder, cap, core.LLVMConstInt(self.i64Type(), map_bucket_bytes, 0), "bucket_bytes"),
            core.LLVMConstInt(self.i64Type(), map_header_words, 0),
            "bytes",
        );
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
        var alloc_args: [2]types.LLVMValueRef = .{ bytes, core.LLVMConstInt(self.i64Type(), map_type_tag, 0) };
        const ptr = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "map");

        const memset_fn = core.LLVMGetNamedFunction(self.module, "memset") orelse unreachable;
        var memset_args: [3]types.LLVMValueRef = .{ ptr, core.LLVMConstInt(core.LLVMInt32TypeInContext(self.context), 0, 0), bytes };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memset_fn), memset_fn, &memset_args, 3, "");

        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), self.arrayHeaderPtr(ptr, -16, "len_ptr"));
        _ = core.LLVMBuildStore(self.builder, cap, self.arrayHeaderPtr(ptr, -8, "cap_ptr"));
        _ = core.LLVMBuildStore(self.builder, core.LLVMGetParam(fn_val, 1), ptr);
        _ = core.LLVMBuildStore(self.builder, core.LLVMGetParam(fn_val, 2), self.mapFlagsPtr(ptr));
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, ptr, self.i64Type(), "handle"));
    }

    /// ko_map_find(map, key) -> i64
    /// Index of the bucket holding `key`, or -1. Tombstones are probed through
    /// so a deleted entry never truncates a probe chain.
    fn codegenMapFind(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_find", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "probe");
        const occupied_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "occupied");
        const next_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "next");
        const miss_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "miss");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "map");
        const key = core.LLVMGetParam(fn_val, 1);
        const cap = self.mapLoadCap(ptr);
        const key_tag = self.mapLoadKeyTag(ptr);
        const mask = core.LLVMBuildSub(self.builder, cap, core.LLVMConstInt(self.i64Type(), 1, 0), "mask");
        const hash_fn = core.LLVMGetNamedFunction(self.module, "ko_hash") orelse unreachable;
        var hash_args: [2]types.LLVMValueRef = .{ key, key_tag };
        const h = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(hash_fn), hash_fn, &hash_args, 2, "h");
        const idx_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "idx");
        const steps_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "steps");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAnd(self.builder, h, mask, "start"), idx_slot);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), steps_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const steps = core.LLVMBuildLoad2(self.builder, self.i64Type(), steps_slot, "steps_val");
        const exhausted = core.LLVMBuildICmp(self.builder, .LLVMIntSGE, steps, cap, "exhausted");
        const probe_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "probe_body");
        self.buildCondBranch(exhausted, miss_bb, probe_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, probe_bb);
        const idx = core.LLVMBuildLoad2(self.builder, self.i64Type(), idx_slot, "idx_val");
        const state = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, idx, 0), "state");
        const is_empty = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, state, core.LLVMConstInt(self.i64Type(), 0, 0), "is_empty");
        const check_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check");
        self.buildCondBranch(is_empty, miss_bb, check_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, check_bb);
        const is_occ = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, state, core.LLVMConstInt(self.i64Type(), 1, 0), "is_occ");
        self.buildCondBranch(is_occ, occupied_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, occupied_bb);
        const slot_key = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, idx, 1), "slot_key");
        const eq_fn = core.LLVMGetNamedFunction(self.module, "ko_key_eq") orelse unreachable;
        var eq_args: [3]types.LLVMValueRef = .{ slot_key, key, key_tag };
        const eq = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(eq_fn), eq_fn, &eq_args, 3, "eq");
        const hit = core.LLVMBuildICmp(self.builder, .LLVMIntNE, eq, core.LLVMConstInt(self.i64Type(), 0, 0), "hit");
        const found_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "found");
        self.buildCondBranch(hit, found_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, found_bb);
        self.buildRet(core.LLVMBuildLoad2(self.builder, self.i64Type(), idx_slot, "found_idx"));

        core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
        const cur_idx = core.LLVMBuildLoad2(self.builder, self.i64Type(), idx_slot, "cur_idx");
        const bumped = core.LLVMBuildAnd(self.builder, core.LLVMBuildAdd(self.builder, cur_idx, core.LLVMConstInt(self.i64Type(), 1, 0), "inc"), mask, "wrapped");
        _ = core.LLVMBuildStore(self.builder, bumped, idx_slot);
        const cur_steps = core.LLVMBuildLoad2(self.builder, self.i64Type(), steps_slot, "cur_steps");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, cur_steps, core.LLVMConstInt(self.i64Type(), 1, 0), "steps_next"), steps_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, miss_bb);
        self.buildRet(core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -1)), 0));
    }

    /// ko_map_insert(map, key, value) -> i64 (unit)
    /// Places an entry without growing; the caller guarantees room.
    fn codegenMapInsert(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_insert", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const update_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "update");
        const probe_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "probe");
        const probe_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "probe_body");
        const place_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "place");
        const next_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "next");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const handle = core.LLVMGetParam(fn_val, 0);
        const ptr = core.LLVMBuildIntToPtr(self.builder, handle, self.ptrType(), "map");
        const key = core.LLVMGetParam(fn_val, 1);
        const value = core.LLVMGetParam(fn_val, 2);
        const cap = self.mapLoadCap(ptr);
        const key_tag = self.mapLoadKeyTag(ptr);
        const mask = core.LLVMBuildSub(self.builder, cap, core.LLVMConstInt(self.i64Type(), 1, 0), "mask");

        // An existing key is overwritten in place, leaving the length alone.
        const find_fn = core.LLVMGetNamedFunction(self.module, "ko_map_find") orelse unreachable;
        var find_args: [2]types.LLVMValueRef = .{ handle, key };
        const existing = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(find_fn), find_fn, &find_args, 2, "existing");
        const has_existing = core.LLVMBuildICmp(self.builder, .LLVMIntSGE, existing, core.LLVMConstInt(self.i64Type(), 0, 0), "has_existing");
        self.buildCondBranch(has_existing, update_bb, probe_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, update_bb);
        _ = core.LLVMBuildStore(self.builder, value, self.mapSlotPtr(ptr, existing, 2));
        self.buildRet(core.LLVMConstInt(self.i64Type(), 0, 0));

        core.LLVMPositionBuilderAtEnd(self.builder, probe_bb);
        const hash_fn = core.LLVMGetNamedFunction(self.module, "ko_hash") orelse unreachable;
        var hash_args: [2]types.LLVMValueRef = .{ key, key_tag };
        const h = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(hash_fn), hash_fn, &hash_args, 2, "h");
        const idx_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "idx");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAnd(self.builder, h, mask, "start"), idx_slot);
        self.buildBranch(probe_body);

        core.LLVMPositionBuilderAtEnd(self.builder, probe_body);
        const idx = core.LLVMBuildLoad2(self.builder, self.i64Type(), idx_slot, "idx_val");
        const state = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, idx, 0), "state");
        const free_slot = core.LLVMBuildICmp(self.builder, .LLVMIntNE, state, core.LLVMConstInt(self.i64Type(), 1, 0), "free_slot");
        self.buildCondBranch(free_slot, place_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
        const bumped = core.LLVMBuildAnd(self.builder, core.LLVMBuildAdd(self.builder, idx, core.LLVMConstInt(self.i64Type(), 1, 0), "inc"), mask, "wrapped");
        _ = core.LLVMBuildStore(self.builder, bumped, idx_slot);
        self.buildBranch(probe_body);

        core.LLVMPositionBuilderAtEnd(self.builder, place_bb);
        const at = core.LLVMBuildLoad2(self.builder, self.i64Type(), idx_slot, "at");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 1, 0), self.mapSlotPtr(ptr, at, 0));
        _ = core.LLVMBuildStore(self.builder, key, self.mapSlotPtr(ptr, at, 1));
        _ = core.LLVMBuildStore(self.builder, value, self.mapSlotPtr(ptr, at, 2));
        const len = self.mapLoadLen(ptr);
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "len_next"), self.arrayHeaderPtr(ptr, -16, "len_ptr"));
        self.buildRet(core.LLVMConstInt(self.i64Type(), 0, 0));
    }

    /// ko_map_set(map, key, value) -> i64
    /// Returns the map, which moves when it has to grow.
    fn codegenMapSet(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_set", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const grow_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "grow");
        const rehash_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rehash");
        const rehash_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rehash_body");
        const rehash_next = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rehash_next");
        const insert_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "insert");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const handle = core.LLVMGetParam(fn_val, 0);
        const key = core.LLVMGetParam(fn_val, 1);
        const value = core.LLVMGetParam(fn_val, 2);
        const ptr = core.LLVMBuildIntToPtr(self.builder, handle, self.ptrType(), "map");
        const len = self.mapLoadLen(ptr);
        const cap = self.mapLoadCap(ptr);
        // Grow at 3/4 occupancy. Linear probing degrades sharply past that, and
        // tombstones count toward the bound only indirectly (via length), so the
        // margin also absorbs a moderate number of deletions.
        const limit = core.LLVMBuildAShr(self.builder, core.LLVMBuildMul(self.builder, cap, core.LLVMConstInt(self.i64Type(), 3, 0), "cap3"), core.LLVMConstInt(self.i64Type(), 2, 0), "limit");
        const needs_grow = core.LLVMBuildICmp(self.builder, .LLVMIntSGE, core.LLVMBuildAdd(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "len1"), limit, "needs_grow");
        const handle_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "handle_slot");
        _ = core.LLVMBuildStore(self.builder, handle, handle_slot);
        self.buildCondBranch(needs_grow, grow_bb, insert_bb);

        // Build a bigger map, re-insert every live entry, release the old one.
        core.LLVMPositionBuilderAtEnd(self.builder, grow_bb);
        const new_cap = core.LLVMBuildMul(self.builder, cap, core.LLVMConstInt(self.i64Type(), 2, 0), "new_cap");
        const new_fn = core.LLVMGetNamedFunction(self.module, "ko_map_new") orelse unreachable;
        var new_args: [3]types.LLVMValueRef = .{
            new_cap,
            self.mapLoadKeyTag(ptr),
            core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapFlagsPtr(ptr), "flags"),
        };
        const fresh = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(new_fn), new_fn, &new_args, 3, "fresh");
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(rehash_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, rehash_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        const done_rehash = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rehash_done");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, cap, "more"), rehash_body, done_rehash);

        core.LLVMPositionBuilderAtEnd(self.builder, rehash_body);
        const st = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 0), "st");
        const live = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, st, core.LLVMConstInt(self.i64Type(), 1, 0), "live");
        const move_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "move");
        self.buildCondBranch(live, move_bb, rehash_next);

        core.LLVMPositionBuilderAtEnd(self.builder, move_bb);
        const ins_fn = core.LLVMGetNamedFunction(self.module, "ko_map_insert") orelse unreachable;
        var mv_args: [3]types.LLVMValueRef = .{
            fresh,
            core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 1), "mk"),
            core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 2), "mv"),
        };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ins_fn), ins_fn, &mv_args, 3, "");
        self.buildBranch(rehash_next);

        core.LLVMPositionBuilderAtEnd(self.builder, rehash_next);
        const i_now = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_now");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i_now, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(rehash_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_rehash);
        // The entries moved wholesale, so the old table must be freed without
        // releasing them — clear its length so ko_decref_map walks nothing.
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), self.arrayHeaderPtr(ptr, -16, "old_len"));
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), self.arrayHeaderPtr(ptr, -8, "old_cap"));
        const decref_fn = core.LLVMGetNamedFunction(self.module, "ko_decref") orelse unreachable;
        var dec_args: [1]types.LLVMValueRef = .{ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(decref_fn), decref_fn, &dec_args, 1, "");
        _ = core.LLVMBuildStore(self.builder, fresh, handle_slot);
        self.buildBranch(insert_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, insert_bb);
        const final_handle = core.LLVMBuildLoad2(self.builder, self.i64Type(), handle_slot, "final_handle");
        const ins2_fn = core.LLVMGetNamedFunction(self.module, "ko_map_insert") orelse unreachable;
        var ins_args: [3]types.LLVMValueRef = .{ final_handle, key, value };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ins2_fn), ins2_fn, &ins_args, 3, "");
        self.buildRet(final_handle);
    }

    /// ko_map_get(map, key) -> i64, a Maybe in the constructor layout.
    fn codegenMapGet(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_get", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const hit_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "hit");
        const miss_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "miss");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const handle = core.LLVMGetParam(fn_val, 0);
        const find_fn = core.LLVMGetNamedFunction(self.module, "ko_map_find") orelse unreachable;
        var find_args: [2]types.LLVMValueRef = .{ handle, core.LLVMGetParam(fn_val, 1) };
        const idx = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(find_fn), find_fn, &find_args, 2, "idx");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSGE, idx, core.LLVMConstInt(self.i64Type(), 0, 0), "found"), hit_bb, miss_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, miss_bb);
        self.buildRet(core.LLVMConstInt(self.i64Type(), 1, 0)); // Nothing

        core.LLVMPositionBuilderAtEnd(self.builder, hit_bb);
        const ptr = core.LLVMBuildIntToPtr(self.builder, handle, self.ptrType(), "map");
        const value = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, idx, 2), "value");
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
        var alloc_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 1, 0) };
        const cell = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "cell");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), cell);
        var payload_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const payload = core.LLVMBuildGEP2(self.builder, self.i8Type(), cell, &payload_idx, 1, "payload");
        _ = core.LLVMBuildStore(self.builder, value, payload);
        // The Just borrows the map's reference. Bump it so dropping the Just
        // cannot free a value the map still holds.
        const flags = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapFlagsPtr(ptr), "flags");
        const vheap = core.LLVMBuildICmp(self.builder, .LLVMIntNE, core.LLVMBuildAnd(self.builder, flags, core.LLVMConstInt(self.i64Type(), 2, 0), "vbit"), core.LLVMConstInt(self.i64Type(), 0, 0), "vheap");
        const inc_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "inc_value");
        const ret_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ret");
        self.buildCondBranch(vheap, inc_bb, ret_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, inc_bb);
        const big = core.LLVMBuildICmp(self.builder, .LLVMIntUGT, value, core.LLVMConstInt(self.i64Type(), 4096, 0), "is_ptr");
        const do_inc = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "do_inc");
        self.buildCondBranch(big, do_inc, ret_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, do_inc);
        const incref_fn = core.LLVMGetNamedFunction(self.module, "ko_incref") orelse unreachable;
        var inc_args: [1]types.LLVMValueRef = .{core.LLVMBuildIntToPtr(self.builder, value, self.ptrType(), "vp")};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(incref_fn), incref_fn, &inc_args, 1, "");
        self.buildBranch(ret_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, ret_bb);
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, cell, self.i64Type(), "just"));
    }

    /// ko_map_contains(map, key) -> i64
    fn codegenMapContains(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_contains", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const find_fn = core.LLVMGetNamedFunction(self.module, "ko_map_find") orelse unreachable;
        var args: [2]types.LLVMValueRef = .{ core.LLVMGetParam(fn_val, 0), core.LLVMGetParam(fn_val, 1) };
        const idx = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(find_fn), find_fn, &args, 2, "idx");
        const found = core.LLVMBuildICmp(self.builder, .LLVMIntSGE, idx, core.LLVMConstInt(self.i64Type(), 0, 0), "found");
        self.buildRet(core.LLVMBuildZExt(self.builder, found, self.i64Type(), "out"));
    }

    /// ko_map_delete(map, key) -> i64 (unit)
    /// Leaves a tombstone so probe chains through the slot stay intact.
    fn codegenMapDelete(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_delete", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const hit_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "hit");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const handle = core.LLVMGetParam(fn_val, 0);
        const find_fn = core.LLVMGetNamedFunction(self.module, "ko_map_find") orelse unreachable;
        var find_args: [2]types.LLVMValueRef = .{ handle, core.LLVMGetParam(fn_val, 1) };
        const idx = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(find_fn), find_fn, &find_args, 2, "idx");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSGE, idx, core.LLVMConstInt(self.i64Type(), 0, 0), "found"), hit_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, hit_bb);
        const ptr = core.LLVMBuildIntToPtr(self.builder, handle, self.ptrType(), "map");
        self.emitMapReleaseSlot(fn_val, ptr, idx);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 2, 0), self.mapSlotPtr(ptr, idx, 0));
        const len = self.mapLoadLen(ptr);
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildSub(self.builder, len, core.LLVMConstInt(self.i64Type(), 1, 0), "len_next"), self.arrayHeaderPtr(ptr, -16, "len_ptr"));
        self.buildBranch(done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(core.LLVMConstInt(self.i64Type(), 0, 0));
    }

    /// Release the key and value of an occupied bucket, honouring the flags.
    /// Leaves the builder positioned in a fresh continuation block.
    fn emitMapReleaseSlot(self: *StdlibCodegen, fn_val: types.LLVMValueRef, ptr: types.LLVMValueRef, idx: types.LLVMValueRef) void {
        const flags = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapFlagsPtr(ptr), "flags");
        const decref_fn = core.LLVMGetNamedFunction(self.module, "ko_decref") orelse unreachable;

        inline for (.{ .{ 1, @as(u64, 1) }, .{ 2, @as(u64, 2) } }) |pair| {
            const word = pair[0];
            const bit = pair[1];
            const set = core.LLVMBuildICmp(
                self.builder,
                .LLVMIntNE,
                core.LLVMBuildAnd(self.builder, flags, core.LLVMConstInt(self.i64Type(), bit, 0), "bit"),
                core.LLVMConstInt(self.i64Type(), 0, 0),
                "is_heap",
            );
            const check_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rel_check");
            const skip_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rel_skip");
            self.buildCondBranch(set, check_bb, skip_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, check_bb);
            const v = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, idx, word), "rel_v");
            // Nullary constructors are bare tags, not pointers.
            const big = core.LLVMBuildICmp(self.builder, .LLVMIntUGT, v, core.LLVMConstInt(self.i64Type(), 4096, 0), "rel_is_ptr");
            const do_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rel_do");
            self.buildCondBranch(big, do_bb, skip_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, do_bb);
            var args: [1]types.LLVMValueRef = .{core.LLVMBuildIntToPtr(self.builder, v, self.ptrType(), "rel_p")};
            _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(decref_fn), decref_fn, &args, 1, "");
            self.buildBranch(skip_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, skip_bb);
        }
    }

    /// ko_map_length(map) -> i64
    fn codegenMapLength(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_map_length", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "map");
        self.buildRet(self.mapLoadLen(ptr));
    }

    /// ko_map_is_empty(map) -> i64 (0/1)
    fn codegenMapIsEmpty(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_map_is_empty", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "map");
        const empty = core.LLVMBuildICmp(self.builder, .LLVMIntSLE, self.mapLoadLen(ptr), core.LLVMConstInt(self.i64Type(), 0, 0), "empty");
        self.buildRet(core.LLVMBuildZExt(self.builder, empty, self.i64Type(), "out"));
    }

    /// ko_map_collect(map, which, elem_tag) -> i64
    /// An Array of the keys (which=0), values (which=1) or (k, v) tuples (2).
    fn codegenMapCollect(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_collect", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const live_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "live");
        const pair_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "pair");
        const plain_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "plain");
        const store_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "store");
        const next_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "next");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "map");
        const which = core.LLVMGetParam(fn_val, 1);
        const len = self.mapLoadLen(ptr);
        const cap = self.mapLoadCap(ptr);
        const out = self.emitArrayAllocPtr(len, len, core.LLVMGetParam(fn_val, 2));
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        const n_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "n");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), n_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, cap, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const st = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 0), "st");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntEQ, st, core.LLVMConstInt(self.i64Type(), 1, 0), "live"), live_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, live_bb);
        const k = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 1), "k");
        const v = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 2), "v");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntEQ, which, core.LLVMConstInt(self.i64Type(), 2, 0), "want_pair"), pair_bb, plain_bb);

        // A tuple in the layout lowerTuple emits: ko_alloc'd, type tag 2.
        core.LLVMPositionBuilderAtEnd(self.builder, pair_bb);
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse unreachable;
        var alloc_args: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 16, 0), core.LLVMConstInt(self.i64Type(), 2, 0) };
        const tup = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &alloc_args, 2, "tup");
        _ = core.LLVMBuildStore(self.builder, k, tup);
        var second_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const second = core.LLVMBuildGEP2(self.builder, self.i8Type(), tup, &second_idx, 1, "second");
        _ = core.LLVMBuildStore(self.builder, v, second);
        const tup_handle = core.LLVMBuildPtrToInt(self.builder, tup, self.i64Type(), "tup_handle");
        self.buildBranch(store_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, plain_bb);
        const plain = core.LLVMBuildSelect(self.builder, core.LLVMBuildICmp(self.builder, .LLVMIntEQ, which, core.LLVMConstInt(self.i64Type(), 0, 0), "want_key"), k, v, "plain");
        self.buildBranch(store_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, store_bb);
        const item = core.LLVMBuildPhi(self.builder, self.i64Type(), "item");
        var item_vals: [2]types.LLVMValueRef = .{ tup_handle, plain };
        var item_bbs: [2]types.LLVMBasicBlockRef = .{ pair_bb, plain_bb };
        core.LLVMAddIncoming(item, &item_vals, &item_bbs, 2);
        const n = core.LLVMBuildLoad2(self.builder, self.i64Type(), n_slot, "n_val");
        _ = core.LLVMBuildStore(self.builder, item, self.arrayElemPtr(out, n));
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, n, core.LLVMConstInt(self.i64Type(), 1, 0), "n_next"), n_slot);
        self.buildBranch(next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
        const i_now = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_now");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i_now, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(core.LLVMBuildPtrToInt(self.builder, out, self.i64Type(), "handle"));
    }

    /// ko_decref_map(ptr) — release every live key and value. ko_decref frees
    /// the table itself, as it does for arrays and closures.
    fn codegenDecrefMap(self: *StdlibCodegen) void {
        const fn_val = core.LLVMGetNamedFunction(self.module, "ko_decref_map").?;
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const next_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "next");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMGetParam(fn_val, 0);
        const cap = self.mapLoadCap(ptr);
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, cap, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const st = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 0), "st");
        const live = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, st, core.LLVMConstInt(self.i64Type(), 1, 0), "live");
        const rel_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "release");
        self.buildCondBranch(live, rel_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, rel_bb);
        const i_rel = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_rel");
        self.emitMapReleaseSlot(fn_val, ptr, i_rel);
        self.buildBranch(next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
        const i_now = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_now");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i_now, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRetVoid();
    }

    /// Bump the refcount of an entry's key and value, per the map's flags.
    /// A copied entry is referenced by both tables, so both must own it.
    fn emitMapRetainSlot(self: *StdlibCodegen, fn_val: types.LLVMValueRef, src: types.LLVMValueRef, idx: types.LLVMValueRef, flags: types.LLVMValueRef) void {
        const incref_fn = core.LLVMGetNamedFunction(self.module, "ko_incref") orelse unreachable;
        inline for (.{ .{ 1, @as(u64, 1) }, .{ 2, @as(u64, 2) } }) |pair| {
            const word = pair[0];
            const bit = pair[1];
            const set = core.LLVMBuildICmp(
                self.builder,
                .LLVMIntNE,
                core.LLVMBuildAnd(self.builder, flags, core.LLVMConstInt(self.i64Type(), bit, 0), "rbit"),
                core.LLVMConstInt(self.i64Type(), 0, 0),
                "r_is_heap",
            );
            const check_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ret_check");
            const skip_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ret_skip");
            self.buildCondBranch(set, check_bb, skip_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, check_bb);
            const v = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(src, idx, word), "ret_v");
            const big = core.LLVMBuildICmp(self.builder, .LLVMIntUGT, v, core.LLVMConstInt(self.i64Type(), 4096, 0), "ret_is_ptr");
            const do_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ret_do");
            self.buildCondBranch(big, do_bb, skip_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, do_bb);
            var args: [1]types.LLVMValueRef = .{core.LLVMBuildIntToPtr(self.builder, v, self.ptrType(), "ret_p")};
            _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(incref_fn), incref_fn, &args, 1, "");
            self.buildBranch(skip_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, skip_bb);
        }
    }

    /// ko_map_merge(a, b, mode) -> i64
    /// mode 0 = union (b wins on conflict), 1 = intersection, 2 = difference.
    ///
    /// The destination is sized for the worst case up front so no insertion can
    /// trigger a resize, which keeps the handle stable through the loops.
    fn codegenMapMerge(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_merge", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ha = core.LLVMGetParam(fn_val, 0);
        const hb = core.LLVMGetParam(fn_val, 1);
        const mode = core.LLVMGetParam(fn_val, 2);
        const pa = core.LLVMBuildIntToPtr(self.builder, ha, self.ptrType(), "pa");
        const pb = core.LLVMBuildIntToPtr(self.builder, hb, self.ptrType(), "pb");
        const flags = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapFlagsPtr(pa), "flags");
        const want = core.LLVMBuildMul(
            self.builder,
            core.LLVMBuildAdd(self.builder, self.mapLoadLen(pa), self.mapLoadLen(pb), "total"),
            core.LLVMConstInt(self.i64Type(), 4, 0),
            "want",
        );
        const new_fn = core.LLVMGetNamedFunction(self.module, "ko_map_new") orelse unreachable;
        var new_args: [3]types.LLVMValueRef = .{ want, self.mapLoadKeyTag(pa), flags };
        const dst = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(new_fn), new_fn, &new_args, 3, "dst");

        const contains_fn = core.LLVMGetNamedFunction(self.module, "ko_map_contains") orelse unreachable;
        const insert_fn = core.LLVMGetNamedFunction(self.module, "ko_map_insert") orelse unreachable;

        // Pass 1 over `a`: which entries survive depends on the mode.
        {
            const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "a_loop");
            const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "a_body");
            const keep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "a_keep");
            const next_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "a_next");
            const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "a_done");
            const cap = self.mapLoadCap(pa);
            const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "ai");
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
            self.buildBranch(loop_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
            const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "ai_val");
            self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, cap, "a_more"), body_bb, done_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
            const st = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(pa, i, 0), "a_st");
            const live = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, st, core.LLVMConstInt(self.i64Type(), 1, 0), "a_live");
            const test_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "a_test");
            self.buildCondBranch(live, test_bb, next_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, test_bb);
            const k = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(pa, i, 1), "a_k");
            var c_args: [2]types.LLVMValueRef = .{ hb, k };
            const in_b = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(contains_fn), contains_fn, &c_args, 2, "in_b");
            const in_b_bool = core.LLVMBuildICmp(self.builder, .LLVMIntNE, in_b, core.LLVMConstInt(self.i64Type(), 0, 0), "in_b_bool");
            const is_inter = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, mode, core.LLVMConstInt(self.i64Type(), 1, 0), "is_inter");
            const is_diff = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, mode, core.LLVMConstInt(self.i64Type(), 2, 0), "is_diff");
            // union keeps everything; intersection keeps keys also in b;
            // difference keeps keys absent from b.
            const keep_inter = core.LLVMBuildSelect(self.builder, is_inter, in_b_bool, core.LLVMConstInt(core.LLVMInt1TypeInContext(self.context), 1, 0), "keep_inter");
            const keep = core.LLVMBuildSelect(self.builder, is_diff, core.LLVMBuildNot(self.builder, in_b_bool, "not_in_b"), keep_inter, "keep");
            self.buildCondBranch(keep, keep_bb, next_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, keep_bb);
            const ik = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "a_ik");
            self.emitMapRetainSlot(fn_val, pa, ik, flags);
            const ik2 = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "a_ik2");
            var ins_args: [3]types.LLVMValueRef = .{
                dst,
                core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(pa, ik2, 1), "kk"),
                core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(pa, ik2, 2), "vv"),
            };
            _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(insert_fn), insert_fn, &ins_args, 3, "");
            self.buildBranch(next_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
            const ni = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "a_ni");
            _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, ni, core.LLVMConstInt(self.i64Type(), 1, 0), "a_next_i"), i_slot);
            self.buildBranch(loop_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        }

        // Pass 2 over `b`, for union only.
        {
            const skip_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "b_skip");
            const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "b_loop");
            const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "b_body");
            const keep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "b_keep");
            const next_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "b_next");
            // Everything the loop needs must be emitted before the branch that
            // terminates this block; anything after it lands past a terminator.
            const cap = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayHeaderPtr(pb, -8, "bcap_ptr"), "bcap");
            const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "bi");
            const is_union = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, mode, core.LLVMConstInt(self.i64Type(), 0, 0), "is_union");
            self.buildCondBranch(is_union, loop_bb, skip_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
            const walk_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "b_walk");
            self.buildBranch(walk_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, walk_bb);
            const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "bi_val");
            self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, cap, "b_more"), body_bb, skip_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
            const st = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(pb, i, 0), "b_st");
            self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntEQ, st, core.LLVMConstInt(self.i64Type(), 1, 0), "b_live"), keep_bb, next_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, keep_bb);
            const ik = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "b_ik");
            self.emitMapRetainSlot(fn_val, pb, ik, flags);
            const ik2 = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "b_ik2");
            var ins_args: [3]types.LLVMValueRef = .{
                dst,
                core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(pb, ik2, 1), "bk"),
                core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(pb, ik2, 2), "bv"),
            };
            _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(insert_fn), insert_fn, &ins_args, 3, "");
            self.buildBranch(next_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
            const ni = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "b_ni");
            _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, ni, core.LLVMConstInt(self.i64Type(), 1, 0), "b_next_i"), i_slot);
            self.buildBranch(walk_bb);

            core.LLVMPositionBuilderAtEnd(self.builder, skip_bb);
        }

        self.buildRet(dst);
    }

    /// ko_map_from_array(arr, key_tag, flags) -> i64
    /// Builds a map from an Array of (k, v) tuples. Later duplicates win.
    fn codegenMapFromArray(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_from_array", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const arr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 0), self.ptrType(), "arr");
        const flags = core.LLVMGetParam(fn_val, 2);
        const len = self.arrayLoadLen(arr);
        const new_fn = core.LLVMGetNamedFunction(self.module, "ko_map_new") orelse unreachable;
        // Sized for every entry up front, so no insert can trigger a resize.
        var new_args: [3]types.LLVMValueRef = .{
            core.LLVMBuildMul(self.builder, len, core.LLVMConstInt(self.i64Type(), 4, 0), "want"),
            core.LLVMGetParam(fn_val, 1),
            flags,
        };
        const dst = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(new_fn), new_fn, &new_args, 3, "dst");
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, len, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const pair = core.LLVMBuildIntToPtr(
            self.builder,
            core.LLVMBuildLoad2(self.builder, self.i64Type(), self.arrayElemPtr(arr, i), "pair_h"),
            self.ptrType(),
            "pair",
        );
        const k = core.LLVMBuildLoad2(self.builder, self.i64Type(), pair, "k");
        var second_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const second = core.LLVMBuildGEP2(self.builder, self.i8Type(), pair, &second_idx, 1, "second");
        const v = core.LLVMBuildLoad2(self.builder, self.i64Type(), second, "v");
        // The map takes its own reference; the tuple keeps holding one too.
        const incref_fn = core.LLVMGetNamedFunction(self.module, "ko_incref") orelse unreachable;
        inline for (.{ .{ 0, @as(u64, 1) }, .{ 1, @as(u64, 2) } }) |pr| {
            const val = if (pr[0] == 0) k else v;
            const set = core.LLVMBuildICmp(
                self.builder,
                .LLVMIntNE,
                core.LLVMBuildAnd(self.builder, flags, core.LLVMConstInt(self.i64Type(), pr[1], 0), "fbit"),
                core.LLVMConstInt(self.i64Type(), 0, 0),
                "f_is_heap",
            );
            const chk = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "fa_chk");
            const skip = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "fa_skip");
            self.buildCondBranch(set, chk, skip);
            core.LLVMPositionBuilderAtEnd(self.builder, chk);
            const big = core.LLVMBuildICmp(self.builder, .LLVMIntUGT, val, core.LLVMConstInt(self.i64Type(), 4096, 0), "fa_ptr");
            const doit = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "fa_do");
            self.buildCondBranch(big, doit, skip);
            core.LLVMPositionBuilderAtEnd(self.builder, doit);
            var ia: [1]types.LLVMValueRef = .{core.LLVMBuildIntToPtr(self.builder, val, self.ptrType(), "fa_p")};
            _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(incref_fn), incref_fn, &ia, 1, "");
            self.buildBranch(skip);
            core.LLVMPositionBuilderAtEnd(self.builder, skip);
        }
        const insert_fn = core.LLVMGetNamedFunction(self.module, "ko_map_insert") orelse unreachable;
        var ins_args: [3]types.LLVMValueRef = .{ dst, k, v };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(insert_fn), insert_fn, &ins_args, 3, "");
        const i_now = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_now");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i_now, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(dst);
    }

    /// ko_map_foldl(f, init, map) -> i64, with `f` curried as `f acc k v`.
    fn codegenMapFoldl(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_map_foldl", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const loop_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const body_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "body");
        const live_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "live");
        const next_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "next");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const f = core.LLVMGetParam(fn_val, 0);
        const ptr = core.LLVMBuildIntToPtr(self.builder, core.LLVMGetParam(fn_val, 2), self.ptrType(), "map");
        const cap = self.mapLoadCap(ptr);
        const acc_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "acc");
        const i_slot = core.LLVMBuildAlloca(self.builder, self.i64Type(), "i");
        _ = core.LLVMBuildStore(self.builder, core.LLVMGetParam(fn_val, 1), acc_slot);
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_val");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntSLT, i, cap, "more"), body_bb, done_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const st = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 0), "st");
        self.buildCondBranch(core.LLVMBuildICmp(self.builder, .LLVMIntEQ, st, core.LLVMConstInt(self.i64Type(), 1, 0), "live"), live_bb, next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, live_bb);
        const k = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 1), "k");
        const v = core.LLVMBuildLoad2(self.builder, self.i64Type(), self.mapSlotPtr(ptr, i, 2), "v");
        const acc = core.LLVMBuildLoad2(self.builder, self.i64Type(), acc_slot, "acc_val");
        // Three applications, each intermediate re-tagged as a closure.
        const p1 = self.emitClosureCall1(fn_val, f, acc, "p1");
        const p1t = core.LLVMBuildOr(self.builder, p1, core.LLVMConstInt(self.i64Type(), 1, 0), "p1t");
        const p2 = self.emitClosureCall1(fn_val, p1t, k, "p2");
        const p2t = core.LLVMBuildOr(self.builder, p2, core.LLVMConstInt(self.i64Type(), 1, 0), "p2t");
        const stepped = self.emitClosureCall1(fn_val, p2t, v, "stepped");
        _ = core.LLVMBuildStore(self.builder, stepped, acc_slot);
        self.buildBranch(next_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, next_bb);
        const i_now = core.LLVMBuildLoad2(self.builder, self.i64Type(), i_slot, "i_now");
        _ = core.LLVMBuildStore(self.builder, core.LLVMBuildAdd(self.builder, i_now, core.LLVMConstInt(self.i64Type(), 1, 0), "i_next"), i_slot);
        self.buildBranch(loop_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRet(core.LLVMBuildLoad2(self.builder, self.i64Type(), acc_slot, "result"));
    }

    pub fn codegenMapOps(self: *StdlibCodegen) void {
        self.codegenHash();
        self.codegenKeyEq();
        self.codegenMapNew();
        self.codegenMapFind();
        self.codegenMapInsert();
        self.codegenMapSet();
        self.codegenMapGet();
        self.codegenMapContains();
        self.codegenMapDelete();
        self.codegenMapLength();
        self.codegenMapIsEmpty();
        self.codegenMapCollect();
        self.codegenMapMerge();
        self.codegenMapFromArray();
        self.codegenMapFoldl();
        self.codegenDecrefMap();
    }

    // ============================================================
    // RC functions
    // ============================================================

    pub fn codegenKoAlloc(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_alloc", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const user_size = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(user_size, "user_size");
        const type_tag = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(type_tag, "type_tag");

        // total = user_size + 32 (8 for rc + 8 for type_tag + 8 for arity + 8 for field_bitmap)
        const total = core.LLVMBuildAdd(self.builder, user_size, core.LLVMConstInt(self.i64Type(), 32, 0), "total");

        // raw = malloc(total)
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{total};
        const raw = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "raw");

        // Store RC = 1 at offset 0
        const rc_ptr = core.LLVMBuildBitCast(self.builder, raw, self.ptrType(), "rc_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 1, 0), rc_ptr);

        // Store type_tag at offset 8
        const tag_ptr_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), raw, @constCast(&tag_ptr_idx), 1, "tag_ptr");
        const tag_ptr_typed = core.LLVMBuildBitCast(self.builder, tag_ptr, self.ptrType(), "tag_ptr_typed");
        _ = core.LLVMBuildStore(self.builder, type_tag, tag_ptr_typed);

        // Initialize arity (offset 16) and field_bitmap (offset 24) to 0
        // These are set by the caller after allocation (constructor/tuple/record codegen)
        var arity_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 16, 0)};
        const arity_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), raw, @constCast(&arity_idx), 1, "arity_ptr");
        const arity_ptr_typed = core.LLVMBuildBitCast(self.builder, arity_ptr, self.ptrType(), "arity_ptr_typed");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), arity_ptr_typed);

        var bitmap_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 24, 0)};
        const bitmap_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), raw, @constCast(&bitmap_idx), 1, "bitmap_ptr");
        const bitmap_ptr_typed = core.LLVMBuildBitCast(self.builder, bitmap_ptr, self.ptrType(), "bitmap_ptr_typed");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), bitmap_ptr_typed);

        // Return raw + 32 (skip rc, type_tag, arity, field_bitmap headers)
        var user_ptr_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 32, 0)};
        const user_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), raw, @ptrCast(&user_ptr_idx), 1, "user_ptr");
        self.buildRet(user_ptr);
    }

    pub fn codegenKoIncref(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_incref", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const compute_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "compute");
        const null_return = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "null_return");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(ptr, "ptr");

        // if ptr == null, return null
        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, ptr, core.LLVMConstNull(self.ptrType()), "is_null");
        self.buildCondBranch(is_null, null_return, compute_block);

        core.LLVMPositionBuilderAtEnd(self.builder, null_return);
        self.buildRet(core.LLVMConstNull(self.ptrType()));

        core.LLVMPositionBuilderAtEnd(self.builder, compute_block);
        // rc_ptr = ptr - 32 (rc is 32 bytes before user data: 8 rc + 8 type_tag + 8 arity + 8 bitmap)
        var rc_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -32)), 0)};
        const rc_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&rc_idx), 1, "rc_ptr");
        const rc_ptr_typed = core.LLVMBuildBitCast(self.builder, rc_ptr, self.ptrType(), "rc_ptr_typed");

        // Load RC, increment, store
        const rc_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), rc_ptr_typed, "rc_val");
        const new_rc = core.LLVMBuildAdd(self.builder, rc_val, core.LLVMConstInt(self.i64Type(), 1, 0), "new_rc");
        _ = core.LLVMBuildStore(self.builder, new_rc, rc_ptr_typed);

        // Return ptr
        self.buildRet(ptr);
    }

    pub fn codegenKoDecref(self: *StdlibCodegen) void {
        const fn_val = core.LLVMGetNamedFunction(self.module, "ko_decref").?;
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const check_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check");
        const free_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "free_block");
        const done_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(ptr, "ptr");

        // if ptr == null, return
        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, ptr, core.LLVMConstNull(self.ptrType()), "is_null");
        self.buildCondBranch(is_null, done_block, check_block);

        // rc_ptr = ptr - 32 (rc is 32 bytes before user data: 8 rc + 8 type_tag + 8 arity + 8 bitmap)
        core.LLVMPositionBuilderAtEnd(self.builder, check_block);
        var rc_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -32)), 0)};
        const rc_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&rc_idx), 1, "rc_ptr");
        const rc_ptr_typed = core.LLVMBuildBitCast(self.builder, rc_ptr, self.ptrType(), "rc_ptr_typed");

        // Load RC, decrement
        const rc_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), rc_ptr_typed, "rc_val");
        const new_rc = core.LLVMBuildSub(self.builder, rc_val, core.LLVMConstInt(self.i64Type(), 1, 0), "new_rc");
        _ = core.LLVMBuildStore(self.builder, new_rc, rc_ptr_typed);

        // if new_rc <= 0, free
        const should_free = core.LLVMBuildICmp(self.builder, .LLVMIntSLE, new_rc, core.LLVMConstInt(self.i64Type(), 0, 0), "should_free");
        self.buildCondBranch(should_free, free_block, done_block);

        // free(ptr - 32)
        core.LLVMPositionBuilderAtEnd(self.builder, free_block);
        
        // Read type_tag from ptr - 24 before freeing (type_tag is 24 bytes before user data)
        var tag_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -24)), 0)};
        const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&tag_idx), 1, "tag_ptr");
        const tag_ptr_typed = core.LLVMBuildBitCast(self.builder, tag_ptr, self.ptrType(), "tag_ptr_typed");
        const type_tag = core.LLVMBuildLoad2(self.builder, self.i64Type(), tag_ptr_typed, "type_tag");
        
        // Read arity from ptr - 16
        var arity_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -16)), 0)};
        const arity_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&arity_idx), 1, "arity_ptr");
        const arity_ptr_typed = core.LLVMBuildBitCast(self.builder, arity_ptr, self.ptrType(), "arity_ptr_typed");
        const arity = core.LLVMBuildLoad2(self.builder, self.i64Type(), arity_ptr_typed, "arity");
        
        // Read field_bitmap from ptr - 8
        var bitmap_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -8)), 0)};
        const bitmap_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&bitmap_idx), 1, "bitmap_ptr");
        const bitmap_ptr_typed = core.LLVMBuildBitCast(self.builder, bitmap_ptr, self.ptrType(), "bitmap_ptr_typed");
        const field_bitmap = core.LLVMBuildLoad2(self.builder, self.i64Type(), bitmap_ptr_typed, "field_bitmap");
        
        // Check if type_tag == 10 (closure) — different layout from normal values
        const is_closure = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 10, 0), "is_closure");
        const closure_walk_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "closure_walk");
        const array_check_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "array_check");
        const array_walk_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "array_walk");
        const decref_value_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "decref_value");

        // Hoist free_fn before the branch so both paths can use it
        const free_fn = core.LLVMGetNamedFunction(self.module, "free");

        self.buildCondBranch(is_closure, closure_walk_bb, array_check_bb);

        // Arrays keep their element count in the header's length slot, not the
        // arity slot, and have no field bitmap — the element kind is the tag
        // itself. Tag 11 (scalar elements) needs no walk at all; tag 12 does.
        core.LLVMPositionBuilderAtEnd(self.builder, array_check_bb);
        const is_heap_array = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), @intCast(array_tag_heap), 0), "is_heap_array");
        const is_scalar_array = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), @intCast(array_tag_scalar), 0), "is_scalar_array");
        const array_free_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "array_free");
        const not_heap_array_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "not_heap_array");
        self.buildCondBranch(is_heap_array, array_walk_bb, not_heap_array_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, not_heap_array_bb);
        const map_check_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "map_check");
        self.buildCondBranch(is_scalar_array, array_free_bb, map_check_bb);

        // Maps keep their bucket count in the capacity slot and have no field
        // bitmap either, so they get their own walk.
        core.LLVMPositionBuilderAtEnd(self.builder, map_check_bb);
        const is_map = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), @intCast(map_type_tag), 0), "is_map");
        const map_walk_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "map_walk");
        self.buildCondBranch(is_map, map_walk_bb, decref_value_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, map_walk_bb);
        const decref_map_fn = core.LLVMGetNamedFunction(self.module, "ko_decref_map") orelse unreachable;
        var dm_args: [1]types.LLVMValueRef = .{ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(decref_map_fn), decref_map_fn, &dm_args, 1, "");
        self.buildBranch(array_free_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, array_walk_bb);
        const decref_array_fn = core.LLVMGetNamedFunction(self.module, "ko_decref_array") orelse unreachable;
        var da_args: [1]types.LLVMValueRef = .{ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(decref_array_fn), decref_array_fn, &da_args, 1, "");
        self.buildBranch(array_free_bb);

        core.LLVMPositionBuilderAtEnd(self.builder, array_free_bb);
        var free_args_array: [1]types.LLVMValueRef = .{rc_ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(free_fn), free_fn, &free_args_array, 1, "");
        self.buildBranch(done_block);

        // In closure_walk_bb: call ko_decref_closure(ptr) to walk captured values, then free
        core.LLVMPositionBuilderAtEnd(self.builder, closure_walk_bb);
        const decref_closure_fn = core.LLVMGetNamedFunction(self.module, "ko_decref_closure");
        var dc_args: [1]types.LLVMValueRef = .{ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(decref_closure_fn), decref_closure_fn, &dc_args, 1, "");
        // Skip ko_decref_value (closure has custom layout), go straight to free
        var free_args_closure: [1]types.LLVMValueRef = .{rc_ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(free_fn), free_fn, &free_args_closure, 1, "");
        self.buildBranch(done_block);
        
        // In decref_value_bb: normal path — call ko_decref_value then free
        core.LLVMPositionBuilderAtEnd(self.builder, decref_value_bb);
        
        // Call ko_decref_value(ptr, type_tag, arity, field_bitmap) to recursively decrement fields
        const decref_value_fn = core.LLVMGetNamedFunction(self.module, "ko_decref_value");
        var decref_args: [4]types.LLVMValueRef = .{ ptr, type_tag, arity, field_bitmap };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(decref_value_fn), decref_value_fn, &decref_args, 4, "");
        
        // free(ptr - 32)
        var free_args: [1]types.LLVMValueRef = .{rc_ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(free_fn), free_fn, &free_args, 1, "");
        self.buildBranch(done_block);

        core.LLVMPositionBuilderAtEnd(self.builder, done_block);
        self.buildRetVoid();
    }

    /// ko_decref_closure(ptr) - Walk captured values in a closure and decref each heap-allocated one.
    /// Does NOT free the closure struct itself — caller (ko_decref) handles that.
    /// Unified closure layout: [ fn_ptr(8) | count(8) | kind(8) | data... | type_tags... ]
    ///   kind=0 (lambda):   count=num_captures, data=captured values, type_tags after data
    ///   kind=1 (partial):  count=total_arity, data=applied_count(8)+applied_args, type_tags after applied_args
    pub fn codegenKoDecrefClosure(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_decref_closure", self.voidType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const check_count = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_count");
        const read_kind = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "read_kind");
        const kind_lambda = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "kind_lambda");
        const kind_partial = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "kind_partial");
        const loop_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_check");
        const loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const loop_next = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_next");
        const loop_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_done");
        const done_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(ptr, "ptr");

        // if ptr == null, return
        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, ptr, core.LLVMConstNull(self.ptrType()), "is_null");
        self.buildCondBranch(is_null, done_block, check_count);

        // Read count from offset 8 (num_captures for lambda, total_arity for partial app)
        core.LLVMPositionBuilderAtEnd(self.builder, check_count);
        var count_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const count_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&count_idx), 1, "count_ptr");
        const count_ptr_typed = core.LLVMBuildBitCast(self.builder, count_ptr, self.ptrType(), "count_ptr_typed");
        const count_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), count_ptr_typed, "count_val");

        // If count == 0, no captures → skip loop
        const is_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, count_val, core.LLVMConstInt(self.i64Type(), 0, 0), "is_zero");
        self.buildCondBranch(is_zero, loop_done, read_kind);

        // Read kind from offset 16 (0=lambda, 1=partial app)
        core.LLVMPositionBuilderAtEnd(self.builder, read_kind);
        var kind_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 16, 0)};
        const kind_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&kind_idx), 1, "kind_ptr");
        const kind_ptr_typed = core.LLVMBuildBitCast(self.builder, kind_ptr, self.ptrType(), "kind_ptr_typed");
        const kind_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), kind_ptr_typed, "kind_val");

        // Branch on kind
        const is_lambda = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, kind_val, core.LLVMConstInt(self.i64Type(), 0, 0), "is_lambda");
        self.buildCondBranch(is_lambda, kind_lambda, kind_partial);

        // Lambda path: compute data_base and tag_base as regular values (not phi)
        core.LLVMPositionBuilderAtEnd(self.builder, kind_lambda);
        const lambda_data_base = core.LLVMConstInt(self.i64Type(), 24, 0);
        const lambda_tag_base = core.LLVMBuildAdd(self.builder, core.LLVMConstInt(self.i64Type(), 24, 0),
            core.LLVMBuildMul(self.builder, count_val, core.LLVMConstInt(self.i64Type(), 8, 0), "mul1"), "lambda_tag_base");
        // Lambda: idx starts at 0
        const lambda_init_idx = core.LLVMConstInt(self.i64Type(), 0, 0);
        self.buildBranch(loop_check);

        // Partial app path: read applied_count from offset 24, data_base=32, tag_base=32+applied_count*8
        core.LLVMPositionBuilderAtEnd(self.builder, kind_partial);
        var pcount_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 24, 0)};
        const pcount_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&pcount_idx), 1, "pcount_ptr");
        const pcount_ptr_typed = core.LLVMBuildBitCast(self.builder, pcount_ptr, self.ptrType(), "pcount_ptr_typed");
        const partial_applied = core.LLVMBuildLoad2(self.builder, self.i64Type(), pcount_ptr_typed, "partial_applied");
        const partial_data_base = core.LLVMConstInt(self.i64Type(), 32, 0);
        const partial_tag_base = core.LLVMBuildAdd(self.builder, core.LLVMConstInt(self.i64Type(), 32, 0),
            core.LLVMBuildMul(self.builder, partial_applied, core.LLVMConstInt(self.i64Type(), 8, 0), "mul2"), "partial_tag_base");
        // Partial: idx starts at 0
        const partial_init_idx = core.LLVMConstInt(self.i64Type(), 0, 0);
        self.buildBranch(loop_check);

        // Loop check: merge data_base, tag_base, and idx from both paths via phi
        core.LLVMPositionBuilderAtEnd(self.builder, loop_check);
        const phi_data_base = core.LLVMBuildPhi(self.builder, self.i64Type(), "data_base");
        const phi_tag_base = core.LLVMBuildPhi(self.builder, self.i64Type(), "tag_base");
        const phi_idx = core.LLVMBuildPhi(self.builder, self.i64Type(), "idx");
        {
            var incoming_vals: [2]types.LLVMValueRef = .{ lambda_data_base, partial_data_base };
            var incoming_bbs: [2]types.LLVMBasicBlockRef = .{ kind_lambda, kind_partial };
            core.LLVMAddIncoming(phi_data_base, @ptrCast(&incoming_vals), @ptrCast(&incoming_bbs), 2);
        }
        {
            var incoming_vals: [2]types.LLVMValueRef = .{ lambda_tag_base, partial_tag_base };
            var incoming_bbs: [2]types.LLVMBasicBlockRef = .{ kind_lambda, kind_partial };
            core.LLVMAddIncoming(phi_tag_base, @ptrCast(&incoming_vals), @ptrCast(&incoming_bbs), 2);
        }
        {
            var incoming_vals: [2]types.LLVMValueRef = .{ lambda_init_idx, partial_init_idx };
            var incoming_bbs: [2]types.LLVMBasicBlockRef = .{ kind_lambda, kind_partial };
            core.LLVMAddIncoming(phi_idx, @ptrCast(&incoming_vals), @ptrCast(&incoming_bbs), 2);
        }

        // Check if idx < count
        const should_continue = core.LLVMBuildICmp(self.builder, .LLVMIntULT, phi_idx, count_val, "should_continue");
        self.buildCondBranch(should_continue, loop_body, loop_done);

        // Loop body: read type tag from tag_base + idx*8
        core.LLVMPositionBuilderAtEnd(self.builder, loop_body);
        const tag_offset = core.LLVMBuildAdd(self.builder, phi_tag_base,
            core.LLVMBuildMul(self.builder, phi_idx, core.LLVMConstInt(self.i64Type(), 8, 0), "mul3"), "tag_offset");

        var tag_gep_idx: [1]types.LLVMValueRef = .{tag_offset};
        const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&tag_gep_idx), 1, "tag_ptr");
        const tag_ptr_typed = core.LLVMBuildBitCast(self.builder, tag_ptr, self.ptrType(), "tag_ptr_typed");
        const type_tag = core.LLVMBuildLoad2(self.builder, self.i64Type(), tag_ptr_typed, "type_tag");

        // Check if type_tag == -1 (skip) or 0 (raw/ref with no fields) → skip decref
        const is_skip = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -1)), 0), "is_skip");
        const is_raw = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 0, 0), "is_raw");
        const should_skip = core.LLVMBuildOr(self.builder, is_skip, is_raw, "should_skip");

        // If type_tag is 1 (constructor), 2 (tuple), or 3 (record) → call ko_decref_value
        const is_ctor = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 1, 0), "is_ctor");
        const is_tuple = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 2, 0), "is_tuple");
        const is_record = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 3, 0), "is_record");
        const is_heap = core.LLVMBuildOr(self.builder,
            core.LLVMBuildOr(self.builder, is_ctor, is_tuple, "or1"),
            is_record, "is_heap");
        const should_decref = core.LLVMBuildAnd(self.builder, is_heap,
            core.LLVMBuildNot(self.builder, should_skip, "not_skip"), "should_decref");

        const decref_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "decref_val");
        self.buildCondBranch(should_decref, decref_bb, loop_next);

        core.LLVMPositionBuilderAtEnd(self.builder, decref_bb);
        // Read value from data_base + idx*8
        const cap_offset = core.LLVMBuildAdd(self.builder, phi_data_base,
            core.LLVMBuildMul(self.builder, phi_idx, core.LLVMConstInt(self.i64Type(), 8, 0), "mul4"), "cap_offset");
        var cap_gep_idx: [1]types.LLVMValueRef = .{cap_offset};
        const cap_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&cap_gep_idx), 1, "cap_ptr");
        const cap_ptr_typed = core.LLVMBuildBitCast(self.builder, cap_ptr, self.ptrType(), "cap_ptr_typed");
        const cap_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), cap_ptr_typed, "cap_val");

        const cap_ptr_val = core.LLVMBuildIntToPtr(self.builder, cap_val, self.ptrType(), "cap_ptr_val");
        // Read arity from cap_ptr_val - 16 (captured value's own header)
        var cap_arity_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -16)), 0)};
        const cap_arity_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), cap_ptr_val, @ptrCast(&cap_arity_idx), 1, "cap_arity_ptr");
        const cap_arity_ptr_typed = core.LLVMBuildBitCast(self.builder, cap_arity_ptr, self.ptrType(), "cap_arity_ptr_typed");
        const cap_arity = core.LLVMBuildLoad2(self.builder, self.i64Type(), cap_arity_ptr_typed, "cap_arity");
        // Read field_bitmap from cap_ptr_val - 8
        var cap_bmp_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -8)), 0)};
        const cap_bmp_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), cap_ptr_val, @ptrCast(&cap_bmp_idx), 1, "cap_bmp_ptr");
        const cap_bmp_ptr_typed = core.LLVMBuildBitCast(self.builder, cap_bmp_ptr, self.ptrType(), "cap_bmp_ptr_typed");
        const cap_bitmap = core.LLVMBuildLoad2(self.builder, self.i64Type(), cap_bmp_ptr_typed, "cap_bitmap");
        var decref_args: [4]types.LLVMValueRef = .{ cap_ptr_val, type_tag, cap_arity, cap_bitmap };
        const decref_value_fn = core.LLVMGetNamedFunction(self.module, "ko_decref_value");
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(decref_value_fn), decref_value_fn, &decref_args, 4, "");
        self.buildBranch(loop_next);

        // Loop increment
        core.LLVMPositionBuilderAtEnd(self.builder, loop_next);
        const next_idx = core.LLVMBuildAdd(self.builder, phi_idx, core.LLVMConstInt(self.i64Type(), 1, 0), "next_idx");
        {
            var next_incoming: [1]types.LLVMValueRef = .{next_idx};
            var next_blocks: [1]types.LLVMBasicBlockRef = .{loop_next};
            core.LLVMAddIncoming(phi_idx, &next_incoming, &next_blocks, 1);
        }
        // data_base and tag_base don't change in the loop — add incoming from loop_next with their own values
        {
            var next_incoming: [1]types.LLVMValueRef = .{phi_data_base};
            var next_blocks: [1]types.LLVMBasicBlockRef = .{loop_next};
            core.LLVMAddIncoming(phi_data_base, &next_incoming, &next_blocks, 1);
        }
        {
            var next_incoming: [1]types.LLVMValueRef = .{phi_tag_base};
            var next_blocks: [1]types.LLVMBasicBlockRef = .{loop_next};
            core.LLVMAddIncoming(phi_tag_base, &next_incoming, &next_blocks, 1);
        }
        self.buildBranch(loop_check);

        // Loop done: just return (caller handles freeing the closure struct)
        core.LLVMPositionBuilderAtEnd(self.builder, loop_done);
        self.buildBranch(done_block);

        core.LLVMPositionBuilderAtEnd(self.builder, done_block);
        self.buildRetVoid();
    }

    /// ko_decref_value(ptr, type_tag, arity, field_bitmap) - Recursively decrement fields.
    /// type_tag: 0=raw/ref, 1=constructor, 2=tuple, 3=record
    /// arity: number of fields/elements (passed by caller, read from header)
    /// field_bitmap: bitmask of which fields are pointers (1=pointer, 0=scalar)
    pub fn codegenKoDecrefValue(self: *StdlibCodegen) void {
        var params: [4]types.LLVMTypeRef = .{ self.ptrType(), self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("ko_decref_value", self.voidType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const check_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check");
        const check_block2 = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_block2");
        const check_block3 = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_block3");
        const constructor_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "constructor");
        const tuple_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tuple");
        const record_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "record");
        const loop_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_body");
        const loop_decref = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_decref");
        const loop_next = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_next");
        const loop_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop_done");
        const done_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(ptr, "ptr");
        const type_tag = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(type_tag, "type_tag");
        const arity_param = core.LLVMGetParam(fn_val, 2);
        core.LLVMSetValueName(arity_param, "arity");
        const field_bitmap = core.LLVMGetParam(fn_val, 3);
        core.LLVMSetValueName(field_bitmap, "field_bitmap");

        // if ptr == null, return
        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, ptr, core.LLVMConstNull(self.ptrType()), "is_null");
        self.buildCondBranch(is_null, done_block, check_block);

        // Check type_tag
        core.LLVMPositionBuilderAtEnd(self.builder, check_block);
        const is_constructor = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 1, 0), "is_constructor");
        self.buildCondBranch(is_constructor, constructor_block, check_block2);

        core.LLVMPositionBuilderAtEnd(self.builder, check_block2);
        const is_tuple = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 2, 0), "is_tuple");
        self.buildCondBranch(is_tuple, tuple_block, check_block3);

        core.LLVMPositionBuilderAtEnd(self.builder, check_block3);
        const is_record = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 3, 0), "is_record");
        self.buildCondBranch(is_record, record_block, done_block);

        // Constructor: tag at index 0, args at indices 1..arity
        core.LLVMPositionBuilderAtEnd(self.builder, constructor_block);
        self.buildBranch(loop_block);

        // Tuple: length at index 0, elements at indices 1..arity
        core.LLVMPositionBuilderAtEnd(self.builder, tuple_block);
        self.buildBranch(loop_block);

        // Record: fields at indices 0..arity-1
        core.LLVMPositionBuilderAtEnd(self.builder, record_block);
        self.buildBranch(loop_block);

        // Loop header: phi nodes for idx, count, and start_idx
        core.LLVMPositionBuilderAtEnd(self.builder, loop_block);
        const phi_idx = core.LLVMBuildPhi(self.builder, self.i64Type(), "idx");
        const phi_count = core.LLVMBuildPhi(self.builder, self.i64Type(), "count");
        const phi_start_idx = core.LLVMBuildPhi(self.builder, self.i64Type(), "start_idx");
        
        // Add incoming values for phi nodes from the type-specific blocks
        var idx_incoming: [3]types.LLVMValueRef = .{
            core.LLVMConstInt(self.i64Type(), 1, 0), // constructor: skip tag
            core.LLVMConstInt(self.i64Type(), 1, 0), // tuple: skip length
            core.LLVMConstInt(self.i64Type(), 0, 0), // record: fields start at 0
        };
        var idx_blocks: [3]types.LLVMBasicBlockRef = .{ constructor_block, tuple_block, record_block };
        core.LLVMAddIncoming(phi_idx, &idx_incoming, &idx_blocks, 3);
        
        var count_incoming: [3]types.LLVMValueRef = .{ arity_param, arity_param, arity_param };
        var count_blocks: [3]types.LLVMBasicBlockRef = .{ constructor_block, tuple_block, record_block };
        core.LLVMAddIncoming(phi_count, &count_incoming, &count_blocks, 3);
        
        var start_incoming: [3]types.LLVMValueRef = .{
            core.LLVMConstInt(self.i64Type(), 1, 0), // constructor: skip tag
            core.LLVMConstInt(self.i64Type(), 1, 0), // tuple: skip length
            core.LLVMConstInt(self.i64Type(), 0, 0), // record: fields start at 0
        };
        var start_blocks: [3]types.LLVMBasicBlockRef = .{ constructor_block, tuple_block, record_block };
        core.LLVMAddIncoming(phi_start_idx, &start_incoming, &start_blocks, 3);
        
        // Check if idx < count
        const should_continue = core.LLVMBuildICmp(self.builder, .LLVMIntULT, phi_idx, phi_count, "should_continue");
        self.buildCondBranch(should_continue, loop_body, loop_done);

        // Loop body: check bitmap, decref field at index if pointer
        core.LLVMPositionBuilderAtEnd(self.builder, loop_body);
        
        // Compute bitmap bit position: for constructor/tuple, bit = idx - start_idx; for record, bit = idx - 0
        const bitmap_idx = core.LLVMBuildSub(self.builder, phi_idx, phi_start_idx, "bitmap_idx");
        
        // Check if bit is set: (field_bitmap >> bitmap_idx) & 1
        const shift_amt = core.LLVMBuildShl(self.builder, core.LLVMConstInt(self.i64Type(), 1, 0), bitmap_idx, "shift_amt");
        const masked = core.LLVMBuildAnd(self.builder, field_bitmap, shift_amt, "masked");
        const is_pointer = core.LLVMBuildICmp(self.builder, .LLVMIntNE, masked, core.LLVMConstInt(self.i64Type(), 0, 0), "is_pointer");
        
        // Compute next_idx and branch
        const next_idx = core.LLVMBuildAdd(self.builder, phi_idx, core.LLVMConstInt(self.i64Type(), 1, 0), "next_idx");
        
        // If pointer, decref the field
        self.buildCondBranch(is_pointer, loop_decref, loop_next);

        // decref block: load field, convert i64 to ptr, call ko_decref recursively
        core.LLVMPositionBuilderAtEnd(self.builder, loop_decref);
        const idx_times_8 = core.LLVMBuildMul(self.builder, phi_idx, core.LLVMConstInt(self.i64Type(), 8, 0), "idx_times_8");
        const field_idx_arr: [1]types.LLVMValueRef = .{idx_times_8};
        const field_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @constCast(&field_idx_arr), 1, "field_ptr");
        const field_ptr_typed = core.LLVMBuildBitCast(self.builder, field_ptr, self.ptrType(), "field_ptr_typed");
        const field_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), field_ptr_typed, "field_val");
        
        // Convert i64 to ptr and call ko_decref (which reads header and recurses)
        const field_as_ptr = core.LLVMBuildIntToPtr(self.builder, field_val, self.ptrType(), "field_as_ptr");
        const ko_decref_fn = core.LLVMGetNamedFunction(self.module, "ko_decref");
        var field_decref_args: [1]types.LLVMValueRef = .{field_as_ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ko_decref_fn), ko_decref_fn, &field_decref_args, 1, "");
        
        self.buildBranch(loop_next);

        // next block: increment idx and loop back
        core.LLVMPositionBuilderAtEnd(self.builder, loop_next);
        self.buildBranch(loop_block);

        // Add incoming for phi_idx in loop (from loop_next which loops back)
        var loop_idx_incoming: [1]types.LLVMValueRef = .{next_idx};
        var loop_idx_blocks: [1]types.LLVMBasicBlockRef = .{loop_next};
        core.LLVMAddIncoming(phi_idx, &loop_idx_incoming, &loop_idx_blocks, 1);
        var loop_count_incoming: [1]types.LLVMValueRef = .{phi_count};
        var loop_count_blocks: [1]types.LLVMBasicBlockRef = .{loop_next};
        core.LLVMAddIncoming(phi_count, &loop_count_incoming, &loop_count_blocks, 1);
        var loop_start_incoming: [1]types.LLVMValueRef = .{phi_start_idx};
        var loop_start_blocks: [1]types.LLVMBasicBlockRef = .{loop_next};
        core.LLVMAddIncoming(phi_start_idx, &loop_start_incoming, &loop_start_blocks, 1);

        // Loop done
        core.LLVMPositionBuilderAtEnd(self.builder, loop_done);
        self.buildBranch(done_block);

        core.LLVMPositionBuilderAtEnd(self.builder, done_block);
        self.buildRetVoid();
    }

    // ============================================================
    // Stack check functions
    // ============================================================

    pub fn codegenInitStack(self: *StdlibCodegen) void {
        const fn_val = self.createFunction("ko_init_stack", self.voidType(), &.{});
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        self.buildRetVoid();
    }

    pub fn codegenCheckStack(self: *StdlibCodegen) void {
        const fn_val = self.createFunction("ko_check_stack", self.voidType(), &.{});
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        self.buildRetVoid();
    }

    pub fn codegenPanic(self: *StdlibCodegen) void {
        // ko_panic(msg_ptr: ptr, msg_len: i64) -> void
        // Writes message to stderr, newline, then aborts.
        {
            var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.i64Type() };
            const fn_val = self.createFunction("ko_panic", self.voidType(), &params);
            const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
            core.LLVMPositionBuilderAtEnd(self.builder, entry);
            const msg_ptr = core.LLVMGetParam(fn_val, 0);
            const msg_len = core.LLVMGetParam(fn_val, 1);
            core.LLVMSetValueName(msg_ptr, "msg_ptr");
            core.LLVMSetValueName(msg_len, "msg_len");

            // Format string for fprintf: "%.*s\n"
            const fmt_str = core.LLVMConstStringInContext(self.context, "%.*s\n", 5, 0);
            const fmt_global = core.LLVMAddGlobal(self.module, core.LLVMTypeOf(fmt_str), "panic_fmt");
            core.LLVMSetInitializer(fmt_global, fmt_str);
            core.LLVMSetGlobalConstant(fmt_global, 1);
            core.LLVMSetLinkage(fmt_global, .LLVMPrivateLinkage);
            var gep_args: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
            const fmt_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMTypeOf(fmt_str), fmt_global, &gep_args, 1, "fmt_ptr");

            // Flush stdout before writing to stderr. abort() does not run the
            // atexit handlers that would normally drain it, so without this any
            // buffered println output is lost whenever stdout is a pipe — which
            // is exactly the case under the test harness.
            if (core.LLVMGetNamedFunction(self.module, "fflush")) |fflush_fn| {
                var flush_args: [1]types.LLVMValueRef = .{core.LLVMConstNull(self.ptrType())};
                _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(fflush_fn), fflush_fn, &flush_args, 1, "");
            }

            // Get fprintf declaration
            const fprintf_fn = core.LLVMGetNamedFunction(self.module, "fprintf") orelse unreachable;
            // Get stderr global and load it
            const stderr_global = core.LLVMGetNamedGlobal(self.module, "stderr") orelse unreachable;
            const stderr_val = core.LLVMBuildLoad2(self.builder, self.ptrType(), stderr_global, "stderr_val");

            // Call fprintf(stderr, "%.*s\n", msg_len, msg_ptr)
            var fprintf_args: [4]types.LLVMValueRef = .{ stderr_val, fmt_ptr, msg_len, msg_ptr };
            _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(fprintf_fn), fprintf_fn, &fprintf_args, 4, "");

            // Call abort()
            const abort_fn = core.LLVMGetNamedFunction(self.module, "abort") orelse unreachable;
            _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(abort_fn), abort_fn, null, 0, "");
            _ = core.LLVMBuildUnreachable(self.builder);
        }

        // ko_panic_str(msg_ptr: ptr) -> void
        // Calls ko_panic with strlen(msg_ptr).
        {
            var params_str: [1]types.LLVMTypeRef = .{self.ptrType()};
            const fn_val = self.createFunction("ko_panic_str", self.voidType(), &params_str);
            const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
            core.LLVMPositionBuilderAtEnd(self.builder, entry);
            const msg_ptr = core.LLVMGetParam(fn_val, 0);
            core.LLVMSetValueName(msg_ptr, "msg_ptr");

            // Call strlen(msg_ptr)
            const strlen_fn = core.LLVMGetNamedFunction(self.module, "strlen") orelse unreachable;
            var strlen_args: [1]types.LLVMValueRef = .{msg_ptr};
            const len = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strlen_fn), strlen_fn, &strlen_args, 1, "len");

            // Call ko_panic(msg_ptr, len)
            const ko_panic_fn = core.LLVMGetNamedFunction(self.module, "ko_panic") orelse unreachable;
            var panic_args: [2]types.LLVMValueRef = .{ msg_ptr, len };
            _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ko_panic_fn), ko_panic_fn, &panic_args, 2, "");
            _ = core.LLVMBuildUnreachable(self.builder);
        }
    }

    pub fn codegenAssert(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.ptrType() };
        _ = self.createFunction("ko_assert", self.voidType(), &params);
    }

    pub fn codegenAssertEq(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.ptrType() };
        _ = self.createFunction("ko_assert_eq", self.voidType(), &params);
    }

    // ============================================================
    // I/O functions — full LLVM IR generation
    // ============================================================

    pub fn codegenInspect(self: *StdlibCodegen) void {
        var params: [6]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.ptrType(), self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("inspect", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        const type_tag = core.LLVMGetParam(fn_val, 1);
        const name_ptr = core.LLVMGetParam(fn_val, 2);
        const raw = core.LLVMGetParam(fn_val, 3);
        const arity = core.LLVMGetParam(fn_val, 4);
        // Type tag of the list element, so list sugar can print non-Int elements
        // correctly. 100 (unknown) when the static type gives us nothing.
        const elem_tag = core.LLVMGetParam(fn_val, 5);
        core.LLVMSetValueName(val, "val");
        core.LLVMSetValueName(type_tag, "type_tag");
        core.LLVMSetValueName(name_ptr, "name_ptr");
        core.LLVMSetValueName(raw, "raw");
        core.LLVMSetValueName(arity, "arity");
        core.LLVMSetValueName(elem_tag, "elem_tag");
        const unknown_tag = core.LLVMConstInt(self.i64Type(), 100, 0);

        const printf_fn = core.LLVMGetNamedFunction(self.module, "printf");
        const fmt_s = self.globalStringConstant("%s");

        // Create default block
        const default_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "default");
        // Create merge block for returning val
        const merge_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "merge");

        // Create blocks for each case (0-9)
        var case_bbs: [10]types.LLVMBasicBlockRef = undefined;
        for (0..10) |i| {
            case_bbs[i] = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "case");
        }

        // Switch on type_tag
        const sw = core.LLVMBuildSwitch(self.builder, type_tag, default_bb, 10);
        for (0..10) |i| {
            core.LLVMAddCase(sw, core.LLVMConstInt(self.i64Type(), i, 0), case_bbs[i]);
        }

        // ---- case 0: int — printf("%ld", val) ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[0]);
        const fmt_ld = self.globalStringConstant("%ld");
        var ld_args: [2]types.LLVMValueRef = .{ fmt_ld, val };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &ld_args, 2, "");
        self.buildBranch(merge_bb);

        // ---- case 1: float — bitcast to double, printf("%f", f) ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[1]);
        const float_val = core.LLVMBuildBitCast(self.builder, val, self.doubleType(), "float_val");
        const fmt_f = self.globalStringConstant("%f");
        var f_args: [2]types.LLVMValueRef = .{ fmt_f, float_val };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &f_args, 2, "");
        self.buildBranch(merge_bb);

        // ---- case 2: bool — val != 0 ? "True" : "False" ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[2]);
        const is_true = core.LLVMBuildICmp(self.builder, .LLVMIntNE, val, core.LLVMConstInt(self.i64Type(), 0, 0), "is_true");
        const true_str = self.globalStringConstant("True");
        const false_str = self.globalStringConstant("False");
        const bool_str = core.LLVMBuildSelect(self.builder, is_true, true_str, false_str, "bool_str");
        var bool_args: [2]types.LLVMValueRef = .{ fmt_s, bool_str };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &bool_args, 2, "");
        self.buildBranch(merge_bb);

        // ---- case 3: char — raw ? printf("%c", ch) : printf("'%c'", ch) ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[3]);
        const char_val = core.LLVMBuildTrunc(self.builder, val, self.i8Type(), "char_val");
        const char_ext = core.LLVMBuildSExt(self.builder, char_val, self.i64Type(), "char_ext");
        const is_raw_char = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, raw, core.LLVMConstInt(self.i64Type(), 1, 0), "is_raw_char");
        const char_raw_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "char_raw");
        const char_debug_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "char_debug");
        const char_merge = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "char_merge");
        self.buildCondBranch(is_raw_char, char_raw_bb, char_debug_bb);
        // raw: printf("%c", ch)
        core.LLVMPositionBuilderAtEnd(self.builder, char_raw_bb);
        const fmt_c_raw = self.globalStringConstant("%c");
        var c_raw_args: [2]types.LLVMValueRef = .{ fmt_c_raw, char_ext };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &c_raw_args, 2, "");
        self.buildBranch(char_merge);
        // debug: printf("'%c'", ch)
        core.LLVMPositionBuilderAtEnd(self.builder, char_debug_bb);
        const fmt_c_debug = self.globalStringConstant("'%c'");
        var c_debug_args: [2]types.LLVMValueRef = .{ fmt_c_debug, char_ext };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &c_debug_args, 2, "");
        self.buildBranch(char_merge);
        core.LLVMPositionBuilderAtEnd(self.builder, char_merge);
        self.buildBranch(merge_bb);

        // ---- case 4: string — raw ? printf("%s", str) : printf("\"%s\"", str) ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[4]);
        const str_ptr = core.LLVMBuildIntToPtr(self.builder, val, self.ptrType(), "str_ptr");
        const is_raw_str = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, raw, core.LLVMConstInt(self.i64Type(), 1, 0), "is_raw_str");
        const str_raw_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "str_raw");
        const str_debug_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "str_debug");
        const str_merge = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "str_merge");
        self.buildCondBranch(is_raw_str, str_raw_bb, str_debug_bb);
        // raw: printf("%s", str)
        core.LLVMPositionBuilderAtEnd(self.builder, str_raw_bb);
        var str_raw_args: [2]types.LLVMValueRef = .{ fmt_s, str_ptr };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &str_raw_args, 2, "");
        self.buildBranch(str_merge);
        // debug: printf("\"%s\"", str)
        core.LLVMPositionBuilderAtEnd(self.builder, str_debug_bb);
        const fmt_qs = self.globalStringConstant("\"%s\"");
        var str_debug_args: [2]types.LLVMValueRef = .{ fmt_qs, str_ptr };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &str_debug_args, 2, "");
        self.buildBranch(str_merge);
        core.LLVMPositionBuilderAtEnd(self.builder, str_merge);
        self.buildBranch(merge_bb);

        // ---- case 5: unit — printf("()") ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[5]);
        const fmt_unit = self.globalStringConstant("()");
        var unit_args: [2]types.LLVMValueRef = .{ fmt_unit, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &unit_args, 2, "");
        self.buildBranch(merge_bb);

        // ---- case 6: constructor — list sugar or name_ptr or fallback ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[6]);
        const strcmp_fn = core.LLVMGetNamedFunction(self.module, "strcmp");
        const inspect_fn = core.LLVMGetNamedFunction(self.module, "inspect");
        const ilt_fn = core.LLVMGetNamedFunction(self.module, "inspect_list_tail");

        // Check if name_ptr is null → fallback to "Constructor(%ld)"
        const ctor_has_name = core.LLVMBuildICmp(self.builder, .LLVMIntNE, name_ptr, core.LLVMConstNull(self.ptrType()), "has_name");
        const ctor_fallback_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_fallback");
        const ctor_name_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_name_check");
        const ctor_merge = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_merge");
        self.buildCondBranch(ctor_has_name, ctor_name_check, ctor_fallback_block);

        // ctor_fallback: try structural list detection, else printf("Constructor(%ld)", val)
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_fallback_block);
        const is_ptr = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, val, core.LLVMConstInt(self.i64Type(), 4096, 0), "is_ptr");
        const ctor_fallback_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_fallback_done");
        const try_list_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "try_list");
        self.buildCondBranch(is_ptr, try_list_block, ctor_fallback_done);

        // try_list: dereference ptr[0], check if it's 0 (Cons tag)
        core.LLVMPositionBuilderAtEnd(self.builder, try_list_block);
        const deref_ptr_try = core.LLVMBuildIntToPtr(self.builder, val, self.ptrType(), "deref_ptr_try");
        var tag_idx_try: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        const tag_ptr_try = core.LLVMBuildGEP2(self.builder, self.i8Type(), deref_ptr_try, @ptrCast(&tag_idx_try), 1, "tag_ptr_try");
        const tag_val_try = core.LLVMBuildLoad2(self.builder, self.i64Type(), tag_ptr_try, "tag_val_try");
        const is_cons_try = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, tag_val_try, core.LLVMConstInt(self.i64Type(), 0, 0), "is_cons_try");
        const print_as_list = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "print_as_list");
        const print_raw_cons = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "print_raw_cons");
        const print_as_list_sugar = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "print_as_list_sugar");
        self.buildCondBranch(is_cons_try, print_as_list, ctor_fallback_done);

        // print_as_list: load head/tail, then check raw for sugar vs raw form
        core.LLVMPositionBuilderAtEnd(self.builder, print_as_list);
        var head_idx_try: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const head_ptr_try = core.LLVMBuildGEP2(self.builder, self.i8Type(), deref_ptr_try, @ptrCast(&head_idx_try), 1, "head_ptr_try");
        const head_val_try = core.LLVMBuildLoad2(self.builder, self.i64Type(), head_ptr_try, "head_val_try");
        var tail_idx_try: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 16, 0)};
        const tail_ptr_try = core.LLVMBuildGEP2(self.builder, self.i8Type(), deref_ptr_try, @ptrCast(&tail_idx_try), 1, "tail_ptr_try");
        const tail_val_try = core.LLVMBuildLoad2(self.builder, self.i64Type(), tail_ptr_try, "tail_val_try");
        // Check raw: raw=0 → Cons form, raw=1 → [sugar] form
        const is_raw_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, raw, core.LLVMConstInt(self.i64Type(), 0, 0), "is_raw_zero");
        self.buildCondBranch(is_raw_zero, print_raw_cons, print_as_list_sugar);

        // print_raw_cons: Cons head tail (raw/debug form)
        core.LLVMPositionBuilderAtEnd(self.builder, print_raw_cons);
        const fmt_cons = self.globalStringConstant("Cons ");
        var cons_args: [2]types.LLVMValueRef = .{ fmt_cons, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &cons_args, 2, "");
        // Print head element (raw=0 for recursive inspect — null name for structural detection)
        var raw_head_args: [6]types.LLVMValueRef = .{ head_val_try, elem_tag, core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 0, 0), core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &raw_head_args, 6, "");
        // Print space separator between head and tail
        const fmt_space_raw = self.globalStringConstant(" ");
        var space_raw_args: [2]types.LLVMValueRef = .{ fmt_space_raw, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &space_raw_args, 2, "");
        // Check if tail is Nil (raw tag=1) or a pointer
        const tail_is_nil_raw = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, tail_val_try, core.LLVMConstInt(self.i64Type(), 1, 0), "tail_is_nil_raw");
        const tail_is_ptr_raw = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, tail_val_try, core.LLVMConstInt(self.i64Type(), 4096, 0), "tail_is_ptr_raw");
        const tail_raw_nil_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tail_raw_nil");
        const tail_raw_ptr_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tail_raw_ptr");
        const tail_raw_other_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tail_raw_other");
        // First check nil, then check ptr
        self.buildCondBranch(tail_is_nil_raw, tail_raw_nil_bb, tail_raw_ptr_bb);
        // tail_raw_nil: print "Nil" directly
        core.LLVMPositionBuilderAtEnd(self.builder, tail_raw_nil_bb);
        const fmt_nil_raw2 = self.globalStringConstant("Nil");
        var nil_raw2_args: [2]types.LLVMValueRef = .{ fmt_nil_raw2, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &nil_raw2_args, 2, "");
        const tail_raw_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tail_raw_done");
        self.buildBranch(tail_raw_done);
        // tail_raw_ptr: it's a pointer, recurse with inspect
        core.LLVMPositionBuilderAtEnd(self.builder, tail_raw_ptr_bb);
        const tail_raw_ptr_bb2 = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tail_raw_ptr2");
        self.buildCondBranch(tail_is_ptr_raw, tail_raw_ptr_bb2, tail_raw_other_bb);
        core.LLVMPositionBuilderAtEnd(self.builder, tail_raw_ptr_bb2);
        var raw_tail_args: [6]types.LLVMValueRef = .{ tail_val_try, core.LLVMConstInt(self.i64Type(), 6, 0), core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 0, 0), core.LLVMConstInt(self.i64Type(), 0, 0), elem_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &raw_tail_args, 6, "");
        self.buildBranch(tail_raw_done);
        // tail_raw_other: small non-Nil value, print as inspect
        core.LLVMPositionBuilderAtEnd(self.builder, tail_raw_other_bb);
        var raw_tail_other_args: [6]types.LLVMValueRef = .{ tail_val_try, core.LLVMConstInt(self.i64Type(), 100, 0), core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 0, 0), core.LLVMConstInt(self.i64Type(), 0, 0), elem_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &raw_tail_other_args, 6, "");
        self.buildBranch(tail_raw_done);
        core.LLVMPositionBuilderAtEnd(self.builder, tail_raw_done);
        self.buildBranch(ctor_merge);

        // print_as_list_sugar: [head, tail...] (user-friendly form)
        core.LLVMPositionBuilderAtEnd(self.builder, print_as_list_sugar);
        // Detect nested list: branch to check head, then select elem_tag
        const head_check_tag_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "head_check_tag");
        const head_is_ptr_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "head_is_ptr_bb");
        const head_is_ptr = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, head_val_try, core.LLVMConstInt(self.i64Type(), 4096, 0), "head_is_ptr");
        self.buildCondBranch(head_is_ptr, head_check_tag_bb, head_is_ptr_bb);
        // head_check_tag: dereference, check Cons tag → set head_is_cons, branch to head_is_ptr_bb
        core.LLVMPositionBuilderAtEnd(self.builder, head_check_tag_bb);
        const head_deref = core.LLVMBuildIntToPtr(self.builder, head_val_try, self.ptrType(), "head_deref");
        var head_tag_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        const head_tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), head_deref, @ptrCast(&head_tag_idx), 1, "head_tag_ptr");
        const head_tag_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), head_tag_ptr, "head_tag_val");
        const head_is_cons_val = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, head_tag_val, core.LLVMConstInt(self.i64Type(), 0, 0), "head_is_cons_val");
        self.buildBranch(head_is_ptr_bb);
        // head_is_ptr_bb: phi for head_is_cons, select elem_tag
        core.LLVMPositionBuilderAtEnd(self.builder, head_is_ptr_bb);
        const head_is_cons_phi = core.LLVMBuildPhi(self.builder, self.i1Type(), "head_is_cons_phi");
        var incoming_cons_vals: [2]types.LLVMValueRef = .{ head_is_cons_val, core.LLVMConstInt(self.i1Type(), 0, 0) };
        var incoming_cons_blocks: [2]types.LLVMBasicBlockRef = .{ head_check_tag_bb, print_as_list_sugar };
        core.LLVMAddIncoming(head_is_cons_phi, &incoming_cons_vals, &incoming_cons_blocks, 2);
        const head_elem_tag = core.LLVMBuildSelect(self.builder, head_is_cons_phi, unknown_tag, elem_tag, "head_elem_tag");
        const fmt_lbracket_try = self.globalStringConstant("[");
        var lbracket_args_try: [2]types.LLVMValueRef = .{ fmt_lbracket_try, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &lbracket_args_try, 2, "");
        var head_args_try: [6]types.LLVMValueRef = .{ head_val_try, head_elem_tag, core.LLVMConstNull(self.ptrType()), raw, core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &head_args_try, 6, "");
        var tail_args_try: [3]types.LLVMValueRef = .{ tail_val_try, raw, elem_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ilt_fn), ilt_fn, &tail_args_try, 3, "");
        const fmt_rbracket_try = self.globalStringConstant("]");
        var rbracket_args_try: [2]types.LLVMValueRef = .{ fmt_rbracket_try, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &rbracket_args_try, 2, "");
        self.buildBranch(ctor_merge);

        // ctor_fallback_done: printf("Constructor(%ld)", val) — for non-list constructors
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_fallback_done);
        const fmt_ctor = self.globalStringConstant("Constructor(%ld)");
        var ctor_fb_args: [2]types.LLVMValueRef = .{ fmt_ctor, val };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &ctor_fb_args, 2, "");
        self.buildBranch(ctor_merge);

        // ctor_name_check: first check if name_ptr is null → fallback to structural detection
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_name_check);
        const is_name_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, name_ptr, core.LLVMConstNull(self.ptrType()), "is_name_null");
        const ctor_name_fallback_null = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_name_fallback_null");
        const ctor_name_not_null = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_name_not_null");
        self.buildCondBranch(is_name_null, ctor_name_fallback_null, ctor_name_not_null);
        // ctor_name_fallback_null: name_ptr is null, check known tags (Nil=1)
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_name_fallback_null);
        const is_val_nil = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, val, core.LLVMConstInt(self.i64Type(), 1, 0), "is_val_nil");
        const null_print_nil = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "null_print_nil");
        self.buildCondBranch(is_val_nil, null_print_nil, ctor_fallback_done);
        // null_print_nil: printf("Nil")
        core.LLVMPositionBuilderAtEnd(self.builder, null_print_nil);
        const fmt_nil_null = self.globalStringConstant("Nil");
        var nil_null_args: [2]types.LLVMValueRef = .{ fmt_nil_null, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &nil_null_args, 2, "");
        self.buildBranch(ctor_merge);
        // ctor_name_not_null: strcmp(name_ptr, "Nil") == 0?
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_name_not_null);
        const str_nil = self.globalStringConstant("Nil");
        var cmp_nil_args: [2]types.LLVMValueRef = .{ name_ptr, str_nil };
        const is_nil = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strcmp_fn), strcmp_fn, &cmp_nil_args, 2, "");
        const is_nil_cmp = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, is_nil, core.LLVMConstInt(core.LLVMInt32TypeInContext(self.context), 0, 0), "is_nil");
        const nil_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "print_nil");
        const ctor_name_check_cons = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_cons");
        self.buildCondBranch(is_nil_cmp, nil_block, ctor_name_check_cons);

        // print_nil: raw=1 → [], raw=0 → Nil
        core.LLVMPositionBuilderAtEnd(self.builder, nil_block);
        const is_raw_nil = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, raw, core.LLVMConstInt(self.i64Type(), 0, 0), "is_raw_nil");
        const nil_sugar_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "nil_sugar");
        const nil_raw_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "nil_raw");
        self.buildCondBranch(is_raw_nil, nil_raw_block, nil_sugar_block);
        // nil_sugar: printf("[]")
        core.LLVMPositionBuilderAtEnd(self.builder, nil_sugar_block);
        const fmt_nil = self.globalStringConstant("[]");
        var nil_args: [2]types.LLVMValueRef = .{ fmt_nil, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &nil_args, 2, "");
        const nil_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "nil_done");
        self.buildBranch(nil_done);
        // nil_raw: printf("Nil")
        core.LLVMPositionBuilderAtEnd(self.builder, nil_raw_block);
        const fmt_nil_raw = self.globalStringConstant("Nil");
        var nil_raw_args: [2]types.LLVMValueRef = .{ fmt_nil_raw, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &nil_raw_args, 2, "");
        self.buildBranch(nil_done);

        // check_cons: strcmp(name_ptr, "Cons") == 0?
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_name_check_cons);
        const str_cons = self.globalStringConstant("Cons");
        var cmp_cons_args: [2]types.LLVMValueRef = .{ name_ptr, str_cons };
        const is_cons_str = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strcmp_fn), strcmp_fn, &cmp_cons_args, 2, "");
        const is_cons_cmp = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, is_cons_str, core.LLVMConstInt(core.LLVMInt32TypeInContext(self.context), 0, 0), "is_cons");
        const cons_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "print_cons");
        const ctor_name_fallback = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_name_fallback");
        self.buildCondBranch(is_cons_cmp, cons_block, ctor_name_fallback);

        // print_cons: dereference val, then branch on raw for sugar vs raw form
        core.LLVMPositionBuilderAtEnd(self.builder, cons_block);
        const deref_ptr_cons = core.LLVMBuildIntToPtr(self.builder, val, self.ptrType(), "deref_ptr_cons");
        var head_idx_cons: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const head_ptr_cons = core.LLVMBuildGEP2(self.builder, self.i8Type(), deref_ptr_cons, @ptrCast(&head_idx_cons), 1, "head_ptr_cons");
        const head_val_cons = core.LLVMBuildLoad2(self.builder, self.i64Type(), head_ptr_cons, "head_val_cons");
        var tail_idx_cons: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 16, 0)};
        const tail_ptr_cons = core.LLVMBuildGEP2(self.builder, self.i8Type(), deref_ptr_cons, @ptrCast(&tail_idx_cons), 1, "tail_ptr_cons");
        const tail_val_cons = core.LLVMBuildLoad2(self.builder, self.i64Type(), tail_ptr_cons, "tail_val_cons");
        // Branch on raw: 0 → Cons head tail, 1 → [head, tail...]
        const is_raw_cons_sugar = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, raw, core.LLVMConstInt(self.i64Type(), 0, 0), "is_raw_cons_sugar");
        const cons_sugar_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "cons_sugar");
        const cons_raw_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "cons_raw");
        self.buildCondBranch(is_raw_cons_sugar, cons_raw_bb, cons_sugar_bb);
        // cons_sugar: [head, tail...]
        core.LLVMPositionBuilderAtEnd(self.builder, cons_sugar_bb);
        const fmt_lbracket = self.globalStringConstant("[");
        var lbracket_args: [2]types.LLVMValueRef = .{ fmt_lbracket, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &lbracket_args, 2, "");
        // inspect(head, elem_tag, null, 1, 0) — sugar=1
        var head_sugar_args: [6]types.LLVMValueRef = .{ head_val_cons, elem_tag, core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 1, 0), core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &head_sugar_args, 6, "");
        // inspect_list_tail(tail, 1) — sugar=1
        var tail_sugar_args: [3]types.LLVMValueRef = .{ tail_val_cons, core.LLVMConstInt(self.i64Type(), 1, 0), elem_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ilt_fn), ilt_fn, &tail_sugar_args, 3, "");
        const fmt_rbracket = self.globalStringConstant("]");
        var rbracket_args: [2]types.LLVMValueRef = .{ fmt_rbracket, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &rbracket_args, 2, "");
        const cons_sugar_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "cons_sugar_done");
        self.buildBranch(cons_sugar_done);
        // cons_raw: Cons head tail
        core.LLVMPositionBuilderAtEnd(self.builder, cons_raw_bb);
        const fmt_cons_raw = self.globalStringConstant("Cons ");
        var cons_raw_args: [2]types.LLVMValueRef = .{ fmt_cons_raw, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &cons_raw_args, 2, "");
        // inspect(head, elem_tag, null, 0, 0) — raw=0
        var head_raw_args: [6]types.LLVMValueRef = .{ head_val_cons, elem_tag, core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 0, 0), core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &head_raw_args, 6, "");
        // inspect_list_tail(tail, 0) — raw=0 (prints space before each tail element)
        var tail_raw_args: [3]types.LLVMValueRef = .{ tail_val_cons, core.LLVMConstInt(self.i64Type(), 0, 0), elem_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ilt_fn), ilt_fn, &tail_raw_args, 3, "");
        self.buildBranch(cons_sugar_done);
        core.LLVMPositionBuilderAtEnd(self.builder, cons_sugar_done);
        self.buildBranch(ctor_merge);

        // ctor_name_fallback: printf("%s", name_ptr), then if arity > 0, print args
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_name_fallback);
        var ctor_name_args: [2]types.LLVMValueRef = .{ fmt_s, name_ptr };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &ctor_name_args, 2, "");
        // If arity > 0, print " " then each arg
        const ctor_has_args = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, arity, core.LLVMConstInt(self.i64Type(), 0, 0), "has_args");
        const ctor_args_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_args");
        const ctor_name_done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_name_done");
        self.buildCondBranch(ctor_has_args, ctor_args_block, ctor_name_done);
        // ctor_args: dereference ptr, print " " then each arg via inspect
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_args_block);
        const ctor_ptr = core.LLVMBuildIntToPtr(self.builder, val, self.ptrType(), "ctor_ptr");
        const fmt_space = self.globalStringConstant(" ");
        var sp_args: [2]types.LLVMValueRef = .{ fmt_space, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &sp_args, 2, "");
        // Loop: for i in 0..arity, print arg i (at ptr[i+1])
        const ctor_loop_entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_loop_entry");
        const ctor_loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_loop_body");
        const ctor_loop_exit = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_loop_exit");
        const ctor_idx_start = core.LLVMBuildAlloca(self.builder, self.i64Type(), "ctor_idx");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), ctor_idx_start);
        self.buildBranch(ctor_loop_entry);
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_loop_entry);
        const ctor_idx_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), ctor_idx_start, "idx_val");
        const ctor_idx_lt = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, ctor_idx_val, arity, "idx_lt");
        self.buildCondBranch(ctor_idx_lt, ctor_loop_body, ctor_loop_exit);
        // loop body: print separator + arg
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_loop_body);
        const ctor_is_first = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, ctor_idx_val, core.LLVMConstInt(self.i64Type(), 0, 0), "is_first");
        const ctor_sep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_sep");
        const ctor_after_sep = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_after_sep");
        self.buildCondBranch(ctor_is_first, ctor_after_sep, ctor_sep_bb);
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_sep_bb);
        var ctor_sep_args: [2]types.LLVMValueRef = .{ fmt_space, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &ctor_sep_args, 2, "");
        self.buildBranch(ctor_after_sep);
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_after_sep);
        // GEP to arg at ptr[i+1], load, call inspect(val, 100, null, 0, 0)
        const arg_offset = core.LLVMBuildAdd(self.builder, ctor_idx_val, core.LLVMConstInt(self.i64Type(), 1, 0), "arg_offset");
        const arg_byte_offset = core.LLVMBuildMul(self.builder, arg_offset, core.LLVMConstInt(self.i64Type(), 8, 0), "arg_byte");
        var arg_idx: [1]types.LLVMValueRef = .{arg_byte_offset};
        const arg_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ctor_ptr, @ptrCast(&arg_idx), 1, "arg_ptr");
        const arg_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), arg_ptr, "arg_val");
        var arg_inspect_args: [6]types.LLVMValueRef = .{ arg_val, core.LLVMConstInt(self.i64Type(), 100, 0), core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 0, 0), core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &arg_inspect_args, 6, "");
        // increment idx
        const ctor_next_idx = core.LLVMBuildAdd(self.builder, ctor_idx_val, core.LLVMConstInt(self.i64Type(), 1, 0), "next_idx");
        _ = core.LLVMBuildStore(self.builder, ctor_next_idx, ctor_idx_start);
        self.buildBranch(ctor_loop_entry);
        // loop exit
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_loop_exit);
        self.buildBranch(ctor_name_done);
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_name_done);
        self.buildBranch(ctor_merge);

        // Merge all branches
        core.LLVMPositionBuilderAtEnd(self.builder, nil_done);
        self.buildBranch(ctor_merge);

        core.LLVMPositionBuilderAtEnd(self.builder, ctor_merge);
        self.buildBranch(merge_bb);

        const fmt_tuple_comma = self.globalStringConstant(", ");
        const fmt_tuple_paren = self.globalStringConstant("(");
        const fmt_tuple_rparen = self.globalStringConstant(")");

        // ---- case 7: record — if name_ptr, printf("Name { ... }", name_ptr), else printf("Record(%ld)", val) ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[7]);
        const rec_has_name = core.LLVMBuildICmp(self.builder, .LLVMIntNE, name_ptr, core.LLVMConstNull(self.ptrType()), "has_name");
        const rec_name_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_name");
        const rec_fallback_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_fallback");
        const rec_merge = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_merge");
        self.buildCondBranch(rec_has_name, rec_name_block, rec_fallback_block);

        // rec_name: print "Name " then if arity > 0, dereference and print fields
        core.LLVMPositionBuilderAtEnd(self.builder, rec_name_block);
        // printf("Name ", name_ptr)  — just the name
        var rec_name_print_args: [2]types.LLVMValueRef = .{ fmt_s, name_ptr };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &rec_name_print_args, 2, "");
        // Check if arity > 0
        const rec_has_arity = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, arity, core.LLVMConstInt(self.i64Type(), 0, 0), "rec_has_arity");
        const rec_fields_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_fields");
        const rec_no_fields = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_no_fields");
        self.buildCondBranch(rec_has_arity, rec_fields_block, rec_no_fields);
        // rec_fields: dereference ptr, print "{ val0, val1, ... }"
        core.LLVMPositionBuilderAtEnd(self.builder, rec_fields_block);
        const rec_ptr = core.LLVMBuildIntToPtr(self.builder, val, self.ptrType(), "rec_ptr");
        const fmt_rec_lbrace = self.globalStringConstant(" { ");
        var rlb_args: [2]types.LLVMValueRef = .{ fmt_rec_lbrace, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &rlb_args, 2, "");
        // Loop: for i in 0..arity, print field i
        const rec_loop_entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_loop_entry");
        const rec_loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_loop_body");
        const rec_loop_exit = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_loop_exit");
        const rec_idx_start = core.LLVMBuildAlloca(self.builder, self.i64Type(), "rec_idx");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), rec_idx_start);
        self.buildBranch(rec_loop_entry);
        core.LLVMPositionBuilderAtEnd(self.builder, rec_loop_entry);
        const rec_idx_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), rec_idx_start, "idx_val");
        const rec_idx_lt = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, rec_idx_val, arity, "idx_lt");
        self.buildCondBranch(rec_idx_lt, rec_loop_body, rec_loop_exit);
        // loop body: print separator + field value
        core.LLVMPositionBuilderAtEnd(self.builder, rec_loop_body);
        const rec_is_first = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, rec_idx_val, core.LLVMConstInt(self.i64Type(), 0, 0), "is_first");
        const rec_sep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_sep");
        const rec_after_sep = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_after_sep");
        self.buildCondBranch(rec_is_first, rec_after_sep, rec_sep_bb);
        core.LLVMPositionBuilderAtEnd(self.builder, rec_sep_bb);
        var rec_sep_args: [2]types.LLVMValueRef = .{ fmt_tuple_comma, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &rec_sep_args, 2, "");
        self.buildBranch(rec_after_sep);
        core.LLVMPositionBuilderAtEnd(self.builder, rec_after_sep);
        // GEP to field i, load, call inspect(val, 100, null, 0, 0)
        const rec_byte_offset = core.LLVMBuildMul(self.builder, rec_idx_val, core.LLVMConstInt(self.i64Type(), 8, 0), "rec_byte");
        var rec_field_idx: [1]types.LLVMValueRef = .{rec_byte_offset};
        const rec_field_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), rec_ptr, @ptrCast(&rec_field_idx), 1, "field_ptr");
        const rec_field_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), rec_field_ptr, "field_val");
        var rec_field_args: [6]types.LLVMValueRef = .{ rec_field_val, core.LLVMConstInt(self.i64Type(), 100, 0), core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 0, 0), core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &rec_field_args, 6, "");
        // increment idx
        const rec_next_idx = core.LLVMBuildAdd(self.builder, rec_idx_val, core.LLVMConstInt(self.i64Type(), 1, 0), "next_idx");
        _ = core.LLVMBuildStore(self.builder, rec_next_idx, rec_idx_start);
        self.buildBranch(rec_loop_entry);
        // loop exit: printf(" }")
        core.LLVMPositionBuilderAtEnd(self.builder, rec_loop_exit);
        const fmt_rec_rbrace = self.globalStringConstant(" }");
        var rrb_args: [2]types.LLVMValueRef = .{ fmt_rec_rbrace, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &rrb_args, 2, "");
        self.buildBranch(rec_merge);
        // rec_no_fields: printf(" { ... }")
        core.LLVMPositionBuilderAtEnd(self.builder, rec_no_fields);
        const fmt_rec = self.globalStringConstant(" { ... }");
        var rec_ellipsis_args: [2]types.LLVMValueRef = .{ fmt_rec, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &rec_ellipsis_args, 2, "");
        self.buildBranch(rec_merge);

        // rec_fallback: printf("Record(%ld)", val)
        core.LLVMPositionBuilderAtEnd(self.builder, rec_fallback_block);
        const fmt_rec_fb = self.globalStringConstant("Record(%ld)");
        var rec_fb_args: [2]types.LLVMValueRef = .{ fmt_rec_fb, val };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &rec_fb_args, 2, "");
        self.buildBranch(rec_merge);

        core.LLVMPositionBuilderAtEnd(self.builder, rec_merge);
        self.buildBranch(merge_bb);

        // ---- case 8: function — printf("<fn>") ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[8]);
        const fmt_fn = self.globalStringConstant("<fn>");
        var fn_args: [2]types.LLVMValueRef = .{ fmt_fn, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &fn_args, 2, "");
        self.buildBranch(merge_bb);

        // ---- case 9: tuple — dereference ptr, print each element ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[9]);
        // Check if arity > 0 (we know element count) vs fallback
        const has_arity = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, arity, core.LLVMConstInt(self.i64Type(), 0, 0), "has_arity");
        const tuple_with_arity = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tuple_with_arity");
        const tuple_fallback = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tuple_fallback");
        const tuple_merge9 = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tuple_merge9");
        self.buildCondBranch(has_arity, tuple_with_arity, tuple_fallback);
        // tuple_with_arity: dereference and print each element
        core.LLVMPositionBuilderAtEnd(self.builder, tuple_with_arity);
        const tuple_ptr = core.LLVMBuildIntToPtr(self.builder, val, self.ptrType(), "tuple_ptr");
        // printf("(")
        var tp_args: [2]types.LLVMValueRef = .{ fmt_tuple_paren, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &tp_args, 2, "");
        // Loop: for i in 0..arity, print element i
        const tuple_loop_entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tuple_loop_entry");
        const tuple_loop_body = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tuple_loop_body");
        const tuple_loop_exit = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tuple_loop_exit");
        const tuple_idx_start = core.LLVMBuildAlloca(self.builder, self.i64Type(), "tuple_idx");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 0, 0), tuple_idx_start);
        self.buildBranch(tuple_loop_entry);
        core.LLVMPositionBuilderAtEnd(self.builder, tuple_loop_entry);
        const tuple_idx_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), tuple_idx_start, "idx_val");
        const tuple_idx_lt = core.LLVMBuildICmp(self.builder, .LLVMIntSLT, tuple_idx_val, arity, "idx_lt");
        self.buildCondBranch(tuple_idx_lt, tuple_loop_body, tuple_loop_exit);
        // loop body: print separator + element
        core.LLVMPositionBuilderAtEnd(self.builder, tuple_loop_body);
        // print ", " if idx > 0
        const is_first = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, tuple_idx_val, core.LLVMConstInt(self.i64Type(), 0, 0), "is_first");
        const sep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "sep_bb");
        const after_sep = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "after_sep");
        self.buildCondBranch(is_first, after_sep, sep_bb);
        core.LLVMPositionBuilderAtEnd(self.builder, sep_bb);
        var sep_args: [2]types.LLVMValueRef = .{ fmt_tuple_comma, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &sep_args, 2, "");
        self.buildBranch(after_sep);
        core.LLVMPositionBuilderAtEnd(self.builder, after_sep);
        // GEP to element i, load, call inspect(val, 100, null, 0, 0)
        const tuple_byte_offset = core.LLVMBuildMul(self.builder, tuple_idx_val, core.LLVMConstInt(self.i64Type(), 8, 0), "tuple_byte");
        var elem_idx: [1]types.LLVMValueRef = .{tuple_byte_offset};
        const elem_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), tuple_ptr, @ptrCast(&elem_idx), 1, "elem_ptr");
        const elem_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), elem_ptr, "elem_val");
        var elem_args: [6]types.LLVMValueRef = .{ elem_val, core.LLVMConstInt(self.i64Type(), 100, 0), core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 0, 0), core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &elem_args, 6, "");
        // increment idx
        const next_idx = core.LLVMBuildAdd(self.builder, tuple_idx_val, core.LLVMConstInt(self.i64Type(), 1, 0), "next_idx");
        _ = core.LLVMBuildStore(self.builder, next_idx, tuple_idx_start);
        self.buildBranch(tuple_loop_entry);
        // loop exit: printf(")")
        core.LLVMPositionBuilderAtEnd(self.builder, tuple_loop_exit);
        var trp_args: [2]types.LLVMValueRef = .{ fmt_tuple_rparen, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &trp_args, 2, "");
        self.buildBranch(tuple_merge9);
        // tuple_fallback: printf("(%ld)", val)
        core.LLVMPositionBuilderAtEnd(self.builder, tuple_fallback);
        const fmt_tuple = self.globalStringConstant("(%ld)");
        var tuple_fb_args: [2]types.LLVMValueRef = .{ fmt_tuple, val };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &tuple_fb_args, 2, "");
        self.buildBranch(tuple_merge9);
        core.LLVMPositionBuilderAtEnd(self.builder, tuple_merge9);
        self.buildBranch(merge_bb);

        // ---- default: printf("%ld", val) — with structural list detection for unknown types ----
        core.LLVMPositionBuilderAtEnd(self.builder, default_bb);
        const def_val_is_ptr = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, val, core.LLVMConstInt(self.i64Type(), 4096, 0), "def_val_is_ptr");
        const def_check_tag_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "def_check_tag");
        const def_ld_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "def_ld");
        self.buildCondBranch(def_val_is_ptr, def_check_tag_bb, def_ld_bb);
        // def_check_tag: dereference, check Cons tag
        core.LLVMPositionBuilderAtEnd(self.builder, def_check_tag_bb);
        const def_deref = core.LLVMBuildIntToPtr(self.builder, val, self.ptrType(), "def_deref");
        var def_tag_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        const def_tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), def_deref, @ptrCast(&def_tag_idx), 1, "def_tag_ptr");
        const def_tag_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), def_tag_ptr, "def_tag_val");
        const def_is_cons = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, def_tag_val, core.LLVMConstInt(self.i64Type(), 0, 0), "def_is_cons");
        const def_cons_list_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "def_cons_list");
        self.buildCondBranch(def_is_cons, def_cons_list_bb, def_ld_bb);
        // def_ld: printf("%ld", val), branch to merge
        core.LLVMPositionBuilderAtEnd(self.builder, def_ld_bb);
        var def_ld_args: [2]types.LLVMValueRef = .{ fmt_ld, val };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &def_ld_args, 2, "");
        self.buildBranch(merge_bb);
        // def_cons_list: print as list [head, tail...]
        core.LLVMPositionBuilderAtEnd(self.builder, def_cons_list_bb);
        var def_head_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const def_head_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), def_deref, @ptrCast(&def_head_idx), 1, "def_head_ptr");
        const def_head_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), def_head_ptr, "def_head_val");
        var def_tail_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 16, 0)};
        const def_tail_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), def_deref, @ptrCast(&def_tail_idx), 1, "def_tail_ptr");
        const def_tail_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), def_tail_ptr, "def_tail_val");
        const fmt_def_lbracket = self.globalStringConstant("[");
        var def_lbracket_args: [2]types.LLVMValueRef = .{ fmt_def_lbracket, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &def_lbracket_args, 2, "");
        var def_head_inspect_args: [6]types.LLVMValueRef = .{ def_head_val, unknown_tag, core.LLVMConstNull(self.ptrType()), raw, core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &def_head_inspect_args, 6, "");
        var def_tail_args: [3]types.LLVMValueRef = .{ def_tail_val, raw, elem_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ilt_fn), ilt_fn, &def_tail_args, 3, "");
        const fmt_def_rbracket = self.globalStringConstant("]");
        var def_rbracket_args: [2]types.LLVMValueRef = .{ fmt_def_rbracket, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &def_rbracket_args, 2, "");
        self.buildBranch(merge_bb);

        // ---- merge: return val ----
        core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        self.buildRet(val);
    }

    pub fn codegenPrintlnWithTag(self: *StdlibCodegen) void {
        var params: [6]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.ptrType(), self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("println_with_tag", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        const type_tag = core.LLVMGetParam(fn_val, 1);
        const name_ptr = core.LLVMGetParam(fn_val, 2);
        const raw = core.LLVMGetParam(fn_val, 3);
        const arity = core.LLVMGetParam(fn_val, 4);
        const elem_tag = core.LLVMGetParam(fn_val, 5);

        // call inspect(val, type_tag, name_ptr, raw, arity, elem_tag)
        const inspect_fn = core.LLVMGetNamedFunction(self.module, "inspect");
        var inspect_args: [6]types.LLVMValueRef = .{ val, type_tag, name_ptr, raw, arity, elem_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &inspect_args, 6, "");

        // printf("\n")
        const printf_fn = core.LLVMGetNamedFunction(self.module, "printf");
        const newline = self.globalStringConstant("\n");
        var nl_args: [2]types.LLVMValueRef = .{ newline, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &nl_args, 2, "");

        self.buildRet(val);
    }

    pub fn codegenPrintWithTag(self: *StdlibCodegen) void {
        var params: [6]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.ptrType(), self.i64Type(), self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("print_with_tag", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        const type_tag = core.LLVMGetParam(fn_val, 1);
        const name_ptr = core.LLVMGetParam(fn_val, 2);
        const raw = core.LLVMGetParam(fn_val, 3);
        const arity = core.LLVMGetParam(fn_val, 4);
        const elem_tag = core.LLVMGetParam(fn_val, 5);

        // call inspect(val, type_tag, name_ptr, raw, arity, elem_tag)
        const inspect_fn = core.LLVMGetNamedFunction(self.module, "inspect");
        var inspect_args: [6]types.LLVMValueRef = .{ val, type_tag, name_ptr, raw, arity, elem_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &inspect_args, 6, "");

        self.buildRet(val);
    }

    /// Prints list continuation: given a tail value, prints ", head" then recurses on next tail.
    /// Nil (raw tag 1) → print nothing (end of list).
    /// Cons (ptr with tag 0) → print ", head", recurse on tail.
    /// Other → print ", value" as-is.
    pub fn codegenInspectListTail(self: *StdlibCodegen) void {
        const fn_val = core.LLVMGetNamedFunction(self.module, "inspect_list_tail") orelse blk: {
            var params: [3]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.i64Type() };
            break :blk self.createFunction("inspect_list_tail", self.voidType(), &params);
        };
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const tail = core.LLVMGetParam(fn_val, 0);
        const raw = core.LLVMGetParam(fn_val, 1);
        const elem_tag = core.LLVMGetParam(fn_val, 2);
        core.LLVMSetValueName(tail, "tail");
        core.LLVMSetValueName(raw, "raw");
        core.LLVMSetValueName(elem_tag, "elem_tag");
        const unknown_tag = core.LLVMConstInt(self.i64Type(), 100, 0);

        const printf_fn = core.LLVMGetNamedFunction(self.module, "printf");
        const fmt_comma = self.globalStringConstant(", ");
        const fmt_space = self.globalStringConstant(" ");

        // Check: tail == 1 (raw Nil tag) → stop
        const is_raw_nil = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, tail, core.LLVMConstInt(self.i64Type(), 1, 0), "is_raw_nil");
        const done_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");
        const check_ptr_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "check_ptr");
        self.buildCondBranch(is_raw_nil, done_bb, check_ptr_bb);

        // done: return void
        core.LLVMPositionBuilderAtEnd(self.builder, done_bb);
        self.buildRetVoid();

        // check_ptr: tail > 4096? (looks like a pointer)
        core.LLVMPositionBuilderAtEnd(self.builder, check_ptr_bb);
        const is_ptr = core.LLVMBuildICmp(self.builder, .LLVMIntSGT, tail, core.LLVMConstInt(self.i64Type(), 4096, 0), "is_ptr");
        const print_sep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "print_sep");
        const tail_is_other = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "tail_is_other");
        self.buildCondBranch(is_ptr, print_sep_bb, tail_is_other);

        // print_sep: choose separator based on raw (raw=0 → space, raw=1 → comma)
        core.LLVMPositionBuilderAtEnd(self.builder, print_sep_bb);
        const is_raw_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, raw, core.LLVMConstInt(self.i64Type(), 0, 0), "is_raw_zero_sep");
        const raw_sep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "raw_sep");
        const sugar_sep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "sugar_sep");
        self.buildCondBranch(is_raw_zero, raw_sep_bb, sugar_sep_bb);
        // raw_sep: printf(" ")
        core.LLVMPositionBuilderAtEnd(self.builder, raw_sep_bb);
        var raw_sep_args: [2]types.LLVMValueRef = .{ fmt_space, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &raw_sep_args, 2, "");
        const after_sep_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "after_sep");
        self.buildBranch(after_sep_bb);
        // sugar_sep: printf(", ")
        core.LLVMPositionBuilderAtEnd(self.builder, sugar_sep_bb);
        var sugar_sep_args: [2]types.LLVMValueRef = .{ fmt_comma, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &sugar_sep_args, 2, "");
        self.buildBranch(after_sep_bb);

        // after_sep: dereference, check tag
        core.LLVMPositionBuilderAtEnd(self.builder, after_sep_bb);
        const deref_ptr = core.LLVMBuildIntToPtr(self.builder, tail, self.ptrType(), "deref_ptr");
        var tag_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 0, 0)};
        const tag_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), deref_ptr, @ptrCast(&tag_idx), 1, "tag_ptr");
        const tag_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), tag_ptr, "tag_val");
        const is_cons = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, tag_val, core.LLVMConstInt(self.i64Type(), 0, 0), "is_cons");

        const cons_tail_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "cons_tail");
        const boxed_nil_bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "boxed_nil");
        self.buildCondBranch(is_cons, cons_tail_bb, boxed_nil_bb);

        // cons_tail: print head, recurse on next tail
        core.LLVMPositionBuilderAtEnd(self.builder, cons_tail_bb);
        var head_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const head_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), deref_ptr, @ptrCast(&head_idx), 1, "head_ptr");
        const head_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), head_ptr, "head_val");
        var tail_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 16, 0)};
        const next_tail_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), deref_ptr, @ptrCast(&tail_idx), 1, "next_tail_ptr");
        const next_tail = core.LLVMBuildLoad2(self.builder, self.i64Type(), next_tail_ptr, "next_tail");
        // inspect(head, elem_tag, null, raw, 0)
        const inspect_fn = core.LLVMGetNamedFunction(self.module, "inspect");
        var head_args: [6]types.LLVMValueRef = .{ head_val, elem_tag, core.LLVMConstNull(self.ptrType()), raw, core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &head_args, 6, "");
        // inspect_list_tail(next_tail, raw)
        const ilt_fn = core.LLVMGetNamedFunction(self.module, "inspect_list_tail");
        var recurse_args: [3]types.LLVMValueRef = .{ next_tail, raw, elem_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(ilt_fn), ilt_fn, &recurse_args, 3, "");
        self.buildRetVoid();

        // boxed_nil: it's a boxed Nil — stop (don't print separator before it)
        core.LLVMPositionBuilderAtEnd(self.builder, boxed_nil_bb);
        self.buildRetVoid();

        // tail_is_other: tail is a small non-Nil value — just print separator + inspect
        core.LLVMPositionBuilderAtEnd(self.builder, tail_is_other);
        // Choose separator based on raw
        const is_raw_zero_other = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, raw, core.LLVMConstInt(self.i64Type(), 0, 0), "is_raw_zero_other");
        const raw_sep_other = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "raw_sep_other");
        const sugar_sep_other = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "sugar_sep_other");
        self.buildCondBranch(is_raw_zero_other, raw_sep_other, sugar_sep_other);
        // raw_sep_other: printf(" ")
        core.LLVMPositionBuilderAtEnd(self.builder, raw_sep_other);
        var raw_other_args: [2]types.LLVMValueRef = .{ fmt_space, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &raw_other_args, 2, "");
        const after_other_sep = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "after_other_sep");
        self.buildBranch(after_other_sep);
        // sugar_sep_other: printf(", ")
        core.LLVMPositionBuilderAtEnd(self.builder, sugar_sep_other);
        var sugar_other_args: [2]types.LLVMValueRef = .{ fmt_comma, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &sugar_other_args, 2, "");
        self.buildBranch(after_other_sep);
        // after_other_sep: inspect + return
        core.LLVMPositionBuilderAtEnd(self.builder, after_other_sep);
        const inspect_fn2 = core.LLVMGetNamedFunction(self.module, "inspect");
        var other_args: [6]types.LLVMValueRef = .{ tail, elem_tag, core.LLVMConstNull(self.ptrType()), raw, core.LLVMConstInt(self.i64Type(), 0, 0), unknown_tag };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn2), inspect_fn2, &other_args, 6, "");
        self.buildRetVoid();
    }

    // ============================================================
    // Generate all stdlib functions
    // ============================================================

    pub fn generateAll(self: *StdlibCodegen) void {
        self.declareExternals();
        // Note: I/O externals are declared by declareBuiltins in codegen.zig

        self.codegenIntPow();
        self.codegenIntGcd();
        self.codegenIntLcm();
        self.codegenIntFactorial();
        self.codegenIntIsqrt();

        // KoString runtime functions
        self.codegenKoStringFromCstr();
        self.codegenKoStringAlloc();
        self.codegenKoStringIncref();
        self.codegenKoStringDecref();
        self.codegenKoStringData();
        self.codegenKoStringByteLength();

        self.codegenStringLength();
        self.codegenStringAppend();
        self.codegenStringEq();
        self.codegenStringContains();
        self.codegenStringCharAt();
        self.codegenStringToUpper();
        self.codegenStringToLower();
        self.codegenStringTrim();
        self.codegenStringReplace();
        self.codegenStringSplit();
        self.codegenStringStartsWith();
        self.codegenStringEndsWith();
        self.codegenStringSubstring();
        self.codegenStringIndexOf();
        self.codegenIntToString();
        self.codegenFloatToString();
        self.codegenCharToString();
        self.codegenBoolToString();
        self.codegenCharOps();
        self.codegenStringToInt();

        self.codegenFloatOfInt();
        self.codegenFloatToInt();
        self.codegenAllFloatMath();
        self.codegenFloatConstants();
        self.codegenFloatPredicates();

        self.codegenKoAlloc();
        // After codegenKoAlloc: these build Maybe cells with it.
        self.codegenStringToMaybe();
        self.codegenKoIncref();

        // Pre-declare ko_decref so ko_decref_value can call it recursively.
        // ko_decref_value calls ko_decref (recursive field decref).
        // We must declare ko_decref first, then generate ko_decref_value body, then ko_decref body.
        if (core.LLVMGetNamedFunction(self.module, "ko_decref") == null) {
            const fn_type = core.LLVMFunctionType(self.voidType(), @ptrCast(@constCast(&.{self.ptrType()})), 1, 0);
            _ = core.LLVMAddFunction(self.module, "ko_decref", fn_type);
        }

        self.codegenKoDecrefValue();
        self.codegenKoDecrefClosure();
        // ko_decref calls ko_decref_array, whose body needs ko_panic_str and so
        // is emitted later; declare it here so the call site can be built.
        if (core.LLVMGetNamedFunction(self.module, "ko_decref_array") == null) {
            const da_type = core.LLVMFunctionType(self.voidType(), @ptrCast(@constCast(&.{self.ptrType()})), 1, 0);
            _ = core.LLVMAddFunction(self.module, "ko_decref_array", da_type);
        }
        if (core.LLVMGetNamedFunction(self.module, "ko_decref_map") == null) {
            const dm_type = core.LLVMFunctionType(self.voidType(), @ptrCast(@constCast(&.{self.ptrType()})), 1, 0);
            _ = core.LLVMAddFunction(self.module, "ko_decref_map", dm_type);
        }
        self.codegenKoDecref();

        self.codegenCheckedArithOverflow("ko_int_add_checked", "llvm.sadd.with.overflow.i64");
        self.codegenCheckedArithOverflow("ko_int_sub_checked", "llvm.ssub.with.overflow.i64");
        self.codegenCheckedArithOverflow("ko_int_mul_checked", "llvm.smul.with.overflow.i64");
        self.codegenCheckedDivMod("ko_int_div_checked", false);
        self.codegenCheckedDivMod("ko_int_mod_checked", true);
        self.codegenIntNegChecked();
        self.codegenIntDivOr();

        self.codegenInitStack();
        self.codegenCheckStack();
        self.codegenPanic();
        // After codegenPanic: bounds checks call ko_panic_str.
        self.codegenArrayOps();
        self.codegenMapOps();
        self.codegenAssert();
        self.codegenAssertEq();

        // Generate I/O functions (inspect, println_with_tag, print_with_tag)
        self.codegenInspect();
        self.codegenInspectListTail();
        self.codegenPrintlnWithTag();
        self.codegenPrintWithTag();
    }
};
