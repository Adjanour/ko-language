const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");

pub const Type = union(enum) {
    variable: *TypeVar,
    int,
    float,
    bool,
    char,
    string,
    unit,
    arrow: struct { from: *Type, to: *Type },
    tuple: []const *Type,
    con: struct { name: []const u8, args: []const *Type },
    record: struct { name: []const u8, fields: []const RecordFieldType },
    @"ref": *Type,
};

pub const TypeVar = struct {
    id: usize,
    name: []const u8,
    instance: ?*Type = null,
};

pub const RecordFieldType = struct {
    name: []const u8,
    ty: *Type,
};

pub const Scheme = struct {
    quantified: []const usize,
    body: *Type,
};

const CtorInfo = struct {
    type_name: []const u8,
    arity: usize,
};

const TypeDefInfo = struct {
    field_names: []const []const u8,
};

pub const Env = struct {
    allocator: std.mem.Allocator,
    parent: ?*Env,
    bindings: std.StringHashMap(Scheme),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) Env {
        return .{
            .allocator = allocator,
            .parent = parent,
            .bindings = std.StringHashMap(Scheme).init(allocator),
        };
    }

    pub fn deinit(self: *Env) void {
        self.bindings.deinit();
    }

    pub fn set(self: *Env, name: []const u8, scheme: Scheme) !void {
        try self.bindings.put(name, scheme);
    }

    pub fn getScheme(self: *Env, name: []const u8) ?Scheme {
        if (self.bindings.get(name)) |scheme| return scheme;
        if (self.parent) |parent| return parent.getScheme(name);
        return null;
    }
};

pub const Error = error{ UndefinedName, TypeMismatch, OccursCheck, UnknownConstructor, UnknownType, OutOfMemory };

pub const ErrorContext = struct {
    message: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,
    loc: ?parser.Loc = null,
};

