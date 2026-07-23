//! LIR → LLVM IR code generator (Phase 5a).
//!
//! Maps the machine-oriented LIR (basic blocks with parameters, explicit
//! memory and reference-counting operations) onto LLVM IR. Each LIR
//! instruction lowers to a small, fixed LLVM sequence — all high-level
//! decisions (closure conversion, match compilation, RC placement) have
//! already been made by earlier passes.
//!
//! Design notes:
//! - Block parameters are realized as LLVM phi nodes. Branch terminators
//!   carry block arguments (`BrTarget.args`); emitting a branch adds the
//!   matching incoming edges to the successor's phis.
//! - `incref`/`decref` map to the shared runtime (`ko_incref`/`ko_decref`,
//!   emitted into the module by `StdlibCodegen`, same as the legacy path).
//! - `is_unique` is emitted inline: the RC header is the i64 stored 8 bytes
//!   before the user pointer (see `stdlib_codegen.codegenKoAlloc`), so
//!   `is_unique(p)` becomes `load i64 (gep i8 p, -8) == 1`. This is the
//!   Perceus fast-path test; it needs no runtime support.
//! - Closures are heap structs `{ ptr fn, cap0, cap1, ... }` allocated with
//!   `ko_alloc` (provisional representation; closure conversion in the LIR
//!   lowering pass owns the final layout).

const std = @import("std");
const llvm = @import("llvm");
const core = llvm.core;
const analysis = llvm.analysis;
const types = llvm.types;
const target = llvm.target;
const target_machine = llvm.target_machine;
const lir = @import("lir.zig");
const hir = @import("hir.zig");
const stdlib_codegen = @import("stdlib_codegen.zig");

pub const CodegenError = error{
    UndefinedLocal,
    UndefinedFunction,
    UndefinedBlock,
    ExpectedPointerType,
    BlockArgArityMismatch,
    UnsupportedPrimOp,
    VerifierFailed,
} || std.mem.Allocator.Error;

/// A (predecessor, target) control-flow edge in the current function.
const Edge = struct {
    pred: types.LLVMBasicBlockRef,
    target: lir.BlockId,
};

/// A deferred trampoline block splitting a duplicate edge.
const Trampoline = struct {
    tramp: types.LLVMBasicBlockRef,
    t: lir.BrTarget,
};

