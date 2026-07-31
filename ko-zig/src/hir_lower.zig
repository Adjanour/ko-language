const std = @import("std");
const ast = @import("ast.zig");
const hir = @import("hir.zig");
const typecheck = @import("typecheck.zig");

/// A top-level function definition, recorded for downstream lowering
/// (the root is the lambda expression wrapping the function body).
pub const HirFnDef = struct {
    name: []const u8,
    root: hir.HirId,
    arity: usize,
};

pub const HirCtorDecl = struct {
    name: []const u8,
    arity: usize,
};

pub const HirTypeDef = struct {
    name: []const u8,
    ctors: []const HirCtorDecl,
};

/// Top-level definition table entry, in source order.
pub const HirDef = union(enum) {
    fn_def: HirFnDef,
    let_binding: struct { name: []const u8, root: hir.HirId },
    type_def: HirTypeDef,
};

/// Shift every HirId embedded in an expression's payload by `offset`.
/// Needed when splicing a module's expression list (whose ids are locally
/// 0-based) into another list at a nonzero starting position.
fn offsetExprIds(e: *hir.HirExpr, offset: usize) void {
    e.id += offset;
    switch (e.kind) {
        .lambda => |*l| l.body += offset,
        .apply => |*a| {
            a.func += offset;
            a.arg += offset;
        },
        .let => |*l| {
            l.value += offset;
            l.body += offset;
        },
        .let_rec => |*lr| {
            const bindings = @constCast(lr.bindings);
            for (bindings) |*b| b.value += offset;
            lr.body += offset;
        },
        .if_ => |*i| {
            i.cond += offset;
            i.then += offset;
            i.else_ += offset;
        },
        .match => |*m| {
            m.scrutinee += offset;
            const arms = @constCast(m.arms);
            for (arms) |*arm| {
                if (arm.guard) |g| arm.guard = g + offset;
                arm.body += offset;
            }
        },
        .record => |*r| {
            const fields = @constCast(r.fields);
            for (fields) |*f| f.value += offset;
        },
        .record_access => |*ra| ra.record += offset,
        .tuple => |*t| {
            const elems = @constCast(t.elements);
            for (elems) |*el| el.* += offset;
        },
        .constructor => |*c| {
            const args = @constCast(c.args);
            for (args) |*a| a.* += offset;
        },
        .ref => |*r| r.* += offset,
        .deref => |*d| d.* += offset,
        .assign => |*a| {
            a.target += offset;
            a.value += offset;
        },
        .comptime_expr => |*c| c.* += offset,
        .primop => |*p| {
            const args = @constCast(p.args);
            for (args) |*a| a.* += offset;
        },
        .int, .float, .bool, .char, .string, .local, .global => {},
    }
}

