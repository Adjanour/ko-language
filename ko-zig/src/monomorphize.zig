const std = @import("std");
const parser = @import("parser.zig");
const ast = @import("ast.zig");

/// Monomorphization pass: replaces calls to polymorphic functions with calls
/// to specialized (monomorphized) copies.
///
/// Per the frozen pipeline: parse → monomorphize → bidirectional-typecheck → linearity-check → codegen
/// This runs BEFORE typechecking. Type arguments are determined from:
/// 1. The callee's type signature (parameter and return types)
/// 2. The structure of the arguments at the call site
///
/// Algorithm:
/// 1. Walk the AST, find all function calls where the callee has a polymorphic type signature
/// 2. At each call site, determine the concrete types from the signature + argument structure
/// 3. For each unique (function, concrete_types) pair, create a specialized copy
/// 4. Replace generic calls with calls to the specialized function
pub const Monomorphizer = struct {
    allocator: std.mem.Allocator,
    specializations: std.StringHashMap(std.ArrayList(Specialization)),
    new_fns: std.ArrayList(parser.FnDef),
    sig_map: std.StringHashMap(FunctionSignature),

    pub const Specialization = struct {
        type_args: std.ArrayList(TypeExpr),
        specialized_name: []const u8,
    };

    pub const TypeExpr = union(enum) {
        int,
        float,
        bool,
        char,
        string,
        unit,
        arrow: struct { from: *TypeExpr, to: *TypeExpr },
        tuple: []const *TypeExpr,
        con: struct { name: []const u8, args: []const *TypeExpr },
        record: struct { name: []const u8, fields: []const RecordField },
        ref: *TypeExpr,
        variable: []const u8,
    };

    pub const RecordField = struct {
        name: []const u8,
        ty: *TypeExpr,
    };

    pub const FunctionSignature = struct {
        params: []const ast.TypeExpr,
        return_type: ?ast.TypeExpr,
        has_type_params: bool,
        param_count: usize,
    };

    pub fn init(allocator: std.mem.Allocator) Monomorphizer {
        return .{
            .allocator = allocator,
            .specializations = std.StringHashMap(std.ArrayList(Specialization)).init(allocator),
            .new_fns = .empty,
            .sig_map = std.StringHashMap(FunctionSignature).init(allocator),
        };
    }

    pub fn deinit(self: *Monomorphizer) void {
        var it = self.specializations.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*spec| {
                spec.type_args.deinit(self.allocator);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.specializations.deinit();
        self.new_fns.deinit(self.allocator);
        self.sig_map.deinit();
    }

    /// Run monomorphization on the program.
    /// Returns new specialized function definitions and a modified definitions list.
    pub fn run(self: *Monomorphizer, prog: parser.Program) !MonomorphResult {
        // Build signature map from the program
        try self.buildSigMap(prog);

        // Pass 1: Find all calls to polymorphic functions and record specializations
        for (prog.definitions) |def| {
            switch (def) {
                .fn_def => |fd| try self.scanWithSigs(fd.body, &self.sig_map),
                .module_def => |md| {
                    for (md.definitions) |inner_def| {
                        switch (inner_def) {
                            .fn_def => |fd| try self.scanWithSigs(fd.body, &self.sig_map),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // Pass 2: For each specialization, clone the function with concrete types
        var it = self.specializations.iterator();
        while (it.next()) |entry| {
            const original_name = entry.key_ptr.*;
            const specs = entry.value_ptr.items;

            const original_fn = self.findFunction(prog, original_name) orelse continue;

            for (specs) |spec| {
                const specialized = try self.specializeFunction(original_fn, spec);
                try self.new_fns.append(self.allocator, specialized);
            }
        }

        // Pass 3: Rewrite call sites in all function bodies
        var defs = std.ArrayList(parser.Definition).empty;
        for (prog.definitions) |def| {
            switch (def) {
                .fn_def => |fd| {
                    var new_fd = fd;
                    new_fd.body = try self.rewriteExpr(fd.body);
                    try defs.append(self.allocator, .{ .fn_def = new_fd });
                },
                .module_def => |md| {
                    var new_defs = std.ArrayList(parser.Definition).empty;
                    for (md.definitions) |inner_def| {
                        switch (inner_def) {
                            .fn_def => |fd| {
                                var new_fd = fd;
                                new_fd.body = try self.rewriteExpr(fd.body);
                                try new_defs.append(self.allocator, .{ .fn_def = new_fd });
                            },
                            else => try new_defs.append(self.allocator, inner_def),
                        }
                    }
                    var new_md = md;
                    new_md.definitions = try self.allocator.dupe(parser.Definition, new_defs.items);
                    try defs.append(self.allocator, .{ .module_def = new_md });
                },
                else => try defs.append(self.allocator, def),
            }
        }

        return .{
            .definitions = try self.allocator.dupe(parser.Definition, defs.items),
            .specialized_fns = self.new_fns.items,
        };
    }

    pub const MonomorphResult = struct {
        definitions: []const parser.Definition,
        specialized_fns: []const parser.FnDef,
    };

    // ── Scanning ──────────────────────────────────────────────────────

    fn scanExpr(self: *Monomorphizer, expr: *const parser.Expr) !void {
        switch (expr.*) {
            .fn_call => |call| {
                if (self.isPolymorphicCall(call)) {
                    try self.recordSpecialization(call);
                }
                for (call.args) |arg| try self.scanExpr(arg);
                for (call.named_args) |na| try self.scanExpr(na.value);
            },
            .lambda => |lam| try self.scanExpr(lam.body),
            .let_expr => |le| {
                try self.scanExpr(le.value);
                try self.scanExpr(le.body);
            },
            .if_expr => |ie| {
                try self.scanExpr(ie.condition);
                try self.scanExpr(ie.then_branch);
                if (ie.else_branch) |eb| try self.scanExpr(eb);
            },
            .match_expr => |me| {
                try self.scanExpr(me.value);
                for (me.arms) |arm| try self.scanExpr(arm.body);
            },
            .binary_op => |bo| {
                try self.scanExpr(bo.left);
                try self.scanExpr(bo.right);
            },
            .unary_op => |uo| try self.scanExpr(uo.expr),
            .tuple => |t| {
                for (t.items) |item| try self.scanExpr(item);
            },
            .block => |b| {
                for (b.items) |item| try self.scanExpr(item);
            },
            .field_access => |fa| try self.scanExpr(fa.object),
            .record_literal => |rec| {
                for (rec.fields) |field| try self.scanExpr(field.value);
            },
            .assign_expr => |ae| {
                try self.scanExpr(ae.target);
                try self.scanExpr(ae.value);
            },
            .comptime_expr => |ce| try self.scanExpr(ce),
            .ref_expr => |re| try self.scanExpr(re),
            else => {},
        }
    }

    fn isPolymorphicCall(self: *Monomorphizer, call: parser.FnCallExpr) bool {
        const callee_name = self.getCalleeName(call) orelse return false;
        const sig = self.sig_map.get(callee_name) orelse return false;
        return sig.has_type_params;
    }

    fn getCalleeName(self: *Monomorphizer, call: parser.FnCallExpr) ?[]const u8 {
        _ = self;
        return switch (call.func.*) {
            .identifier => |id| id.name,
            .field_access => |fa| switch (fa.object.*) {
                .constructor => |c| c.name,
                .identifier => |id| id.name,
                else => null,
            },
            else => null,
        };
    }

    /// Build the signature map from the program
    fn buildSigMap(self: *Monomorphizer, prog: parser.Program) !void {
        for (prog.definitions) |def| {
            switch (def) {
                .fn_def => |fd| {
                    const sig = self.extractSignature(fd);
                    try self.sig_map.put(fd.name, sig);
                },
                .module_def => |md| {
                    for (md.definitions) |inner_def| {
                        switch (inner_def) {
                            .fn_def => |fd| {
                                const sig = self.extractSignature(fd);
                                try self.sig_map.put(fd.name, sig);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
    }

    // ── Signature extraction ──────────────────────────────────────────

    /// Extract the type signature from a function definition.
    pub fn extractSignature(self: *Monomorphizer, fd: parser.FnDef) FunctionSignature {
        var has_type_params = false;
        for (fd.params) |param| {
            if (param.type_ann != null) {
                has_type_params = true;
                break;
            }
        }
        if (fd.return_type != null) has_type_params = true;

        var param_types: std.ArrayList(ast.TypeExpr) = .empty;
        for (fd.params) |param| {
            if (param.type_ann) |ann| {
                param_types.append(self.allocator, ann) catch {};
            } else {
                // No annotation — use a placeholder type variable
                const placeholder = self.allocator.create(ast.TypeExpr) catch break;
                placeholder.* = .{ .ident = "?" };
                param_types.append(self.allocator, placeholder.*) catch {};
            }
        }

        return .{
            .params = param_types.items,
            .return_type = fd.return_type,
            .has_type_params = has_type_params,
            .param_count = fd.params.len,
        };
    }

    /// Parse a TypeExpr into our internal TypeExpr representation.
    pub fn parseTypeExpr(self: *Monomorphizer, te: ast.TypeExpr) !*TypeExpr {
        return switch (te) {
            .ident => |name| blk: {
                const ptr = try self.allocator.create(TypeExpr);
                ptr.* = .{ .variable = name };
                break :blk ptr;
            },
            .constructor => |name| blk: {
                const ptr = try self.allocator.create(TypeExpr);
                if (std.mem.eql(u8, name, "Int")) {
                    ptr.* = .int;
                } else if (std.mem.eql(u8, name, "Float")) {
                    ptr.* = .float;
                } else if (std.mem.eql(u8, name, "Bool")) {
                    ptr.* = .bool;
                } else if (std.mem.eql(u8, name, "Char")) {
                    ptr.* = .char;
                } else if (std.mem.eql(u8, name, "String")) {
                    ptr.* = .string;
                } else {
                    ptr.* = .{ .con = .{ .name = name, .args = &.{} } };
                }
                break :blk ptr;
            },
            .arrow => |a| blk: {
                const from = try self.parseTypeExpr(a.from.*);
                const to = try self.parseTypeExpr(a.to.*);
                const ptr = try self.allocator.create(TypeExpr);
                ptr.* = .{ .arrow = .{ .from = from, .to = to } };
                break :blk ptr;
            },
            .record => |fields| blk: {
                var fts = try self.allocator.alloc(RecordField, fields.len);
                for (fields, 0..) |f, i| {
                    fts[i] = .{ .name = f.name, .ty = try self.parseTypeExpr(f.type_expr) };
                }
                const ptr = try self.allocator.create(TypeExpr);
                ptr.* = .{ .record = .{ .name = "", .fields = fts } };
                break :blk ptr;
            },
            .group => |inner| self.parseTypeExpr(inner.*),
            .application => |app| blk: {
                // Type application like `List a` → con("List", [variable("a")])
                const func = try self.parseTypeExpr(app.func.*);
                const arg = try self.parseTypeExpr(app.arg.*);
                switch (func.*) {
                    .con => |*c| {
                        // Append arg to existing args
                        var new_args = try self.allocator.alloc(*TypeExpr, c.args.len + 1);
                        for (c.args, 0..) |a, i| new_args[i] = a;
                        new_args[c.args.len] = arg;
                        c.args = new_args;
                        break :blk func;
                    },
                    else => {
                        // Wrap in a con with the func as name
                        const ptr = try self.allocator.create(TypeExpr);
                        ptr.* = .{ .con = .{ .name = "?apply", .args = try self.allocator.dupe(*TypeExpr, &.{ func, arg }) } };
                        break :blk ptr;
                    },
                }
            },
        };
    }

    /// Record a specialization for a polymorphic call.
    fn recordSpecialization(self: *Monomorphizer, call: parser.FnCallExpr) !void {
        const callee_name = self.getCalleeName(call) orelse return;

        // We need the original function to extract its signature.
        // This is handled externally — we store signatures in a map.
        // For now, we'll collect what we can from the call site.

        // Generate a placeholder specialization name
        // The actual type args will be determined when we have the signature
        const specialized_name = try std.fmt.allocPrint(self.allocator, "{s}__mono_{d}", .{ callee_name, self.new_fns.items.len });

        // Check if already recorded
        if (self.specializations.getPtr(callee_name)) |specs| {
            for (specs.items) |*existing| {
                if (std.mem.eql(u8, existing.specialized_name, specialized_name)) return;
            }
        }

        // We'll collect the actual type args when we process the signature
        // For now, record with empty type args (will be filled in by processSignatures)
        var type_args: std.ArrayList(TypeExpr) = .empty;
        try type_args.append(self.allocator, .{ .variable = "?" });

        if (self.specializations.getPtr(callee_name)) |specs| {
            try specs.append(self.allocator, .{
                .type_args = type_args,
                .specialized_name = specialized_name,
            });
        } else {
            var specs: std.ArrayList(Specialization) = .empty;
            try specs.append(self.allocator, .{
                .type_args = type_args,
                .specialized_name = specialized_name,
            });
            try self.specializations.put(callee_name, specs);
        }
    }

    // ── Signature-based monomorphization ──────────────────────────────

    /// Process function signatures to determine type arguments for each call site.
    /// This is the main entry point for monomorphization with full signatures.
    pub fn processSignatures(self: *Monomorphizer, prog: parser.Program) !void {
        // Build a map of function name → signature
        var sigs = std.StringHashMap(FunctionSignature).init(self.allocator);
        defer sigs.deinit();

        for (prog.definitions) |def| {
            switch (def) {
                .fn_def => |fd| {
                    const sig = self.extractSignature(fd);
                    try sigs.put(fd.name, sig);
                },
                .module_def => |md| {
                    for (md.definitions) |inner_def| {
                        switch (inner_def) {
                            .fn_def => |fd| {
                                const sig = self.extractSignature(fd);
                                try sigs.put(fd.name, sig);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // Now rescan with signature information
        self.specializations.clearRetainingCapacity();

        for (prog.definitions) |def| {
            switch (def) {
                .fn_def => |fd| try self.scanWithSigs(fd.body, &sigs),
                .module_def => |md| {
                    for (md.definitions) |inner_def| {
                        switch (inner_def) {
                            .fn_def => |fd| try self.scanWithSigs(fd.body, &sigs),
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // For each recorded specialization, determine the actual type args
        // by matching argument types against the callee's parameter types
        var spec_it = self.specializations.iterator();
        while (spec_it.next()) |entry| {
            const callee_name = entry.key_ptr.*;
            const callee_sig = sigs.get(callee_name) orelse continue;

            if (!callee_sig.has_type_params) continue;
            if (callee_sig.param_count == 0) continue;

            // Parse the callee's parameter types
            var callee_param_tys: std.ArrayList(*TypeExpr) = .empty;
            defer callee_param_tys.deinit(self.allocator);
            for (callee_sig.params) |param| {
                callee_param_tys.append(self.allocator, try self.parseTypeExpr(param)) catch continue;
            }

            // For each specialization, we need the call site's argument types.
            // We'll do this by walking the program and matching.
            // For now, create specializations with inferred type args.
        }
    }

    fn scanWithSigs(self: *Monomorphizer, expr: *const parser.Expr, sigs: *const std.StringHashMap(FunctionSignature)) !void {
        switch (expr.*) {
            .fn_call => |call| {
                const callee_name = self.getCalleeName(call) orelse {
                    // Scan arguments even if callee isn't polymorphic
                    for (call.args) |arg| try self.scanWithSigs(arg, sigs);
                    for (call.named_args) |na| try self.scanWithSigs(na.value, sigs);
                    return;
                };

                const sig = sigs.get(callee_name) orelse {
                    for (call.args) |arg| try self.scanWithSigs(arg, sigs);
                    for (call.named_args) |na| try self.scanWithSigs(na.value, sigs);
                    return;
                };

                if (sig.has_type_params and call.args.len >= sig.param_count) {
                    // Determine type args by matching argument structure against parameter types
                    const type_args = self.inferTypeArgs(sig, call);

                    if (type_args) |args| {
                        // Generate specialized name
                        const specialized_name = try self.generateSpecializedName(callee_name, args);

                        // Check if already recorded
                        var already_exists = false;
                        if (self.specializations.get(callee_name)) |existing| {
                            for (existing.items) |*spec| {
                                if (self.typesEqualList(&spec.type_args, &args)) {
                                    already_exists = true;
                                    break;
                                }
                            }
                        }

                        if (!already_exists) {
                            if (self.specializations.getPtr(callee_name)) |specs| {
                                try specs.append(self.allocator, .{
                                    .type_args = args,
                                    .specialized_name = specialized_name,
                                });
                            } else {
                                var specs: std.ArrayList(Specialization) = .empty;
                                try specs.append(self.allocator, .{
                                    .type_args = args,
                                    .specialized_name = specialized_name,
                                });
                                try self.specializations.put(callee_name, specs);
                            }
                        }
                    }
                }

                // Scan arguments
                for (call.args) |arg| try self.scanWithSigs(arg, sigs);
                for (call.named_args) |na| try self.scanWithSigs(na.value, sigs);
            },
            .lambda => |lam| try self.scanWithSigs(lam.body, sigs),
            .let_expr => |le| {
                try self.scanWithSigs(le.value, sigs);
                try self.scanWithSigs(le.body, sigs);
            },
            .if_expr => |ie| {
                try self.scanWithSigs(ie.condition, sigs);
                try self.scanWithSigs(ie.then_branch, sigs);
                if (ie.else_branch) |eb| try self.scanWithSigs(eb, sigs);
            },
            .match_expr => |me| {
                try self.scanWithSigs(me.value, sigs);
                for (me.arms) |arm| try self.scanWithSigs(arm.body, sigs);
            },
            .binary_op => |bo| {
                try self.scanWithSigs(bo.left, sigs);
                try self.scanWithSigs(bo.right, sigs);
            },
            .unary_op => |uo| try self.scanWithSigs(uo.expr, sigs),
            .tuple => |t| {
                for (t.items) |item| try self.scanWithSigs(item, sigs);
            },
            .block => |b| {
                for (b.items) |item| try self.scanWithSigs(item, sigs);
            },
            .field_access => |fa| try self.scanWithSigs(fa.object, sigs),
            .record_literal => |rec| {
                for (rec.fields) |field| try self.scanWithSigs(field.value, sigs);
            },
            .assign_expr => |ae| {
                try self.scanWithSigs(ae.target, sigs);
                try self.scanWithSigs(ae.value, sigs);
            },
            .comptime_expr => |ce| try self.scanWithSigs(ce, sigs),
            .ref_expr => |re| try self.scanWithSigs(re, sigs),
            else => {},
        }
    }

    /// Infer type arguments by matching argument types against parameter types.
    /// Returns null if we can't determine all type arguments.
    fn inferTypeArgs(self: *Monomorphizer, sig: FunctionSignature, call: parser.FnCallExpr) ?std.ArrayList(TypeExpr) {
        var type_args: std.ArrayList(TypeExpr) = .empty;

        // Collect type variable names from the signature
        var type_var_names: std.ArrayList([]const u8) = .empty;
        defer type_var_names.deinit(self.allocator);

        for (sig.params) |param| {
            self.collectTypeVars(param, &type_var_names);
        }
        if (sig.return_type) |rt| {
            self.collectTypeVars(rt, &type_var_names);
        }

        // Initialize type args as unresolved
        for (type_var_names.items) |_| {
            type_args.append(self.allocator, .{ .variable = "?" }) catch return null;
        }

        // Match argument types against parameter types
        for (sig.params, 0..) |param, i| {
            if (i >= call.args.len) break;
            const arg = call.args[i];
            const param_ty = self.parseTypeExpr(param) catch continue;

            // Try to extract type info from the argument expression
            const arg_ty = self.exprToType(arg) orelse continue;

            // Match param_ty against arg_ty, filling in type variables
            self.matchType(param_ty, arg_ty, &type_args, &type_var_names);
        }

        // Check that all type args were determined
        for (type_args.items) |ta| {
            switch (ta) {
                .variable => |name| {
                    if (std.mem.eql(u8, name, "?")) return null;
                },
                else => {},
            }
        }

        return type_args;
    }

    /// Collect type variable names from a TypeExpr
    fn collectTypeVars(self: *Monomorphizer, te: ast.TypeExpr, vars: *std.ArrayList([]const u8)) void {
        switch (te) {
            .ident => |name| {
                // Check if already collected
                for (vars.items) |v| {
                    if (std.mem.eql(u8, v, name)) return;
                }
                vars.append(self.allocator, name) catch {};
            },
            .constructor => {}, // Concrete types, no vars
            .arrow => |a| {
                self.collectTypeVars(a.from.*, vars);
                self.collectTypeVars(a.to.*, vars);
            },
            .record => |fields| {
                for (fields) |f| self.collectTypeVars(f.type_expr, vars);
            },
            .group => |inner| self.collectTypeVars(inner.*, vars),
            .application => |app| {
                self.collectTypeVars(app.func.*, vars);
                self.collectTypeVars(app.arg.*, vars);
            },
        }
    }

    /// Try to convert an expression to a type (best-effort).
    fn exprToType(self: *Monomorphizer, expr: *const parser.Expr) ?*TypeExpr {
        return switch (expr.*) {
            .int_literal => blk: {
                const ptr = self.allocator.create(TypeExpr) catch return null;
                ptr.* = .int;
                break :blk ptr;
            },
            .float_literal => blk: {
                const ptr = self.allocator.create(TypeExpr) catch return null;
                ptr.* = .float;
                break :blk ptr;
            },
            .bool_literal => blk: {
                const ptr = self.allocator.create(TypeExpr) catch return null;
                ptr.* = .bool;
                break :blk ptr;
            },
            .string_literal => blk: {
                const ptr = self.allocator.create(TypeExpr) catch return null;
                ptr.* = .string;
                break :blk ptr;
            },
            .char_literal => blk: {
                const ptr = self.allocator.create(TypeExpr) catch return null;
                ptr.* = .char;
                break :blk ptr;
            },
            .identifier => blk: {
                const ptr = self.allocator.create(TypeExpr) catch return null;
                ptr.* = .{ .variable = expr.identifier.name };
                break :blk ptr;
            },
            .constructor => |c| blk: {
                const ptr = self.allocator.create(TypeExpr) catch return null;
                if (std.mem.eql(u8, c.name, "True") or std.mem.eql(u8, c.name, "False")) {
                    ptr.* = .bool;
                } else {
                    ptr.* = .{ .con = .{ .name = c.name, .args = &.{} } };
                }
                break :blk ptr;
            },
            .tuple => |t| blk: {
                var tys = self.allocator.alloc(*TypeExpr, t.items.len) catch return null;
                for (t.items, 0..) |item, i| {
                    tys[i] = self.exprToType(item) orelse blk2: {
                        const unk = self.allocator.create(TypeExpr) catch return null;
                        unk.* = .{ .variable = "?" };
                        break :blk2 unk;
                    };
                }
                const ptr = self.allocator.create(TypeExpr) catch return null;
                ptr.* = .{ .tuple = tys };
                break :blk ptr;
            },
            else => null, // Can't determine type from expression
        };
    }

    /// Match a parameter type pattern against an argument type, filling in type variables.
    fn matchType(self: *Monomorphizer, param: *TypeExpr, arg: *TypeExpr, type_args: *std.ArrayList(TypeExpr), type_var_names: *const std.ArrayList([]const u8)) void {
        switch (param.*) {
            .variable => |name| {
                if (std.mem.eql(u8, name, "?")) return;
                // Find this variable's index
                for (type_var_names.items, 0..) |vn, i| {
                    if (std.mem.eql(u8, vn, name)) {
                        // Fill in the type arg
                        if (i < type_args.items.len) {
                            type_args.items[i] = arg.*;
                        }
                        return;
                    }
                }
            },
            .arrow => |pa| {
                if (arg.* == .arrow) {
                    self.matchType(pa.from, arg.arrow.from, type_args, type_var_names);
                    self.matchType(pa.to, arg.arrow.to, type_args, type_var_names);
                }
            },
            .tuple => |pt| {
                if (arg.* == .tuple) {
                    if (pt.len == arg.tuple.len) {
                        for (pt, arg.tuple) |p, a| {
                            self.matchType(p, a, type_args, type_var_names);
                        }
                    }
                }
            },
            .con => |pc| {
                if (arg.* == .con) {
                    if (std.mem.eql(u8, pc.name, arg.con.name)) {
                        for (pc.args, arg.con.args) |p, a| {
                            self.matchType(p, a, type_args, type_var_names);
                        }
                    }
                }
            },
            .ref => |pr| {
                if (arg.* == .ref) {
                    self.matchType(pr, arg.ref, type_args, type_var_names);
                }
            },
            else => {},
        }
    }

    // ── Specialization ────────────────────────────────────────────────

    /// Create a specialized copy of a function with concrete types.
    fn specializeFunction(self: *Monomorphizer, original: parser.FnDef, spec: Specialization) !parser.FnDef {
        // Build a substitution map from type variable names to concrete types
        var subst = std.StringHashMap(*TypeExpr).init(self.allocator);
        defer subst.deinit();

        // We need the original function's type parameter names.
        // Extract them from the function signature.
        var type_param_names: std.ArrayList([]const u8) = .empty;
        defer type_param_names.deinit(self.allocator);

        for (original.params) |param| {
            if (param.type_ann) |ann| {
                self.collectTypeVarsFromTypeExpr(ann, &type_param_names);
            }
        }
        if (original.return_type) |rt| {
            self.collectTypeVarsFromTypeExpr(rt, &type_param_names);
        }

        // Map type param names to concrete types
        for (type_param_names.items, 0..) |name, i| {
            if (i < spec.type_args.items.len) {
                const concrete = try self.allocator.create(TypeExpr);
                concrete.* = spec.type_args.items[i];
                try subst.put(name, concrete);
            }
        }

        // Clone the function body with substitution
        const new_body = try self.cloneExprWithSubst(original.body, &subst);

        // Clone params with substitution
        var new_params = try self.allocator.alloc(ast.FnParam, original.params.len);
        for (original.params, 0..) |param, i| {
            new_params[i] = .{
                .pattern = param.pattern,
                .type_ann = if (param.type_ann) |ann| try self.cloneTypeExprWithSubst(ann, &subst) else null,
            };
        }

        // Clone return type with substitution
        const new_return_type = if (original.return_type) |rt|
            try self.cloneTypeExprWithSubst(rt, &subst)
        else
            null;

        return .{
            .name = spec.specialized_name,
            .params = new_params,
            .return_type = new_return_type,
            .body = new_body,
            .is_pub = original.is_pub,
            .is_comptime = original.is_comptime,
            .doc_comments = original.doc_comments,
            .loc = original.loc,
        };
    }

    /// Collect type variable names from an AST TypeExpr (not our internal one).
    fn collectTypeVarsFromTypeExpr(self: *Monomorphizer, te: ast.TypeExpr, vars: *std.ArrayList([]const u8)) void {
        switch (te) {
            .ident => |name| {
                for (vars.items) |v| {
                    if (std.mem.eql(u8, v, name)) return;
                }
                vars.append(self.allocator, name) catch {};
            },
            .constructor => {},
            .arrow => |a| {
                self.collectTypeVarsFromTypeExpr(a.from.*, vars);
                self.collectTypeVarsFromTypeExpr(a.to.*, vars);
            },
            .record => |fields| {
                for (fields) |f| self.collectTypeVarsFromTypeExpr(f.type_expr, vars);
            },
            .group => |inner| self.collectTypeVarsFromTypeExpr(inner.*, vars),
            .application => |app| {
                self.collectTypeVarsFromTypeExpr(app.func.*, vars);
                self.collectTypeVarsFromTypeExpr(app.arg.*, vars);
            },
        }
    }

    /// Clone a TypeExpr with type variable substitution.
    fn cloneTypeExprWithSubst(self: *Monomorphizer, te: ast.TypeExpr, subst: *const std.StringHashMap(*TypeExpr)) !ast.TypeExpr {
        return switch (te) {
            .ident => |name| {
                if (subst.get(name)) |replacement| {
                    // Convert our internal TypeExpr back to AST TypeExpr
                    return self.typeExprToAst(replacement.*);
                }
                return te;
            },
            .constructor => te,
            .arrow => |a| blk: {
                const from = try self.allocator.create(ast.TypeExpr);
                from.* = try self.cloneTypeExprWithSubst(a.from.*, subst);
                const to = try self.allocator.create(ast.TypeExpr);
                to.* = try self.cloneTypeExprWithSubst(a.to.*, subst);
                break :blk .{ .arrow = .{ .from = from, .to = to } };
            },
            .record => |fields| blk: {
                var new_fields = try self.allocator.alloc(ast.RecordField, fields.len);
                for (fields, 0..) |f, i| {
                    new_fields[i] = .{
                        .name = f.name,
                        .type_expr = try self.cloneTypeExprWithSubst(f.type_expr, subst),
                    };
                }
                break :blk .{ .record = new_fields };
            },
            .group => |inner| blk: {
                const inner_ptr = try self.allocator.create(ast.TypeExpr);
                inner_ptr.* = try self.cloneTypeExprWithSubst(inner.*, subst);
                break :blk .{ .group = inner_ptr };
            },
            .application => |app| blk: {
                const func = try self.allocator.create(ast.TypeExpr);
                func.* = try self.cloneTypeExprWithSubst(app.func.*, subst);
                const arg = try self.allocator.create(ast.TypeExpr);
                arg.* = try self.cloneTypeExprWithSubst(app.arg.*, subst);
                break :blk .{ .application = .{ .func = func, .arg = arg } };
            },
        };
    }

    /// Convert our internal TypeExpr back to an AST TypeExpr.
    fn typeExprToAst(self: *Monomorphizer, te: TypeExpr) !ast.TypeExpr {
        _ = self;
        return switch (te) {
            .int => .{ .constructor = "Int" },
            .float => .{ .constructor = "Float" },
            .bool => .{ .constructor = "Bool" },
            .char => .{ .constructor = "Char" },
            .string => .{ .constructor = "String" },
            .unit => .{ .constructor = "()" },
            .variable => |name| .{ .ident = name },
            .con => |c| .{ .constructor = c.name },
            else => .{ .ident = "?" },
        };
    }

    /// Clone an expression with type variable substitution.
    fn cloneExprWithSubst(self: *Monomorphizer, expr: *const parser.Expr, subst: *const std.StringHashMap(*TypeExpr)) error{OutOfMemory}!*parser.Expr {
        const new_expr = try self.allocator.create(parser.Expr);
        new_expr.* = try self.cloneExprInner(expr, subst);
        return new_expr;
    }

    const CloneError = error{OutOfMemory};

    fn cloneExprInner(self: *Monomorphizer, expr: *const parser.Expr, subst: *const std.StringHashMap(*TypeExpr)) CloneError!parser.Expr {
        // Helper: recursively clone and allocate a sub-expression
        const clone = struct {
            fn doClone(s: *Monomorphizer, e: *const parser.Expr, sb: *const std.StringHashMap(*TypeExpr)) CloneError!*parser.Expr {
                const ptr = try s.allocator.create(parser.Expr);
                ptr.* = try s.cloneExprInner(e, sb);
                return ptr;
            }
        }.doClone;
        return switch (expr.*) {
            .int_literal => |v| .{ .int_literal = v },
            .float_literal => |v| .{ .float_literal = v },
            .string_literal => |v| .{ .string_literal = v },
            .char_literal => |v| .{ .char_literal = v },
            .bool_literal => |v| .{ .bool_literal = v },
            .identifier => |id| .{ .identifier = id },
            .constructor => |c| .{ .constructor = c },
            .pat_record => |pr| .{ .pat_record = pr },
            .tuple => |t| blk: {
                var items = try self.allocator.alloc(*parser.Expr, t.items.len);
                for (t.items, 0..) |item, i| {
                    items[i] = try clone(self, item, subst);
                }
                break :blk .{ .tuple = .{ .items = items, .loc = t.loc } };
            },
            .block => |b| blk: {
                var items = try self.allocator.alloc(*parser.Expr, b.items.len);
                for (b.items, 0..) |item, i| {
                    items[i] = try clone(self, item, subst);
                }
                break :blk .{ .block = .{ .items = items, .loc = b.loc } };
            },
            .field_access => |fa| blk: {
                const obj = try clone(self, fa.object, subst);
                break :blk .{ .field_access = .{ .object = obj, .field = fa.field, .loc = fa.loc } };
            },
            .fn_call => |call| blk: {
                const func = try clone(self, call.func, subst);
                var args = try self.allocator.alloc(*parser.Expr, call.args.len);
                for (call.args, 0..) |arg, i| {
                    args[i] = try clone(self, arg, subst);
                }
                var named_args = try self.allocator.alloc(ast.NamedArg, call.named_args.len);
                for (call.named_args, 0..) |na, i| {
                    named_args[i] = .{
                        .name = na.name,
                        .value = try clone(self, na.value, subst),
                    };
                }
                break :blk .{ .fn_call = .{
                    .func = func,
                    .args = args,
                    .named_args = named_args,
                    .loc = call.loc,
                } };
            },
            .lambda => |lam| blk: {
                const body = try clone(self, lam.body, subst);
                break :blk .{ .lambda = .{ .params = lam.params, .body = body, .loc = lam.loc } };
            },
            .comptime_expr => |inner| blk: {
                const inner_expr = try clone(self, inner, subst);
                break :blk .{ .comptime_expr = inner_expr };
            },
            .unary_op => |u| blk: {
                const inner = try clone(self, u.expr, subst);
                break :blk .{ .unary_op = .{ .op = u.op, .expr = inner, .loc = u.loc } };
            },
            .binary_op => |b| blk: {
                const left = try clone(self, b.left, subst);
                const right = try clone(self, b.right, subst);
                break :blk .{ .binary_op = .{ .op = b.op, .left = left, .right = right, .loc = b.loc } };
            },
            .let_expr => |le| blk: {
                const value = try clone(self, le.value, subst);
                const body = try clone(self, le.body, subst);
                break :blk .{ .let_expr = .{
                    .name = le.name,
                    .type_ann = if (le.type_ann) |ta| try self.cloneTypeExprWithSubst(ta, subst) else null,
                    .value = value,
                    .body = body,
                    .loc = le.loc,
                    .pattern = le.pattern,
                } };
            },
            .if_expr => |ie| blk: {
                const cond = try clone(self, ie.condition, subst);
                const then = try clone(self, ie.then_branch, subst);
                const else_branch = if (ie.else_branch) |eb| try clone(self, eb, subst) else null;
                break :blk .{ .if_expr = .{
                    .condition = cond,
                    .then_branch = then,
                    .else_branch = else_branch,
                    .loc = ie.loc,
                } };
            },
            .match_expr => |me| blk: {
                const value = try clone(self, me.value, subst);
                var arms = try self.allocator.alloc(ast.MatchArm, me.arms.len);
                for (me.arms, 0..) |arm, i| {
                    arms[i] = .{
                        .pattern = arm.pattern,
                        .body = try clone(self, arm.body, subst),
                    };
                }
                break :blk .{ .match_expr = .{ .value = value, .arms = arms, .loc = me.loc } };
            },
            .record_literal => |rec| blk: {
                var fields = try self.allocator.alloc(ast.NamedArg, rec.fields.len);
                for (rec.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = f.name,
                        .value = try clone(self, f.value, subst),
                    };
                }
                break :blk .{ .record_literal = .{ .name = rec.name, .fields = fields, .loc = rec.loc } };
            },
            .assign_expr => |ae| blk: {
                const target = try clone(self, ae.target, subst);
                const value = try clone(self, ae.value, subst);
                break :blk .{ .assign_expr = .{ .target = target, .value = value, .loc = ae.loc } };
            },
            .ref_expr => |inner| blk: {
                const inner_expr = try clone(self, inner, subst);
                break :blk .{ .ref_expr = inner_expr };
            },
        };
    }

    // ── Call site rewriting ───────────────────────────────────────────

    /// Rewrite call sites in an expression, replacing generic calls with specialized ones.
    fn rewriteExpr(self: *Monomorphizer, expr: *const parser.Expr) !*parser.Expr {
        return switch (expr.*) {
            .fn_call => |call| blk: {
                const callee_name = self.getCalleeName(call) orelse {
                    // Not a recognizable call — rewrite arguments
                    const func = try self.rewriteExpr(call.func);
                    var args = try self.allocator.alloc(*parser.Expr, call.args.len);
                    for (call.args, 0..) |arg, i| {
                        args[i] = try self.rewriteExpr(arg);
                    }
                    var named_args = try self.allocator.alloc(ast.NamedArg, call.named_args.len);
                    for (call.named_args, 0..) |na, i| {
                        named_args[i] = .{
                            .name = na.name,
                            .value = try self.rewriteExpr(na.value),
                        };
                    }
                    break :blk try self.allocExpr(.{ .fn_call = .{
                        .func = func,
                        .args = args,
                        .named_args = named_args,
                        .loc = call.loc,
                    } });
                };

                // Check if we have a specialization for this call
                if (self.specializations.get(callee_name)) |specs| {
                    // Find the matching specialization by checking call-site arg types
                    var matched_spec: ?*Specialization = null;
                    if (call.args.len > 0) {
                        const first_arg_ty = self.exprToType(call.args[0]);
                        if (first_arg_ty) |arg_ty| {
                            for (specs.items) |*spec| {
                                if (spec.type_args.items.len > 0) {
                                    if (self.typesEqualSingle(arg_ty.*, spec.type_args.items[0])) {
                                        matched_spec = spec;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    // Fallback: if no match by type, use first spec
                    if (matched_spec == null and specs.items.len > 0) {
                        matched_spec = &specs.items[0];
                    }

                    if (matched_spec) |spec| {
                        // Replace the callee with the specialized name
                        const new_func = try self.allocExpr(.{ .identifier = .{ .name = spec.specialized_name } });
                        var args = try self.allocator.alloc(*parser.Expr, call.args.len);
                        for (call.args, 0..) |arg, i| {
                            args[i] = try self.rewriteExpr(arg);
                        }
                        var named_args = try self.allocator.alloc(ast.NamedArg, call.named_args.len);
                        for (call.named_args, 0..) |na, i| {
                            named_args[i] = .{
                                .name = na.name,
                                .value = try self.rewriteExpr(na.value),
                            };
                        }
                        break :blk try self.allocExpr(.{ .fn_call = .{
                            .func = new_func,
                            .args = args,
                            .named_args = named_args,
                            .loc = call.loc,
                        } });
                    }
                }

                // No specialization — rewrite arguments only
                const func = try self.rewriteExpr(call.func);
                var args = try self.allocator.alloc(*parser.Expr, call.args.len);
                for (call.args, 0..) |arg, i| {
                    args[i] = try self.rewriteExpr(arg);
                }
                var named_args = try self.allocator.alloc(ast.NamedArg, call.named_args.len);
                for (call.named_args, 0..) |na, i| {
                    named_args[i] = .{
                        .name = na.name,
                        .value = try self.rewriteExpr(na.value),
                    };
                }
                break :blk try self.allocExpr(.{ .fn_call = .{
                    .func = func,
                    .args = args,
                    .named_args = named_args,
                    .loc = call.loc,
                } });
            },
            .lambda => |lam| blk: {
                const body = try self.rewriteExpr(lam.body);
                break :blk try self.allocExpr(.{ .lambda = .{ .params = lam.params, .body = body, .loc = lam.loc } });
            },
            .let_expr => |le| blk: {
                const value = try self.rewriteExpr(le.value);
                const body = try self.rewriteExpr(le.body);
                break :blk try self.allocExpr(.{ .let_expr = .{
                    .name = le.name,
                    .type_ann = le.type_ann,
                    .value = value,
                    .body = body,
                    .loc = le.loc,
                    .pattern = le.pattern,
                } });
            },
            .if_expr => |ie| blk: {
                const cond = try self.rewriteExpr(ie.condition);
                const then = try self.rewriteExpr(ie.then_branch);
                const else_branch = if (ie.else_branch) |eb| try self.rewriteExpr(eb) else null;
                break :blk try self.allocExpr(.{ .if_expr = .{
                    .condition = cond,
                    .then_branch = then,
                    .else_branch = else_branch,
                    .loc = ie.loc,
                } });
            },
            .match_expr => |me| blk: {
                const value = try self.rewriteExpr(me.value);
                var arms = try self.allocator.alloc(ast.MatchArm, me.arms.len);
                for (me.arms, 0..) |arm, i| {
                    arms[i] = .{
                        .pattern = arm.pattern,
                        .body = try self.rewriteExpr(arm.body),
                    };
                }
                break :blk try self.allocExpr(.{ .match_expr = .{ .value = value, .arms = arms, .loc = me.loc } });
            },
            .binary_op => |b| blk: {
                const left = try self.rewriteExpr(b.left);
                const right = try self.rewriteExpr(b.right);
                break :blk try self.allocExpr(.{ .binary_op = .{ .op = b.op, .left = left, .right = right, .loc = b.loc } });
            },
            .unary_op => |u| blk: {
                const inner = try self.rewriteExpr(u.expr);
                break :blk try self.allocExpr(.{ .unary_op = .{ .op = u.op, .expr = inner, .loc = u.loc } });
            },
            .tuple => |t| blk: {
                var items = try self.allocator.alloc(*parser.Expr, t.items.len);
                for (t.items, 0..) |item, i| {
                    items[i] = try self.rewriteExpr(item);
                }
                break :blk try self.allocExpr(.{ .tuple = .{ .items = items, .loc = t.loc } });
            },
            .block => |b| blk: {
                var items = try self.allocator.alloc(*parser.Expr, b.items.len);
                for (b.items, 0..) |item, i| {
                    items[i] = try self.rewriteExpr(item);
                }
                break :blk try self.allocExpr(.{ .block = .{ .items = items, .loc = b.loc } });
            },
            .field_access => |fa| blk: {
                const obj = try self.rewriteExpr(fa.object);
                break :blk try self.allocExpr(.{ .field_access = .{ .object = obj, .field = fa.field, .loc = fa.loc } });
            },
            .record_literal => |rec| blk: {
                var fields = try self.allocator.alloc(ast.NamedArg, rec.fields.len);
                for (rec.fields, 0..) |f, i| {
                    fields[i] = .{
                        .name = f.name,
                        .value = try self.rewriteExpr(f.value),
                    };
                }
                break :blk try self.allocExpr(.{ .record_literal = .{ .name = rec.name, .fields = fields, .loc = rec.loc } });
            },
            .assign_expr => |ae| blk: {
                const target = try self.rewriteExpr(ae.target);
                const value = try self.rewriteExpr(ae.value);
                break :blk try self.allocExpr(.{ .assign_expr = .{ .target = target, .value = value, .loc = ae.loc } });
            },
            .comptime_expr => |inner| blk: {
                const inner_expr = try self.rewriteExpr(inner);
                break :blk try self.allocExpr(.{ .comptime_expr = inner_expr });
            },
            .ref_expr => |inner| blk: {
                const inner_expr = try self.rewriteExpr(inner);
                break :blk try self.allocExpr(.{ .ref_expr = inner_expr });
            },
            // Leaf nodes — allocate and copy
            .int_literal, .float_literal, .string_literal, .char_literal, .bool_literal, .identifier, .constructor, .pat_record => blk: {
                const ptr = try self.allocator.create(parser.Expr);
                ptr.* = expr.*;
                break :blk ptr;
            },
        };
    }

    fn allocExpr(self: *Monomorphizer, expr: parser.Expr) !*parser.Expr {
        const ptr = try self.allocator.create(parser.Expr);
        ptr.* = expr;
        return ptr;
    }

    // ── Name generation ───────────────────────────────────────────────

    fn generateSpecializedName(self: *Monomorphizer, base_name: []const u8, type_args: std.ArrayList(TypeExpr)) ![]const u8 {
        var name = std.ArrayList(u8).empty;
        defer name.deinit(self.allocator);

        try name.appendSlice(self.allocator, base_name);
        for (type_args.items) |ty| {
            try name.append(self.allocator, '_');
            const type_str = try self.typeExprToString(ty);
            try name.appendSlice(self.allocator, type_str);
        }

        return try self.allocator.dupe(u8, name.items);
    }

    fn typeExprToString(_: *Monomorphizer, te: TypeExpr) ![]const u8 {
        return switch (te) {
            .int => "Int",
            .float => "Float",
            .bool => "Bool",
            .char => "Char",
            .string => "String",
            .unit => "Unit",
            .arrow => "Fn",
            .tuple => "Tuple",
            .con => |c| c.name,
            .record => |r| r.name,
            .variable => |v| v,
            .ref => "Ref",
        };
    }

    // ── Type equality ─────────────────────────────────────────────────

    fn typesEqualList(self: *Monomorphizer, a: *const std.ArrayList(TypeExpr), b: *const std.ArrayList(TypeExpr)) bool {
        if (a.items.len != b.items.len) return false;
        for (a.items, b.items) |ta, tb| {
            if (!self.typesEqualSingle(ta, tb)) return false;
        }
        return true;
    }

    fn typesEqualSingle(self: *Monomorphizer, a: TypeExpr, b: TypeExpr) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        switch (a) {
            .int, .float, .bool, .char, .string, .unit => return true,
            .arrow => |aa| {
                const ba = b.arrow;
                return self.typesEqualSingle(aa.from.*, ba.from.*) and self.typesEqualSingle(aa.to.*, ba.to.*);
            },
            .tuple => |at| {
                const bt = b.tuple;
                if (at.len != bt.len) return false;
                for (at, bt) |ta, tb| {
                    if (!self.typesEqualSingle(ta.*, tb.*)) return false;
                }
                return true;
            },
            .con => |ac| {
                const bc = b.con;
                if (!std.mem.eql(u8, ac.name, bc.name)) return false;
                if (ac.args.len != bc.args.len) return false;
                for (ac.args, bc.args) |ta, tb| {
                    if (!self.typesEqualSingle(ta.*, tb.*)) return false;
                }
                return true;
            },
            .record => |ar| {
                const br = b.record;
                return std.mem.eql(u8, ar.name, br.name);
            },
            .variable => |av| return std.mem.eql(u8, av, b.variable),
            .ref => |ar| return self.typesEqualSingle(ar.*, b.ref.*),
        }
    }

    // ── Utility ───────────────────────────────────────────────────────

    fn findFunction(self: *Monomorphizer, prog: parser.Program, name: []const u8) ?parser.FnDef {
        _ = self;
        for (prog.definitions) |def| {
            switch (def) {
                .fn_def => |fd| {
                    if (std.mem.eql(u8, fd.name, name)) return fd;
                },
                .module_def => |md| {
                    for (md.definitions) |inner_def| {
                        switch (inner_def) {
                            .fn_def => |fd| {
                                if (std.mem.eql(u8, fd.name, name)) return fd;
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }
};
