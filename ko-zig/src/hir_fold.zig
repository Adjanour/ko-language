const std = @import("std");
const hir = @import("hir.zig");
const typecheck = @import("typecheck.zig");

pub const HirFold = struct {
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(hir.HirExpr),
    const_fold: bool,
    if_fold: bool,
    prop_consts: std.AutoHashMap(hir.LocalVarId, hir.HirId),

    pub fn init(allocator: std.mem.Allocator, expressions: *std.ArrayList(hir.HirExpr)) HirFold {
        return .{
            .allocator = allocator,
            .expressions = expressions,
            .const_fold = true,
            .if_fold = true,
            .prop_consts = std.AutoHashMap(hir.LocalVarId, hir.HirId).init(allocator),
        };
    }

    pub fn deinit(self: *HirFold) void {
        self.prop_consts.deinit();
    }

    pub fn run(self: *HirFold) void {
        for (0..self.expressions.items.len) |i| {
            self.foldExpr(@intCast(i));
        }
    }

    fn foldExpr(self: *HirFold, id: hir.HirId) void {
        if (id >= self.expressions.items.len) return;
        const kind = self.expressions.items[id].kind;
        switch (kind) {
            .primop => self.foldPrimop(id),
            .if_ => self.foldIf(id),
            .let => self.foldLet(id),
            .local => self.foldLocal(id),
            else => self.foldChildren(id),
        }
    }

    fn foldChildren(self: *HirFold, id: hir.HirId) void {
        const kind = self.expressions.items[id].kind;
        switch (kind) {
            .apply => |a| {
                self.foldExpr(a.func);
                self.foldExpr(a.arg);
            },
            .let_rec => |lr| {
                for (lr.bindings) |b| self.foldExpr(b.value);
                self.foldExpr(lr.body);
            },
            .match => |m| {
                self.foldExpr(m.scrutinee);
                for (m.arms) |arm| {
                    if (arm.guard) |g| self.foldExpr(g);
                    self.foldExpr(arm.body);
                }
            },
            .record => |r| {
                for (r.fields) |f| self.foldExpr(f.value);
            },
            .record_access => |ra| self.foldExpr(ra.record),
            .tuple => |t| {
                for (t.elements) |e| self.foldExpr(e);
            },
            .constructor => |c| {
                for (c.args) |a| self.foldExpr(a);
            },
            .ref => |inner| self.foldExpr(inner),
            .deref => |inner| self.foldExpr(inner),
            .assign => |a| {
                self.foldExpr(a.target);
                self.foldExpr(a.value);
            },
            .comptime_expr => |inner| self.foldExpr(inner),
            else => {},
        }
    }

    fn foldLocal(self: *HirFold, id: hir.HirId) void {
        const local_id = self.expressions.items[id].kind.local;
        if (self.prop_consts.get(local_id)) |const_id| {
            if (isConstExpr(&self.expressions.items[const_id])) {
                self.expressions.items[id] = self.expressions.items[const_id];
                self.expressions.items[id].id = id;
            }
        }
    }

    fn foldLet(self: *HirFold, id: hir.HirId) void {
        const let_data = self.expressions.items[id].kind.let;
        self.foldExpr(let_data.value);
        self.foldExpr(let_data.body);
        const val_kind = self.expressions.items[let_data.value].kind;
        if (isConstKind(val_kind)) {
            self.prop_consts.put(let_data.name, let_data.value) catch {};
        }
    }

    fn foldIf(self: *HirFold, id: hir.HirId) void {
        const if_data = self.expressions.items[id].kind.if_;
        self.foldExpr(if_data.cond);
        self.foldExpr(if_data.then);
        self.foldExpr(if_data.else_);
        if (!self.if_fold) return;
        if (self.expressions.items[if_data.cond].kind != .bool) return;
        const cond_val = self.expressions.items[if_data.cond].kind.bool;
        if (cond_val) {
            self.expressions.items[id] = self.expressions.items[if_data.then];
        } else {
            self.expressions.items[id] = self.expressions.items[if_data.else_];
        }
        self.expressions.items[id].id = id;
    }

    fn foldPrimop(self: *HirFold, id: hir.HirId) void {
        if (!self.const_fold) return;
        const prim = self.expressions.items[id].kind.primop;
        for (prim.args) |arg| self.foldExpr(arg);
        const args = prim.args;

        const all_int = for (args) |arg| {
            if (self.expressions.items[arg].kind != .int) break false;
        } else true;

        const all_bool = for (args) |arg| {
            if (self.expressions.items[arg].kind != .bool) break false;
        } else true;

        if (all_int) {
            if (tryFoldIntOp(self, id, prim.op, args)) return;
        }
        if (all_bool and args.len == 2) {
            if (tryFoldBoolOp(self, id, prim.op, args)) return;
        }
        if (args.len == 1 and args[0] == id) {}
    }

    fn isConstKind(kind: hir.HirExprKind) bool {
        return switch (kind) {
            .int, .float, .bool, .char, .string => true,
            else => false,
        };
    }
};