pub const HirLower = struct {
    allocator: std.mem.Allocator,
    inferer: *typecheck.Inferer,
    expressions: std.ArrayList(hir.HirExpr),
    roots: std.ArrayList(hir.HirId),
    defs: std.ArrayList(HirDef),
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
            .defs = .empty,
            .next_id = 0,
            .scopes = .empty,
            .next_local = 0,
        };
    }

    pub fn deinit(self: *HirLower) void {
        for (self.scopes.items) |*s| s.deinit();
        self.scopes.deinit(self.allocator);
        self.defs.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.expressions.deinit(self.allocator);
    }

    pub fn lowerProgram(self: *HirLower, program: *const ast.Program) !void {
        // Process imports — register imported function definitions
        // The typechecker already registered their types; we just need their bodies in HIR.
        if (self.inferer.module_loader) |loader| {
            for (program.imports) |imp| {
                const mod = loader.loadModule(imp.path) catch |err| {
                    std.log.err("Failed to load module: {}", .{err});
                    continue;
                } orelse {
                    std.log.err("Module not found: {s}", .{std.mem.join(self.allocator, "/", imp.path) catch "unknown"});
                    continue;
                };
                const module_name = imp.alias orelse imp.path[imp.path.len - 1];

                // Parse the imported module
                var imp_parser = try @import("parser.zig").Parser.init(self.allocator, mod.source);
                defer imp_parser.deinit();
                const imp_prog = imp_parser.parse_program() catch |err| {
                    std.log.err("Failed to parse imported module '{s}': {}", .{ module_name, err });
                    continue;
                };

                // Create a fresh inferer for the imported module to get type info
                var imp_inferer = try self.allocator.create(typecheck.Inferer);
                imp_inferer.* = typecheck.Inferer.init(self.allocator);
                imp_inferer.module_loader = loader;
                imp_inferer.inferProgram(&imp_prog) catch |err| {
                    std.log.err("Failed to typecheck imported module '{s}': {}", .{ module_name, err });
                    self.allocator.destroy(imp_inferer);
                    continue;
                };

                // Create a fresh HIR lower for the imported module
                var imp_hl = HirLower.init(self.allocator, imp_inferer);
                defer imp_hl.deinit();

                for (imp_prog.definitions) |def| {
                    switch (def) {
                        .fn_def => |fd| {
                            // Lower ALL functions (helpers may be called by selected ones)
                            // Use qualified name so they don't collide with main program
                            const prefixed_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, fd.name });
                            var fd_copy = fd;
                            fd_copy.name = prefixed_name;
                            try imp_hl.lowerDefinition(&.{ .fn_def = fd_copy });

                            // Also register with unqualified name for intra-module calls
                            if (!std.mem.eql(u8, fd.name, prefixed_name)) {
                                const fd_unqual = fd;
                                try imp_hl.lowerDefinition(&.{ .fn_def = fd_unqual });
                            }
                        },
                        .type_def => |td| {
                            const prefixed_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, td.name });
                            var td_copy = td;
                            td_copy.name = prefixed_name;
                            try imp_hl.lowerDefinition(&.{ .type_def = td_copy });
                        },
                        else => {},
                    }
                }

                // Copy imported expressions and definitions into the main HIR.
                // The imported HirLower numbered its expressions from 0; shift
                // every id (both the array position and every HirId embedded
                // inside each expression's payload) by expr_offset so they
                // remain valid once appended after whatever's already here.
                const expr_offset = self.expressions.items.len;
                for (imp_hl.expressions.items) |e| {
                    var e_copy = e;
                    offsetExprIds(&e_copy, expr_offset);
                    try self.expressions.append(self.allocator, e_copy);
                }
                // Keep self.next_id in sync so the main program's own
                // subsequent allocExpr calls don't reuse positions we just filled.
                self.next_id = self.expressions.items.len;
                for (imp_hl.defs.items) |d| {
                    // Adjust root IDs to account for expression offset
                    var adjusted_def = d;
                    switch (adjusted_def) {
                        .fn_def => |*fd| {
                            fd.root += expr_offset;
                        },
                        .let_binding => |*lb| {
                            lb.root += expr_offset;
                        },
                        else => {},
                    }
                    try self.defs.append(self.allocator, adjusted_def);
                }

                // Copy imported inferer's global entries to main inferer
                var glob_iter = imp_inferer.global.bindings.iterator();
                while (glob_iter.next()) |entry| {
                    try self.inferer.global.set(entry.key_ptr.*, entry.value_ptr.*);
                }

                self.allocator.destroy(imp_inferer);
            }
        }

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
                const root = try self.allocExpr(.{
                    .lambda = .{
                        .params = try param_ids.toOwnedSlice(self.allocator),
                        .body = body_id,
                        .captures = &.{},
                    },
                }, fd_ty, fd.body);
                try self.defs.append(self.allocator, .{ .fn_def = .{
                    .name = fd.name,
                    .root = root,
                    .arity = fd.params.len,
                } });
            },
            .type_def => |td| {
                var ctors: std.ArrayList(HirCtorDecl) = .empty;
                defer ctors.deinit(self.allocator);
                switch (td.body) {
                    .sum => |cs| {
                        for (cs) |c| {
                            try ctors.append(self.allocator, .{ .name = c.name, .arity = c.params.len });
                        }
                    },
                    .record => {},
                }
                try self.defs.append(self.allocator, .{ .type_def = .{
                    .name = td.name,
                    .ctors = try ctors.toOwnedSlice(self.allocator),
                } });
            },
            .let_binding => |lb| {
                const val_id = try self.lowerExpr(lb.value);
                const lb_ty = self.inferer.expr_types.get(lb.value) orelse
                    @panic("let binding type not found");
                const root = try self.allocExpr(.{ .let = .{ .name = 0, .value = val_id, .body = 0 } }, lb_ty, lb.value);
                try self.defs.append(self.allocator, .{ .let_binding = .{
                    .name = lb.name,
                    .root = root,
                } });
            },
            .import => {},
            .package => {},
            .module_def => |m| {
                // Process module definitions with qualified names
                for (m.definitions) |inner_def| {
                    try self.lowerDefinitionWithPrefix(&inner_def, m.name);
                }
            },
        }
    }

    fn lowerDefinitionWithPrefix(self: *HirLower, def: *const ast.Definition, prefix: []const u8) !void {
        switch (def.*) {
            .fn_def => |fd| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, fd.name })
                else
                    fd.name;
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
                const root = try self.allocExpr(.{
                    .lambda = .{
                        .params = try param_ids.toOwnedSlice(self.allocator),
                        .body = body_id,
                        .captures = &.{},
                    },
                }, fd_ty, fd.body);
                try self.defs.append(self.allocator, .{ .fn_def = .{
                    .name = prefixed_name,
                    .root = root,
                    .arity = fd.params.len,
                } });
            },
            .type_def => |td| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, td.name })
                else
                    td.name;
                var ctors: std.ArrayList(HirCtorDecl) = .empty;
                defer ctors.deinit(self.allocator);
                switch (td.body) {
                    .sum => |cs| {
                        for (cs) |c| {
                            try ctors.append(self.allocator, .{ .name = c.name, .arity = c.params.len });
                        }
                    },
                    .record => {},
                }
                try self.defs.append(self.allocator, .{ .type_def = .{
                    .name = prefixed_name,
                    .ctors = try ctors.toOwnedSlice(self.allocator),
                } });
            },
            .module_def => |m| {
                const mod_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, m.name })
                else
                    m.name;
                for (m.definitions) |inner_def| {
                    try self.lowerDefinitionWithPrefix(&inner_def, mod_prefix);
                }
            },
            .let_binding => |lb| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, lb.name })
                else
                    lb.name;
                const val_id = try self.lowerExpr(lb.value);
                const lb_ty = self.inferer.expr_types.get(lb.value) orelse
                    @panic("let binding type not found");
                const root = try self.allocExpr(.{ .let = .{ .name = 0, .value = val_id, .body = 0 } }, lb_ty, lb.value);
                try self.defs.append(self.allocator, .{ .let_binding = .{
                    .name = prefixed_name,
                    .root = root,
                } });
            },
            .import => {},
            .package => {},
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
            .string_literal => |val| blk: {
                // Strip surrounding quotes once, here — downstream paths
                // (HIR folds, LIR lowering, codegen) see clean string bytes.
                const inner = if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"')
                    val[1 .. val.len - 1]
                else
                    val;
                break :blk self.allocExpr(.{ .string = inner }, ty, expr);
            },
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
                if (blk.items.len == 0) return self.allocExpr(.{ .int = 0 }, ty, expr);
                if (blk.items.len == 1) return self.lowerExpr(blk.items[0]);
                // Chain intermediate items so side effects (assignments, calls)
                // execute in order before the final expression:
                //   item1; item2; …; last  →  let _ = item1 in let _ = item2 in … last
                var result = try self.lowerExpr(blk.items[blk.items.len - 1]);
                var i = blk.items.len - 1;
                while (i > 0) {
                    i -= 1;
                    const item_id = try self.lowerExpr(blk.items[i]);
                    const dummy = try self.newLocal("_blk");
                    result = try self.allocExpr(.{ .let = .{ .name = dummy, .value = item_id, .body = result } }, ty, expr);
                }
                return result;
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
                switch (uop.op) {
                    .deref => return self.allocExpr(.{ .deref = inner_id }, ty, expr),
                    .ref => return self.allocExpr(.{ .ref = inner_id }, ty, expr),
                    else => {},
                }
                const op = astUnaryToPrimOp(uop.op);
                const args = try self.allocator.alloc(hir.HirId, 1);
                args[0] = inner_id;
                return self.allocExpr(.{ .primop = .{ .op = op, .args = args } }, ty, expr);
            },
            .binary_op => |binop| {
                // `::` desugars to a Cons constructor application (mirrors
                // the legacy codegen): left :: right → Cons left right.
                if (binop.op == .cons) {
                    const left_id = try self.lowerExpr(binop.left);
                    const right_id = try self.lowerExpr(binop.right);
                    const cons_ref = try self.allocExpr(.{ .constructor = .{ .type_name = "", .ctor_name = "Cons", .args = &.{} } }, ty, expr);
                    const app1 = try self.allocExpr(.{ .apply = .{ .func = cons_ref, .arg = left_id } }, ty, expr);
                    return self.allocExpr(.{ .apply = .{ .func = app1, .arg = right_id } }, ty, expr);
                }
                const left_id = try self.lowerExpr(binop.left);
                const right_id = try self.lowerExpr(binop.right);
                var op = astBinaryToPrimOp(binop.op);
                // `+` on strings is concatenation, not pointer arithmetic
                // (fixes the documented STRING.md bug at the HIR level).
                if (op == .add) {
                    const lty = self.inferer.expr_types.get(binop.left);
                    const rty = self.inferer.expr_types.get(binop.right);
                    const is_str = struct {
                        fn check(t: ?*const typecheck.Type) bool {
                            const x = t orelse return false;
                            return x.* == .string;
                        }
                    };
                    if (is_str.check(lty) or is_str.check(rty)) op = .concat;
                }
                const args = try self.allocator.alloc(hir.HirId, 2);
                args[0] = left_id;
                args[1] = right_id;
                return self.allocExpr(.{ .primop = .{ .op = op, .args = args } }, ty, expr);
            },
            .let_expr => |le| {
                if (le.pattern) |pat| {
                    // Tuple/constructor destructuring: desugar to match
                    // let (x, y) = value in body  →  match value | (x, y) → body
                    const val_id = try self.lowerExpr(le.value);
                    self.pushScope();
                    defer self.popScope();
                    const hir_pat = try self.lowerPattern(&pat);
                    const body_id = try self.lowerExpr(le.body);
                    var arms: std.ArrayList(hir.MatchArm) = .empty;
                    defer arms.deinit(self.allocator);
                    try arms.append(self.allocator, .{
                        .pattern = hir_pat,
                        .guard = null,
                        .body = body_id,
                    });
                    return self.allocExpr(.{ .match = .{
                        .scrutinee = val_id,
                        .arms = try arms.toOwnedSlice(self.allocator),
                    } }, ty, expr);
                }
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
                    // Pattern first (it introduces binds into scope), then the
                    // body — and each arm gets its own scope so binds don't leak.
                    self.pushScope();
                    const pat = try self.lowerPattern(&arm.pattern);
                    const body_id = try self.lowerExpr(arm.body);
                    self.popScope();
                    try arms.append(self.allocator, .{
                        .pattern = pat,
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
        // Build the left-associative spine in source order: ((f a) b).
        var cur = func_id;
        for (args) |arg| {
            cur = try self.allocExpr(.{ .apply = .{ .func = cur, .arg = arg } }, ty, expr);
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
