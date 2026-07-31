const std = @import("std");
const hir = @import("hir.zig");
const diagnostics = @import("diagnostics.zig");

pub const HirCheck = struct {
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(hir.HirExpr),
    diags: *diagnostics.DiagnosticList,

    pub fn init(
        allocator: std.mem.Allocator,
        expressions: *std.ArrayList(hir.HirExpr),
        diags: *diagnostics.DiagnosticList,
    ) HirCheck {
        return .{
            .allocator = allocator,
            .expressions = expressions,
            .diags = diags,
        };
    }

    pub fn run(self: *HirCheck) void {
        // Only check top-level expression types that need analysis.
        // Don't recurse into children — the main loop handles all expressions.
        for (0..self.expressions.items.len) |i| {
            const kind = self.expressions.items[i].kind;
            switch (kind) {
                .primop => self.checkPrimop(@intCast(i)),
                .if_ => self.checkIf(@intCast(i)),
                .match => self.checkMatch(@intCast(i)),
                .apply => self.checkApply(@intCast(i)),
                else => {},
            }
        }
    }

    fn checkExpr(self: *HirCheck, id: hir.HirId) void {
        if (id >= self.expressions.items.len) return;
        const kind = self.expressions.items[id].kind;
        switch (kind) {
            .primop => self.checkPrimop(id),
            .if_ => self.checkIf(id),
            .match => self.checkMatch(id),
            .apply => self.checkApply(id),
            .let => |l| {
                self.checkExpr(l.value);
                self.checkExpr(l.body);
            },
            .let_rec => |lr| {
                for (lr.bindings) |b| self.checkExpr(b.value);
                self.checkExpr(lr.body);
            },
            .lambda => |l| self.checkExpr(l.body),
            .tuple => |t| {
                for (t.elements) |e| self.checkExpr(e);
            },
            .record => |r| {
                for (r.fields) |f| self.checkExpr(f.value);
            },
            .record_access => |ra| self.checkExpr(ra.record),
            .constructor => |c| {
                for (c.args) |a| self.checkExpr(a);
            },
            .comptime_expr => |inner| self.checkExpr(inner),
            .ref => |inner| self.checkExpr(inner),
            .deref => |inner| self.checkExpr(inner),
            .assign => |a| {
                self.checkExpr(a.target);
                self.checkExpr(a.value);
            },
            else => {},
        }
    }

    fn checkPrimop(self: *HirCheck, id: hir.HirId) void {
        const prim = self.expressions.items[id].kind.primop;
        const args = prim.args;

        // 1. Division/modulo by zero
        if (prim.op == .div or prim.op == .rem) {
            if (args.len < 2) return;
            const divisor = args[1];
            if (self.expressions.items[divisor].kind == .int) {
                const b = self.expressions.items[divisor].kind.int;
                if (b == 0) {
                    const op_name = if (prim.op == .div) "division" else "modulo";
                    self.emitError(id, "{s} by zero", .{op_name});
                    return;
                }
            }
        }

        // 2. Arithmetic overflow for integer literals
        if (prim.op == .add or prim.op == .sub or prim.op == .mul) {
            if (args.len >= 2) {
                const left = self.expressions.items[args[0]];
                const right = self.expressions.items[args[1]];
                if (left.kind == .int and right.kind == .int) {
                    const a = left.kind.int;
                    const b = right.kind.int;
                    const overflowed: bool = switch (prim.op) {
                        .add => @addWithOverflow(a, b)[1] != 0,
                        .sub => @subWithOverflow(a, b)[1] != 0,
                        .mul => @mulWithOverflow(a, b)[1] != 0,
                        else => unreachable,
                    };
                    if (overflowed) {
                        const op_char: []const u8 = switch (prim.op) {
                            .add => "+",
                            .sub => "-",
                            .mul => "*",
                            else => unreachable,
                        };
                        self.emitError(id, "integer overflow in `{s}` operation", .{op_char});
                    }
                }
            }
        }

        // 3. Integer literal range warning (near i64 bounds)
        for (args) |arg| {
            const arg_expr = self.expressions.items[arg];
            if (arg_expr.kind == .int) {
                const val = arg_expr.kind.int;
                const min_safe = -9223372036854775000; // ~i64.min + 1000
                const max_safe = 9223372036854775000; // ~i64.max - 1000
                if (val < min_safe or val > max_safe) {
                    self.emitWarning(id, "integer literal near i64 bounds may cause overflow", .{});
                }
            }
        }

        // 4. String bounds checking — handled in checkApply for function applications

        // Recurse into args
        for (args) |arg| self.checkExpr(arg);
    }

    fn checkIf(self: *HirCheck, id: hir.HirId) void {
        const if_expr = self.expressions.items[id].kind.if_;
        self.checkExpr(if_expr.cond);
        self.checkExpr(if_expr.then);
        self.checkExpr(if_expr.else_);

        // 5. Redundant conditions — if True/False then x else y
        const cond = self.expressions.items[if_expr.cond];
        if (cond.kind == .bool) {
            const branch = if (cond.kind.bool) "true" else "false";
            self.emitWarningIfNew(id, "redundant condition: `if {s}` always takes the {s} branch", .{ branch, branch });
        } else if (cond.kind == .constructor) {
            // True/False are constructors
            if (std.mem.eql(u8, cond.kind.constructor.ctor_name, "True")) {
                self.emitWarningIfNew(id, "redundant condition: `if True` always takes the true branch", .{});
            } else if (std.mem.eql(u8, cond.kind.constructor.ctor_name, "False")) {
                self.emitWarningIfNew(id, "redundant condition: `if False` always takes the false branch", .{});
            }
        }
    }

    fn checkMatch(self: *HirCheck, id: hir.HirId) void {
        const match_expr = self.expressions.items[id].kind.match;

        // 6. Empty match expressions
        if (match_expr.arms.len == 0) {
            self.emitError(id, "match expression has no arms", .{});
            return;
        }

        // 7. Unreachable match branches
        // Check if scrutinee is a known constructor and which arm matches
        const scrutinee = self.expressions.items[match_expr.scrutinee];
        if (scrutinee.kind == .constructor) {
            const ctor = scrutinee.kind.constructor;
            var found_match = false;
            for (match_expr.arms) |arm| {
                switch (arm.pattern) {
                    .constructor => |pctor| {
                        if (std.mem.eql(u8, pctor.ctor_name, ctor.ctor_name)) {
                            if (found_match) {
                                self.emitWarning(id, "unreachable pattern `{s}` (matched by earlier arm)", .{pctor.ctor_name});
                            }
                            found_match = true;
                        }
                    },
                    .wildcard => {
                        if (found_match) {
                            self.emitWarning(id, "unreachable wildcard pattern (all constructors already matched)", .{});
                        }
                        found_match = true;
                    },
                    else => {},
                }
            }
        }

        // Check each arm's body for dead code
        for (match_expr.arms) |arm| {
            self.checkExpr(arm.body);
        }
    }

    fn checkApply(self: *HirCheck, id: hir.HirId) void {
        const apply = self.expressions.items[id].kind.apply;
        self.checkExpr(apply.func);
        self.checkExpr(apply.arg);

        // 8. String.charAt bounds checking
        // Walk through nested applies to find the actual function
        var func_id = apply.func;
        while (func_id < self.expressions.items.len) {
            const func_expr = self.expressions.items[func_id];
            switch (func_expr.kind) {
                .global => |name| {
                    if (std.mem.eql(u8, name, "String.charAt")) {
                        // Check if index is a known integer literal
                        const arg = self.expressions.items[apply.arg];
                        if (arg.kind == .int) {
                            const idx = arg.kind.int;
                            if (idx < 0) {
                                self.emitError(id, "String.charAt: negative index ({d})", .{idx});
                            }
                        }
                    }
                    break;
                },
                .record_access => |ra| {
                    if (std.mem.eql(u8, ra.field, "charAt")) {
                        // Check if index is a known integer literal
                        const arg = self.expressions.items[apply.arg];
                        if (arg.kind == .int) {
                            const idx = arg.kind.int;
                            if (idx < 0) {
                                self.emitError(id, "String.charAt: negative index ({d})", .{idx});
                            }
                        }
                    }
                    break;
                },
                .apply => |a| {
                    func_id = a.func;
                    continue;
                },
                else => break,
            }
        }
    }

    fn emitError(self: *HirCheck, id: hir.HirId, comptime fmt: []const u8, args: anytype) void {
        const span = self.expressions.items[id].span;
        self.diags.add(.{
            .message = std.fmt.allocPrint(self.allocator, fmt, args) catch return,
            .severity = .@"error",
            .loc = .{
                .line = span.line,
                .col = span.col,
                .end_line = span.end_line,
                .end_col = span.end_col,
            },
        }) catch return;
    }

    fn emitWarning(self: *HirCheck, id: hir.HirId, comptime fmt: []const u8, args: anytype) void {
        const span = self.expressions.items[id].span;
        self.diags.add(.{
            .message = std.fmt.allocPrint(self.allocator, fmt, args) catch return,
            .severity = .warning,
            .loc = .{
                .line = span.line,
                .col = span.col,
                .end_line = span.end_line,
                .end_col = span.end_col,
            },
        }) catch return;
    }

    fn emitWarningIfNew(self: *HirCheck, id: hir.HirId, comptime fmt: []const u8, args: anytype) void {
        const span = self.expressions.items[id].span;
        // Check if we already reported a warning at this location
        for (self.diags.items.items) |existing| {
            if (existing.loc) |loc| {
                if (loc.line == span.line and loc.col == span.col) {
                    return; // Already reported
                }
            }
        }
        self.emitWarning(id, fmt, args);
    }
};
