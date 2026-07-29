//! HIR Let Simplification Pass
//!
//! Three optimizations:
//! 1. **Identity let**: `let x = x in body` → `body`
//! 2. **Dead let**: `let x = e in body` where x is unused and e is pure → `body`
//! 3. **Single-use literal inline**: `let x = 42 in body` where x is used once
//!    → `body[42/x]` (replace the single use with the literal)
//!
//! Runs to fixpoint — simplifications may expose more opportunities.

const std = @import("std");
const hir = @import("hir.zig");
const typecheck = @import("typecheck.zig");

pub const HirLetSimpl = struct {
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(hir.HirExpr),
    simplified: usize,

    pub fn init(allocator: std.mem.Allocator, expressions: *std.ArrayList(hir.HirExpr)) HirLetSimpl {
        return .{
            .allocator = allocator,
            .expressions = expressions,
            .simplified = 0,
        };
    }

    pub fn run(self: *HirLetSimpl) void {
        var changed = true;
        while (changed) {
            changed = false;
            const len = self.expressions.items.len;
            for (0..len) |i| {
                if (self.simplifyLet(@intCast(i))) {
                    changed = true;
                }
            }
        }
    }

    fn simplifyLet(self: *HirLetSimpl, id: hir.HirId) bool {
        if (id >= self.expressions.items.len) return false;
        const kind = self.expressions.items[id].kind;
        if (kind != .let) return false;

        const let = kind.let;
        const val_kind = self.expressions.items[let.value].kind;

        // 1. Identity let: let x = x in body → body
        if (val_kind == .local and val_kind.local == let.name) {
            self.replaceWith(id, let.body);
            self.simplified += 1;
            return true;
        }

        // 2. Dead let: let x = e in body where x is unused and e is pure
        if (!self.isUsed(let.name, let.body) and isPure(val_kind)) {
            self.replaceWith(id, let.body);
            self.simplified += 1;
            return true;
        }

        // 3. Single-use literal inline: let x = literal in body
        if (isLiteral(val_kind) and self.countUses(let.name, let.body) == 1) {
            self.inlineSingleUse(id, let.name, let.value, let.body);
            self.simplified += 1;
            return true;
        }

        return false;
    }

    /// Replace expression `id` with expression `other_id` (copy in place).
    fn replaceWith(self: *HirLetSimpl, id: hir.HirId, other_id: hir.HirId) void {
        self.expressions.items[id] = self.expressions.items[other_id];
        self.expressions.items[id].id = id;
    }

    /// Check if a local variable is used in an expression subtree.
    fn isUsed(self: *HirLetSimpl, name: hir.LocalVarId, root: hir.HirId) bool {
        return self.countUses(name, root) > 0;
    }

    /// Count uses of a local variable in an expression subtree.
    fn countUses(self: *HirLetSimpl, name: hir.LocalVarId, id: hir.HirId) usize {
        if (id >= self.expressions.items.len) return 0;
        const kind = self.expressions.items[id].kind;
        var count: usize = 0;
        switch (kind) {
            .local => |lv| {
                if (lv == name) count = 1;
            },
            .int, .float, .bool, .char, .string, .global, .constructor => {},
            .primop => |p| {
                for (p.args) |a| count += self.countUses(name, a);
            },
            .let => |le| {
                count += self.countUses(name, le.value);
                // Don't count past the binding — name is shadowed
                if (le.name != name) {
                    count += self.countUses(name, le.body);
                }
            },
            .let_rec => |lr| {
                for (lr.bindings) |b| {
                    count += self.countUses(name, b.value);
                }
                // Don't count past the bindings — names are shadowed
                for (lr.bindings) |b| {
                    if (b.name == name) return count;
                }
                count += self.countUses(name, lr.body);
            },
            .if_ => |i| {
                count += self.countUses(name, i.cond);
                count += self.countUses(name, i.then);
                count += self.countUses(name, i.else_);
            },
            .lambda => |l| {
                // Don't count past the binding
                for (l.params) |p| {
                    if (p == name) return count;
                }
                count += self.countUses(name, l.body);
            },
            .apply => |a| {
                count += self.countUses(name, a.func);
                count += self.countUses(name, a.arg);
            },
            .match => |m| {
                count += self.countUses(name, m.scrutinee);
                for (m.arms) |arm| {
                    if (arm.guard) |g| count += self.countUses(name, g);
                    count += self.countUses(name, arm.body);
                }
            },
            .record => |r| {
                for (r.fields) |f| count += self.countUses(name, f.value);
            },
            .record_access => |ra| count += self.countUses(name, ra.record),
            .tuple => |t| {
                for (t.elements) |e| count += self.countUses(name, e);
            },
            .ref => |inner| count += self.countUses(name, inner),
            .deref => |inner| count += self.countUses(name, inner),
            .assign => |a| {
                count += self.countUses(name, a.target);
                count += self.countUses(name, a.value);
            },
            .comptime_expr => |inner| count += self.countUses(name, inner),
        }
        return count;
    }

    /// Inline a single-use literal: replace the one use of `name` in `body`
    /// with the literal value `val_id`.
    fn inlineSingleUse(self: *HirLetSimpl, id: hir.HirId, name: hir.LocalVarId, val_id: hir.HirId, body: hir.HirId) void {
        self.inlineInExpr(name, val_id, body);
        self.replaceWith(id, body);
    }

    /// Replace the single use of `name` in `id` with `val_id`.
    fn inlineInExpr(self: *HirLetSimpl, name: hir.LocalVarId, val_id: hir.HirId, id: hir.HirId) void {
        if (id >= self.expressions.items.len) return;
        const kind = self.expressions.items[id].kind;
        switch (kind) {
            .local => |lv| {
                if (lv == name) {
                    self.expressions.items[id] = self.expressions.items[val_id];
                    self.expressions.items[id].id = id;
                }
            },
            .int, .float, .bool, .char, .string, .global, .constructor => {},
            .primop => |p| {
                for (p.args) |a| self.inlineInExpr(name, val_id, a);
            },
            .let => |le| {
                self.inlineInExpr(name, val_id, le.value);
                if (le.name != name) {
                    self.inlineInExpr(name, val_id, le.body);
                }
            },
            .let_rec => |lr| {
                for (lr.bindings) |b| self.inlineInExpr(name, val_id, b.value);
                for (lr.bindings) |b| {
                    if (b.name == name) return;
                }
                self.inlineInExpr(name, val_id, lr.body);
            },
            .if_ => |i| {
                self.inlineInExpr(name, val_id, i.cond);
                self.inlineInExpr(name, val_id, i.then);
                self.inlineInExpr(name, val_id, i.else_);
            },
            .lambda => |l| {
                for (l.params) |p| {
                    if (p == name) return;
                }
                self.inlineInExpr(name, val_id, l.body);
            },
            .apply => |a| {
                self.inlineInExpr(name, val_id, a.func);
                self.inlineInExpr(name, val_id, a.arg);
            },
            .match => |m| {
                self.inlineInExpr(name, val_id, m.scrutinee);
                for (m.arms) |arm| {
                    if (arm.guard) |g| self.inlineInExpr(name, val_id, g);
                    self.inlineInExpr(name, val_id, arm.body);
                }
            },
            .record => |r| {
                for (r.fields) |f| self.inlineInExpr(name, val_id, f.value);
            },
            .record_access => |ra| self.inlineInExpr(name, val_id, ra.record),
            .tuple => |t| {
                for (t.elements) |e| self.inlineInExpr(name, val_id, e);
            },
            .ref => |inner| self.inlineInExpr(name, val_id, inner),
            .deref => |inner| self.inlineInExpr(name, val_id, inner),
            .assign => |a| {
                self.inlineInExpr(name, val_id, a.target);
                self.inlineInExpr(name, val_id, a.value);
            },
            .comptime_expr => |inner| self.inlineInExpr(name, val_id, inner),
        }
    }
};

fn isPure(kind: hir.HirExprKind) bool {
    return switch (kind) {
        .int, .float, .bool, .char, .string, .local, .global => true,
        .lambda, .tuple, .record, .constructor => true,
        .primop => |p| switch (p.op) {
            .ptrtoint, .inttoptr, .bitcast => false,
            else => true,
        },
        // Conservative: treat everything else as impure
        else => false,
    };
}

fn isLiteral(kind: hir.HirExprKind) bool {
    return switch (kind) {
        .int, .float, .bool, .char, .string => true,
        else => false,
    };
}
