const std = @import("std");
const hir = @import("hir.zig");

pub const HirDce = struct {
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(hir.HirExpr),

    pub fn init(allocator: std.mem.Allocator, expressions: *std.ArrayList(hir.HirExpr)) HirDce {
        return .{ .allocator = allocator, .expressions = expressions };
    }

    pub fn run(self: *HirDce, roots: []const hir.HirId) void {
        var stack: std.ArrayList(hir.HirId) = .empty;
        defer stack.deinit(self.allocator);
        for (roots) |r| {
            if (r < self.expressions.items.len) {
                stack.append(self.allocator, r) catch unreachable;
            }
        }
        while (stack.items.len > 0) {
            const maybe_id = stack.pop();
            const id = maybe_id orelse continue;
            if (id >= self.expressions.items.len) continue;
            if (self.expressions.items[id].live) continue;
            self.expressions.items[id].live = true;
            self.forEachChild(id, &stack);
        }
    }

    fn forEachChild(self: *HirDce, id: hir.HirId, stack: *std.ArrayList(hir.HirId)) void {
        const kind = self.expressions.items[id].kind;
        switch (kind) {
            .int, .float, .bool, .char, .string, .local, .global => {},
            .primop => |p| {
                for (p.args) |arg| stack.append(self.allocator, arg) catch unreachable;
            },
            .let => |l| {
                stack.append(self.allocator, l.value) catch unreachable;
                stack.append(self.allocator, l.body) catch unreachable;
            },
            .let_rec => |lr| {
                for (lr.bindings) |b| stack.append(self.allocator, b.value) catch unreachable;
                stack.append(self.allocator, lr.body) catch unreachable;
            },
            .if_ => |i| {
                stack.append(self.allocator, i.cond) catch unreachable;
                stack.append(self.allocator, i.then) catch unreachable;
                stack.append(self.allocator, i.else_) catch unreachable;
            },
            .lambda => |l| {
                stack.append(self.allocator, l.body) catch unreachable;
            },
            .apply => |a| {
                stack.append(self.allocator, a.func) catch unreachable;
                stack.append(self.allocator, a.arg) catch unreachable;
            },
            .record => |r| {
                for (r.fields) |f| stack.append(self.allocator, f.value) catch unreachable;
            },
            .record_access => |ra| stack.append(self.allocator, ra.record) catch unreachable,
            .match => |m| {
                stack.append(self.allocator, m.scrutinee) catch unreachable;
                for (m.arms) |arm| {
                    if (arm.guard) |g| stack.append(self.allocator, g) catch unreachable;
                    stack.append(self.allocator, arm.body) catch unreachable;
                }
            },
            .assign => |a| {
                stack.append(self.allocator, a.target) catch unreachable;
                stack.append(self.allocator, a.value) catch unreachable;
            },
            .ref => |inner| stack.append(self.allocator, inner) catch unreachable,
            .deref => |inner| stack.append(self.allocator, inner) catch unreachable,
            .constructor => |c| {
                for (c.args) |arg| stack.append(self.allocator, arg) catch unreachable;
            },
            .tuple => |t| {
                for (t.elements) |e| stack.append(self.allocator, e) catch unreachable;
            },
            .comptime_expr => |inner| stack.append(self.allocator, inner) catch unreachable,
        }
    }
};
