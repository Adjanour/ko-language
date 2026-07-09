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
            std.mem.eql(u8, name_slice, "ko_string_char_at"))
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
    // External declarations (system calls we can't generate IR for)
    // ============================================================

    pub fn declareExternals(self: *StdlibCodegen) void {
        // malloc(i64) -> ptr
        var malloc_params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const malloc_type = core.LLVMFunctionType(self.ptrType(), &malloc_params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "malloc", malloc_type);

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

        // abort() -> void
        var empty_params: [0]types.LLVMTypeRef = .{};
        const abort_type = core.LLVMFunctionType(self.voidType(), &empty_params, 0, 0);
        _ = core.LLVMAddFunction(self.module, "abort", abort_type);

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
    // String functions
    // ============================================================

    pub fn codegenStringLength(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_string_length", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");
        const null_check = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "null_check");
        const loop = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "loop");
        const done = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "done");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const str = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(str, "str");

        // if str == null, return 0
        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, str, core.LLVMConstNull(self.ptrType()), "is_null");
        self.buildCondBranch(is_null, done, null_check);

        core.LLVMPositionBuilderAtEnd(self.builder, null_check);
        self.buildBranch(loop);

        // loop: len = 0; while str[len] != 0: len++
        core.LLVMPositionBuilderAtEnd(self.builder, loop);
        const len_phi = core.LLVMBuildPhi(self.builder, self.i64Type(), "len");
        var gep_indices: [1]types.LLVMValueRef = .{len_phi};
        const idx = core.LLVMBuildGEP2(self.builder, self.i8Type(), str, @ptrCast(&gep_indices), 1, "idx");
        const ch = core.LLVMBuildLoad2(self.builder, self.i8Type(), idx, "ch");
        const ch_zero = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, ch, core.LLVMConstInt(self.i8Type(), 0, 0), "ch_zero");
        const new_len = core.LLVMBuildAdd(self.builder, len_phi, core.LLVMConstInt(self.i64Type(), 1, 0), "new_len");
        self.buildCondBranch(ch_zero, done, loop);

        var len_vals: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 0, 0), new_len };
        var len_blocks: [2]types.LLVMBasicBlockRef = .{ null_check, loop };
        core.LLVMAddIncoming(len_phi, &len_vals, @ptrCast(&len_blocks), 2);

        // done: return len
        core.LLVMPositionBuilderAtEnd(self.builder, done);
        const final_len = core.LLVMBuildPhi(self.builder, self.i64Type(), "final_len");
        var final_len_vals: [2]types.LLVMValueRef = .{ core.LLVMConstInt(self.i64Type(), 0, 0), len_phi };
        var final_len_blocks: [2]types.LLVMBasicBlockRef = .{ entry, loop };
        core.LLVMAddIncoming(final_len, &final_len_vals, @ptrCast(&final_len_blocks), 2);
        self.buildRet(final_len);
    }

    pub fn codegenStringAppend(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fn_val = self.createFunction("ko_string_append", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const a = core.LLVMGetParam(fn_val, 0);
        const b = core.LLVMGetParam(fn_val, 1);
        core.LLVMSetValueName(a, "a");
        core.LLVMSetValueName(b, "b");

        // len_a = strlen(a)
        const strlen_fn = core.LLVMGetNamedFunction(self.module, "strlen");
        var len_a_args: [1]types.LLVMValueRef = .{a};
        const len_a = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strlen_fn), strlen_fn, &len_a_args, 1, "len_a");

        // len_b = strlen(b)
        var len_b_args: [1]types.LLVMValueRef = .{b};
        const len_b = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(strlen_fn), strlen_fn, &len_b_args, 1, "len_b");

        // total = len_a + len_b + 1
        const total = core.LLVMBuildAdd(self.builder, core.LLVMBuildAdd(self.builder, len_a, len_b, "sum_len"), core.LLVMConstInt(self.i64Type(), 1, 0), "total");

        // buf = malloc(total)
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{total};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");

        // memcpy(buf, a, len_a)
        const memcpy_fn = core.LLVMGetNamedFunction(self.module, "memcpy");
        var memcpy_args: [3]types.LLVMValueRef = .{ buf, a, len_a };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_args, 3, "");

        // memcpy(buf + len_a, b, len_b)
        var buf_offset_idx: [1]types.LLVMValueRef = .{len_a};
        const buf_offset = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(&buf_offset_idx), 1, "buf_offset");
        var memcpy_args2: [3]types.LLVMValueRef = .{ buf_offset, b, len_b };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(memcpy_fn), memcpy_fn, &memcpy_args2, 3, "");

        // buf[total - 1] = 0
        const last_idx = core.LLVMBuildSub(self.builder, total, core.LLVMConstInt(self.i64Type(), 1, 0), "last_idx");
        var last_ptr_idx: [1]types.LLVMValueRef = .{last_idx};
        const last_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), buf, @ptrCast(&last_ptr_idx), 1, "last_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i8Type(), 0, 0), last_ptr);

        self.buildRet(buf);
    }

    // ============================================================
    // Additional String functions (C-backed)
    // ============================================================

    pub fn codegenStringContains(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType() };
        const fn_type = core.LLVMFunctionType(self.i64Type(), &params, 2, 0);
        _ = core.LLVMAddFunction(self.module, "ko_string_contains", fn_type);
    }

    pub fn codegenStringCharAt(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.ptrType(), self.i64Type() };
        const fn_type = core.LLVMFunctionType(self.i64Type(), &params, 2, 0);
        _ = core.LLVMAddFunction(self.module, "ko_string_char_at", fn_type);
    }

    pub fn codegenStringToUpper(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_type = core.LLVMFunctionType(self.ptrType(), &params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "ko_string_to_upper", fn_type);
    }

    pub fn codegenStringToLower(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_type = core.LLVMFunctionType(self.ptrType(), &params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "ko_string_to_lower", fn_type);
    }

    pub fn codegenStringTrim(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_type = core.LLVMFunctionType(self.ptrType(), &params, 1, 0);
        _ = core.LLVMAddFunction(self.module, "ko_string_trim", fn_type);
    }

    pub fn codegenStringReplace(self: *StdlibCodegen) void {
        var params: [3]types.LLVMTypeRef = .{ self.ptrType(), self.ptrType(), self.ptrType() };
        const fn_type = core.LLVMFunctionType(self.ptrType(), &params, 3, 0);
        _ = core.LLVMAddFunction(self.module, "ko_string_replace", fn_type);
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
    // Int toString (using snprintf)
    // ============================================================

    pub fn codegenIntToString(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_int_to_string", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(val, "val");

        // buf = malloc(32)
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 32, 0)};
        const buf = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "buf");

        // snprintf(buf, 32, "%ld", val)
        const snprintf_fn = core.LLVMGetNamedFunction(self.module, "snprintf");
        const fmt_str = self.globalStringConstant("%ld");
        var snprintf_args: [3]types.LLVMValueRef = .{ buf, core.LLVMConstInt(self.i64Type(), 32, 0), fmt_str };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(snprintf_fn), snprintf_fn, &snprintf_args, 3, "");

        self.buildRet(buf);
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

    // ============================================================
    // RC functions
    // ============================================================

    pub fn codegenKoAlloc(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.i64Type()};
        const fn_val = self.createFunction("ko_alloc", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const user_size = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(user_size, "user_size");

        // total = user_size + 8
        const total = core.LLVMBuildAdd(self.builder, user_size, core.LLVMConstInt(self.i64Type(), 8, 0), "total");

        // raw = malloc(total)
        const malloc_fn = core.LLVMGetNamedFunction(self.module, "malloc");
        var malloc_args: [1]types.LLVMValueRef = .{total};
        const raw = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(malloc_fn), malloc_fn, &malloc_args, 1, "raw");

        // Store RC = 1 at offset 0
        const rc_ptr = core.LLVMBuildBitCast(self.builder, raw, self.ptrType(), "rc_ptr");
        _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(self.i64Type(), 1, 0), rc_ptr);

        // Return raw + 8 (skip RC header)
        var user_ptr_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), 8, 0)};
        const user_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), raw, @ptrCast(&user_ptr_idx), 1, "user_ptr");
        self.buildRet(user_ptr);
    }

    pub fn codegenKoIncref(self: *StdlibCodegen) void {
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_incref", self.ptrType(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const ptr = core.LLVMGetParam(fn_val, 0);
        core.LLVMSetValueName(ptr, "ptr");

        // if ptr == null, return null
        const is_null = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, ptr, core.LLVMConstNull(self.ptrType()), "is_null");

        const null_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "null_return");
        const compute_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "compute");
        self.buildCondBranch(is_null, null_block, compute_block);

        core.LLVMPositionBuilderAtEnd(self.builder, null_block);
        self.buildRet(core.LLVMConstNull(self.ptrType()));

        core.LLVMPositionBuilderAtEnd(self.builder, compute_block);
        // rc_ptr = ptr - 8
        var rc_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -8)), 0)};
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
        var params: [1]types.LLVMTypeRef = .{self.ptrType()};
        const fn_val = self.createFunction("ko_decref", self.voidType(), &params);
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

        // rc_ptr = ptr - 8
        core.LLVMPositionBuilderAtEnd(self.builder, check_block);
        var rc_idx: [1]types.LLVMValueRef = .{core.LLVMConstInt(self.i64Type(), @bitCast(@as(i64, -8)), 0)};
        const rc_ptr = core.LLVMBuildGEP2(self.builder, self.i8Type(), ptr, @ptrCast(&rc_idx), 1, "rc_ptr");
        const rc_ptr_typed = core.LLVMBuildBitCast(self.builder, rc_ptr, self.ptrType(), "rc_ptr_typed");

        // Load RC, decrement
        const rc_val = core.LLVMBuildLoad2(self.builder, self.i64Type(), rc_ptr_typed, "rc_val");
        const new_rc = core.LLVMBuildSub(self.builder, rc_val, core.LLVMConstInt(self.i64Type(), 1, 0), "new_rc");
        _ = core.LLVMBuildStore(self.builder, new_rc, rc_ptr_typed);

        // if new_rc <= 0, free
        const should_free = core.LLVMBuildICmp(self.builder, .LLVMIntSLE, new_rc, core.LLVMConstInt(self.i64Type(), 0, 0), "should_free");
        self.buildCondBranch(should_free, free_block, done_block);

        // free(ptr - 8)
        core.LLVMPositionBuilderAtEnd(self.builder, free_block);
        const free_fn = core.LLVMGetNamedFunction(self.module, "free");
        var free_args: [1]types.LLVMValueRef = .{rc_ptr};
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(free_fn), free_fn, &free_args, 1, "");
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

    // ============================================================
    // I/O functions — full LLVM IR generation
    // ============================================================

    pub fn codegenInspect(self: *StdlibCodegen) void {
        var params: [4]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type(), self.ptrType(), self.i64Type() };
        const fn_val = self.createFunction("inspect", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        const type_tag = core.LLVMGetParam(fn_val, 1);
        const name_ptr = core.LLVMGetParam(fn_val, 2);
        const raw = core.LLVMGetParam(fn_val, 3);
        core.LLVMSetValueName(val, "val");
        core.LLVMSetValueName(type_tag, "type_tag");
        core.LLVMSetValueName(name_ptr, "name_ptr");
        core.LLVMSetValueName(raw, "raw");

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

        // ---- case 2: bool — val == 0 ? "True" : "False" (True=tag0, False=tag1) ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[2]);
        const is_true = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, val, core.LLVMConstInt(self.i64Type(), 0, 0), "is_true");
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

        // ---- case 6: constructor — if name_ptr, printf("%s", name_ptr), else printf("Constructor(%ld)", val) ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[6]);
        const ctor_has_name = core.LLVMBuildICmp(self.builder, .LLVMIntNE, name_ptr, core.LLVMConstNull(self.ptrType()), "has_name");
        const ctor_name_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_name");
        const ctor_fallback_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_fallback");
        const ctor_merge = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "ctor_merge");
        self.buildCondBranch(ctor_has_name, ctor_name_block, ctor_fallback_block);

        // ctor_name: printf("%s", name_ptr)
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_name_block);
        var ctor_name_args: [2]types.LLVMValueRef = .{ fmt_s, name_ptr };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &ctor_name_args, 2, "");
        self.buildBranch(ctor_merge);

        // ctor_fallback: printf("Constructor(%ld)", val)
        core.LLVMPositionBuilderAtEnd(self.builder, ctor_fallback_block);
        const fmt_ctor = self.globalStringConstant("Constructor(%ld)");
        var ctor_fb_args: [2]types.LLVMValueRef = .{ fmt_ctor, val };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &ctor_fb_args, 2, "");
        self.buildBranch(ctor_merge);

        core.LLVMPositionBuilderAtEnd(self.builder, ctor_merge);
        self.buildBranch(merge_bb);

        // ---- case 7: record — if name_ptr, printf("%s { ... }", name_ptr), else printf("Record(%ld)", val) ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[7]);
        const rec_has_name = core.LLVMBuildICmp(self.builder, .LLVMIntNE, name_ptr, core.LLVMConstNull(self.ptrType()), "has_name");
        const rec_name_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_name");
        const rec_fallback_block = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_fallback");
        const rec_merge = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "rec_merge");
        self.buildCondBranch(rec_has_name, rec_name_block, rec_fallback_block);

        // rec_name: printf("%s { ... }", name_ptr)
        core.LLVMPositionBuilderAtEnd(self.builder, rec_name_block);
        const fmt_rec = self.globalStringConstant("%s { ... }");
        var rec_name_args: [2]types.LLVMValueRef = .{ fmt_rec, name_ptr };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &rec_name_args, 2, "");
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

        // ---- case 9: tuple — printf("(%ld)", val) ----
        core.LLVMPositionBuilderAtEnd(self.builder, case_bbs[9]);
        const fmt_tuple = self.globalStringConstant("(%ld)");
        var tuple_args: [2]types.LLVMValueRef = .{ fmt_tuple, val };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &tuple_args, 2, "");
        self.buildBranch(merge_bb);

        // ---- default: printf("%ld", val) ----
        core.LLVMPositionBuilderAtEnd(self.builder, default_bb);
        var def_args: [2]types.LLVMValueRef = .{ fmt_ld, val };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &def_args, 2, "");
        self.buildBranch(merge_bb);

        // ---- merge: return val ----
        core.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        self.buildRet(val);
    }

    pub fn codegenPrintlnWithTag(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("println_with_tag", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        const type_tag = core.LLVMGetParam(fn_val, 1);

        // call inspect(val, type_tag, null, 1) — raw=1 for user output
        const inspect_fn = core.LLVMGetNamedFunction(self.module, "inspect");
        var inspect_args: [4]types.LLVMValueRef = .{ val, type_tag, core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 1, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &inspect_args, 4, "");

        // printf("\n")
        const printf_fn = core.LLVMGetNamedFunction(self.module, "printf");
        const newline = self.globalStringConstant("\n");
        var nl_args: [2]types.LLVMValueRef = .{ newline, core.LLVMConstInt(self.i64Type(), 0, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(printf_fn), printf_fn, &nl_args, 2, "");

        self.buildRet(val);
    }

    pub fn codegenPrintWithTag(self: *StdlibCodegen) void {
        var params: [2]types.LLVMTypeRef = .{ self.i64Type(), self.i64Type() };
        const fn_val = self.createFunction("print_with_tag", self.i64Type(), &params);
        const entry = core.LLVMAppendBasicBlockInContext(self.context, fn_val, "entry");

        core.LLVMPositionBuilderAtEnd(self.builder, entry);
        const val = core.LLVMGetParam(fn_val, 0);
        const type_tag = core.LLVMGetParam(fn_val, 1);

        // call inspect(val, type_tag, null, 1) — raw=1 for user output
        const inspect_fn = core.LLVMGetNamedFunction(self.module, "inspect");
        var inspect_args: [4]types.LLVMValueRef = .{ val, type_tag, core.LLVMConstNull(self.ptrType()), core.LLVMConstInt(self.i64Type(), 1, 0) };
        _ = core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(inspect_fn), inspect_fn, &inspect_args, 4, "");

        self.buildRet(val);
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

        self.codegenStringLength();
        self.codegenStringAppend();
        self.codegenStringContains();
        self.codegenStringCharAt();
        self.codegenStringToUpper();
        self.codegenStringToLower();
        self.codegenStringTrim();
        self.codegenStringReplace();
        self.codegenIntToString();
        self.codegenStringToInt();

        self.codegenFloatOfInt();
        self.codegenFloatToInt();
        self.codegenAllFloatMath();

        self.codegenKoAlloc();
        self.codegenKoIncref();
        self.codegenKoDecref();

        self.codegenInitStack();
        self.codegenCheckStack();

        // Generate I/O functions (inspect, println_with_tag, print_with_tag)
        self.codegenInspect();
        self.codegenPrintlnWithTag();
        self.codegenPrintWithTag();
    }
};
