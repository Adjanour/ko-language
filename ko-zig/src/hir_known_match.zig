//! HIR Known-Constructor Match Reduction
//!
//! When a `match` scrutinee is a known constructor application
//! (e.g. `match (Cons 1 Nil) | Cons h t -> ... | Nil -> ...`),
//! reduce to the matching arm with pattern variables bound.
//!
//! This is a key optimization: it eliminates dead match arms and
//! enables further simplification (beta reduction, DCE, etc.).

const std = @import("std");
const hir = @import("hir.zig");
const typecheck = @import("typecheck.zig");

pub const HirKnownMatch = struct {
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(hir.HirExpr),
    reduced: usize,

    pub fn init(allocator: std.mem.Allocator, expressions: *std.ArrayList(hir.HirExpr)) HirKnownMatch {
        return .{
            .allocator = allocator,
            .expressions = expressions,
            .reduced = 0,
        };
    }

    pub fn run(self: *HirKnownMatch) void {
        var changed = true;
        while (changed) {
            changed = false;
            const len = self.expressions.items.len;
            for (0..len) |i| {
                if (self.tryReduce(@intCast(i))) {
                    changed = true;
                }
            }
        }
    }

    fn tryReduce(self: *HirKnownMatch, id: hir.HirId) bool {
        if (id >= self.expressions.items.len) return false;
        const kind = self.expressions.items[id].kind;
        if (kind != .match) return false;

        const m = kind.match;

        // Check if the scrutinee is a known constructor application:
        // `Constructor arg1 arg2 ...` = apply(apply(...Constructor, arg1), arg2)
        const ctor_name = self.getConstructorName(m.scrutinee) orelse return false;
        const ctor_args = self.getConstructorArgs(m.scrutinee);

        // Find the matching arm
        for (m.arms) |arm| {
            if (arm.pattern == .constructor) {
                const cp = arm.pattern.constructor;
                if (std.mem.eql(u8, cp.ctor_name, ctor_name)) {
                    // Check arity matches
                    if (cp.args.len != ctor_args.len) continue;

                    // Build the body with pattern variables bound
                    var result = arm.body;
                    // Bind pattern variables in reverse order (innermost first)
                    var i = cp.args.len;
                    while (i > 0) {
                        i -= 1;
                        result = self.bindPatternVar(cp.args[i], ctor_args[i], result, arm.body);
                    }

                    self.replaceWith(id, result);
                    self.reduced += 1;
                    return true;
                }
            }
        }
        return false;
    }

    /// Extract the constructor name from a scrutinee expression.
    /// Handles: `Ctor`, `Ctor arg1`, `Ctor arg1 arg2`, etc.
    fn getConstructorName(self: *HirKnownMatch, id: hir.HirId) ?[]const u8 {
        if (id >= self.expressions.items.len) return null;
        return switch (self.expressions.items[id].kind) {
            .constructor => |c| c.ctor_name,
            .apply => |a| self.getConstructorName(a.func),
            else => null,
        };
    }

    /// Extract the constructor arguments from a scrutinee expression.
    /// `Ctor a b c` → [a, b, c]
    fn getConstructorArgs(self: *HirKnownMatch, id: hir.HirId) []const hir.HirId {
        if (id >= self.expressions.items.len) return &.{};
        return switch (self.expressions.items[id].kind) {
            .constructor => |c| c.args,
            .apply => |a| blk: {
                const inner = self.getConstructorArgs(a.func);
                // Append the current arg
                const result = self.allocator.alloc(hir.HirId, inner.len + 1) catch return &.{};
                @memcpy(result[0..inner.len], inner);
                result[inner.len] = a.arg;
                break :blk result;
            },
            else => &.{},
        };
    }

    /// Bind a pattern variable: for a simple bind `x`, create `let x = arg in body`.
    fn bindPatternVar(
        self: *HirKnownMatch,
        pat: hir.Pattern,
        arg: hir.HirId,
        body: hir.HirId,
        body_orig: hir.HirId,
    ) hir.HirId {
        switch (pat) {
            .bind => |lv| {
                return self.addExpr(.{
                    .let = .{ .name = lv, .value = arg, .body = body },
                }, self.expressions.items[body_orig].ty, self.expressions.items[body_orig].span);
            },
            .wildcard => return body,
            else => return body, // Nested patterns need more work (future)
        }
    }

    fn replaceWith(self: *HirKnownMatch, id: hir.HirId, other_id: hir.HirId) void {
        self.expressions.items[id] = self.expressions.items[other_id];
        self.expressions.items[id].id = id;
    }

    fn addExpr(self: *HirKnownMatch, kind: hir.HirExprKind, ty: *const typecheck.Type, span: hir.SourceSpan) hir.HirId {
        const id = self.expressions.items.len;
        self.expressions.append(self.allocator, .{
            .id = id,
            .ty = ty,
            .span = span,
            .kind = kind,
        }) catch unreachable;
        return id;
    }
};
