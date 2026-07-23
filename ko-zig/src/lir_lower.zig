//! HIR → LIR lowering (Phase 5b).
//!
//! Lowers the functional, ANF-shaped HIR onto the explicit-control-flow LIR:
//! - `let` bindings become straight-line local assignments
//! - `if`/`match` become basic blocks with parameters (SSA via block args)
//! - lambdas become curried unary closures: each lifted fn takes
//!   `(captures_ptr, one_param)`; a closure is `{ fn_ptr, cap0, ... }`
//!   (same convention as the legacy backend: apply one arg at a time)
//! - constructors adopt the legacy runtime representation so output matches:
//!   zero-arg → raw i64 tag; multi-arg → ptrtoint of `{ i64 tag, i64 fields… }`
//! - records/tuples are typed structs behind opaque pointers
//! - `println`/`print`/`inspect` use the legacy `*_with_tag` calling
//!   convention (value as i64, type tag, ctor/record name ptr, 0)
//!
//! Documented gaps (deferred): partial application of top-level fns and
//! constructors, top-level `let` bindings, `comptime` in the LIR path,
//! string literal patterns.

const std = @import("std");
const hir = @import("hir.zig");
const lir = @import("lir.zig");
const typecheck = @import("typecheck.zig");
const hir_lower = @import("hir_lower.zig");

pub const LowerError = error{
    Unsupported,
    UndefinedLocal,
    UndefinedGlobal,
    ArityMismatch,
    TypeError,
} || std.mem.Allocator.Error;

const CtorEntry = struct {
    tag: i64,
    arity: usize,
    type_name: []const u8,
};

const GlobalKind = enum { user_fn, ctor, std_fn, std_special };

const GlobalEntry = struct {
    arity: usize,
    kind: GlobalKind,
};

/// A basic block under construction (finalized into `lir.BasicBlock`).
const BlockBuilder = struct {
    id: lir.BlockId,
    params: []const lir.LocalId,
    body: std.ArrayList(lir.LirStmt) = .empty,
    term: ?lir.LirTerminator = null,
};

/// Per-function emission state; saved/restored around nested lambda lifting.
const FnState = struct {
    locals: std.ArrayList(lir.LirType) = .empty,
    blocks: std.ArrayList(BlockBuilder) = .empty,
    hir_map: std.AutoHashMap(hir.LocalVarId, lir.LocalId),
    current: usize = 0,
    next_block: lir.BlockId = 0,
};

const Binding = union(enum) {
    /// Direct alias between a hir local and an existing lir local.
    alias: struct { hir_lv: hir.LocalVarId, lir_local: lir.LocalId },
    /// A field that must be loaded (GEP + load) from an ADT scrutinee,
    /// deferred to when the arm body is entered (safe for mixed-arity ADTs).
    field: struct { hir_lv: hir.LocalVarId, scrut_local: lir.LocalId, field_index: usize, ctor_arity: usize, field_ty: typecheck.Type },
};

const ParamInfo = struct {
    hir_lv: hir.LocalVarId,
    lir_ty: lir.LirType,
};

const CapInfo = struct {
    hir_lv: hir.LocalVarId,
    lir_ty: lir.LirType,
};

/// What the innermost curried level evaluates.
const Leaf = union(enum) {
    /// Lower a HIR body (ordinary lambda).
    hir_body: hir.HirId,
    /// Direct-call a top-level fn with all accumulated params (curry
    /// trampoline for globals used as values).
    direct_call: []const u8,
};