pub const Inferer = struct {
    allocator: std.mem.Allocator,
    next_id: usize,
    global: Env,
    ctors: std.StringHashMap(CtorInfo),
    types: std.StringHashMap(TypeDefInfo),
    type_names: std.StringHashMap(usize),
    current_module: ?[]const u8,
    last_error: ?ErrorContext,
    current_loc: ?parser.Loc = null,
    doc_comments: std.StringHashMap([]const []const u8),

    pub fn init(allocator: std.mem.Allocator) Inferer {
        return .{
            .allocator = allocator,
            .next_id = 0,
            .global = Env.init(allocator, null),
            .ctors = std.StringHashMap(CtorInfo).init(allocator),
            .types = std.StringHashMap(TypeDefInfo).init(allocator),
            .type_names = std.StringHashMap(usize).init(allocator),
            .current_module = null,
            .last_error = null,
            .doc_comments = std.StringHashMap([]const []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Inferer) void {
        self.global.deinit();
        self.ctors.deinit();
        self.types.deinit();
        self.type_names.deinit();
        self.doc_comments.deinit();
    }

    /// Resolve a name: try the bare name first, then try module-qualified if inside a module.
    fn resolveName(self: *Inferer, env: *Env, name: []const u8) ?Scheme {
        if (env.getScheme(name)) |scheme| return scheme;
        if (self.current_module) |mod| {
            const qualified = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ mod, name }) catch return null;
            return env.getScheme(qualified);
        }
        return null;
    }

    fn newType(self: *Inferer, ty: Type) Error!*Type {
        const ptr = try self.allocator.create(Type);
        ptr.* = ty;
        return ptr;
    }

    fn newVarType(self: *Inferer, name: []const u8) Error!*Type {
        self.next_id += 1;
        const v = try self.allocator.create(TypeVar);
        v.* = .{ .id = self.next_id, .name = name };
        return self.newType(.{ .variable = v });
    }

    fn freshName(self: *Inferer, prefix: []const u8) Error![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, self.next_id + 1 });
    }

    pub fn resolve(self: *Inferer, ty: *Type) *Type {
        return switch (ty.*) {
            .variable => |v| blk: {
                if (v.instance) |inst| {
                    const resolved = self.resolve(inst);
                    v.instance = resolved;
                    break :blk resolved;
                }
                break :blk ty;
            },
            else => ty,
        };
    }

    fn occurs(self: *Inferer, tv: *TypeVar, ty: *Type) bool {
        const resolved = self.resolve(ty);
        return switch (resolved.*) {
            .variable => |v| v.id == tv.id,
            .arrow => |a| self.occurs(tv, a.from) or self.occurs(tv, a.to),
            .tuple => |items| blk: {
                for (items) |item| {
                    if (self.occurs(tv, item)) break :blk true;
                }
                break :blk false;
            },
            .con => |c| blk: {
                for (c.args) |arg| {
                    if (self.occurs(tv, arg)) break :blk true;
                }
                break :blk false;
            },
            .record => |r| blk: {
                for (r.fields) |field| {
                    if (self.occurs(tv, field.ty)) break :blk true;
                }
                break :blk false;
            },
            .@"ref" => |inner| self.occurs(tv, inner),
            else => false,
        };
    }

    fn unify(self: *Inferer, left: *Type, right: *Type) Error!void {
        const a = self.resolve(left);
        const b = self.resolve(right);

        if (a == b) return;

        switch (a.*) {
            .variable => |v| {
                if (self.occurs(v, b)) return error.OccursCheck;
                v.instance = b;
                return;
            },
            else => {},
        }

        switch (b.*) {
            .variable => |v| {
                if (self.occurs(v, a)) return error.OccursCheck;
                v.instance = a;
                return;
            },
            else => {},
        }

        const mismatch = struct {
            fn f(self_inner: *Inferer, l: *Type, r: *Type) Error!void {
                const exp_str = typeToString(self_inner.allocator, l.*) catch null;
                const act_str = typeToString(self_inner.allocator, r.*) catch null;
                self_inner.last_error = .{
                    .message = std.fmt.allocPrint(self_inner.allocator, "type mismatch: expected {s}, got {s}", .{
                        exp_str orelse "?",
                        act_str orelse "?",
                    }) catch null,
                    .expected = exp_str,
                    .actual = act_str,
                    .loc = self_inner.current_loc,
                };
                return error.TypeMismatch;
            }
        };

        switch (a.*) {
            .int => if (b.* != .int) return mismatch.f(self, a, b),
            .float => if (b.* != .float) return mismatch.f(self, a, b),
            .bool => if (b.* != .bool) return mismatch.f(self, a, b),
            .char => if (b.* != .char) return mismatch.f(self, a, b),
            .string => if (b.* != .string) return mismatch.f(self, a, b),
            .unit => if (b.* != .unit) return mismatch.f(self, a, b),
            .arrow => |aa| switch (b.*) {
                .arrow => |bb| {
                    try self.unify(aa.from, bb.from);
                    try self.unify(aa.to, bb.to);
                },
                else => return mismatch.f(self, a, b),
            },
            .tuple => |items| switch (b.*) {
                .tuple => |other| {
                    if (items.len != other.len) return mismatch.f(self, a, b);
                    for (items, other) |x, y| try self.unify(x, y);
                },
                else => return mismatch.f(self, a, b),
            },
            .con => |c| switch (b.*) {
                .con => |d| {
                    if (!std.mem.eql(u8, c.name, d.name) or c.args.len != d.args.len) return mismatch.f(self, a, b);
                    for (c.args, d.args) |x, y| try self.unify(x, y);
                },
                else => return mismatch.f(self, a, b),
            },
            .record => |r| switch (b.*) {
                .record => |s| {
                    if (!std.mem.eql(u8, r.name, s.name) or r.fields.len != s.fields.len) return mismatch.f(self, a, b);
                    for (r.fields, s.fields) |x, y| {
                        if (!std.mem.eql(u8, x.name, y.name)) return mismatch.f(self, a, b);
                        try self.unify(x.ty, y.ty);
                    }
                },
                else => return mismatch.f(self, a, b),
            },
            .@"ref" => |inner_a| switch (b.*) {
                .@"ref" => |inner_b| try self.unify(inner_a, inner_b),
                else => return mismatch.f(self, a, b),
            },
            .variable => unreachable,
        }
    }

    fn collectFree(self: *Inferer, ty: *Type, out: *std.AutoHashMap(usize, void)) Error!void {
        const resolved = self.resolve(ty);
        switch (resolved.*) {
            .variable => |v| try out.put(v.id, {}),
            .arrow => |a| {
                try self.collectFree(a.from, out);
                try self.collectFree(a.to, out);
            },
            .tuple => |items| for (items) |item| try self.collectFree(item, out),
            .con => |c| for (c.args) |arg| try self.collectFree(arg, out),
            .record => |r| for (r.fields) |field| try self.collectFree(field.ty, out),
            .@"ref" => |inner| try self.collectFree(inner, out),
            else => {},
        }
    }

    fn collectEnvFree(self: *Inferer, env: *Env, out: *std.AutoHashMap(usize, void)) Error!void {
        var it = env.bindings.iterator();
        while (it.next()) |entry| {
            try self.collectFree(entry.value_ptr.body, out);
            for (entry.value_ptr.quantified) |qid| _ = out.remove(qid);
        }
        if (env.parent) |parent| try self.collectEnvFree(parent, out);
    }

    fn generalize(self: *Inferer, env: *Env, ty: *Type) Error!Scheme {
        var free_ty = std.AutoHashMap(usize, void).init(self.allocator);
        defer free_ty.deinit();
        try self.collectFree(ty, &free_ty);

        var env_free = std.AutoHashMap(usize, void).init(self.allocator);
        defer env_free.deinit();
        try self.collectEnvFree(env, &env_free);

        var quantified = std.ArrayList(usize).empty;
        defer quantified.deinit(self.allocator);
        var it = free_ty.iterator();
        while (it.next()) |entry| {
            if (!env_free.contains(entry.key_ptr.*)) {
                try quantified.append(self.allocator, entry.key_ptr.*);
            }
        }

        return .{
            .quantified = try self.allocator.dupe(usize, quantified.items),
            .body = ty,
        };
    }

    fn instantiate(self: *Inferer, scheme: Scheme) Error!*Type {
        if (scheme.quantified.len == 0) return scheme.body;
        var map = std.AutoHashMap(usize, *Type).init(self.allocator);
        defer map.deinit();
        for (scheme.quantified) |qid| {
            const name = try self.freshName("t");
            const fresh = try self.newVarType(name);
            try map.put(qid, fresh);
        }
        return self.cloneType(scheme.body, &map);
    }

    fn cloneType(self: *Inferer, ty: *Type, map: *std.AutoHashMap(usize, *Type)) Error!*Type {
        const resolved = self.resolve(ty);
        return switch (resolved.*) {
            .variable => |v| if (map.get(v.id)) |rep| rep else resolved,
            .int => try self.newType(.int),
            .float => try self.newType(.float),
            .bool => try self.newType(.bool),
            .char => try self.newType(.char),
            .string => try self.newType(.string),
            .unit => try self.newType(.unit),
            .arrow => |a| try self.newType(.{ .arrow = .{ .from = try self.cloneType(a.from, map), .to = try self.cloneType(a.to, map) } }),
            .tuple => |items| blk: {
                var out = try self.allocator.alloc(*Type, items.len);
                for (items, 0..) |item, i| out[i] = try self.cloneType(item, map);
                break :blk try self.newType(.{ .tuple = out });
            },
            .con => |c| blk: {
                var out = try self.allocator.alloc(*Type, c.args.len);
                for (c.args, 0..) |arg, i| out[i] = try self.cloneType(arg, map);
                break :blk try self.newType(.{ .con = .{ .name = c.name, .args = out } });
            },
            .record => |r| blk: {
                var out = try self.allocator.alloc(RecordFieldType, r.fields.len);
                for (r.fields, 0..) |field, i| {
                    out[i] = .{ .name = field.name, .ty = try self.cloneType(field.ty, map) };
                }
                break :blk try self.newType(.{ .record = .{ .name = r.name, .fields = out } });
            },
            .@"ref" => |inner| try self.newType(.{ .@"ref" = try self.cloneType(inner, map) }),
        };
    }

    fn typeExprToType(self: *Inferer, te: parser.TypeExpr) Error!*Type {
        return switch (te) {
            .ident => |name| {
                if (self.types.get(name)) |_| {
                    return try self.newType(.{ .con = .{ .name = name, .args = &.{} } });
                }
                return try self.newVarType(try self.freshName(name));
            },
            .constructor => |name| {
                if (std.mem.eql(u8, name, "Int")) return try self.newType(.int);
                if (std.mem.eql(u8, name, "Float")) return try self.newType(.float);
                if (std.mem.eql(u8, name, "Bool")) return try self.newType(.bool);
                if (std.mem.eql(u8, name, "String")) return try self.newType(.string);
                if (std.mem.eql(u8, name, "Char")) return try self.newType(.char);
                if (self.type_names.get(name)) |num_params| {
                    const args = try self.allocator.alloc(*Type, num_params);
                    for (args) |*slot| {
                        slot.* = try self.newVarType(try self.freshName(name));
                    }
                    return try self.newType(.{ .con = .{ .name = name, .args = args } });
                }
                return try self.newType(.{ .con = .{ .name = name, .args = &.{} } });
            },
            .arrow => |a| try self.newType(.{ .arrow = .{ .from = try self.typeExprToType(a.from.*), .to = try self.typeExprToType(a.to.*) } }),
            .record => |fields| {
                var fts = try self.allocator.alloc(RecordFieldType, fields.len);
                for (fields, 0..) |f, i| fts[i] = .{ .name = f.name, .ty = try self.typeExprToType(f.type_expr) };
                return try self.newType(.{ .record = .{ .name = "", .fields = fts } });
            },
            .group => |inner| self.typeExprToType(inner.*),
            .application => |app| {
                const func_ty = try self.typeExprToType(app.func.*);
                const arg_ty = try self.typeExprToType(app.arg.*);
                const result = try self.newVarType(try self.freshName("t"));
                try self.unify(func_ty, try self.newType(.{ .arrow = .{ .from = arg_ty, .to = result } }));
                return result;
            },
        };
    }

    fn functionReturnType(fn_type: *Type) *Type {
        var cur = fn_type;
        while (true) {
            switch (cur.*) {
                .arrow => |a| cur = a.to,
                else => return cur,
            }
        }
    }

    fn functionTypeFromParams(self: *Inferer, name: []const u8, param_count: usize) Error!*Type {
        var result = try self.newVarType(try self.freshName(name));
        var i: usize = param_count;
        while (i > 0) : (i -= 1) {
            const param = try self.newVarType(try self.freshName("p"));
            result = try self.newType(.{ .arrow = .{ .from = param, .to = result } });
        }
        return result;
    }

    pub fn inferProgram(self: *Inferer, program: *const parser.Program) Error!void {
        // Register type definitions and constructor types first.
        for (program.definitions) |def| {
            switch (def) {
                .type_def => |t| try self.registerTypeDef(t),
                .module_def => |m| {
                    for (m.definitions) |inner_def| {
                        switch (inner_def) {
                            .type_def => |t| {
                                const prefixed_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ m.name, t.name });
                                var td = t;
                                td.name = prefixed_name;
                                try self.registerTypeDef(td);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // Predeclare built-in functions (polymorphic, prints and returns the value)
        const println_from = try self.newVarType("a");
        const println_to = println_from;
        const println_ty = try self.allocator.create(Type);
        println_ty.* = .{ .arrow = .{ .from = println_from, .to = println_to } };
        const println_var_id = println_from.variable.id;
        const println_quantified = try self.allocator.alloc(usize, 1);
        println_quantified[0] = println_var_id;
        try self.global.set("println", .{ .quantified = println_quantified, .body = println_ty });

        const print_from = try self.newVarType("b");
        const print_to = print_from;
        const print_ty = try self.allocator.create(Type);
        print_ty.* = .{ .arrow = .{ .from = print_from, .to = print_to } };
        const print_var_id = print_from.variable.id;
        const print_quantified = try self.allocator.alloc(usize, 1);
        print_quantified[0] = print_var_id;
        try self.global.set("print", .{ .quantified = print_quantified, .body = print_ty });

        // inspect: forall a. a -> a (polymorphic, prints and returns the value)
        const inspect_from = try self.newVarType("a");
        const inspect_to = inspect_from;
        const inspect_ty = try self.allocator.create(Type);
        inspect_ty.* = .{ .arrow = .{ .from = inspect_from, .to = inspect_to } };
        const var_id = inspect_from.variable.id;
        const quantified = try self.allocator.alloc(usize, 1);
        quantified[0] = var_id;
        try self.global.set("inspect", .{ .quantified = quantified, .body = inspect_ty });

        // String module builtins
        const string_ty = try self.newType(.string);
        const string_to_int = try self.allocator.create(Type);
        string_to_int.* = .{ .arrow = .{ .from = string_ty, .to = try self.newType(.int) } };
        try self.global.set("String.length", .{ .quantified = &.{}, .body = string_to_int });

        const string_string_to_string = try self.allocator.create(Type);
        const string_param = try self.newType(.string);
        const string_result = try self.newType(.string);
        const inner_arrow = try self.allocator.create(Type);
        inner_arrow.* = .{ .arrow = .{ .from = string_result, .to = try self.newType(.string) } };
        string_string_to_string.* = .{ .arrow = .{ .from = string_param, .to = inner_arrow } };
        try self.global.set("String.append", .{ .quantified = &.{}, .body = string_string_to_string });

        const string_string_to_bool = try self.allocator.create(Type);
        const string_param2 = try self.newType(.string);
        const string_param3 = try self.newType(.string);
        const inner_arrow2 = try self.allocator.create(Type);
        inner_arrow2.* = .{ .arrow = .{ .from = string_param3, .to = try self.newType(.bool) } };
        string_string_to_bool.* = .{ .arrow = .{ .from = string_param2, .to = inner_arrow2 } };
        try self.global.set("String.contains", .{ .quantified = &.{}, .body = string_string_to_bool });

        const string_int_to_char = try self.allocator.create(Type);
        const string_param4 = try self.newType(.string);
        const int_param = try self.newType(.int);
        const inner_arrow3 = try self.allocator.create(Type);
        inner_arrow3.* = .{ .arrow = .{ .from = int_param, .to = try self.newType(.char) } };
        string_int_to_char.* = .{ .arrow = .{ .from = string_param4, .to = inner_arrow3 } };
        try self.global.set("String.charAt", .{ .quantified = &.{}, .body = string_int_to_char });

        const string_to_string = try self.allocator.create(Type);
        const string_param5 = try self.newType(.string);
        const string_result2 = try self.newType(.string);
        string_to_string.* = .{ .arrow = .{ .from = string_param5, .to = string_result2 } };
        try self.global.set("String.toUpperCase", .{ .quantified = &.{}, .body = string_to_string });
        try self.global.set("String.toLowerCase", .{ .quantified = &.{}, .body = string_to_string });
        try self.global.set("String.trim", .{ .quantified = &.{}, .body = string_to_string });

        const string_string_string_to_string = try self.allocator.create(Type);
        const string_param6 = try self.newType(.string);
        const string_param7 = try self.newType(.string);
        const string_param8 = try self.newType(.string);
        const string_result3 = try self.newType(.string);
        const inner_arrow4 = try self.allocator.create(Type);
        inner_arrow4.* = .{ .arrow = .{ .from = string_param8, .to = string_result3 } };
        const inner_arrow5 = try self.allocator.create(Type);
        inner_arrow5.* = .{ .arrow = .{ .from = string_param7, .to = inner_arrow4 } };
        string_string_string_to_string.* = .{ .arrow = .{ .from = string_param6, .to = inner_arrow5 } };
        try self.global.set("String.replace", .{ .quantified = &.{}, .body = string_string_string_to_string });

        // Predeclare functions for recursion.
        for (program.definitions) |def| {
            try self.predeclareDefinition(def, "");
        }

        // Infer top-level definitions in order.
        for (program.definitions) |def| {
            try self.inferDefinition(def, "");
        }
    }

    fn predeclareDefinition(self: *Inferer, def: parser.Definition, prefix: []const u8) Error!void {
        switch (def) {
            .fn_def => |f| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, f.name })
                else
                    f.name;
                const fn_type = try self.functionTypeFromParams(prefixed_name, f.params.len);
                try self.global.set(prefixed_name, .{ .quantified = &.{}, .body = fn_type });
            },
            .type_def => |t| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, t.name })
                else
                    t.name;
                var td = t;
                td.name = prefixed_name;
                try self.registerTypeDef(td);
            },
            .module_def => |m| {
                const mod_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, m.name })
                else
                    m.name;
                for (m.definitions) |inner_def| {
                    try self.predeclareDefinition(inner_def, mod_prefix);
                }
            },
            else => {},
        }
    }

    fn inferDefinition(self: *Inferer, def: parser.Definition, prefix: []const u8) Error!void {
        switch (def) {
            .fn_def => |f| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, f.name })
                else
                    f.name;
                if (f.doc_comments) |docs| {
                    self.doc_comments.put(prefixed_name, docs) catch {};
                }
                var fd = f;
                fd.name = prefixed_name;
                try self.inferFn(fd);
            },
            .let_binding => |l| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, l.name })
                else
                    l.name;
                if (l.doc_comments) |docs| {
                    self.doc_comments.put(prefixed_name, docs) catch {};
                }
                const t = try self.inferExpr(&self.global, l.value);
                if (l.type_ann) |ann| {
                    const ann_ty = try self.typeExprToType(ann);
                    try self.unify(t, ann_ty);
                }
                const scheme = try self.generalize(&self.global, t);
                try self.global.set(prefixed_name, scheme);
            },
            .type_def => |t| {
                const prefixed_name = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, t.name })
                else
                    t.name;
                if (t.doc_comments) |docs| {
                    self.doc_comments.put(prefixed_name, docs) catch {};
                }
                var td = t;
                td.name = prefixed_name;
                try self.registerTypeDef(td);
            },
            .module_def => |m| {
                const mod_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, m.name })
                else
                    m.name;
                const prev_module = self.current_module;
                self.current_module = mod_prefix;
                defer self.current_module = prev_module;
                for (m.definitions) |inner_def| {
                    try self.inferDefinition(inner_def, mod_prefix);
                }
            },
            else => {},
        }
    }

    fn registerTypeDef(self: *Inferer, t: parser.TypeDef) Error!void {
        try self.type_names.put(t.name, t.type_params.len);
        switch (t.body) {
            .sum => |ctors| {
                const type_param_vars = try self.allocator.alloc(*Type, t.type_params.len);
                for (type_param_vars) |*slot| {
                    slot.* = try self.newVarType(try self.freshName(t.name));
                }

                for (ctors) |ctor| {
                    const arity = ctor.params.len;
                    try self.ctors.put(ctor.name, .{ .type_name = t.name, .arity = arity });

                    const result = try self.newType(.{ .con = .{ .name = t.name, .args = type_param_vars } });
                    var fn_type = result;
                    var idx = arity;
                    while (idx > 0) : (idx -= 1) {
                        const arg_var = try self.newVarType(try self.freshName(ctor.name));
                        fn_type = try self.newType(.{ .arrow = .{ .from = arg_var, .to = fn_type } });
                    }

                    var quantified = std.ArrayList(usize).empty;
                    defer quantified.deinit(self.allocator);
                    for (type_param_vars) |arg| switch (arg.*) {
                        .variable => |v| try quantified.append(self.allocator, v.id),
                        else => {},
                    };
                    try self.global.set(ctor.name, .{ .quantified = try self.allocator.dupe(usize, quantified.items), .body = fn_type });
                }
            },
            .record => |fields| {
                var names = std.ArrayList([]const u8).empty;
                defer names.deinit(self.allocator);
                for (fields) |field| try names.append(self.allocator, field.name);
                try self.types.put(t.name, .{ .field_names = try self.allocator.dupe([]const u8, names.items) });
            },
        }
    }

    fn inferFn(self: *Inferer, f: parser.FnDef) Error!void {
        const scheme = self.global.getScheme(f.name) orelse return error.UndefinedName;
        const fn_type = scheme.body;
        var local = Env.init(self.allocator, &self.global);
        defer local.deinit();

        var cur = fn_type;
        for (f.params) |param| {
            switch (cur.*) {
                .arrow => |a| {
                    if (param.type_ann) |ann| {
                        const ann_ty = try self.typeExprToType(ann);
                        try self.unify(a.from, ann_ty);
                    }
                switch (param.pattern) {
                    .identifier => |name| {
                        try local.set(name, .{ .quantified = &.{}, .body = a.from });
                    },
                    else => {
                        try self.inferPattern(&local, param.pattern, a.from);
                    },
                }
                    cur = a.to;
                },
                else => break,
            }
        }

        const body_ty = try self.inferExpr(&local, f.body);
        try self.unify(cur, body_ty);
        if (f.return_type) |ann| {
            const ann_ty = try self.typeExprToType(ann);
            try self.unify(cur, ann_ty);
        }
        try self.global.set(f.name, try self.generalize(&self.global, fn_type));
    }

    fn inferExpr(self: *Inferer, env: *Env, expr: *const parser.Expr) Error!*Type {
        self.current_loc = expr.getLoc();
        return switch (expr.*) {
            .int_literal => try self.newType(.int),
            .float_literal => try self.newType(.float),
            .string_literal => try self.newType(.string),
            .char_literal => try self.newType(.char),
            .bool_literal => try self.newType(.bool),
            .identifier => |id| blk: {
                const scheme = self.resolveName(env, id.name) orelse {
                    return error.UndefinedName;
                };
                break :blk try self.instantiate(scheme);
            },
            .constructor => |c| blk: {
                const scheme = self.resolveName(env, c.name) orelse {
                    return error.UndefinedName;
                };
                break :blk try self.instantiate(scheme);
            },
            .tuple => |t| {
                const tys = try self.allocator.alloc(*Type, t.items.len);
                for (t.items, 0..) |item, i| tys[i] = try self.inferExpr(env, item);
                return try self.newType(.{ .tuple = tys });
            },
            .record_literal => |rec| try self.inferRecordLiteral(env, rec.name, rec.fields),
            .field_access => |fa| try self.inferFieldAccess(env, fa.object, fa.field),
            .fn_call => |call| try self.inferCall(env, call.func, call.args, call.named_args),
            .lambda => |lam| try self.inferLambda(env, lam.params, lam.body),
            .unary_op => |u| try self.inferUnary(env, u.op, u.expr),
            .binary_op => |b| try self.inferBinary(env, b.op, b.left, b.right),
            .let_expr => |l| try self.inferLetExpr(env, l.name, l.value, l.body, l.type_ann),
            .if_expr => |i| try self.inferIf(env, i.condition, i.then_branch, i.else_branch),
            .block => |b| try self.inferBlock(env, b.items),
            .match_expr => |m| try self.inferMatch(env, m.value, m.arms),
            .comptime_expr => |inner| try self.inferExpr(env, inner),
            .pat_record => try self.newType(.unit),
            .ref_expr => |inner| try self.inferUnary(env, .ref, inner),
            .assign_expr => |a| {
                _ = try self.inferExpr(env, a.target);
                _ = try self.inferExpr(env, a.value);
                return try self.newType(.unit);
            },
        };
    }

    fn inferBlock(self: *Inferer, env: *Env, items: []const *parser.Expr) Error!*Type {
        var last = try self.newType(.unit);
        for (items) |item| last = try self.inferExpr(env, item);
        return last;
    }

    fn inferLetExpr(self: *Inferer, env: *Env, name: []const u8, value: *parser.Expr, body: *parser.Expr, type_ann: ?parser.TypeExpr) Error!*Type {
        const val_ty = try self.inferExpr(env, value);
        if (type_ann) |ann| {
            const ann_ty = try self.typeExprToType(ann);
            try self.unify(val_ty, ann_ty);
        }
        var local = Env.init(self.allocator, env);
        defer local.deinit();
        const scheme = try self.generalize(env, val_ty);
        try local.set(name, scheme);
        return self.inferExpr(&local, body);
    }

    fn inferIf(self: *Inferer, env: *Env, cond: *parser.Expr, then_branch: *parser.Expr, else_branch: ?*parser.Expr) Error!*Type {
        const cond_ty = try self.inferExpr(env, cond);
        try self.unify(cond_ty, try self.newType(.bool));
        const then_ty = try self.inferExpr(env, then_branch);
        if (else_branch) |else_expr| {
            const else_ty = try self.inferExpr(env, else_expr);
            try self.unify(then_ty, else_ty);
            return then_ty;
        }
        return then_ty;
    }

    fn inferUnary(self: *Inferer, env: *Env, op: parser.UnaryOp, inner: *parser.Expr) Error!*Type {
        const ty = try self.inferExpr(env, inner);
        return switch (op) {
            .neg => blk: {
                try self.unify(ty, try self.newType(.int));
                break :blk try self.newType(.int);
            },
            .not => blk: {
                try self.unify(ty, try self.newType(.bool));
                break :blk try self.newType(.bool);
            },
            .ref => try self.newType(.{ .@"ref" = ty }),
            .deref => blk: {
                const inner_ty = try self.newVarType(try self.freshName("deref"));
                try self.unify(ty, try self.newType(.{ .@"ref" = inner_ty }));
                break :blk inner_ty;
            },
            .try_op => blk: {
                const result_ty = try self.newVarType(try self.freshName("result"));
                const ok_ty = try self.newVarType(try self.freshName("ok"));
                try self.unify(ty, try self.newType(.{ .con = .{ .name = "Result", .args = &.{ ok_ty, result_ty } } }));
                break :blk ok_ty;
            },
        };
    }

    fn inferBinary(self: *Inferer, env: *Env, op: parser.BinaryOp, left: *parser.Expr, right: *parser.Expr) Error!*Type {
        const lt = try self.inferExpr(env, left);
        const rt = try self.inferExpr(env, right);
        return switch (op) {
            .add => blk: {
                if (lt.* == .string or rt.* == .string) {
                    try self.unify(lt, try self.newType(.string));
                    try self.unify(rt, try self.newType(.string));
                    break :blk try self.newType(.string);
                }
                try self.unify(lt, try self.newType(.int));
                try self.unify(rt, try self.newType(.int));
                break :blk try self.newType(.int);
            },
            .sub, .mul, .div, .mod => blk: {
                try self.unify(lt, try self.newType(.int));
                try self.unify(rt, try self.newType(.int));
                break :blk try self.newType(.int);
            },
            .eq, .neq, .lt, .lte, .gt, .gte => blk: {
                try self.unify(lt, rt);
                break :blk try self.newType(.bool);
            },
            .and_op, .or_op => blk: {
                try self.unify(lt, try self.newType(.bool));
                try self.unify(rt, try self.newType(.bool));
                break :blk try self.newType(.bool);
            },
            .pipe => blk: {
                break :blk rt;
            },
            .cons => blk: {
                // desugar: left :: right  →  Cons left right
                const ctor_scheme = self.resolveName(env, "Cons") orelse return error.UndefinedName;
                const ctor_ty = try self.instantiate(ctor_scheme);
                // Cons : a -> List a -> List a
                // Apply to left and right, return List a
                const elem_ty = try self.newVarType(try self.freshName("elem"));
                const list_ty = try self.newType(.{ .con = .{ .name = "List", .args = try self.allocator.dupe(*Type, &.{elem_ty}) } });
                const expected = try self.newType(.{ .arrow = .{ .from = elem_ty, .to = try self.newType(.{ .arrow = .{ .from = list_ty, .to = list_ty } }) } });
                try self.unify(ctor_ty, expected);
                try self.unify(lt, elem_ty);
                try self.unify(rt, list_ty);
                break :blk list_ty;
            },
        };
    }

    fn inferCall(self: *Inferer, env: *Env, func: *parser.Expr, args: []const *parser.Expr, named_args: []const parser.NamedArg) Error!*Type {
        const fn_ty = try self.inferExpr(env, func);
        const expected = try self.newVarType(try self.freshName("ret"));
        var chain = expected;
        const total = args.len + named_args.len;
        var arg_tys = try self.allocator.alloc(*Type, total);
        var i: usize = total;
        while (i > 0) : (i -= 1) {
            const arg_ty = try self.newVarType(try self.freshName("arg"));
            arg_tys[i - 1] = arg_ty;
            chain = try self.newType(.{ .arrow = .{ .from = arg_ty, .to = chain } });
        }
        try self.unify(fn_ty, chain);
        for (args, 0..) |arg, idx| {
            const arg_ty = try self.inferExpr(env, arg);
            try self.unify(arg_tys[idx], arg_ty);
        }
        for (named_args, 0..) |na, idx| {
            const arg_ty = try self.inferExpr(env, na.value);
            try self.unify(arg_tys[args.len + idx], arg_ty);
        }
        return expected;
    }

    fn inferLambda(self: *Inferer, env: *Env, params: []const parser.Pattern, body: *parser.Expr) Error!*Type {
        var local = Env.init(self.allocator, env);
        defer local.deinit();
        var param_types = try self.allocator.alloc(*Type, params.len);
        for (params, 0..) |pat, i| {
            const ty = try self.newVarType(try self.freshName("param"));
            param_types[i] = ty;
            switch (pat) {
                .identifier => |name| {
                    try local.set(name, .{ .quantified = &.{}, .body = ty });
                },
                else => {},
            }
        }
        const body_ty = try self.inferExpr(&local, body);
        var result = body_ty;
        var idx = params.len;
        while (idx > 0) : (idx -= 1) {
            result = try self.newType(.{ .arrow = .{ .from = param_types[idx - 1], .to = result } });
        }
        return result;
    }

    fn inferFieldAccess(self: *Inferer, env: *Env, object: *parser.Expr, field: []const u8) Error!*Type {
        if (object.* == .identifier or object.* == .constructor) {
            // Try dot-separated module name (e.g., Math.add)
            const obj_name = switch (object.*) {
                .identifier => |id| id.name,
                .constructor => |c| c.name,
                else => unreachable,
            };
            const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ obj_name, field });
            if (env.getScheme(combined)) |scheme| return self.instantiate(scheme);
        }

        const obj_ty = try self.inferExpr(env, object);
        const resolved = self.resolve(obj_ty);
        switch (resolved.*) {
            .string => {
                if (std.mem.eql(u8, field, "length")) return try self.newType(.int);
                return error.UnknownType;
            },
            .record => |rec| {
                for (rec.fields) |f| {
                    if (std.mem.eql(u8, f.name, field)) return f.ty;
                }
                return error.UnknownType;
            },
            .variable => {
                if (std.mem.eql(u8, field, "length")) {
                    try self.unify(obj_ty, try self.newType(.string));
                    return try self.newType(.int);
                }
                return try self.newVarType(try self.freshName("field"));
            },
            else => return error.UnknownType,
        }
    }

    fn inferRecordLiteral(self: *Inferer, env: *Env, name: []const u8, fields: []const parser.NamedArg) Error!*Type {
        var field_types = std.ArrayList(RecordFieldType).empty;
        defer field_types.deinit(self.allocator);

        // Try bare name first, then module-qualified
        var resolved_name = name;
        if (self.types.get(name) == null) {
            if (self.current_module) |mod| {
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ mod, name });
                if (self.types.get(qualified)) |_| {
                    resolved_name = qualified;
                }
            }
        }

        if (self.types.get(resolved_name)) |info| {
            for (info.field_names) |wanted| {
                var found: ?*parser.Expr = null;
                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, wanted)) {
                        found = field.value;
                        break;
                    }
                }
                const expr = found orelse return error.UnknownType;
                try field_types.append(self.allocator, .{ .name = wanted, .ty = try self.inferExpr(env, expr) });
            }
        } else {
            for (fields) |field| {
                try field_types.append(self.allocator, .{ .name = field.name, .ty = try self.inferExpr(env, field.value) });
            }
        }

        return try self.newType(.{ .record = .{ .name = resolved_name, .fields = try self.allocator.dupe(RecordFieldType, field_types.items) } });
    }

    fn inferMatch(self: *Inferer, env: *Env, value: *parser.Expr, arms: []const parser.MatchArm) Error!*Type {
        const scrutinee_ty = try self.inferExpr(env, value);
        var result_ty: ?*Type = null;
        for (arms) |arm| {
            var arm_env = Env.init(self.allocator, env);
            defer arm_env.deinit();
            try self.inferPattern(&arm_env, arm.pattern, scrutinee_ty);
            const body_ty = try self.inferExpr(&arm_env, arm.body);
            if (result_ty) |prev| {
                try self.unify(prev, body_ty);
            } else {
                result_ty = body_ty;
            }
        }
        return result_ty orelse try self.newType(.unit);
    }

    const PatternBinding = struct { name: []const u8, ty: *Type };

    fn inferPattern(self: *Inferer, env: *Env, pat: parser.Pattern, expected: *Type) Error!void {
        var bindings = std.ArrayList(PatternBinding).empty;
        defer bindings.deinit(self.allocator);
        try self.inferPatternBindings(&bindings, pat, expected);
        for (bindings.items) |binding| {
            try env.set(binding.name, .{ .quantified = &.{}, .body = binding.ty });
        }
    }

    fn inferPatternBindings(self: *Inferer, bindings: *std.ArrayList(PatternBinding), pat: parser.Pattern, expected: *Type) Error!void {
        switch (pat) {
            .wildcard => {},
            .identifier => |name| try bindings.append(self.allocator, .{ .name = name, .ty = expected }),
            .literal => |lit| switch (lit) {
                .int => try self.unify(expected, try self.newType(.int)),
                .float => try self.unify(expected, try self.newType(.float)),
                .string => try self.unify(expected, try self.newType(.string)),
                .char => try self.unify(expected, try self.newType(.char)),
                .bool => try self.unify(expected, try self.newType(.bool)),
            },
            .tuple => |items| {
                const elem_types = try self.allocator.alloc(*Type, items.len);
                for (items, 0..) |_, i| elem_types[i] = try self.newVarType(try self.freshName("tup"));
                try self.unify(expected, try self.newType(.{ .tuple = elem_types }));
                for (items, elem_types) |item, ty| {
                    try self.inferPatternBindings(bindings, item, ty);
                }
            },
            .constructor => |ctor| {
                // Try bare name first, then module-qualified
                var ctor_info = self.ctors.get(ctor.name);
                if (ctor_info == null) {
                    if (self.current_module) |mod| {
                        const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ mod, ctor.name });
                        ctor_info = self.ctors.get(qualified);
                    }
                }
                const info = ctor_info orelse return error.UnknownConstructor;
                const num_type_params = self.type_names.get(info.type_name) orelse 0;
                const type_args = try self.allocator.alloc(*Type, num_type_params);
                for (type_args) |*slot| {
                    slot.* = try self.newVarType(try self.freshName(info.type_name));
                }
                const arg_types = try self.allocator.alloc(*Type, info.arity);
                for (arg_types) |*slot| {
                    slot.* = try self.newVarType(try self.freshName(ctor.name));
                }
                try self.unify(expected, try self.newType(.{ .con = .{ .name = info.type_name, .args = type_args } }));
                if (ctor.args.len != info.arity) return error.TypeMismatch;
                for (ctor.args, arg_types) |sub_pat, arg_ty| {
                    try self.inferPatternBindings(bindings, sub_pat, arg_ty);
                }
            },
            .record => |rec| {
                var field_types = std.ArrayList(RecordFieldType).empty;
                defer field_types.deinit(self.allocator);

                // Try bare name first, then module-qualified
                var resolved_rec_name = rec.name;
                if (self.types.get(rec.name) == null) {
                    if (self.current_module) |mod| {
                        const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ mod, rec.name });
                        if (self.types.get(qualified)) |_| {
                            resolved_rec_name = qualified;
                        }
                    }
                }

                if (self.types.get(resolved_rec_name)) |info| {
                    for (info.field_names) |wanted| {
                        const field_ty = try self.newVarType(try self.freshName(wanted));
                        try field_types.append(self.allocator, .{ .name = wanted, .ty = field_ty });
                    }
                } else {
                    for (rec.fields) |field| {
                        const field_ty = try self.newVarType(try self.freshName(field.name));
                        try field_types.append(self.allocator, .{ .name = field.name, .ty = field_ty });
                    }
                }

                try self.unify(expected, try self.newType(.{ .record = .{ .name = resolved_rec_name, .fields = try self.allocator.dupe(RecordFieldType, field_types.items) } }));

                for (rec.fields) |field| {
                    var matched: ?*Type = null;
                    for (field_types.items) |decl| {
                        if (std.mem.eql(u8, decl.name, field.name)) {
                            matched = decl.ty;
                            break;
                        }
                    }
                    const field_ty = matched orelse return error.TypeMismatch;
                    if (field.pattern) |sub| {
                        try self.inferPatternBindings(bindings, sub.*, field_ty);
                    } else {
                        try bindings.append(self.allocator, .{ .name = field.name, .ty = field_ty });
                    }
                }
                _ = rec.rest;
            },
        }
    }
};