fn isConstExpr(expr: *const hir.HirExpr) bool {
    return switch (expr.kind) {
        .int, .float, .bool, .char, .string => true,
        else => false,
    };
}

fn intVal(exprs: *const std.ArrayList(hir.HirExpr), id: hir.HirId) i64 {
    return exprs.items[id].kind.int;
}

fn boolVal(exprs: *const std.ArrayList(hir.HirExpr), id: hir.HirId) bool {
    return exprs.items[id].kind.bool;
}

fn tryFoldIntOp(fold: *HirFold, id: hir.HirId, op: hir.PrimOp, args: []const hir.HirId) bool {
    const exprs = fold.expressions;
    switch (op) {
        .add => {
            var sum: i64 = 0;
            for (args) |a| sum += intVal(exprs, a);
            exprs.items[id].kind = .{ .int = sum };
            return true;
        },
        .sub => {
            if (args.len >= 1) {
                if (args.len == 1) {
                    // Unary minus: `-x` lowers to `sub` with one argument.
                    exprs.items[id].kind = .{ .int = -intVal(exprs, args[0]) };
                } else {
                    var result = intVal(exprs, args[0]);
                    for (args[1..]) |a| result -= intVal(exprs, a);
                    exprs.items[id].kind = .{ .int = result };
                }
                return true;
            }
            return false;
        },
        .mul => {
            var product: i64 = 1;
            for (args) |a| product *= intVal(exprs, a);
            exprs.items[id].kind = .{ .int = product };
            return true;
        },
        .div => {
            if (args.len < 2) return false;
            const a = intVal(exprs, args[0]);
            const b = intVal(exprs, args[1]);
            if (b == 0) return false;
            exprs.items[id].kind = .{ .int = @divTrunc(a, b) };
            return true;
        },
        .rem => {
            if (args.len < 2) return false;
            const a = intVal(exprs, args[0]);
            const b = intVal(exprs, args[1]);
            if (b == 0) return false;
            exprs.items[id].kind = .{ .int = @rem(a, b) };
            return true;
        },
        .eq => {
            if (args.len < 2) return false;
            exprs.items[id].kind = .{ .bool = intVal(exprs, args[0]) == intVal(exprs, args[1]) };
            return true;
        },
        .neq => {
            if (args.len < 2) return false;
            exprs.items[id].kind = .{ .bool = intVal(exprs, args[0]) != intVal(exprs, args[1]) };
            return true;
        },
        .lt => {
            if (args.len < 2) return false;
            exprs.items[id].kind = .{ .bool = intVal(exprs, args[0]) < intVal(exprs, args[1]) };
            return true;
        },
        .le => {
            if (args.len < 2) return false;
            exprs.items[id].kind = .{ .bool = intVal(exprs, args[0]) <= intVal(exprs, args[1]) };
            return true;
        },
        .gt => {
            if (args.len < 2) return false;
            exprs.items[id].kind = .{ .bool = intVal(exprs, args[0]) > intVal(exprs, args[1]) };
            return true;
        },
        .ge => {
            if (args.len < 2) return false;
            exprs.items[id].kind = .{ .bool = intVal(exprs, args[0]) >= intVal(exprs, args[1]) };
            return true;
        },
        else => return false,
    }
}

fn tryFoldBoolOp(fold: *HirFold, id: hir.HirId, op: hir.PrimOp, args: []const hir.HirId) bool {
    const exprs = fold.expressions;
    switch (op) {
        .and_ => {
            const result = boolVal(exprs, args[0]) and boolVal(exprs, args[1]);
            exprs.items[id].kind = .{ .bool = result };
            return true;
        },
        .or_ => {
            const result = boolVal(exprs, args[0]) or boolVal(exprs, args[1]);
            exprs.items[id].kind = .{ .bool = result };
            return true;
        },
        else => return false,
    }
}