pub const CodegenLir = struct {
    allocator: std.mem.Allocator,
    context: types.LLVMContextRef,
    module: types.LLVMModuleRef,
    builder: types.LLVMBuilderRef,
    /// LocalId → LLVM value for the function currently being emitted.
    locals: std.AutoHashMap(lir.LocalId, types.LLVMValueRef),
    /// BlockId → LLVM basic block for the function currently being emitted.
    blocks: std.AutoHashMap(lir.BlockId, types.LLVMBasicBlockRef),
    /// BlockId → phi nodes realizing that block's parameters (positional).
    block_phis: std.AutoHashMap(lir.BlockId, []types.LLVMValueRef),
    /// Types of the current function's locals (indexed by LocalId).
    local_types: []const lir.LirType = &.{},
    /// LLVM function currently being emitted (for trampoline creation).
    current_fn: ?types.LLVMValueRef = null,
    /// Edges already emitted in the current function; detects duplicates.
    emitted_edges: std.AutoHashMap(Edge, void),
    /// Trampoline blocks deferred until all source blocks are emitted.
    pending_tramps: std.ArrayList(Trampoline),
    module_owned_by_jit: bool = false,

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) CodegenLir {
        const ctx = core.LLVMContextCreate();
        const mod = core.LLVMModuleCreateWithNameInContext(module_name, ctx);
        // Same data layout / triple as the legacy codegen so type sizes match.
        core.LLVMSetDataLayout(mod, "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128");
        _ = target.LLVMInitializeNativeTarget();
        const triple = target_machine.LLVMGetDefaultTargetTriple();
        defer core.LLVMDisposeMessage(@ptrCast(triple));
        core.LLVMSetTarget(mod, triple);
        return .{
            .allocator = allocator,
            .context = ctx,
            .module = mod,
            .builder = core.LLVMCreateBuilderInContext(ctx),
            .locals = std.AutoHashMap(lir.LocalId, types.LLVMValueRef).init(allocator),
            .blocks = std.AutoHashMap(lir.BlockId, types.LLVMBasicBlockRef).init(allocator),
            .block_phis = std.AutoHashMap(lir.BlockId, []types.LLVMValueRef).init(allocator),
            .emitted_edges = std.AutoHashMap(Edge, void).init(allocator),
            .pending_tramps = .empty,
        };
    }

    pub fn deinit(self: *CodegenLir) void {
        self.pending_tramps.deinit(self.allocator);
        self.emitted_edges.deinit();
        self.block_phis.deinit();
        self.blocks.deinit();
        self.locals.deinit();
        core.LLVMDisposeBuilder(self.builder);
        if (!self.module_owned_by_jit) {
            core.LLVMDisposeModule(self.module);
        }
        core.LLVMContextDispose(self.context);
    }

    /// Emit the shared Kō runtime (ko_alloc / ko_incref / ko_decref, string
    /// functions, ...) into the module so LIR programs can call it.
    pub fn declareRuntime(self: *CodegenLir) void {
        var scg = stdlib_codegen.StdlibCodegen.init(self.context, self.module, self.builder, self.allocator);
        stdlib_codegen.StdlibCodegen.generateAll(&scg);
    }

    /// Verify the whole module; dumps the verifier message on failure.
    pub fn verify(self: *CodegenLir) CodegenError!void {
        var msg: [*c]u8 = null;
        const failed = analysis.LLVMVerifyModule(self.module, .LLVMReturnStatusAction, &msg);
        if (failed != 0) {
            if (msg != null) {
                std.debug.print("LIR module verification failed:\n{s}\n", .{std.mem.sliceTo(msg, 0)});
                core.LLVMDisposeMessage(@ptrCast(msg));
            }
            return error.VerifierFailed;
        }
    }

    /// Module IR as text (caller frees the returned slice).
    pub fn printToString(self: *CodegenLir) ![]const u8 {
        const s = core.LLVMPrintModuleToString(self.module);
        defer core.LLVMDisposeMessage(@ptrCast(s));
        return try self.allocator.dupe(u8, std.mem.sliceTo(s, 0));
    }

    fn dupeZ(self: *CodegenLir, s: []const u8) ![*:0]const u8 {
        return try self.allocator.dupeZ(u8, s);
    }

    // =================================================================
    // Types
    // =================================================================

    pub fn lirType(self: *CodegenLir, ty: lir.LirType) CodegenError!types.LLVMTypeRef {
        return switch (ty) {
            .int => core.LLVMInt64TypeInContext(self.context),
            .float => core.LLVMDoubleTypeInContext(self.context),
            .bool => core.LLVMInt1TypeInContext(self.context),
            .char => core.LLVMInt8TypeInContext(self.context),
            // Unit is represented as the i64 constant 0, like the legacy path.
            .unit => core.LLVMInt64TypeInContext(self.context),
            // Strings are null-terminated i8* (C-runtime compatible).
            .string => core.LLVMPointerTypeInContext(self.context, 0),
            .ptr => core.LLVMPointerTypeInContext(self.context, 0),
            .opaque_type => core.LLVMPointerTypeInContext(self.context, 0),
            .function => core.LLVMPointerTypeInContext(self.context, 0),
            .struct_ => |fields| blk: {
                const field_types = try self.allocator.alloc(types.LLVMTypeRef, fields.len);
                defer self.allocator.free(field_types);
                for (fields, 0..) |f, i| field_types[i] = try self.lirType(f);
                break :blk core.LLVMStructTypeInContext(self.context, field_types.ptr, @intCast(fields.len), 0);
            },
            .array => |arr| core.LLVMArrayType(try self.lirType(arr.elem.*), @intCast(arr.len)),
        };
    }

    pub fn lirFnType(self: *CodegenLir, ft: lir.LirFnType) CodegenError!types.LLVMTypeRef {
        const param_types = try self.allocator.alloc(types.LLVMTypeRef, ft.params.len);
        defer self.allocator.free(param_types);
        for (ft.params, 0..) |p, i| param_types[i] = try self.lirType(p);
        return core.LLVMFunctionType(try self.lirType(ft.returns), param_types.ptr, @intCast(ft.params.len), 0);
    }

    // =================================================================
    // Functions
    // =================================================================

    /// Declare a top-level LIR function (or reuse an existing declaration,
    /// e.g. a runtime function emitted by `declareRuntime`).
    pub fn declareFn(self: *CodegenLir, lfn: *const lir.LirFn) CodegenError!types.LLVMValueRef {
        const name_z = try self.dupeZ(lfn.name);
        if (core.LLVMGetNamedFunction(self.module, name_z)) |existing| return existing;
        const param_types = try self.allocator.alloc(types.LLVMTypeRef, lfn.params.len);
        defer self.allocator.free(param_types);
        for (lfn.params, 0..) |pid, i| param_types[i] = try self.lirType(lfn.locals[pid]);
        const ft = core.LLVMFunctionType(try self.lirType(lfn.return_type), param_types.ptr, @intCast(lfn.params.len), 0);
        return core.LLVMAddFunction(self.module, name_z, ft);
    }

    /// Two-pass codegen: declare all functions, then emit bodies.
    pub fn codegenProgram(self: *CodegenLir, prog: []const lir.LirFn) CodegenError!void {
        for (prog) |*lfn| _ = try self.declareFn(lfn);
        for (prog) |*lfn| try self.codegenFn(lfn);
    }

    /// Emit one function body. Two passes over the blocks: create all blocks
    /// and parameter phis first, then emit statements and terminators.
    pub fn codegenFn(self: *CodegenLir, lfn: *const lir.LirFn) CodegenError!void {
        const fn_val = try self.declareFn(lfn);

        self.locals.clearRetainingCapacity();
        self.blocks.clearRetainingCapacity();
        self.emitted_edges.clearRetainingCapacity();
        self.pending_tramps.clearRetainingCapacity();
        self.local_types = lfn.locals;
        self.current_fn = fn_val;

        // Bind function parameters to their locals.
        for (lfn.params, 0..) |pid, i| {
            try self.locals.put(pid, core.LLVMGetParam(fn_val, @intCast(i)));
        }

        // Pass A: create all basic blocks.
        for (lfn.blocks) |blk| {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrintZ(&name_buf, "bb{d}", .{blk.id}) catch "block";
            const bb = core.LLVMAppendBasicBlockInContext(self.context, fn_val, name);
            try self.blocks.put(blk.id, bb);
        }

        // Pass A': create a phi node for each block parameter.
        for (lfn.blocks) |blk| {
            if (blk.params.len == 0) continue;
            const bb = self.blocks.get(blk.id).?;
            core.LLVMPositionBuilderAtEnd(self.builder, bb);
            const phis = try self.allocator.alloc(types.LLVMValueRef, blk.params.len);
            for (blk.params, 0..) |pid, i| {
                var name_buf: [32]u8 = undefined;
                const name = std.fmt.bufPrintZ(&name_buf, "v{d}", .{pid}) catch "param";
                phis[i] = core.LLVMBuildPhi(self.builder, try self.lirType(lfn.locals[pid]), name);
                try self.locals.put(pid, phis[i]);
            }
            try self.block_phis.put(blk.id, phis);
        }

        // Pass B: emit statements and terminators.
        for (lfn.blocks) |blk| {
            const bb = self.blocks.get(blk.id).?;
            // Positions after any phis created above.
            core.LLVMPositionBuilderAtEnd(self.builder, bb);
            for (blk.body) |stmt| try self.codegenStmt(stmt);
            try self.codegenTerminator(blk.terminator, bb);
        }

        // Emit deferred trampoline blocks for duplicate edges.
        try self.emitTrampolines();

        // Free per-function phi slices.
        var it = self.block_phis.valueIterator();
        while (it.next()) |slice| self.allocator.free(slice.*);
        self.block_phis.clearRetainingCapacity();

        // Verify the function we just emitted (only our own IR — runtime
        // functions emitted by StdlibCodegen are checked by their own path).
        if (analysis.LLVMVerifyFunction(fn_val, .LLVMReturnStatusAction) != 0) {
            std.debug.print("verification failed for LIR function '{s}':\n", .{lfn.name});
            core.LLVMDumpValue(fn_val);
            return error.VerifierFailed;
        }
    }

    // =================================================================
    // Statements
    // =================================================================

    fn codegenStmt(self: *CodegenLir, stmt: lir.LirStmt) CodegenError!void {
        switch (stmt) {
            .assign => |a| {
                const v = try self.codegenValue(&a.value);
                try self.locals.put(a.dest, v);
            },
            .store => |s| {
                const dest = self.locals.get(s.dest) orelse return error.UndefinedLocal;
                const val = self.locals.get(s.value) orelse return error.UndefinedLocal;
                _ = core.LLVMBuildStore(self.builder, val, dest);
            },
            .effect => |v| {
                _ = try self.codegenValue(&v);
            },
        }
    }

    // =================================================================
    // Values
    // =================================================================

    fn codegenValue(self: *CodegenLir, val: *const lir.LirValue) CodegenError!types.LLVMValueRef {
        return switch (val.*) {
            .int => |v| core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @bitCast(v), 1),
            .float => |v| core.LLVMConstReal(core.LLVMDoubleTypeInContext(self.context), v),
            .bool => |v| core.LLVMConstInt(core.LLVMInt1TypeInContext(self.context), @intFromBool(v), 0),
            .char => |v| core.LLVMConstInt(core.LLVMInt8TypeInContext(self.context), v, 0),
            .string => |s| core.LLVMBuildGlobalStringPtr(self.builder, try self.dupeZ(s.ptr), "str"),
            .local => |id| self.locals.get(id) orelse error.UndefinedLocal,
            .fn_ref => |name| core.LLVMGetNamedFunction(self.module, try self.dupeZ(name)) orelse error.UndefinedFunction,
            .alloc => |ty| try self.codegenAlloc(try self.lirType(ty)),
            .alloc_stack => |ty| core.LLVMBuildAlloca(self.builder, try self.lirType(ty), "stack"),
            .load => |id| try self.codegenLoad(id),
            .incref => |id| try self.codegenRcCall("ko_incref", id),
            .decref => |id| try self.codegenRcCall("ko_decref", id),
            .is_unique => |id| try self.codegenIsUnique(id),
            .call => |c| try self.codegenCall(c),
            .make_closure => |mc| try self.codegenMakeClosure(mc),
            .extract_value => |ev| blk: {
                const agg = self.locals.get(ev.aggregate) orelse return error.UndefinedLocal;
                break :blk core.LLVMBuildExtractValue(self.builder, agg, @intCast(ev.index), "extract");
            },
            .insert_value => |iv| blk: {
                const agg = self.locals.get(iv.aggregate) orelse return error.UndefinedLocal;
                const v = self.locals.get(iv.value) orelse return error.UndefinedLocal;
                break :blk core.LLVMBuildInsertValue(self.builder, agg, v, @intCast(iv.index), "insert");
            },
            .get_element_ptr => |g| try self.codegenGep(g),
            .ptrtoint => |id| blk: {
                const v = self.locals.get(id) orelse return error.UndefinedLocal;
                break :blk core.LLVMBuildPtrToInt(self.builder, v, core.LLVMInt64TypeInContext(self.context), "p2i");
            },
            .inttoptr => |it| blk: {
                const v = self.locals.get(it.val) orelse return error.UndefinedLocal;
                break :blk core.LLVMBuildIntToPtr(self.builder, v, try self.lirType(it.ty), "i2p");
            },
            .zext => |c| blk: {
                const v = self.locals.get(c.val) orelse return error.UndefinedLocal;
                break :blk core.LLVMBuildZExt(self.builder, v, try self.lirType(c.ty), "zext");
            },
            .trunc => |c| blk: {
                const v = self.locals.get(c.val) orelse return error.UndefinedLocal;
                break :blk core.LLVMBuildTrunc(self.builder, v, try self.lirType(c.ty), "trunc");
            },
            .bitcast => |c| blk: {
                const v = self.locals.get(c.val) orelse return error.UndefinedLocal;
                break :blk core.LLVMBuildBitCast(self.builder, v, try self.lirType(c.ty), "bc");
            },
            .primop => |p| try self.codegenPrimop(p),
        };
    }

    /// `alloc(T)` → `call ko_alloc(sizeof(T))` (returns an untyped ptr).
    fn codegenAlloc(self: *CodegenLir, llvm_ty: types.LLVMTypeRef) CodegenError!types.LLVMValueRef {
        const alloc_fn = core.LLVMGetNamedFunction(self.module, "ko_alloc") orelse return error.UndefinedFunction;
        const dl = target.LLVMGetModuleDataLayout(self.module);
        const size = target.LLVMStoreSizeOfType(dl, llvm_ty);
        var args = [1]types.LLVMValueRef{core.LLVMConstInt(core.LLVMInt64TypeInContext(self.context), @intCast(size), 0)};
        return core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(alloc_fn), alloc_fn, &args, 1, "");
    }

    /// `load(p)` — the element type comes from the local's `ptr(T)` LIR type.
    fn codegenLoad(self: *CodegenLir, id: lir.LocalId) CodegenError!types.LLVMValueRef {
        const ptr = self.locals.get(id) orelse return error.UndefinedLocal;
        if (id >= self.local_types.len) return error.UndefinedLocal;
        const elem = switch (self.local_types[id]) {
            .ptr => |elem| elem,
            else => return error.ExpectedPointerType,
        };
        return core.LLVMBuildLoad2(self.builder, try self.lirType(elem.*), ptr, "load");
    }

    /// `incref`/`decref` → call the shared runtime function.
    fn codegenRcCall(self: *CodegenLir, comptime name: [*:0]const u8, id: lir.LocalId) CodegenError!types.LLVMValueRef {
        const rc_fn = core.LLVMGetNamedFunction(self.module, name) orelse return error.UndefinedFunction;
        const ptr = self.locals.get(id) orelse return error.UndefinedLocal;
        var args = [1]types.LLVMValueRef{ptr};
        return core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(rc_fn), rc_fn, &args, 1, "");
    }

    /// `is_unique(p)` → `load i64 (gep i8 p, -8) == 1` — inlined Perceus
    /// fast-path uniqueness test over the RC header (no runtime call).
    fn codegenIsUnique(self: *CodegenLir, id: lir.LocalId) CodegenError!types.LLVMValueRef {
        const ptr = self.locals.get(id) orelse return error.UndefinedLocal;
        const i64_type = core.LLVMInt64TypeInContext(self.context);
        var idx = [1]types.LLVMValueRef{core.LLVMConstInt(i64_type, @bitCast(@as(i64, -8)), 0)};
        const rc_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), ptr, &idx, 1, "rc_ptr");
        const rc = core.LLVMBuildLoad2(self.builder, i64_type, rc_ptr, "rc");
        return core.LLVMBuildICmp(self.builder, .LLVMIntEQ, rc, core.LLVMConstInt(i64_type, 1, 0), "is_unique");
    }

    fn codegenCall(self: *CodegenLir, c: lir.CallValue) CodegenError!types.LLVMValueRef {
        const func = self.locals.get(c.func) orelse return error.UndefinedLocal;
        const args = try self.allocator.alloc(types.LLVMValueRef, c.args.len);
        defer self.allocator.free(args);
        for (c.args, 0..) |a, i| args[i] = self.locals.get(a) orelse return error.UndefinedLocal;
        return core.LLVMBuildCall2(self.builder, try self.lirFnType(c.fn_type), func, args.ptr, @intCast(args.len), "");
    }

    /// `make_closure(fn, captures)` → heap struct `{ ptr fn, cap0, ... }`.
    fn codegenMakeClosure(self: *CodegenLir, mc: lir.MakeClosure) CodegenError!types.LLVMValueRef {
        const fn_val = core.LLVMGetNamedFunction(self.module, try self.dupeZ(mc.fn_name)) orelse return error.UndefinedFunction;
        const field_types = try self.allocator.alloc(types.LLVMTypeRef, mc.captures.len + 1);
        defer self.allocator.free(field_types);
        field_types[0] = core.LLVMPointerTypeInContext(self.context, 0);
        for (mc.captures, 1..) |cap, i| {
            if (cap >= self.local_types.len) return error.UndefinedLocal;
            field_types[i] = try self.lirType(self.local_types[cap]);
        }
        const closure_ty = core.LLVMStructTypeInContext(self.context, field_types.ptr, @intCast(field_types.len), 0);
        const raw = try self.codegenAlloc(closure_ty);

        // Store the function pointer and each captured value.
        const i32_type = core.LLVMInt32TypeInContext(self.context);
        var fn_idx = [2]types.LLVMValueRef{ core.LLVMConstInt(i32_type, 0, 0), core.LLVMConstInt(i32_type, 0, 0) };
        const fn_slot = core.LLVMBuildGEP2(self.builder, closure_ty, raw, &fn_idx, 2, "fn_slot");
        _ = core.LLVMBuildStore(self.builder, fn_val, fn_slot);
        for (mc.captures, 1..) |cap, i| {
            const v = self.locals.get(cap) orelse return error.UndefinedLocal;
            var idx = [2]types.LLVMValueRef{ core.LLVMConstInt(i32_type, 0, 0), core.LLVMConstInt(i32_type, @intCast(i), 0) };
            const slot = core.LLVMBuildGEP2(self.builder, closure_ty, raw, &idx, 2, "cap_slot");
            _ = core.LLVMBuildStore(self.builder, v, slot);
        }
        return raw;
    }

    fn codegenGep(self: *CodegenLir, g: lir.GetElementPtr) CodegenError!types.LLVMValueRef {
        const ptr = self.locals.get(g.ptr) orelse return error.UndefinedLocal;
        const elem_llvm = try self.lirType(g.elem_type);
        // LLVM requires struct GEP indices to be i32 (constants fold; our
        // struct indices are always constant locals). Pointer/array GEPs
        // keep the i64 indices as-is.
        const need_i32 = core.LLVMGetTypeKind(elem_llvm) == .LLVMStructTypeKind;
        const indices = try self.allocator.alloc(types.LLVMValueRef, g.indices.len);
        defer self.allocator.free(indices);
        for (g.indices, 0..) |ix, i| {
            const v = self.locals.get(ix) orelse return error.UndefinedLocal;
            indices[i] = if (need_i32)
                core.LLVMBuildTrunc(self.builder, v, core.LLVMInt32TypeInContext(self.context), "idx32")
            else
                v;
        }
        return core.LLVMBuildGEP2(self.builder, elem_llvm, ptr, indices.ptr, @intCast(indices.len), "gep");
    }

    /// Primitive operations. Arithmetic/comparison selects integer or float
    /// instructions based on the operand type. `bitcast` is a no-op
    /// passthrough (opaque pointers make ptr→ptr casts identity).
    fn codegenPrimop(self: *CodegenLir, p: lir.PrimOpValue) CodegenError!types.LLVMValueRef {
        if (p.op == .not_) {
            if (p.args.len != 1) return error.UnsupportedPrimOp;
            const v = self.locals.get(p.args[0]) orelse return error.UndefinedLocal;
            return core.LLVMBuildXor(self.builder, v, core.LLVMConstInt(core.LLVMInt1TypeInContext(self.context), 1, 0), "not");
        }
        if (p.op == .ptrtoint) {
            if (p.args.len != 1) return error.UnsupportedPrimOp;
            const v = self.locals.get(p.args[0]) orelse return error.UndefinedLocal;
            return core.LLVMBuildPtrToInt(self.builder, v, core.LLVMInt64TypeInContext(self.context), "p2i");
        }
        if (p.op == .inttoptr) {
            if (p.args.len != 1) return error.UnsupportedPrimOp;
            const v = self.locals.get(p.args[0]) orelse return error.UndefinedLocal;
            return core.LLVMBuildIntToPtr(self.builder, v, core.LLVMPointerTypeInContext(self.context, 0), "i2p");
        }
        if (p.op == .bitcast) {
            if (p.args.len != 1) return error.UnsupportedPrimOp;
            return self.locals.get(p.args[0]) orelse error.UndefinedLocal;
        }
        if (p.args.len != 2) return error.UnsupportedPrimOp;
        const lhs = self.locals.get(p.args[0]) orelse return error.UndefinedLocal;
        const rhs = self.locals.get(p.args[1]) orelse return error.UndefinedLocal;

        if (p.op == .concat) {
            const append_fn = core.LLVMGetNamedFunction(self.module, "ko_string_append") orelse return error.UndefinedFunction;
            var args = [2]types.LLVMValueRef{ lhs, rhs };
            return core.LLVMBuildCall2(self.builder, core.LLVMGlobalGetValueType(append_fn), append_fn, &args, 2, "concat");
        }

        const is_float = core.LLVMGetTypeKind(core.LLVMTypeOf(lhs)) == .LLVMDoubleTypeKind;
        return switch (p.op) {
            .add => if (is_float) core.LLVMBuildFAdd(self.builder, lhs, rhs, "fadd") else core.LLVMBuildAdd(self.builder, lhs, rhs, "add"),
            .sub => if (is_float) core.LLVMBuildFSub(self.builder, lhs, rhs, "fsub") else core.LLVMBuildSub(self.builder, lhs, rhs, "sub"),
            .mul => if (is_float) core.LLVMBuildFMul(self.builder, lhs, rhs, "fmul") else core.LLVMBuildMul(self.builder, lhs, rhs, "mul"),
            .div => if (is_float) core.LLVMBuildFDiv(self.builder, lhs, rhs, "fdiv") else core.LLVMBuildSDiv(self.builder, lhs, rhs, "sdiv"),
            .rem => if (is_float) core.LLVMBuildFRem(self.builder, lhs, rhs, "frem") else core.LLVMBuildSRem(self.builder, lhs, rhs, "srem"),
            .eq => if (is_float) core.LLVMBuildFCmp(self.builder, .LLVMRealOEQ, lhs, rhs, "feq") else core.LLVMBuildICmp(self.builder, .LLVMIntEQ, lhs, rhs, "eq"),
            .neq => if (is_float) core.LLVMBuildFCmp(self.builder, .LLVMRealONE, lhs, rhs, "fne") else core.LLVMBuildICmp(self.builder, .LLVMIntNE, lhs, rhs, "ne"),
            .lt => if (is_float) core.LLVMBuildFCmp(self.builder, .LLVMRealOLT, lhs, rhs, "flt") else core.LLVMBuildICmp(self.builder, .LLVMIntSLT, lhs, rhs, "lt"),
            .le => if (is_float) core.LLVMBuildFCmp(self.builder, .LLVMRealOLE, lhs, rhs, "fle") else core.LLVMBuildICmp(self.builder, .LLVMIntSLE, lhs, rhs, "le"),
            .gt => if (is_float) core.LLVMBuildFCmp(self.builder, .LLVMRealOGT, lhs, rhs, "fgt") else core.LLVMBuildICmp(self.builder, .LLVMIntSGT, lhs, rhs, "gt"),
            .ge => if (is_float) core.LLVMBuildFCmp(self.builder, .LLVMRealOGE, lhs, rhs, "fge") else core.LLVMBuildICmp(self.builder, .LLVMIntSGE, lhs, rhs, "ge"),
            .and_ => core.LLVMBuildAnd(self.builder, lhs, rhs, "and"),
            .or_ => core.LLVMBuildOr(self.builder, lhs, rhs, "or"),
            else => error.UnsupportedPrimOp,
        };
    }

    // =================================================================
    // Terminators
    // =================================================================

    fn codegenTerminator(self: *CodegenLir, term: lir.LirTerminator, bb: types.LLVMBasicBlockRef) CodegenError!void {
        switch (term) {
            .br => |t| {
                const target_bb = try self.resolveEdge(t, bb);
                _ = core.LLVMBuildBr(self.builder, target_bb);
            },
            .cond_br => |c| {
                const cond = self.locals.get(c.cond) orelse return error.UndefinedLocal;
                const then_bb = try self.resolveEdge(c.then, bb);
                const else_bb = try self.resolveEdge(c.else_, bb);
                _ = core.LLVMBuildCondBr(self.builder, cond, then_bb, else_bb);
            },
            .switch_ => |s| {
                const val = self.locals.get(s.val) orelse return error.UndefinedLocal;
                const default_bb = try self.resolveEdge(s.default, bb);
                const sw = core.LLVMBuildSwitch(self.builder, val, default_bb, @intCast(s.cases.len));
                for (s.cases) |case| {
                    const case_bb = try self.resolveEdge(case.target, bb);
                    const on = core.LLVMConstInt(core.LLVMTypeOf(val), @bitCast(case.tag), 0);
                    core.LLVMAddCase(sw, on, case_bb);
                }
            },
            .ret => |id| {
                const v = self.locals.get(id) orelse return error.UndefinedLocal;
                _ = core.LLVMBuildRet(self.builder, v);
            },
            .unreachable_ => {
                _ = core.LLVMBuildUnreachable(self.builder);
            },
            .tail_call => |c| {
                const call = try self.codegenCall(c);
                core.LLVMSetTailCall(call, 1);
                if (core.LLVMGetTypeKind(core.LLVMTypeOf(call)) == .LLVMVoidTypeKind) {
                    _ = core.LLVMBuildRetVoid(self.builder);
                } else {
                    _ = core.LLVMBuildRet(self.builder, call);
                }
            },
        }
    }

    /// Add incoming (value, predecessor) edges to a branch target's
    /// parameter phis. No-op when the target block has no parameters.
    fn addIncoming(self: *CodegenLir, t: lir.BrTarget, pred: types.LLVMBasicBlockRef) CodegenError!void {
        const phis = self.block_phis.get(t.target) orelse return;
        if (t.args.len != phis.len) return error.BlockArgArityMismatch;
        for (phis, t.args) |phi, arg| {
            var values = [1]types.LLVMValueRef{self.locals.get(arg) orelse return error.UndefinedLocal};
            var preds = [1]types.LLVMBasicBlockRef{pred};
            core.LLVMAddIncoming(phi, &values, &preds, 1);
        }
    }

    /// Resolve a branch edge to the LLVM block the branch instruction should
    /// target. The first (pred → target) edge adds phi incoming values
    /// directly; a duplicate edge to a block with parameters is split
    /// through a fresh trampoline block, because LLVM phi nodes cannot hold
    /// two entries for the same predecessor with different values (this is
    /// critical-edge splitting, done lazily only where needed).
    fn resolveEdge(self: *CodegenLir, t: lir.BrTarget, pred: types.LLVMBasicBlockRef) CodegenError!types.LLVMBasicBlockRef {
        const real_target = self.blocks.get(t.target) orelse return error.UndefinedBlock;
        const key = Edge{ .pred = pred, .target = t.target };
        const duplicate = self.emitted_edges.contains(key);
        try self.emitted_edges.put(key, {});
        if (!duplicate or !self.block_phis.contains(t.target)) {
            try self.addIncoming(t, pred);
            return real_target;
        }
        const tramp = core.LLVMAppendBasicBlockInContext(self.context, self.current_fn.?, "tramp");
        try self.pending_tramps.append(self.allocator, .{ .tramp = tramp, .t = t });
        return tramp;
    }

    /// Emit deferred trampoline blocks: each forwards its block arguments to
    /// the real target, giving duplicate edges distinct predecessors.
    fn emitTrampolines(self: *CodegenLir) CodegenError!void {
        for (self.pending_tramps.items) |tramp| {
            core.LLVMPositionBuilderAtEnd(self.builder, tramp.tramp);
            const real_target = self.blocks.get(tramp.t.target) orelse return error.UndefinedBlock;
            try self.addIncoming(tramp.t, tramp.tramp);
            _ = core.LLVMBuildBr(self.builder, real_target);
        }
        self.pending_tramps.clearRetainingCapacity();
    }
};
