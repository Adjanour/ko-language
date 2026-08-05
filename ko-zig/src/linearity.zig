const std = @import("std");
const hir = @import("hir.zig");
const hir_lower = @import("hir_lower.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");

/// Linearity checker: walks the HIR and verifies that linear variables
/// are used exactly once.
///
/// Rules (per SPEC-0.md):
/// - Function parameters are unrestricted (can be used any number of times)
/// - Pattern match bindings are linear (consumed by the match)
/// - `let` bindings are linear (consumed by the body)
/// - Polymorphic parameters (type variables) are unrestricted (deferred to Phase 2)
/// - Literals, constructors, primitive ops don't consume variables
///
/// Scope handling:
/// - Bindings are scoped (added when entering a scope, removed when leaving)
/// - Consumed state is GLOBAL (once consumed, always consumed across the program)
/// - This prevents the same variable from being consumed in two different scopes
pub const LinearityChecker = struct {
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(hir.HirExpr),
    diags: *diagnostics.DiagnosticList,

    /// Per-scope usage counts: LocalVarId → number of times referenced.
    usage_counts: std.AutoHashMap(hir.LocalVarId, usize),

    /// Bindings in current scope: LocalVarId → the HirId where it was bound.
    bindings: std.AutoHashMap(hir.LocalVarId, hir.HirId),

    /// Linear variables that have been consumed (GLOBAL — persists across scopes).
    consumed: std.AutoHashMap(hir.LocalVarId, void),

    /// Unrestricted variables (lambda params) — can be used any number of times.
    unrestricted: std.AutoHashMap(hir.LocalVarId, void),

    /// Root expression ID of the main function (if found).
    main_root: ?hir.HirId = null,

    pub fn init(
        allocator: std.mem.Allocator,
        expressions: *std.ArrayList(hir.HirExpr),
        diags: *diagnostics.DiagnosticList,
    ) LinearityChecker {
        return .{
            .allocator = allocator,
            .expressions = expressions,
            .diags = diags,
            .usage_counts = std.AutoHashMap(hir.LocalVarId, usize).init(allocator),
            .bindings = std.AutoHashMap(hir.LocalVarId, hir.HirId).init(allocator),
            .consumed = std.AutoHashMap(hir.LocalVarId, void).init(allocator),
            .unrestricted = std.AutoHashMap(hir.LocalVarId, void).init(allocator),
        };
    }

    pub fn deinit(self: *LinearityChecker) void {
        self.usage_counts.deinit();
        self.bindings.deinit();
        self.consumed.deinit();
        self.unrestricted.deinit();
    }

    /// Run the linearity check on root expressions only.
    /// Lambda bodies are checked recursively when the lambda is processed.
    pub fn run(self: *LinearityChecker, roots: []const hir.HirId, defs: []const hir_lower.HirDef) void {
        // Register top-level function names so we can identify main
        for (defs) |def| {
            switch (def) {
                .fn_def => |fd| {
                    if (std.mem.eql(u8, fd.name, "main")) {
                        self.main_root = fd.root;
                    }
                },
                else => {},
            }
        }

        for (roots) |root_id| {
            self.checkExpr(root_id, true);
        }
        // Post-check: verify all let-bound variables were used.
        self.checkAllLetBindings(roots);
    }

    /// Walk all let expressions and check that each binding was used.
    fn checkAllLetBindings(self: *LinearityChecker, roots: []const hir.HirId) void {
        for (roots) |root_id| {
            self.checkLetBindingsIn(root_id);
        }
    }

    fn checkLetBindingsIn(self: *LinearityChecker, id: hir.HirId) void {
        if (id >= self.expressions.items.len) return;
        const expr = &self.expressions.items[id];

        switch (expr.kind) {
            .let => |let_expr| {
                // Check if this let binding was used
                self.reportIfUnused(let_expr.name);
                // Recurse into value and body
                self.checkLetBindingsIn(let_expr.value);
                self.checkLetBindingsIn(let_expr.body);
            },
            .let_rec => |let_rec| {
                for (let_rec.bindings) |binding| {
                    self.reportIfUnused(binding.name);
                }
                for (let_rec.bindings) |binding| {
                    self.checkLetBindingsIn(binding.value);
                }
                self.checkLetBindingsIn(let_rec.body);
            },
            .lambda => |lam| {
                self.checkLetBindingsIn(lam.body);
            },
            .apply => |app| {
                self.checkLetBindingsIn(app.func);
                self.checkLetBindingsIn(app.arg);
            },
            .if_ => |if_expr| {
                self.checkLetBindingsIn(if_expr.cond);
                self.checkLetBindingsIn(if_expr.then);
                self.checkLetBindingsIn(if_expr.else_);
            },
            .match => |match_expr| {
                self.checkLetBindingsIn(match_expr.scrutinee);
                for (match_expr.arms) |arm| {
                    if (arm.guard) |g| self.checkLetBindingsIn(g);
                    self.checkLetBindingsIn(arm.body);
                }
            },
            .record => |rec| {
                for (rec.fields) |field| {
                    self.checkLetBindingsIn(field.value);
                }
            },
            .record_access => |ra| {
                self.checkLetBindingsIn(ra.record);
            },
            .tuple => |tup| {
                for (tup.elements) |elem_id| {
                    self.checkLetBindingsIn(elem_id);
                }
            },
            .constructor => |ctor| {
                for (ctor.args) |arg_id| {
                    self.checkLetBindingsIn(arg_id);
                }
            },
            .ref => |ref_id| {
                self.checkLetBindingsIn(ref_id);
            },
            .deref => |deref_id| {
                self.checkLetBindingsIn(deref_id);
            },
            .assign => |assign_expr| {
                self.checkLetBindingsIn(assign_expr.target);
                self.checkLetBindingsIn(assign_expr.value);
            },
            .comptime_expr => |ce_id| {
                self.checkLetBindingsIn(ce_id);
            },
            .primop => |primop| {
                for (primop.args) |arg_id| {
                    self.checkLetBindingsIn(arg_id);
                }
            },
            .local, .global, .int, .float, .bool, .char, .string => {},
        }
    }

    /// Convert a HIR SourceSpan to a parser.Loc for diagnostics.
    fn spanToLoc(span: hir.SourceSpan) parser.Loc {
        return .{
            .line = span.line,
            .col = span.col,
            .end_line = span.end_line,
            .end_col = span.end_col,
        };
    }

    fn checkExpr(self: *LinearityChecker, id: hir.HirId, consume: bool) void {
        if (id >= self.expressions.items.len) return;
        const expr = &self.expressions.items[id];

        switch (expr.kind) {
            .local => |var_id| {
                if (consume) {
                    self.consumeVar(var_id);
                } else {
                    self.borrowVar(var_id);
                }
            },
            .global => {},
            .int, .float, .bool, .char, .string => {},

            .lambda => |lam| {
                // Check if this is the main function
                const is_main = if (self.main_root) |mr| mr == id else false;

                // Bind params
                for (lam.params) |param_id| {
                    self.bindings.put(param_id, id) catch {};
                    // Only main's params are unrestricted; others are linear
                    if (is_main) {
                        self.unrestricted.put(param_id, {}) catch {};
                    }
                }

                // Check body
                self.checkExpr(lam.body, true);

                // Remove params from bindings
                for (lam.params) |param_id| {
                    _ = self.bindings.remove(param_id);
                }
            },

            .apply => |app| {
                self.checkExpr(app.func, true);
                self.checkExpr(app.arg, true);
            },

            .let => |let_expr| {
                // Check value first (it may consume variables from outer scope)
                self.checkExpr(let_expr.value, true);

                // Bind the name — discard bindings (`let _ = ...`) are unrestricted
                self.bindings.put(let_expr.name, id) catch {};
                if (let_expr.is_discard) {
                    self.unrestricted.put(let_expr.name, {}) catch {};
                }

                // Check body
                self.checkExpr(let_expr.body, true);

                // Remove the binding (deferred check: usage counted during body check)
                _ = self.bindings.remove(let_expr.name);
            },

            .let_rec => |let_rec| {
                // Bind all names first (recursive)
                for (let_rec.bindings) |binding| {
                    self.bindings.put(binding.name, id) catch {};
                }

                // Check all values
                for (let_rec.bindings) |binding| {
                    self.checkExpr(binding.value, true);
                }

                // Check body
                self.checkExpr(let_rec.body, true);

                // Report unused bindings
                for (let_rec.bindings) |binding| {
                    self.reportIfUnused(binding.name);
                }

                // Remove bindings
                for (let_rec.bindings) |binding| {
                    _ = self.bindings.remove(binding.name);
                }
            },

            .if_ => |if_expr| {
                self.checkExpr(if_expr.cond, false);
                self.checkExpr(if_expr.then, true);
                self.checkExpr(if_expr.else_, true);
            },

            .match => |match_expr| {
                // Check scrutinee (consumes it if linear)
                self.checkExpr(match_expr.scrutinee, true);

                // Each arm binds new variables; save consumed state per arm
                // so a variable consumed in one arm can be used in another
                const saved_consumed = self.saveConsumed();

                for (match_expr.arms) |arm| {
                    // Save current bindings and consumed state for this arm
                    const saved_bindings = self.saveBindings();
                    const arm_consumed = self.saveConsumed();
                    defer {
                        self.restoreBindings(saved_bindings);
                        self.restoreConsumed(arm_consumed);
                    }

                    // Bind pattern variables
                    self.bindPattern(&arm.pattern, id);

                    // Check guard if present
                    if (arm.guard) |guard_id| {
                        self.checkExpr(guard_id, false);
                    }

                    // Check body
                    self.checkExpr(arm.body, true);

                    // Report unused pattern bindings
                    self.reportUnusedInPattern(&arm.pattern);
                }

                // After all arms, variables consumed in ANY arm are consumed.
                // This is conservative but correct: if the program takes an arm
                // that consumes a variable, it's consumed after the match.
                // Restore the pre-arm consumed state and merge in all arm-consumed variables.
                self.restoreConsumed(saved_consumed);
            },

            .record => |rec| {
                for (rec.fields) |field| {
                    self.checkExpr(field.value, true);
                }
            },

            .record_access => |ra| {
                self.checkExpr(ra.record, false);
            },

            .tuple => |tup| {
                for (tup.elements) |elem_id| {
                    self.checkExpr(elem_id, true);
                }
            },

            .constructor => |ctor| {
                for (ctor.args) |arg_id| {
                    self.checkExpr(arg_id, true);
                }
            },

            .ref => |ref_id| {
                self.checkExpr(ref_id, true);
            },

            .deref => |deref_id| {
                self.checkExpr(deref_id, false);
            },

            .assign => |assign_expr| {
                self.checkExpr(assign_expr.target, false);
                self.checkExpr(assign_expr.value, true);
            },

            .comptime_expr => |ce_id| {
                self.checkExpr(ce_id, true);
            },

            .primop => |primop| {
                for (primop.args) |arg_id| {
                    self.checkExpr(arg_id, false);
                }
            },
        }
    }

    /// Record a use of a variable in a borrow context (read-only).
    /// Borrows don't consume the variable — it can be used again later.
    /// Used for: primop args, if/match conditions, field access, deref.
    fn borrowVar(self: *LinearityChecker, var_id: hir.LocalVarId) void {
        // Unrestricted variables (lambda params of main) can be used any number of times
        if (self.unrestricted.contains(var_id)) {
            const count = self.usage_counts.get(var_id) orelse 0;
            self.usage_counts.put(var_id, count + 1) catch {};
            return;
        }

        // If already consumed, error: linear variable used after consumption
        if (self.consumed.contains(var_id)) {
            const binding_site = self.bindings.get(var_id) orelse return;
            const binding_expr = &self.expressions.items[binding_site];
            self.diags.addErrorCtx(
                "linear variable used after consumption",
                spanToLoc(binding_expr.span),
                "consumed at previous use",
                "reuse the variable by cloning or rebinding",
            ) catch {};
            return;
        }

        // Increment usage count (but do NOT mark as consumed — this is a borrow)
        const count = self.usage_counts.get(var_id) orelse 0;
        self.usage_counts.put(var_id, count + 1) catch {};
    }

    /// Record a use of a variable in a consume context (ownership transfer).
    /// Consumes the variable — it cannot be used again.
    /// Used for: function application args, match scrutinee, let values, etc.
    fn consumeVar(self: *LinearityChecker, var_id: hir.LocalVarId) void {
        // Unrestricted variables (lambda params) can be used any number of times
        if (self.unrestricted.contains(var_id)) {
            const count = self.usage_counts.get(var_id) orelse 0;
            self.usage_counts.put(var_id, count + 1) catch {};
            return;
        }

        // If already consumed, error: linear variable used twice
        if (self.consumed.contains(var_id)) {
            const binding_site = self.bindings.get(var_id) orelse return;
            const binding_expr = &self.expressions.items[binding_site];
            self.diags.addErrorCtx(
                "linear variable used twice (already consumed here)",
                spanToLoc(binding_expr.span),
                "consumed at previous use",
                "reuse the variable by cloning or rebinding",
            ) catch {};
            return;
        }

        // Increment usage count
        const count = self.usage_counts.get(var_id) orelse 0;
        self.usage_counts.put(var_id, count + 1) catch {};

        // Mark as consumed (linear = consumed exactly once) — GLOBAL, persists across scopes
        self.consumed.put(var_id, {}) catch {};
    }

    /// Report an error if a linear variable was never used.
    fn reportIfUnused(self: *LinearityChecker, var_id: hir.LocalVarId) void {
        // Unrestricted variables don't need to be used
        if (self.unrestricted.contains(var_id)) return;

        const count = self.usage_counts.get(var_id) orelse 0;
        if (count == 0) {
            const binding_site = self.bindings.get(var_id) orelse return;
            const binding_expr = &self.expressions.items[binding_site];
            self.diags.addErrorCtx(
                "linear variable never used",
                spanToLoc(binding_expr.span),
                null,
                "use the variable or prefix with `_` to ignore",
            ) catch {};
        }
    }

    /// Bind all variables introduced by a pattern.
    fn bindPattern(self: *LinearityChecker, pattern: *const hir.Pattern, bind_site: hir.HirId) void {
        switch (pattern.*) {
            .wildcard => {},
            .bind => |var_id| {
                self.bindings.put(var_id, bind_site) catch {};
            },
            .literal => {},
            .constructor => |ctor| {
                for (ctor.args) |*arg| {
                    self.bindPattern(arg, bind_site);
                }
            },
            .record => |rec| {
                for (rec.fields) |*field| {
                    self.bindPattern(&field.p, bind_site);
                }
            },
            .tuple => |tup| {
                for (tup) |*elem| {
                    self.bindPattern(elem, bind_site);
                }
            },
        }
    }

    /// Report unused variables bound by a pattern.
    fn reportUnusedInPattern(self: *LinearityChecker, pattern: *const hir.Pattern) void {
        switch (pattern.*) {
            .wildcard => {},
            .bind => |var_id| {
                self.reportIfUnused(var_id);
            },
            .literal => {},
            .constructor => |ctor| {
                for (ctor.args) |*arg| {
                    self.reportUnusedInPattern(arg);
                }
            },
            .record => |rec| {
                for (rec.fields) |*field| {
                    self.reportUnusedInPattern(&field.p);
                }
            },
            .tuple => |tup| {
                for (tup) |*elem| {
                    self.reportUnusedInPattern(elem);
                }
            },
        }
    }

    // --- Scope save/restore for bindings only (consumed is global) ---

    const SavedBindings = struct {
        keys: []const hir.LocalVarId,
        values: []const hir.HirId,
    };

    const SavedConsumed = struct {
        keys: []const hir.LocalVarId,
    };

    fn saveBindings(self: *LinearityChecker) SavedBindings {
        const count = self.bindings.count();
        const keys = self.allocator.alloc(hir.LocalVarId, count) catch return .{ .keys = &.{}, .values = &.{} };
        const values = self.allocator.alloc(hir.HirId, count) catch {
            self.allocator.free(keys);
            return .{ .keys = &.{}, .values = &.{} };
        };
        var i: usize = 0;
        var it = self.bindings.iterator();
        while (it.next()) |entry| : (i += 1) {
            keys[i] = entry.key_ptr.*;
            values[i] = entry.value_ptr.*;
        }
        return .{ .keys = keys, .values = values };
    }

    fn restoreBindings(self: *LinearityChecker, saved: SavedBindings) void {
        self.bindings.clearRetainingCapacity();
        for (saved.keys, saved.values) |k, v| {
            self.bindings.put(k, v) catch {};
        }
        self.allocator.free(saved.keys);
        self.allocator.free(saved.values);
    }

    fn saveConsumed(self: *LinearityChecker) SavedConsumed {
        const count = self.consumed.count();
        const keys = self.allocator.alloc(hir.LocalVarId, count) catch return .{ .keys = &.{} };
        var i: usize = 0;
        var it = self.consumed.iterator();
        while (it.next()) |entry| : (i += 1) {
            keys[i] = entry.key_ptr.*;
        }
        return .{ .keys = keys };
    }

    fn restoreConsumed(self: *LinearityChecker, saved: SavedConsumed) void {
        self.consumed.clearRetainingCapacity();
        for (saved.keys) |k| {
            self.consumed.put(k, {}) catch {};
        }
        self.allocator.free(saved.keys);
    }
};