pub const LirLower = struct {
    allocator: std.mem.Allocator,
    exprs: []const hir.HirExpr,
    defs: []const hir_lower.HirDef,
    inferer: *typecheck.Inferer,
    ctors: std.StringHashMap(CtorEntry),
    globals: std.StringHashMap(GlobalEntry),
    /// User fn name → LIR signature (params slice owned by allocator).
    fn_sigs: std.StringHashMap(lir.LirFnType),
    /// Stdlib fn name → runtime fn name (direct calls).
    std_names: std.StringHashMap([]const u8),
    fns: std.ArrayList(lir.LirFn),
    state: FnState,
    lift_counter: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        exprs: []const hir.HirExpr,
        defs: []const hir_lower.HirDef,
        inferer: *typecheck.Inferer,
    ) LirLower {
        return .{
            .allocator = allocator,
            .exprs = exprs,
            .defs = defs,
            .inferer = inferer,
            .ctors = std.StringHashMap(CtorEntry).init(allocator),
            .globals = std.StringHashMap(GlobalEntry).init(allocator),
            .fn_sigs = std.StringHashMap(lir.LirFnType).init(allocator),
            .std_names = std.StringHashMap([]const u8).init(allocator),
            .fns = .empty,
            .state = .{ .hir_map = std.AutoHashMap(hir.LocalVarId, lir.LocalId).init(allocator) },
        };
    }

    pub fn deinit(self: *LirLower) void {
        self.state.locals.deinit(self.allocator);
        self.state.blocks.deinit(self.allocator);
        self.state.hir_map.deinit();
        self.fns.deinit(self.allocator);
        self.std_names.deinit();
        self.fn_sigs.deinit();
        self.globals.deinit();
        self.ctors.deinit();
    }

    // =================================================================
    // Per-function state management
    // =================================================================

    fn resetState(self: *LirLower) void {
        self.state.locals = .empty;
        self.state.blocks = .empty;
        self.state.hir_map.clearRetainingCapacity();
        self.state.current = 0;
        self.state.next_block = 0;
    }

    fn saveState(self: *LirLower) FnState {
        const saved = self.state;
        self.state = .{ .hir_map = std.AutoHashMap(hir.LocalVarId, lir.LocalId).init(self.allocator) };
        return saved;
    }

    fn restoreState(self: *LirLower, saved: FnState) void {
        self.state.locals.deinit(self.allocator);
        self.state.blocks.deinit(self.allocator);
        self.state.hir_map.deinit();
        self.state = saved;
    }

    fn newLocal(self: *LirLower, ty: lir.LirType) LowerError!lir.LocalId {
        const id = self.state.locals.items.len;
        try self.state.locals.append(self.allocator, ty);
        return id;
    }

    fn localType(self: *LirLower, id: lir.LocalId) lir.LirType {
        return self.state.locals.items[id];
    }

    /// Emit an assignment in the current block; returns the new local.
    fn emit(self: *LirLower, value: lir.LirValue, ty: lir.LirType) LowerError!lir.LocalId {
        const id = try self.newLocal(ty);
        try self.state.blocks.items[self.state.current].body.append(self.allocator, .{
            .assign = .{ .dest = id, .value = value },
        });
        return id;
    }

    fn emitEffect(self: *LirLower, value: lir.LirValue) LowerError!void {
        try self.state.blocks.items[self.state.current].body.append(self.allocator, .{ .effect = value });
    }

    fn emitStore(self: *LirLower, dest: lir.LocalId, value: lir.LocalId) LowerError!void {
        try self.state.blocks.items[self.state.current].body.append(self.allocator, .{
            .store = .{ .dest = dest, .value = value },
        });
    }

    fn rid(self: *LirLower) lir.BlockId {
        const id = self.state.next_block;
        self.state.next_block += 1;
        return id;
    }

    fn startBlock(self: *LirLower, params: []const lir.LocalId) LowerError!void {
        const id = self.rid();
        try self.startBlockWithId(id, params);
    }

    fn startBlockWithId(self: *LirLower, id: lir.BlockId, params: []const lir.LocalId) LowerError!void {
        try self.state.blocks.append(self.allocator, .{ .id = id, .params = params });
        self.state.current = self.state.blocks.items.len - 1;
    }

    fn terminateCurrent(self: *LirLower, term: lir.LirTerminator) void {
        self.state.blocks.items[self.state.current].term = term;
    }

    fn finishBlocks(self: *LirLower) LowerError![]const lir.BasicBlock {
        var out = try self.allocator.alloc(lir.BasicBlock, self.state.blocks.items.len);
        for (self.state.blocks.items, 0..) |*b, i| {
            out[i] = .{
                .id = b.id,
                .params = b.params,
                .body = try b.body.toOwnedSlice(self.allocator),
                .terminator = b.term orelse .{ .unreachable_ = {} },
            };
        }
        return out;
    }

    fn dupeIds(self: *LirLower, ids: []const lir.LocalId) LowerError![]const lir.LocalId {
        return try self.allocator.dupe(lir.LocalId, ids);
    }

    fn freshName(self: *LirLower, prefix: []const u8) LowerError![]const u8 {
        self.lift_counter += 1;
        return try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ prefix, self.lift_counter });
    }

    fn ptrTo(self: *LirLower, inner: lir.LirType) LowerError!lir.LirType {
        const b = try self.allocator.create(lir.LirType);
        b.* = inner;
        return .{ .ptr = b };
    }

    // =================================================================
    // Types
    // =================================================================

    /// Follow type-variable instances to the concrete type.
    fn resolve(self: *LirLower, ty: *const typecheck.Type) *const typecheck.Type {
        _ = self;
        var cur = ty;
        while (cur.* == .variable) {
            if (cur.variable.instance) |inst| {
                cur = inst;
            } else break;
        }
        return cur;
    }

    /// Map a typechecker type to the LIR runtime representation:
    /// ADT values and ref addresses are i64; closures, tuples, and records
    /// are opaque pointers; unit is the i64 constant 0.
    fn lowerType(self: *LirLower, ty: *const typecheck.Type) LowerError!lir.LirType {
        return switch (self.resolve(ty).*) {
            .int => .{ .int = {} },
            .float => .{ .float = {} },
            .bool => .{ .bool = {} },
            .char => .{ .char = {} },
            .string => .{ .string = {} },
            .unit => .{ .int = {} },
            .con => .{ .int = {} },
            .@"ref" => .{ .int = {} },
            .arrow, .tuple, .record => .{ .opaque_type = {} },
            // Unresolved (generic) type variables use the universal i64
            // representation, matching the legacy ABI. Proper support is
            // monomorphization (v0.4); closures crossing a generic boundary
            // round-trip through ptrtoint/inttoptr coercions.
            .variable => .{ .int = {} },
        };
    }

    /// Collect the parameter types of an arrow chain; returns the final
    /// result type. Non-arrow types yield an empty chain and the type itself.
    fn arrowChain(self: *LirLower, ty: *const typecheck.Type, out: *std.ArrayList(*const typecheck.Type)) LowerError!*const typecheck.Type {
        var cur = self.resolve(ty);
        while (cur.* == .arrow) {
            try out.append(self.allocator, cur.arrow.from);
            cur = self.resolve(cur.arrow.to);
        }
        return cur;
    }

    /// Arity-aware arrow walk: collect exactly `n` parameter types (as LIR
    /// types), stopping before the remainder — which is the return type,
    /// possibly itself an arrow (a function-returning function is NOT the
    /// same as a curried multi-param fn). Returns the LIR return type.
    fn arrowChainN(self: *LirLower, ty: *const typecheck.Type, n: usize, params_out: *std.ArrayList(lir.LirType)) LowerError!lir.LirType {
        var cur = self.resolve(ty);
        var i: usize = 0;
        while (i < n and cur.* == .arrow) : (i += 1) {
            try params_out.append(self.allocator, try self.lowerType(cur.arrow.from));
            cur = self.resolve(cur.arrow.to);
        }
        return self.lowerType(cur);
    }

    /// Coerce a local to a target LIR type (boxing/unboxing/boundary casts).
    fn coerce(self: *LirLower, id: lir.LocalId, to: lir.LirType) LowerError!lir.LocalId {
        const from = self.localType(id);
        if (std.meta.activeTag(from) == std.meta.activeTag(to)) return id;
        switch (to) {
            .int => return switch (from) {
                .bool, .char => self.emit(.{ .zext = .{ .val = id, .ty = to } }, to),
                .float => self.emit(.{ .bitcast = .{ .val = id, .ty = to } }, to),
                .string, .opaque_type, .ptr => self.emit(.{ .ptrtoint = id }, to),
                else => error.TypeError,
            },
            .bool, .char => return switch (from) {
                .int => self.emit(.{ .trunc = .{ .val = id, .ty = to } }, to),
                else => error.TypeError,
            },
            .float => return switch (from) {
                .int => self.emit(.{ .bitcast = .{ .val = id, .ty = to } }, to),
                else => error.TypeError,
            },
            .string, .opaque_type, .ptr => return switch (from) {
                .int => self.emit(.{ .inttoptr = .{ .val = id, .ty = to } }, to),
                else => error.TypeError,
            },
            else => return error.TypeError,
        }
    }

    /// Ensure a condition local is an i1 (ADTs represent True/False as i64).
    fn asBool(self: *LirLower, id: lir.LocalId) LowerError!lir.LocalId {
        switch (self.localType(id)) {
            .bool => return id,
            .int => {
                const zero = try self.emit(.{ .int = 0 }, .{ .int = {} });
                return self.emitPrimop2(.neq, id, zero);
            },
            else => return error.TypeError,
        }
    }

    /// Emit a binary primop producing an i1 (comparisons, and/or).
    fn emitPrimop2(self: *LirLower, op: hir.PrimOp, a: lir.LocalId, b: lir.LocalId) LowerError!lir.LocalId {
        const ty: lir.LirType = switch (op) {
            .eq, .neq, .lt, .le, .gt, .ge, .and_, .or_ => .{ .bool = {} },
            else => self.localType(a),
        };
        return self.emit(.{ .primop = .{ .op = op, .args = try self.dupeIds(&.{ a, b }) } }, ty);
    }

    /// GEP into a struct value at a constant field index.
    fn gepStruct(self: *LirLower, struct_ty: lir.LirType, ptr: lir.LocalId, field_index: usize, pointee: lir.LirType) LowerError!lir.LocalId {
        const idx0 = try self.emit(.{ .int = 0 }, .{ .int = {} });
        const idx1 = try self.emit(.{ .int = @intCast(field_index) }, .{ .int = {} });
        return self.emit(.{ .get_element_ptr = .{
            .ptr = ptr,
            .indices = try self.dupeIds(&.{ idx0, idx1 }),
            .elem_type = struct_ty,
        } }, try self.ptrTo(pointee));
    }

    // =================================================================
    // Program lowering
    // =================================================================

    pub fn lowerProgram(self: *LirLower) LowerError![]const lir.LirFn {
        try self.registerBuiltins();
        for (self.defs) |def| {
            switch (def) {
                .type_def => |td| try self.registerTypeDef(td),
                .fn_def => |fd| try self.globals.put(fd.name, .{ .arity = fd.arity, .kind = .user_fn }),
                .let_binding => {},
            }
        }
        // Pass 1: register user fn signatures (for direct calls).
        for (self.defs) |def| {
            switch (def) {
                .fn_def => |fd| try self.registerFnSig(fd),
                else => {},
            }
        }
        // Pass 2: lower function bodies.
        for (self.defs) |def| {
            switch (def) {
                .fn_def => |fd| try self.lowerFn(fd),
                .let_binding => |lb| std.debug.print("lir_lower: top-level let '{s}' not yet supported; skipping\n", .{lb.name}),
                else => {},
            }
        }
        return self.fns.items;
    }

    fn registerBuiltins(self: *LirLower) LowerError!void {
        // Bool and Result constructors, matching the legacy codegen's tags.
        try self.ctors.put("True", .{ .tag = 1, .arity = 0, .type_name = "Bool" });
        try self.ctors.put("False", .{ .tag = 0, .arity = 0, .type_name = "Bool" });
        try self.ctors.put("Ok", .{ .tag = 0, .arity = 1, .type_name = "Result" });
        try self.ctors.put("Err", .{ .tag = 1, .arity = 1, .type_name = "Result" });
        try self.globals.put("True", .{ .arity = 0, .kind = .ctor });
        try self.globals.put("False", .{ .arity = 0, .kind = .ctor });
        try self.globals.put("Ok", .{ .arity = 1, .kind = .ctor });
        try self.globals.put("Err", .{ .arity = 1, .kind = .ctor });
        // I/O builtins with the *_with_tag calling convention.
        try self.globals.put("println", .{ .arity = 1, .kind = .std_special });
        try self.globals.put("print", .{ .arity = 1, .kind = .std_special });
        try self.globals.put("inspect", .{ .arity = 1, .kind = .std_special });
        // Direct stdlib mappings (subset; extend as needed).
        const entries = [_][2][]const u8{
            .{ "String.length", "ko_string_length" },
            .{ "String.append", "ko_string_append" },
            .{ "String.contains", "ko_string_contains" },
            .{ "String.charAt", "ko_string_char_at" },
            .{ "String.toUpperCase", "ko_string_to_upper" },
            .{ "String.toLowerCase", "ko_string_to_lower" },
            .{ "String.trim", "ko_string_trim" },
            .{ "Int.toString", "ko_int_to_string" },
        };
        for (entries) |e| {
            try self.std_names.put(e[0], e[1]);
            try self.globals.put(e[0], .{ .arity = 0, .kind = .std_fn });
        }
    }

    fn registerTypeDef(self: *LirLower, td: hir_lower.HirTypeDef) LowerError!void {
        for (td.ctors, 0..) |c, i| {
            try self.ctors.put(c.name, .{ .tag = @intCast(i), .arity = c.arity, .type_name = td.name });
            try self.globals.put(c.name, .{ .arity = c.arity, .kind = .ctor });
        }
    }

    fn registerFnSig(self: *LirLower, fd: hir_lower.HirFnDef) LowerError!void {
        const scheme = self.inferer.global.getScheme(fd.name) orelse return error.UndefinedGlobal;
        var param_list: std.ArrayList(lir.LirType) = .empty;
        defer param_list.deinit(self.allocator);
        const returns = try self.arrowChainN(scheme.body, fd.arity, &param_list);
        try self.fn_sigs.put(fd.name, .{
            .params = try param_list.toOwnedSlice(self.allocator),
            .returns = returns,
        });
    }

    fn lowerFn(self: *LirLower, fd: hir_lower.HirFnDef) LowerError!void {
        self.resetState();
        const root = self.exprs[fd.root];
        const lam = root.kind.lambda;
        const sig = self.fn_sigs.get(fd.name).?;

        const params = try self.allocator.alloc(lir.LocalId, lam.params.len);
        for (lam.params, 0..) |hvp, i| {
            const lid = try self.newLocal(sig.params[i]);
            params[i] = lid;
            try self.state.hir_map.put(hvp, lid);
        }

        try self.startBlock(&.{});
        var result = try self.lowerExpr(lam.body);
        const is_main = std.mem.eql(u8, fd.name, "main");
        if (is_main) result = try self.coerce(result, .{ .int = {} });
        self.terminateCurrent(.{ .ret = result });

        try self.fns.append(self.allocator, .{
            .name = fd.name,
            .params = params,
            .return_type = if (is_main) .{ .int = {} } else sig.returns,
            .blocks = try self.finishBlocks(),
            .locals = try self.state.locals.toOwnedSlice(self.allocator),
        });
    }

    // =================================================================
    // Expressions
    // =================================================================

    /// Lower one HIR expression; returns the local holding its value.
    fn lowerExpr(self: *LirLower, id: hir.HirId) LowerError!lir.LocalId {
        const e = self.exprs[id];
        return switch (e.kind) {
            .int => |v| self.emit(.{ .int = v }, .{ .int = {} }),
            .float => |v| self.emit(.{ .float = v }, .{ .float = {} }),
            .bool => |v| self.emit(.{ .bool = v }, .{ .bool = {} }),
            .char => |v| self.emit(.{ .char = v }, .{ .char = {} }),
            .string => |s| self.emit(.{ .string = .{ .ptr = s, .len = s.len } }, .{ .string = {} }),
            .local => |lv| self.state.hir_map.get(lv) orelse error.UndefinedLocal,
            .global => |name| self.lowerGlobalValue(name),
            .primop => |p| self.lowerPrimop(p),
            .let => |le| blk: {
                const v = try self.lowerExpr(le.value);
                try self.state.hir_map.put(le.name, v);
                break :blk try self.lowerExpr(le.body);
            },
            .if_ => |ife| self.lowerIf(ife),
            .apply => self.lowerApplyChain(id),
            .lambda => |lam| self.lowerLambdaValue(lam, e.ty),
            .constructor => |c| self.lowerConstructorValue(c),
            .tuple => |t| self.lowerTuple(t),
            .record => |r| self.lowerRecord(r, e.ty),
            .record_access => |ra| blk: {
                // Module access (`String.length`): the "object" is a
                // constructor-position namespace, not a record value.
                if (self.exprs[ra.record].kind == .constructor) {
                    const ns = self.exprs[ra.record].kind.constructor.ctor_name;
                    const full = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns, ra.field });
                    if (self.globals.contains(full)) break :blk try self.lowerGlobalValue(full);
                }
                break :blk try self.lowerRecordAccess(ra, e.ty);
            },
            .match => |m| self.lowerMatch(m, e.ty),
            .ref => |inner| self.lowerRef(inner),
            .deref => |inner| self.lowerDeref(inner, e.ty),
            .assign => |a| self.lowerAssign(a),
            .comptime_expr, .let_rec => error.Unsupported,
        };
    }

    fn lowerPrimop(self: *LirLower, p: hir.PrimOpExpr) LowerError!lir.LocalId {
        // Unary minus arrives as `sub` with one argument: rewrite to 0 - x.
        if (p.op == .sub and p.args.len == 1) {
            const x = try self.lowerExpr(p.args[0]);
            const ty = self.localType(x);
            const zero = try self.emit(switch (ty) {
                .float => .{ .float = 0.0 },
                else => .{ .int = 0 },
            }, ty);
            return self.emit(.{ .primop = .{ .op = .sub, .args = try self.dupeIds(&.{ zero, x }) } }, ty);
        }
        if (p.op == .not_) {
            const x = try self.lowerExpr(p.args[0]);
            const b = try self.coerce(x, .{ .bool = {} });
            return self.emit(.{ .primop = .{ .op = .not_, .args = try self.dupeIds(&.{b}) } }, .{ .bool = {} });
        }
        if (p.args.len != 2) return error.Unsupported;
        const a = try self.lowerExpr(p.args[0]);
        const b = try self.lowerExpr(p.args[1]);
        // Logic ops operate on i1; ADT-encoded bools need truncating.
        switch (p.op) {
            .and_, .or_ => {
                const ba = try self.coerce(a, .{ .bool = {} });
                const bb = try self.coerce(b, .{ .bool = {} });
                return self.emit(.{ .primop = .{ .op = p.op, .args = try self.dupeIds(&.{ ba, bb }) } }, .{ .bool = {} });
            },
            else => {},
        }
        return self.emitPrimop2(p.op, a, b);
    }

    fn lowerIf(self: *LirLower, ife: hir.IfExpr) LowerError!lir.LocalId {
        const cond = try self.asBool(try self.lowerExpr(ife.cond));
        const then_id = self.rid();
        const else_id = self.rid();
        const merge_id = self.rid();
        self.terminateCurrent(.{ .cond_br = .{
            .cond = cond,
            .then = .{ .target = then_id },
            .else_ = .{ .target = else_id },
        } });

        try self.startBlockWithId(then_id, &.{});
        const t = try self.lowerExpr(ife.then);
        self.terminateCurrent(.{ .br = .{ .target = merge_id, .args = try self.dupeIds(&.{t}) } });

        try self.startBlockWithId(else_id, &.{});
        const el = try self.lowerExpr(ife.else_);
        self.terminateCurrent(.{ .br = .{ .target = merge_id, .args = try self.dupeIds(&.{el}) } });

        const result = try self.newLocal(self.localType(t));
        try self.startBlockWithId(merge_id, try self.dupeIds(&.{result}));
        return result;
    }

    // =================================================================
    // Application
    // =================================================================

    /// Lower an apply spine `((f a) b)` into a single call where possible.
    fn lowerApplyChain(self: *LirLower, id: hir.HirId) LowerError!lir.LocalId {
        var rev_args: std.ArrayList(hir.HirId) = .empty;
        defer rev_args.deinit(self.allocator);
        var head = id;
        while (self.exprs[head].kind == .apply) {
            try rev_args.append(self.allocator, self.exprs[head].kind.apply.arg);
            head = self.exprs[head].kind.apply.func;
        }
        std.mem.reverse(hir.HirId, rev_args.items);
        const head_expr = self.exprs[head];
        switch (head_expr.kind) {
            .global => |name| return self.lowerGlobalCall(name, rev_args.items, self.exprs[id].ty),
            .constructor => |c| return self.lowerConstructorApply(c.ctor_name, rev_args.items),
            .record_access => |ra| {
                // Module fn call (`String.length x`): resolve to a global.
                if (self.exprs[ra.record].kind == .constructor) {
                    const ns = self.exprs[ra.record].kind.constructor.ctor_name;
                    const full = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns, ra.field });
                    if (self.globals.contains(full)) return self.lowerGlobalCall(full, rev_args.items, self.exprs[id].ty);
                }
                return self.lowerClosureCall(head, rev_args.items);
            },
            else => return self.lowerClosureCall(head, rev_args.items),
        }
    }

    fn lowerGlobalCall(self: *LirLower, name: []const u8, args: []const hir.HirId, result_hir_ty: *const typecheck.Type) LowerError!lir.LocalId {
        const g = self.globals.get(name) orelse {
            std.debug.print("lir_lower: undefined global '{s}'\n", .{name});
            return error.UndefinedGlobal;
        };
        switch (g.kind) {
            .std_special => return self.lowerStdPrint(name, args),
            .std_fn => return self.lowerStdFnCall(name, args, result_hir_ty),
            .ctor => return self.lowerConstructorApply(name, args),
            .user_fn => {
                if (args.len != g.arity) {
                    std.debug.print("lir_lower: partial application of '{s}' ({d}/{d} args) not yet supported\n", .{ name, args.len, g.arity });
                    return error.ArityMismatch;
                }
                const sig = self.fn_sigs.get(name).?;
                const fn_local = try self.emit(.{ .fn_ref = name }, .{ .opaque_type = {} });
                const arg_locals = try self.allocator.alloc(lir.LocalId, args.len);
                for (args, 0..) |ah, i| arg_locals[i] = try self.coerce(try self.lowerExpr(ah), sig.params[i]);
                return self.emit(.{ .call = .{ .func = fn_local, .args = arg_locals, .fn_type = sig } }, sig.returns);
            },
        }
    }

    /// A top-level fn used as a value: wrap it in a curry trampoline so every
    /// function value has the uniform closure representation.
    fn lowerGlobalValue(self: *LirLower, name: []const u8) LowerError!lir.LocalId {
        const g = self.globals.get(name) orelse {
            std.debug.print("lir_lower: undefined global '{s}'\n", .{name});
            return error.UndefinedGlobal;
        };
        switch (g.kind) {
            .ctor => return self.lowerConstructorApply(name, &.{}),
            .user_fn => {
                const sig = self.fn_sigs.get(name).?;
                if (sig.params.len == 0) return error.Unsupported;
                const params = try self.allocator.alloc(ParamInfo, sig.params.len);
                for (params, 0..) |*p, i| {
                    self.lift_counter += 1;
                    p.* = .{ .hir_lv = 100_000_000 + self.lift_counter, .lir_ty = sig.params[i] };
                }
                const tname = try self.freshName("curry");
                try self.emitLiftLevel(tname, params, 0, .{ .direct_call = name }, &.{}, sig.returns);
                return self.emit(.{ .make_closure = .{ .fn_name = tname, .captures = &.{} } }, .{ .opaque_type = {} });
            },
            .std_fn, .std_special => {
                std.debug.print("lir_lower: stdlib fn '{s}' used as value not yet supported\n", .{name});
                return error.Unsupported;
            },
        }
    }

    /// Runtime signature for a mapped stdlib fn (legacy reps: bools as i64).
    const SigSpec = struct {
        params: []const lir.LirType,
        ret: lir.LirType,
    };

    fn lowerStdFnCall(self: *LirLower, name: []const u8, args: []const hir.HirId, result_hir_ty: *const typecheck.Type) LowerError!lir.LocalId {
        const runtime = self.std_names.get(name).?;
        const spec: SigSpec = blk: {
            if (std.mem.eql(u8, runtime, "ko_string_length")) break :blk .{ .params = &.{.{ .string = {} }}, .ret = .{ .int = {} } };
            if (std.mem.eql(u8, runtime, "ko_string_append")) break :blk .{ .params = &.{ .{ .string = {} }, .{ .string = {} } }, .ret = .{ .string = {} } };
            if (std.mem.eql(u8, runtime, "ko_string_contains")) break :blk .{ .params = &.{ .{ .string = {} }, .{ .string = {} } }, .ret = .{ .int = {} } };
            if (std.mem.eql(u8, runtime, "ko_string_char_at")) break :blk .{ .params = &.{ .{ .string = {} }, .{ .int = {} } }, .ret = .{ .int = {} } };
            if (std.mem.eql(u8, runtime, "ko_string_to_upper")) break :blk .{ .params = &.{.{ .string = {} }}, .ret = .{ .string = {} } };
            if (std.mem.eql(u8, runtime, "ko_string_to_lower")) break :blk .{ .params = &.{.{ .string = {} }}, .ret = .{ .string = {} } };
            if (std.mem.eql(u8, runtime, "ko_string_trim")) break :blk .{ .params = &.{.{ .string = {} }}, .ret = .{ .string = {} } };
            if (std.mem.eql(u8, runtime, "ko_int_to_string")) break :blk .{ .params = &.{.{ .int = {} }}, .ret = .{ .string = {} } };
            return error.Unsupported;
        };
        if (args.len != spec.params.len) return error.ArityMismatch;
        const fn_local = try self.emit(.{ .fn_ref = runtime }, .{ .opaque_type = {} });
        const arg_locals = try self.allocator.alloc(lir.LocalId, args.len);
        for (args, 0..) |ah, i| arg_locals[i] = try self.coerce(try self.lowerExpr(ah), spec.params[i]);
        const result = try self.emit(.{ .call = .{
            .func = fn_local,
            .args = arg_locals,
            .fn_type = .{ .params = spec.params, .returns = spec.ret },
        } }, spec.ret);
        // e.g. Bool-returning runtime fns actually return i64; truncate to i1.
        return self.coerce(result, try self.lowerType(result_hir_ty));
    }

    /// `println`/`print`/`inspect` via the legacy `*_with_tag` convention:
    /// `(value as i64, type tag, ctor/record name ptr or null, 0)`.
    fn lowerStdPrint(self: *LirLower, name: []const u8, args: []const hir.HirId) LowerError!lir.LocalId {
        if (args.len != 1) return error.ArityMismatch;
        const arg_hir = args[0];
        const v = try self.lowerExpr(arg_hir);
        const tag = typeTag(self.resolve(self.exprs[arg_hir].ty));
        const boxed = try self.coerce(v, .{ .int = {} });
        const tag_local = try self.emit(.{ .int = tag }, .{ .int = {} });
        var name_local: lir.LocalId = undefined;
        if (self.ctorNameOf(arg_hir)) |cn| {
            name_local = try self.emit(.{ .string = .{ .ptr = cn, .len = cn.len } }, .{ .string = {} });
        } else if (self.recordNameOf(arg_hir)) |rn| {
            name_local = try self.emit(.{ .string = .{ .ptr = rn, .len = rn.len } }, .{ .string = {} });
        } else {
            const zero = try self.emit(.{ .int = 0 }, .{ .int = {} });
            name_local = try self.emit(.{ .inttoptr = .{ .val = zero, .ty = .{ .opaque_type = {} } } }, .{ .opaque_type = {} });
        }
        const zero2 = try self.emit(.{ .int = 0 }, .{ .int = {} });
        const runtime: []const u8 = if (std.mem.eql(u8, name, "println"))
            "println_with_tag"
        else if (std.mem.eql(u8, name, "print"))
            "print_with_tag"
        else
            "inspect";
        const fn_local = try self.emit(.{ .fn_ref = runtime }, .{ .opaque_type = {} });
        const call_args = try self.dupeIds(&.{ boxed, tag_local, name_local, zero2 });
        const param_tys = try self.allocator.alloc(lir.LirType, 4);
        for (param_tys, 0..) |*pt, i| pt.* = if (i == 2) .{ .opaque_type = {} } else .{ .int = {} };
        return self.emit(.{ .call = .{
            .func = fn_local,
            .args = call_args,
            .fn_type = .{ .params = param_tys, .returns = .{ .int = {} } },
        } }, .{ .int = {} });
    }

    fn ctorNameOf(self: *LirLower, id: hir.HirId) ?[]const u8 {
        var cur = id;
        while (true) {
            switch (self.exprs[cur].kind) {
                .constructor => |c| return c.ctor_name,
                .apply => |a| cur = a.func,
                else => return null,
            }
        }
    }

    fn recordNameOf(self: *LirLower, id: hir.HirId) ?[]const u8 {
        return switch (self.resolve(self.exprs[id].ty).*) {
            .record => |rec| rec.name,
            else => null,
        };
    }

    // =================================================================
    // Closures
    // =================================================================

    /// Apply a closure value one argument at a time (curried convention).
    fn lowerClosureCall(self: *LirLower, head: hir.HirId, args: []const hir.HirId) LowerError!lir.LocalId {
        var f = try self.lowerExpr(head);
        var cur_ty = self.resolve(self.exprs[head].ty);
        for (args) |ah| {
            if (cur_ty.* != .arrow) return error.TypeError;
            const arg_lty = try self.lowerType(cur_ty.arrow.from);
            const ret_lty = try self.lowerType(cur_ty.arrow.to);
            const a = try self.coerce(try self.lowerExpr(ah), arg_lty);
            f = try self.emitClosureApply(f, a, arg_lty, ret_lty);
            cur_ty = self.resolve(cur_ty.arrow.to);
        }
        return f;
    }

    /// One closure application: load fn ptr from slot 0, call
    /// `fn_ptr(closure, arg)`. The closure struct itself serves as the
    /// captures pointer (captures live in slots 1..).
    fn emitClosureApply(self: *LirLower, closure: lir.LocalId, arg: lir.LocalId, arg_lty: lir.LirType, ret_lty: lir.LirType) LowerError!lir.LocalId {
        // Slot 0 is the fn ptr at offset 0 regardless of capture count, so a
        // canonical { ptr } struct type suffices for the GEP.
        const head_struct = lir.LirType{ .struct_ = &.{.{ .opaque_type = {} }} };
        const slot = try self.gepStruct(head_struct, closure, 0, .{ .opaque_type = {} });
        const fn_ptr = try self.emit(.{ .load = slot }, .{ .opaque_type = {} });
        const params = try self.allocator.alloc(lir.LirType, 2);
        params[0] = .{ .opaque_type = {} };
        params[1] = arg_lty;
        return self.emit(.{ .call = .{
            .func = fn_ptr,
            .args = try self.dupeIds(&.{ closure, arg }),
            .fn_type = .{ .params = params, .returns = ret_lty },
        } }, ret_lty);
    }

    /// Lower a lambda to a (possibly multi-level curried) closure value.
    fn lowerLambdaValue(self: *LirLower, lam: hir.LambdaExpr, lam_ty: *const typecheck.Type) LowerError!lir.LocalId {
        if (lam.params.len == 0) return error.Unsupported;
        var param_ltys: std.ArrayList(lir.LirType) = .empty;
        defer param_ltys.deinit(self.allocator);
        const final_ret = try self.arrowChainN(lam_ty, lam.params.len, &param_ltys);

        var bound = std.AutoHashMap(hir.LocalVarId, void).init(self.allocator);
        defer bound.deinit();
        for (lam.params) |p| try bound.put(p, {});
        var seen = std.AutoHashMap(hir.LocalVarId, void).init(self.allocator);
        defer seen.deinit();
        var caps: std.ArrayList(hir.LocalVarId) = .empty;
        defer caps.deinit(self.allocator);
        try self.freeVars(lam.body, &bound, &seen, &caps);

        const params = try self.allocator.alloc(ParamInfo, lam.params.len);
        for (lam.params, 0..) |p, i| params[i] = .{ .hir_lv = p, .lir_ty = param_ltys.items[i] };
        const cap_infos = try self.allocator.alloc(CapInfo, caps.items.len);
        const cap_locals = try self.allocator.alloc(lir.LocalId, caps.items.len);
        for (caps.items, 0..) |cv, i| {
            const ll = self.state.hir_map.get(cv) orelse return error.UndefinedLocal;
            cap_locals[i] = ll;
            cap_infos[i] = .{ .hir_lv = cv, .lir_ty = self.localType(ll) };
        }
        const name = try self.freshName("lam");
        try self.emitLiftLevel(name, params, 0, .{ .hir_body = lam.body }, cap_infos, final_ret);
        return self.emit(.{ .make_closure = .{ .fn_name = name, .captures = cap_locals } }, .{ .opaque_type = {} });
    }

    /// Emit one lifted fn for one currying level. Signature:
    /// `name(captures_ptr, param_level) -> ret | next_closure`.
    /// Level captures = original captures ++ params[0..level]. Emits deeper
    /// levels recursively (saving/restoring the current emission state).
    fn emitLiftLevel(
        self: *LirLower,
        name: []const u8,
        params: []const ParamInfo,
        level: usize,
        leaf: Leaf,
        orig_caps: []const CapInfo,
        final_ret: lir.LirType,
    ) LowerError!void {
        const saved = self.saveState();
        defer self.restoreState(saved);

        const level_caps_len = orig_caps.len + level;
        const level_caps = try self.allocator.alloc(CapInfo, level_caps_len);
        for (orig_caps, 0..) |c, i| level_caps[i] = c;
        for (params[0..level], 0..) |p, i| level_caps[orig_caps.len + i] = .{ .hir_lv = p.hir_lv, .lir_ty = p.lir_ty };

        const caps_ptr = try self.newLocal(.{ .opaque_type = {} });
        const param_l = try self.newLocal(params[level].lir_ty);
        const fn_params = try self.dupeIds(&.{ caps_ptr, param_l });
        try self.startBlock(&.{});

        // Load captures out of the closure struct { fn_ptr, cap0, cap1, ... }.
        const field_tys = try self.allocator.alloc(lir.LirType, level_caps_len + 1);
        field_tys[0] = .{ .opaque_type = {} };
        for (level_caps, 0..) |c, i| field_tys[i + 1] = c.lir_ty;
        const clos_struct = lir.LirType{ .struct_ = field_tys };
        const bound_caps = try self.allocator.alloc(lir.LocalId, level_caps_len);
        for (level_caps, 0..) |c, i| {
            const slot = try self.gepStruct(clos_struct, caps_ptr, i + 1, c.lir_ty);
            bound_caps[i] = try self.emit(.{ .load = slot }, c.lir_ty);
            try self.state.hir_map.put(c.hir_lv, bound_caps[i]);
        }
        try self.state.hir_map.put(params[level].hir_lv, param_l);

        const is_leaf = level == params.len - 1;
        var result: lir.LocalId = undefined;
        var ret_ty: lir.LirType = .{ .opaque_type = {} };
        if (is_leaf) {
            switch (leaf) {
                .hir_body => |body_id| {
                    result = try self.coerce(try self.lowerExpr(body_id), final_ret);
                },
                .direct_call => |gname| {
                    const sig = self.fn_sigs.get(gname).?;
                    const fn_local = try self.emit(.{ .fn_ref = gname }, .{ .opaque_type = {} });
                    const call_args = try self.allocator.alloc(lir.LocalId, bound_caps.len + 1);
                    for (bound_caps, 0..) |bc, i| call_args[i] = bc;
                    call_args[bound_caps.len] = param_l;
                    result = try self.emit(.{ .call = .{ .func = fn_local, .args = call_args, .fn_type = sig } }, sig.returns);
                    result = try self.coerce(result, final_ret);
                },
            }
            ret_ty = final_ret;
        } else {
            const next_name = try self.freshName("lam");
            try self.emitLiftLevel(next_name, params, level + 1, leaf, orig_caps, final_ret);
            const clos_caps = try self.allocator.alloc(lir.LocalId, bound_caps.len + 1);
            for (bound_caps, 0..) |bc, i| clos_caps[i] = bc;
            clos_caps[bound_caps.len] = param_l;
            result = try self.emit(.{ .make_closure = .{ .fn_name = next_name, .captures = clos_caps } }, .{ .opaque_type = {} });
        }
        self.terminateCurrent(.{ .ret = result });
        try self.fns.append(self.allocator, .{
            .name = name,
            .params = fn_params,
            .return_type = ret_ty,
            .blocks = try self.finishBlocks(),
            .locals = try self.state.locals.toOwnedSlice(self.allocator),
        });
    }

    /// Collect free local variables of a HIR subtree (for lambda captures).
    fn freeVars(
        self: *LirLower,
        id: hir.HirId,
        bound: *std.AutoHashMap(hir.LocalVarId, void),
        seen: *std.AutoHashMap(hir.LocalVarId, void),
        out: *std.ArrayList(hir.LocalVarId),
    ) LowerError!void {
        const e = self.exprs[id];
        switch (e.kind) {
            .local => |lv| {
                if (!bound.contains(lv) and !seen.contains(lv)) {
                    try seen.put(lv, {});
                    try out.append(self.allocator, lv);
                }
            },
            .int, .float, .bool, .char, .string, .global, .constructor => {},
            .primop => |p| for (p.args) |a| try self.freeVars(a, bound, seen, out),
            .let => |le| {
                try self.freeVars(le.value, bound, seen, out);
                try bound.put(le.name, {});
                defer _ = bound.remove(le.name);
                try self.freeVars(le.body, bound, seen, out);
            },
            .let_rec => |lr| {
                for (lr.bindings) |b| try bound.put(b.name, {});
                defer {
                    for (lr.bindings) |b| _ = bound.remove(b.name);
                }
                for (lr.bindings) |b| try self.freeVars(b.value, bound, seen, out);
                try self.freeVars(lr.body, bound, seen, out);
            },
            .if_ => |ife| {
                try self.freeVars(ife.cond, bound, seen, out);
                try self.freeVars(ife.then, bound, seen, out);
                try self.freeVars(ife.else_, bound, seen, out);
            },
            .apply => |a| {
                try self.freeVars(a.func, bound, seen, out);
                try self.freeVars(a.arg, bound, seen, out);
            },
            .lambda => |lam| {
                for (lam.params) |p| try bound.put(p, {});
                defer {
                    for (lam.params) |p| _ = bound.remove(p);
                }
                try self.freeVars(lam.body, bound, seen, out);
            },
            .match => |m| {
                try self.freeVars(m.scrutinee, bound, seen, out);
                for (m.arms) |arm| {
                    var arm_bound = std.AutoHashMap(hir.LocalVarId, void).init(self.allocator);
                    defer arm_bound.deinit();
                    try self.patternBinds(arm.pattern, &arm_bound);
                    var it = arm_bound.keyIterator();
                    while (it.next()) |k| try bound.put(k.*, {});
                    defer {
                        var it2 = arm_bound.keyIterator();
                        while (it2.next()) |k| _ = bound.remove(k.*);
                    }
                    if (arm.guard) |g| try self.freeVars(g, bound, seen, out);
                    try self.freeVars(arm.body, bound, seen, out);
                }
            },
            .record => |r| for (r.fields) |f| try self.freeVars(f.value, bound, seen, out),
            .record_access => |ra| try self.freeVars(ra.record, bound, seen, out),
            .tuple => |t| for (t.elements) |el| try self.freeVars(el, bound, seen, out),
            .ref, .deref, .comptime_expr => |inner| try self.freeVars(inner, bound, seen, out),
            .assign => |a| {
                try self.freeVars(a.target, bound, seen, out);
                try self.freeVars(a.value, bound, seen, out);
            },
        }
    }

    fn patternBinds(self: *LirLower, pat: hir.Pattern, out: *std.AutoHashMap(hir.LocalVarId, void)) LowerError!void {
        switch (pat) {
            .bind => |lv| try out.put(lv, {}),
            .constructor => |cp| for (cp.args) |sub| try self.patternBinds(sub, out),
            .record => |rp| for (rp.fields) |f| try self.patternBinds(f.p, out),
            .tuple => |subs| for (subs) |sub| try self.patternBinds(sub, out),
            else => {},
        }
    }

    // =================================================================
    // Constructors
    // =================================================================

    fn lowerConstructorValue(self: *LirLower, c: hir.ConstructorExpr) LowerError!lir.LocalId {
        return self.lowerConstructorApply(c.ctor_name, &.{});
    }

    /// Legacy representation: zero-arg → raw i64 tag; multi-arg →
    /// ptrtoint of `{ i64 tag, i64 field0, ... }` with boxed fields.
    fn lowerConstructorApply(self: *LirLower, name: []const u8, args: []const hir.HirId) LowerError!lir.LocalId {
        const entry = self.ctors.get(name) orelse {
            std.debug.print("lir_lower: undefined constructor '{s}'\n", .{name});
            return error.UndefinedGlobal;
        };
        if (args.len != entry.arity) {
            std.debug.print("lir_lower: constructor '{s}' applied to {d}/{d} args (partial/unsupported use)\n", .{ name, args.len, entry.arity });
            return error.ArityMismatch;
        }
        if (entry.arity == 0) return self.emit(.{ .int = entry.tag }, .{ .int = {} });

        const struct_ty = try self.ctorStructType(entry.arity);
        const raw = try self.emit(.{ .alloc = struct_ty }, .{ .opaque_type = {} });
        const tag = try self.emit(.{ .int = entry.tag }, .{ .int = {} });
        const tag_slot = try self.gepStruct(struct_ty, raw, 0, .{ .int = {} });
        try self.emitStore(tag_slot, tag);
        for (args, 0..) |ah, i| {
            const boxed = try self.coerce(try self.lowerExpr(ah), .{ .int = {} });
            const slot = try self.gepStruct(struct_ty, raw, i + 1, .{ .int = {} });
            try self.emitStore(slot, boxed);
        }
        return self.emit(.{ .ptrtoint = raw }, .{ .int = {} });
    }

    fn ctorStructType(self: *LirLower, arity: usize) LowerError!lir.LirType {
        const fields = try self.allocator.alloc(lir.LirType, arity + 1);
        for (fields) |*f| f.* = .{ .int = {} };
        return .{ .struct_ = fields };
    }

    // =================================================================
    // Match (naive linear chain; decision trees are Phase 6)
    // =================================================================

    fn lowerMatch(self: *LirLower, m: hir.MatchExpr, result_hir_ty: *const typecheck.Type) LowerError!lir.LocalId {
        const scrut = try self.lowerExpr(m.scrutinee);
        const scrut_ty = self.exprs[m.scrutinee].ty;
        const result_ty = try self.lowerType(result_hir_ty);
        const merge_id = self.rid();
        const result = try self.newLocal(result_ty);
        var pending_fail: ?lir.BlockId = null;
        for (m.arms, 0..) |arm, i| {
            if (pending_fail == null and i > 0) break; // dead arm after unconditional match
            if (pending_fail) |fid| try self.startBlockWithId(fid, &.{});
            var bindings: std.ArrayList(Binding) = .empty;
            defer bindings.deinit(self.allocator);
            const cond = try self.lowerPatternTest(arm.pattern, scrut, scrut_ty, &bindings);
            const arm_id = self.rid();
            const is_last = i == m.arms.len - 1;
            if (cond) |c| {
                if (is_last) {
                    const un_id = self.rid();
                    self.terminateCurrent(.{ .cond_br = .{ .cond = c, .then = .{ .target = arm_id }, .else_ = .{ .target = un_id } } });
                    try self.startBlockWithId(un_id, &.{});
                    self.terminateCurrent(.{ .unreachable_ = {} });
                } else {
                    const fid = self.rid();
                    self.terminateCurrent(.{ .cond_br = .{ .cond = c, .then = .{ .target = arm_id }, .else_ = .{ .target = fid } } });
                    pending_fail = fid;
                }
            } else {
                self.terminateCurrent(.{ .br = .{ .target = arm_id } });
                pending_fail = null;
            }
            try self.startBlockWithId(arm_id, &.{});
            for (bindings.items) |b| switch (b) {
                .alias => |a| { try self.state.hir_map.put(a.hir_lv, a.lir_local); },
                .field => |f| {
                    const struct_ty = try self.ctorStructType(f.ctor_arity);
                    const ptr = try self.coerce(f.scrut_local, .{ .opaque_type = {} });
                    const slot = try self.gepStruct(struct_ty, ptr, f.field_index + 1, .{ .int = {} });
                    const raw = try self.emit(.{ .load = slot }, .{ .int = {} });
                    const natural = try self.coerce(raw, try self.lowerType(&f.field_ty));
                    try self.state.hir_map.put(f.hir_lv, natural);
                },
            };
            const v = try self.coerce(try self.lowerExpr(arm.body), result_ty);
            self.terminateCurrent(.{ .br = .{ .target = merge_id, .args = try self.dupeIds(&.{v}) } });
        }
        if (pending_fail) |fid| {
            try self.startBlockWithId(fid, &.{});
            self.terminateCurrent(.{ .unreachable_ = {} });
        }
        try self.startBlockWithId(merge_id, try self.dupeIds(&.{result}));
        return result;
    }

    /// Compile a pattern to a condition (null = matches unconditionally)
    /// plus bindings for pattern variables.
    fn lowerPatternTest(self: *LirLower, pat: hir.Pattern, scrut: lir.LocalId, scrut_ty: *const typecheck.Type, bindings: *std.ArrayList(Binding)) LowerError!?lir.LocalId {
        switch (pat) {
            .wildcard => return null,
            .bind => |lv| {
                try bindings.append(self.allocator, .{ .alias = .{ .hir_lv = lv, .lir_local = scrut } });
                return null;
            },
            .literal => |lit| {
                const c = switch (lit) {
                    .int => |v| try self.emit(.{ .int = v }, .{ .int = {} }),
                    .float => |v| try self.emit(.{ .float = v }, .{ .float = {} }),
                    .bool => |v| try self.emit(.{ .bool = v }, .{ .bool = {} }),
                    .char => |v| try self.emit(.{ .char = if (v.len > 0) v[0] else 0 }, .{ .char = {} }),
                    .string => return error.Unsupported,
                };
                const sc = try self.coerce(scrut, self.localType(c));
                return try self.emitPrimop2(.eq, sc, c);
            },
            .constructor => |cp| return self.lowerCtorPattern(cp, scrut, bindings),
            .tuple => |subs| return self.lowerTuplePattern(subs, scrut, scrut_ty, bindings),
            .record => |rp| return self.lowerRecordPattern(rp, scrut, scrut_ty, bindings),
        }
    }

    fn lowerCtorPattern(self: *LirLower, cp: hir.ConstructorPattern, scrut: lir.LocalId, bindings: *std.ArrayList(Binding)) LowerError!?lir.LocalId {
        const entry = self.ctors.get(cp.ctor_name) orelse return error.UndefinedGlobal;
        if (entry.arity == 0) {
            const t = try self.emit(.{ .int = entry.tag }, .{ .int = {} });
            return try self.emitPrimop2(.eq, scrut, t);
        }
        // Struct type for the ADT: {i64 tag, i64 x arity}
        const struct_ty = try self.ctorStructType(entry.arity);
        const ptr = try self.coerce(scrut, .{ .opaque_type = {} });
        const tag_slot = try self.gepStruct(struct_ty, ptr, 0, .{ .int = {} });
        const tag = try self.emit(.{ .load = tag_slot }, .{ .int = {} });
        const want = try self.emit(.{ .int = entry.tag }, .{ .int = {} });
        var cond = try self.emitPrimop2(.eq, tag, want);

        // For each field sub-pattern: defer field *access* to the arm body
        // (the tag check above already confirmed the constructor matches, but
        // any GEP+load of the field is only safe once we're inside the arm).
        // Nested sub-patterns (e.g. inner constructor checks) must happen in a
        // specialisation block after the tag match.
        var field_tys: std.ArrayList(*const typecheck.Type) = .empty;
        defer field_tys.deinit(self.allocator);
        if (self.inferer.global.getScheme(cp.ctor_name)) |scheme| {
            _ = try self.arrowChain(scheme.body, &field_tys);
        }
        for (cp.args, 0..) |sub, i| {
            const fty: *const typecheck.Type = if (i < field_tys.items.len)
                field_tys.items[i]
            else
                self.inferer.newType(.{ .int = {} }) catch return error.TypeError;
            switch (sub) {
                // Simple bind: defer field load to arm body.
                .bind => |lv| try bindings.append(self.allocator, .{ .field = .{
                    .hir_lv = lv,
                    .scrut_local = scrut,
                    .field_index = i,
                    .ctor_arity = entry.arity,
                    .field_ty = fty.*,
                } }),
                // Nested or literal sub-pattern: load the field eagerly now
                // (safe since we already confirmed the tag matches).
                else => {
                    const slot = try self.gepStruct(struct_ty, ptr, i + 1, .{ .int = {} });
                    const raw = try self.emit(.{ .load = slot }, .{ .int = {} });
                    const natural = try self.coerce(raw, try self.lowerType(fty));
                    if (try self.lowerPatternTest(sub, natural, fty, bindings)) |sc| {
                        cond = try self.emitPrimop2(.and_, cond, sc);
                    }
                },
            }
        }
        return cond;
    }

    fn lowerTuplePattern(self: *LirLower, subs: []const hir.Pattern, scrut: lir.LocalId, scrut_ty: *const typecheck.Type, bindings: *std.ArrayList(Binding)) LowerError!?lir.LocalId {
        const r = self.resolve(scrut_ty);
        if (r.* != .tuple) return error.TypeError;
        const field_tys = try self.allocator.alloc(lir.LirType, r.tuple.len);
        for (r.tuple, 0..) |et, i| field_tys[i] = try self.lowerType(et);
        const struct_ty = lir.LirType{ .struct_ = field_tys };
        var cond: ?lir.LocalId = null;
        for (subs, 0..) |sub, i| {
            const slot = try self.gepStruct(struct_ty, scrut, i, field_tys[i]);
            const v = try self.emit(.{ .load = slot }, field_tys[i]);
            if (try self.lowerPatternTest(sub, v, r.tuple[i], bindings)) |sc| {
                cond = if (cond) |c| try self.emitPrimop2(.and_, c, sc) else sc;
            }
        }
        return cond;
    }

    fn lowerRecordPattern(self: *LirLower, rp: hir.RecordPattern, scrut: lir.LocalId, scrut_ty: *const typecheck.Type, bindings: *std.ArrayList(Binding)) LowerError!?lir.LocalId {
        const r = self.resolve(scrut_ty);
        if (r.* != .record) return error.TypeError;
        const rec = r.record;
        const field_tys = try self.allocator.alloc(lir.LirType, rec.fields.len);
        for (rec.fields, 0..) |f, i| field_tys[i] = try self.lowerType(f.ty);
        const struct_ty = lir.LirType{ .struct_ = field_tys };
        var cond: ?lir.LocalId = null;
        for (rp.fields) |pf| {
            var idx: ?usize = null;
            for (rec.fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, pf.name)) {
                    idx = i;
                    break;
                }
            }
            const i = idx orelse return error.TypeError;
            const slot = try self.gepStruct(struct_ty, scrut, i, field_tys[i]);
            const v = try self.emit(.{ .load = slot }, field_tys[i]);
            if (try self.lowerPatternTest(pf.p, v, rec.fields[i].ty, bindings)) |sc| {
                cond = if (cond) |c| try self.emitPrimop2(.and_, c, sc) else sc;
            }
        }
        return cond;
    }

    // =================================================================
    // Aggregates (tuples, records)
    // =================================================================

    fn lowerTuple(self: *LirLower, t: hir.TupleExpr) LowerError!lir.LocalId {
        const field_tys = try self.allocator.alloc(lir.LirType, t.elements.len);
        const vals = try self.allocator.alloc(lir.LocalId, t.elements.len);
        for (t.elements, 0..) |el, i| {
            vals[i] = try self.lowerExpr(el);
            field_tys[i] = self.localType(vals[i]);
        }
        const struct_ty = lir.LirType{ .struct_ = field_tys };
        const raw = try self.emit(.{ .alloc = struct_ty }, .{ .opaque_type = {} });
        for (vals, 0..) |v, i| {
            const slot = try self.gepStruct(struct_ty, raw, i, field_tys[i]);
            try self.emitStore(slot, v);
        }
        return raw;
    }

    fn lowerRecord(self: *LirLower, r: hir.RecordExpr, record_hir_ty: *const typecheck.Type) LowerError!lir.LocalId {
        const rt = self.resolve(record_hir_ty);
        if (rt.* != .record) return error.TypeError;
        const rec = rt.record;
        // Canonical layout: the type's field order, not the literal's.
        const field_tys = try self.allocator.alloc(lir.LirType, rec.fields.len);
        const vals = try self.allocator.alloc(?lir.LocalId, rec.fields.len);
        for (vals) |*v| v.* = null;
        for (rec.fields, 0..) |f, i| field_tys[i] = try self.lowerType(f.ty);
        for (r.fields) |hf| {
            var idx: ?usize = null;
            for (rec.fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, hf.name)) {
                    idx = i;
                    break;
                }
            }
            const i = idx orelse return error.TypeError;
            vals[i] = try self.coerce(try self.lowerExpr(hf.value), field_tys[i]);
        }
        const struct_ty = lir.LirType{ .struct_ = field_tys };
        const raw = try self.emit(.{ .alloc = struct_ty }, .{ .opaque_type = {} });
        for (vals, 0..) |v, i| {
            const slot = try self.gepStruct(struct_ty, raw, i, field_tys[i]);
            try self.emitStore(slot, v orelse return error.TypeError);
        }
        return raw;
    }

    fn lowerRecordAccess(self: *LirLower, ra: hir.RecordAccess, result_hir_ty: *const typecheck.Type) LowerError!lir.LocalId {
        const rec_local = try self.lowerExpr(ra.record);
        const rt = self.resolve(self.exprs[ra.record].ty);
        if (rt.* != .record) return error.TypeError;
        const rec = rt.record;
        const field_tys = try self.allocator.alloc(lir.LirType, rec.fields.len);
        var idx: ?usize = null;
        for (rec.fields, 0..) |f, i| {
            field_tys[i] = try self.lowerType(f.ty);
            if (std.mem.eql(u8, f.name, ra.field)) idx = i;
        }
        const i = idx orelse return error.TypeError;
        const struct_ty = lir.LirType{ .struct_ = field_tys };
        const slot = try self.gepStruct(struct_ty, rec_local, i, field_tys[i]);
        const v = try self.emit(.{ .load = slot }, field_tys[i]);
        return self.coerce(v, try self.lowerType(result_hir_ty));
    }

    // =================================================================
    // Mutable refs (legacy rep: address as i64)
    // =================================================================

    fn lowerRef(self: *LirLower, inner: hir.HirId) LowerError!lir.LocalId {
        const v = try self.lowerExpr(inner);
        const vty = self.localType(v);
        const addr = try self.emit(.{ .alloc_stack = vty }, try self.ptrTo(vty));
        try self.emitStore(addr, v);
        return self.emit(.{ .ptrtoint = addr }, .{ .int = {} });
    }

    fn lowerDeref(self: *LirLower, inner: hir.HirId, result_hir_ty: *const typecheck.Type) LowerError!lir.LocalId {
        const r = try self.lowerExpr(inner);
        const result_ty = try self.lowerType(result_hir_ty);
        const ptr = try self.emit(.{ .inttoptr = .{ .val = r, .ty = try self.ptrTo(result_ty) } }, try self.ptrTo(result_ty));
        return self.emit(.{ .load = ptr }, result_ty);
    }

    fn lowerAssign(self: *LirLower, a: hir.AssignExpr) LowerError!lir.LocalId {
        const target = try self.lowerExpr(a.target);
        const v = try self.lowerExpr(a.value);
        const vty = self.localType(v);
        const ptr = try self.emit(.{ .inttoptr = .{ .val = target, .ty = try self.ptrTo(vty) } }, try self.ptrTo(vty));
        try self.emitStore(ptr, v);
        return self.emit(.{ .int = 0 }, .{ .int = {} });
    }
};

/// Type tag for the `*_with_tag` runtime fns (mirrors the legacy codegen
/// and `hir_lower.typeFromTag`).
fn typeTag(r: *const typecheck.Type) i64 {
    return switch (r.*) {
        .int => 0,
        .float => 1,
        .bool => 2,
        .char => 3,
        .string => 4,
        .unit => 5,
        .con => 6,
        .record => 7,
        .arrow => 8,
        .tuple => 9,
        else => 100,
    };
}
