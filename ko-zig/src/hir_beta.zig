//! HIR Beta Reduction Pass
//!
//! Rewrites `(\x -> body) arg` → `let x = arg in body`.
//! For multi-param lambdas applied to multiple args, reduces one param at a
//! time (the inner apply becomes reducible after the outer let is floated).
//!
//! Partial applications (fewer args than params) are NOT reduced.

const std = @import("std");
const hir = @import("hir.zig");
const typecheck = @import("typecheck.zig");

pub const HirBeta = struct {
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(hir.HirExpr),
    reduced: usize,

    pub fn init(allocator: std.mem.Allocator, expressions: *std.ArrayList(hir.HirExpr)) HirBeta {
        return .{
            .allocator = allocator,
            .expressions = expressions,
            .reduced = 0,
        };
    }

    pub fn run(self: *HirBeta) void {
        // Run to fixpoint — beta reduction may expose new opportunities.
        var changed = true;
        while (changed) {
            changed = false;
            const len = self.expressions.items.len;
            for (0..len) |i| {
                if (self.tryBetaReduce(@intCast(i))) {
                    changed = true;
                }
            }
        }
    }

    /// If expression `id` is `apply(lambda(...), arg)`, rewrite in place.
    fn tryBetaReduce(self: *HirBeta, id: hir.HirId) bool {
        if (id >= self.expressions.items.len) return false;
        const kind = self.expressions.items[id].kind;
        if (kind != .apply) return false;

        const apply = kind.apply;
        const func_expr = self.expressions.items[apply.func];
        if (func_expr.kind != .lambda) return false;

        const lam = func_expr.kind.lambda;
        if (lam.params.len == 0) return false;

        // Reduce: apply(lambda([p, ...], body), arg) → let p = arg in body
        // If the lambda has more params, the body becomes a new lambda
        // with the remaining params.
        const param = lam.params[0];
        const arg = apply.arg;

        const body = if (lam.params.len > 1) blk: {
            // Create inner lambda with remaining params
            const remaining = self.allocator.alloc(hir.LocalVarId, lam.params.len - 1) catch return false;
            @memcpy(remaining, lam.params[1..]);
            break :blk self.addExpr(.{
                .lambda = .{
                    .params = remaining,
                    .body = lam.body,
                    .captures = lam.captures,
                },
            }, func_expr.ty, func_expr.span);
        } else lam.body;

        // Rewrite this expression as: let param = arg in body
        self.expressions.items[id].kind = .{ .let = .{
            .name = param,
            .value = arg,
            .body = body,
        } };

        self.reduced += 1;
        return true;
    }

    fn addExpr(self: *HirBeta, kind: hir.HirExprKind, ty: *const typecheck.Type, span: hir.SourceSpan) hir.HirId {
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
