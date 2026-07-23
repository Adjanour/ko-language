const std = @import("std");
const ast = @import("ast.zig");
const hir = @import("hir.zig");
const typecheck = @import("typecheck.zig");

pub const HirLower = struct {
    allocator: std.mem.Allocator,
    inferer: *typecheck.Inferer,
    expressions: std.ArrayList(hir.HirExpr),
    roots: std.ArrayList(hir.HirId),
    next_id: hir.HirId,
    scopes: std.ArrayList(Scope),
    next_local: hir.LocalVarId,

    const Scope = std.StringHashMap(hir.LocalVarId);

    pub fn init(allocator: std.mem.Allocator, inferer: *typecheck.Inferer) HirLower {
        return .{
            .allocator = allocator,
            .inferer = inferer,
            .expressions = .empty,
            .roots = .empty,
            .next_id = 0,
            .scopes = .empty,
            .next_local = 0,
        };
    }

    pub fn deinit(self: *HirLower) void {
        for (self.scopes.items) |*s| s.deinit();
        self.scopes.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.expressions.deinit(self.allocator);
    }

    pub fn lowerProgram(self: *HirLower, program: *const ast.Program) !void {
        for (program.definitions) |def| {
            const before = self.expressions.items.len;
            try self.lowerDefinition(&def);
            if (self.expressions.items.len > before) {
                try self.roots.append(self.allocator, self.expressions.items.len - 1);
            }
        }
    }

    fn lowerDefinition(self: *HirLower, def: *const ast.Definition) !void {
        switch (def.*) {
            .fn_def => |fd| {
                self.pushScope();
                defer self.popScope();
                var param_ids: std.ArrayList(hir.LocalVarId) = .empty;
                defer param_ids.deinit(self.allocator);
                for (fd.params) |p| {
                    const name = switch (p.pattern) {
                        .identifier => |n| n,
                        else => @panic("unexpected param pattern"),
                    };
                    const id = try self.newLocal(name);
                    try param_ids.append(self.allocator, id);
                }
                const body_id = try self.lowerExpr(fd.body);
                const fd_ty = self.inferer.expr_types.get(fd.body) orelse @panic("fn body type not found");
                _ = try self.allocExpr(.{
                    .lambda = .{
                        .params = try param_ids.toOwnedSlice(self.allocator),
                        .body = body_id,
                        .captures = &.{},
                    },
                }, fd_ty, fd.body);
            },
            .type_def => {},
            .let_binding => |lb| {
                const val_id = try self.lowerExpr(lb.value);
                const lb_ty = self.inferer.expr_types.get(lb.value) orelse
                    @panic("let binding type not found");
                _ = try self.allocExpr(.{ .let = .{ .name = 0, .value = val_id, .body = 0 } }, lb_ty, lb.value);
            },
            .import => {},
            .package => {},
            .module_def => {},
        }
    }

    fn lowerExpr(self: *HirLower, expr: *const ast.Expr) !hir.HirId {
        const ty = self.inferer.expr_types.get(expr) orelse
            self.typeFromTag(expr);
        return switch (expr.*) {
            .int_literal => |val| self.allocExpr(.{ .int = val }, ty, expr),
            .float_literal => |val| self.allocExpr(.{ .float = val }, ty, expr),
            .bool_literal => |val| self.allocExpr(.{ .bool = val }, ty, expr),
            .char_literal => |val| self.allocExpr(.{ .char = if (val.len > 0) val[0] else 0 }, ty, expr),
            .string_literal => |val| self.allocExpr(.{ .string = val }, ty, expr),
            .identifier => |id| {
                const local = self.lookupLocal(id.name);
                if (local) |lid| {
                    return self.allocExpr(.{ .local = lid }, ty, expr);
                }
                return self.allocExpr(.{ .global = id.name }, ty, expr);
            },
            .constructor => |ctor| self.allocExpr(.{
                .constructor = .{ .type_name = "", .ctor_name = ctor.name, .args = &.{} },
            }, ty, expr),
            .record_literal => |rec| {
                var fields: std.ArrayList(hir.RecordField) = .empty;
                defer fields.deinit(self.allocator);
                for (rec.fields) |na| {
                    const val_id = try self.lowerExpr(na.value);
                    try fields.append(self.allocator, .{ .name = na.name, .value = val_id });
                }
                return self.allocExpr(.{ .record = .{ .fields = try fields.toOwnedSlice(self.allocator) } }, ty, expr);
            },
            .tuple => |tup| {
                var elems: std.ArrayList(hir.HirId) = .empty;
                defer elems.deinit(self.allocator);
                for (tup.items) |item| {
                    try elems.append(self.allocator, try self.lowerExpr(item));
                }
                return self.allocExpr(.{ .tuple = .{ .elements = try elems.toOwnedSlice(self.allocator) } }, ty, expr);
            },
            .block => |blk| {
                var last_id: hir.HirId = undefined;
                for (blk.items) |item| {
                    last_id = try self.lowerExpr(item);
                }
                return last_id;
            },
            .field_access => |fa| {
                const obj_id = try self.lowerExpr(fa.object);
                return self.allocExpr(.{ .record_access = .{ .record = obj_id, .field = fa.field } }, ty, expr);
            },
            .fn_call => |call| {
                const func_id = try self.lowerExpr(call.func);
                var args: std.ArrayList(hir.HirId) = .empty;
                defer args.deinit(self.allocator);
                for (call.args) |arg| {
                    try args.append(self.allocator, try self.lowerExpr(arg));
                }
                return self.lowerFnCall(func_id, try args.toOwnedSlice(self.allocator), ty, expr);
            },
            .lambda => |lam| {
                self.pushScope();
                defer self.popScope();
                var param_ids: std.ArrayList(hir.LocalVarId) = .empty;
                defer param_ids.deinit(self.allocator);
                for (lam.params) |p| {
                    const name = switch (p) {
                        .identifier => |n| n,
                        else => "param",
                    };
                    const lid = try self.newLocal(name);
                    try param_ids.append(self.allocator, lid);
                }
                const body_id = try self.lowerExpr(lam.body);
                return self.allocExpr(.{
                    .lambda = .{
                        .params = try param_ids.toOwnedSlice(self.allocator),
                        .body = body_id,
                        .captures = &.{},
                    },
                }, ty, expr);
            },
            .comptime_expr => |inner| {
                const inner_id = try self.lowerExpr(inner);
                return self.allocExpr(.{ .comptime_expr = inner_id }, ty, expr);
            },
            .unary_op => |uop| {
                const inner_id = try self.lowerExpr(uop.expr);
                const op = astUnaryToPrimOp(uop.op);
                const args = try self.allocator.alloc(hir.HirId, 1);
                args[0] = inner_id;
                return self.allocExpr(.{ .primop = .{ .op = op, .args = args } }, ty, expr);
            },
            .binary_op => |binop| {
                const left_id = try self.lowerExpr(binop.left);
                const right_id = try self.lowerExpr(binop.right);
                const op = astBinaryToPrimOp(binop.op);
                const args = try self.allocator.alloc(hir.HirId, 2);
                args[0] = left_id;
                args[1] = right_id;
                return self.allocExpr(.{ .primop = .{ .op = op, .args = args } }, ty, expr);
            },
            .let_expr => |le| {
                self.pushScope();
                defer self.popScope();
                const val_id = try self.lowerExpr(le.value);
                const name = le.name;
                const lid = try self.newLocal(name);
                const body_id = try self.lowerExpr(le.body);
                return self.allocExpr(.{ .let = .{ .name = lid, .value = val_id, .body = body_id } }, ty, expr);
            },
            .if_expr => |ife| {
                const cond_id = try self.lowerExpr(ife.condition);
                const then_id = try self.lowerExpr(ife.then_branch);
                const else_id = if (ife.else_branch) |eb| try self.lowerExpr(eb) else
                    try self.allocExpr(.{ .int = 0 }, ty, expr);
                return self.allocExpr(.{ .if_ = .{ .cond = cond_id, .then = then_id, .else_ = else_id } }, ty, expr);
            },
            .match_expr => |m| {
                const scrut_id = try self.lowerExpr(m.value);
                var arms: std.ArrayList(hir.MatchArm) = .empty;
                defer arms.deinit(self.allocator);
                for (m.arms) |arm| {
                    const body_id = try self.lowerExpr(arm.body);
                    try arms.append(self.allocator, .{
                        .pattern = try self.lowerPattern(&arm.pattern),
                        .guard = null,
                        .body = body_id,
                    });
                }
                return self.allocExpr(.{ .match = .{
                    .scrutinee = scrut_id,
                    .arms = try arms.toOwnedSlice(self.allocator),
                } }, ty, expr);
            },
            .assign_expr => |a| {
                const target_id = try self.lowerExpr(a.target);
                const val_id = try self.lowerExpr(a.value);
                return self.allocExpr(.{ .assign = .{ .target = target_id, .value = val_id } }, ty, expr);
            },
            .ref_expr => |inner| {
                const inner_id = try self.lowerExpr(inner);
                return self.allocExpr(.{ .ref = inner_id }, ty, expr);
            },
            .pat_record => |pr| {
                _ = pr;
                return self.allocExpr(.{ .int = 0 }, ty, expr);
            },
        };
    }

    fn lowerFnCall(self: *HirLower, func_id: hir.HirId, args: []const hir.HirId, ty: *const typecheck.Type, expr: *const ast.Expr) !hir.HirId {
        if (args.len == 1) {
            return self.allocExpr(.{ .apply = .{ .func = func_id, .arg = args[0] } }, ty, expr);
        }
        var cur = try self.allocExpr(.{ .apply = .{ .func = func_id, .arg = args[args.len - 1] } }, ty, expr);
        var i: usize = args.len - 1;
        while (i > 0) {
            i -= 1;
            cur = try self.allocExpr(.{ .apply = .{ .func = cur, .arg = args[i] } }, ty, expr);
        }
        return cur;
    }

    fn lowerPattern(self: *HirLower, pattern: *const ast.Pattern) !hir.Pattern {
        return switch (pattern.*) {
            .wildcard => hir.Pattern{ .wildcard = {} },
            .identifier => |name| hir.Pattern{ .bind = try self.newLocal(name) },
            .literal => |lit| hir.Pattern{ .literal = astLiteralToHir(lit) },
            .constructor => |ctor| hir.Pattern{
                .constructor = .{
                    .type_name = "",
                    .ctor_name = ctor.name,
                    .args = try self.lowerPatterns(ctor.args),
                },
            },
            .record => |rec| hir.Pattern{
                .record = .{
                    .fields = try self.lowerRecordPatternFields(rec.fields),
                    .rest = rec.rest,
                },
            },
            .tuple => |items| hir.Pattern{ .tuple = try self.lowerPatterns(items) },
        };
    }

    fn lowerPatterns(self: *HirLower, patterns: []const ast.Pattern) (error{OutOfMemory}![]const hir.Pattern) {
        var result: std.ArrayList(hir.Pattern) = .empty;
        defer result.deinit(self.allocator);
        for (patterns) |*p| {
            try result.append(self.allocator, try self.lowerPattern(p));
        }
        return try result.toOwnedSlice(self.allocator);
    }

    fn lowerRecordPatternFields(self: *HirLower, fields: []const ast.RecordPatternField) (error{OutOfMemory}![]const hir.RecordPatternField) {
        var result: std.ArrayList(hir.RecordPatternField) = .empty;
        defer result.deinit(self.allocator);
        for (fields) |f| {
            const p = if (f.pattern) |fp| try self.lowerPattern(fp) else hir.Pattern{ .wildcard = {} };
            try result.append(self.allocator, .{ .name = f.name, .p = p });
        }
        return try result.toOwnedSlice(self.allocator);
    }

    fn allocExpr(self: *HirLower, kind: hir.HirExprKind, ty: *const typecheck.Type, expr: *const ast.Expr) !hir.HirId {
        const id = self.next_id;
        self.next_id += 1;
        try self.expressions.append(self.allocator, .{
            .id = id,
            .ty = ty,
            .span = .{
                .line = expr.getLoc().line,
                .col = expr.getLoc().col,
                .end_line = expr.getLoc().end_line,
                .end_col = expr.getLoc().end_col,
            },
            .kind = kind,
        });
        return id;
    }

    fn typeFromTag(self: *HirLower, expr: *const ast.Expr) *const typecheck.Type {
        if (self.inferer.expr_type_tags.get(expr)) |tag| {
            return self.inferer.newType(switch (tag) {
                0 => .{ .int = {} },
                1 => .{ .float = {} },
                2 => .{ .bool = {} },
                3 => .{ .char = {} },
                4 => .{ .string = {} },
                5 => .{ .unit = {} },
                6 => .{ .con = .{ .name = "", .args = &.{} } },
                else => .{ .int = {} },
            }) catch unreachable;
        }
        return self.inferer.newType(.{ .int = {} }) catch unreachable;
    }

    fn pushScope(self: *HirLower) void {
        self.scopes.append(self.allocator, Scope.init(self.allocator)) catch unreachable;
    }

    fn popScope(self: *HirLower) void {
        if (self.scopes.pop()) |scope| {
            var s = scope;
            s.deinit();
        }
    }

    fn newLocal(self: *HirLower, name: []const u8) !hir.LocalVarId {
        const id = self.next_local;
        self.next_local += 1;
        if (self.scopes.items.len > 0) {
            try self.scopes.items[self.scopes.items.len - 1].put(name, id);
        }
        return id;
    }

    fn lookupLocal(self: *HirLower, name: []const u8) ?hir.LocalVarId {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |id| return id;
        }
        return null;
    }
};

fn astBinaryToPrimOp(op: ast.BinaryOp) hir.PrimOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .rem,
        .eq => .eq,
        .neq => .neq,
        .lt => .lt,
        .lte => .le,
        .gt => .gt,
        .gte => .ge,
        .and_op => .and_,
        .or_op => .or_,
        .pipe => .add,
        .cons => .add,
    };
}

fn astUnaryToPrimOp(op: ast.UnaryOp) hir.PrimOp {
    return switch (op) {
        .neg => .sub,
        .not => .not_,
        .ref => .add,
        .deref => .add,
        .try_op => .add,
    };
}

fn astLiteralToHir(lit: ast.Literal) hir.HirLiteral {
    return switch (lit) {
        .int => |v| .{ .int = v },
        .float => |v| .{ .float = v },
        .string => |v| .{ .string = v },
        .char => |v| .{ .char = v },
        .bool => |v| .{ .bool = v },
    };
}