pub fn testInfer(source: [:0]const u8) anyerror!void {
    var p = try parser.Parser.init(std.heap.page_allocator, source);
    var prog = try p.parse_program();
    var inferer = Inferer.init(std.heap.page_allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
}

pub fn testInferExpr(source: [:0]const u8, expr: *const parser.Expr) anyerror!*Type {
    var p = try parser.Parser.init(std.heap.page_allocator, source);
    var prog = try p.parse_program();
    var inferer = Inferer.init(std.heap.page_allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    return inferer.inferExpr(&inferer.global, expr);
}

pub fn deallocProg(allocator: std.mem.Allocator, prog: *parser.Program) void {
    allocator.free(prog.definitions);
    if (prog.package) |pkg| allocator.free(pkg);
    for (prog.imports) |imp| {
        allocator.free(imp.path);
        if (imp.selective) |sel| allocator.free(sel);
        if (imp.alias) |alias| allocator.free(alias);
    }
}

pub fn typeToString(alloc: std.mem.Allocator, t: Type) ![]const u8 {
    return switch (t) {
        .int => try alloc.dupe(u8, "Int"),
        .float => try alloc.dupe(u8, "Float"),
        .bool => try alloc.dupe(u8, "Bool"),
        .char => try alloc.dupe(u8, "Char"),
        .string => try alloc.dupe(u8, "String"),
        .unit => try alloc.dupe(u8, "()"),
        .variable => |v| {
            if (v.instance) |inst| return typeToString(alloc, inst.*);
            if (v.name.len > 0) return try alloc.dupe(u8, v.name);
            return try std.fmt.allocPrint(alloc, "t{d}", .{v.id});
        },
        .arrow => |a| {
            const from_str = try typeToString(alloc, a.from.*);
            defer alloc.free(from_str);
            const to_str = try typeToString(alloc, a.to.*);
            defer alloc.free(to_str);
            if (a.from.* == .arrow)
                return std.fmt.allocPrint(alloc, "({s}) -> {s}", .{ from_str, to_str });
            return std.fmt.allocPrint(alloc, "{s} -> {s}", .{ from_str, to_str });
        },
        .tuple => |elems| {
            if (elems.len == 0) return try alloc.dupe(u8, "()");
            var parts = std.ArrayList([]const u8).empty;
            defer {
                for (parts.items) |p| alloc.free(p);
                parts.deinit(alloc);
            }
            for (elems) |e| {
                try parts.append(alloc, try typeToString(alloc, e.*));
            }
            return std.fmt.allocPrint(alloc, "({s})", .{try std.mem.join(alloc, ", ", parts.items)});
        },
        .con => |c| {
            if (c.args.len == 0) return try alloc.dupe(u8, c.name);
            var parts = std.ArrayList([]const u8).empty;
            defer {
                for (parts.items) |p| alloc.free(p);
                parts.deinit(alloc);
            }
            for (c.args) |a| {
                const s = try typeToString(alloc, a.*);
                const need_parens = a.* == .arrow or a.* == .con;
                if (need_parens) {
                    try parts.append(alloc, try std.fmt.allocPrint(alloc, "({s})", .{s}));
                } else {
                    try parts.append(alloc, s);
                }
            }
            return std.fmt.allocPrint(alloc, "{s} {s}", .{ c.name, try std.mem.join(alloc, " ", parts.items) });
        },
        .record => |r| {
            var parts = std.ArrayList([]const u8).empty;
            defer {
                for (parts.items) |p| alloc.free(p);
                parts.deinit(alloc);
            }
            for (r.fields) |f| {
                const ft = try typeToString(alloc, f.ty.*);
                try parts.append(alloc, try std.fmt.allocPrint(alloc, "{s}: {s}", .{ f.name, ft }));
            }
            return std.fmt.allocPrint(alloc, "{{{s}}}", .{try std.mem.join(alloc, ", ", parts.items)});
        },
        .@"ref" => |inner| {
            const inner_str = try typeToString(alloc, inner.*);
            defer alloc.free(inner_str);
            return std.fmt.allocPrint(alloc, "ref {s}", .{inner_str});
        },
    };
}
