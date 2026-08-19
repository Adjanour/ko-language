const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const module_loader_mod = @import("module_loader.zig");

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

pub const CtorInfo = struct {
    type_name: []const u8,
    arity: usize,
    tag: u8 = 0,
    value_arg_types: ?[]const *Type = null,
};

const TypeDefInfo = struct {
    field_names: []const []const u8,
    /// The declared record type, so a `: Rect` annotation resolves to the same
    /// structural record a `Rect { ... }` literal produces. Without it the two
    /// are con("Rect") and record{...} respectively, and never unify.
    record_type: ?*Type = null,
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

fn levenshteinDistance(a: []const u8, b: []const u8) usize {
    const m = a.len;
    const n = b.len;
    if (m == 0) return n;
    if (n == 0) return m;
    if (m > 64 or n > 64) return 999;

    var prev: [65]usize = undefined;
    var curr: [65]usize = undefined;

    for (0..n + 1) |j| prev[j] = j;

    for (0..m) |i| {
        curr[0] = i + 1;
        for (0..n) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            const insert = prev[j + 1] + 1;
            const del = curr[j] + 1;
            const replace = prev[j] + cost;
            curr[j + 1] = @min(insert, del, replace);
        }
        std.mem.swap([65]usize, &prev, &curr);
    }
    return prev[n];
}

fn findSimilarName(name: []const u8, env: *Env) ?[]const u8 {
    var best_name: ?[]const u8 = null;
    var best_dist: usize = 3;

    var it = env.bindings.keyIterator();
    while (it.next()) |key_ptr| {
        const key = key_ptr.*;
        const dist = levenshteinDistance(name, key);
        if (dist < best_dist) {
            best_dist = dist;
            best_name = key;
        }
    }

    if (env.parent) |parent| {
        if (findSimilarName(name, parent)) |suggestion| {
            return suggestion;
        }
    }

    return best_name;
}

pub const ErrorContext = struct {
    message: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,
    loc: ?parser.Loc = null,
    note: ?[]const u8 = null,
    help: ?[]const u8 = null,
};

pub const Inferer = struct {
    allocator: std.mem.Allocator,
    next_id: usize,
    global: Env,
    ctors: std.StringHashMap(CtorInfo),
    types: std.StringHashMap(TypeDefInfo),
    type_names: std.StringHashMap(usize),
    type_ids: std.StringHashMap(usize), // type_name → unique type ID (for constructor table indexing)
    next_type_id: usize, // next type ID to assign
    current_module: ?[]const u8,
    last_error: ?ErrorContext,
    current_loc: ?parser.Loc = null,
    doc_comments: std.StringHashMap([]const []const u8),
    expr_type_tags: std.AutoHashMap(*const parser.Expr, i64),
    /// Tag of a `con` type's first type argument — the element type of `List a`.
    /// `inspect` needs it to print list elements with the right representation;
    /// without it every element falls back to tag 100 and prints as a raw i64.
    expr_elem_tags: std.AutoHashMap(*const parser.Expr, i64),
    expr_types: std.AutoHashMap(*const parser.Expr, *Type),
    concrete_elem_tags: std.StringHashMap(i64),
    /// Arguments of `String.from`, i.e. `${}` interpolation sites, with the loc
    /// to report against. Checked by validateInterpolations() after inference.
    interp_sites: std.AutoHashMap(*const parser.Expr, parser.Loc),
    /// Types that appeared as the object of a field access. See generalize().
    /// Stored as pointers, not ids: `unify` links a variable by setting
    /// `instance`, so the id that was current at field-access time may have
    /// been re-pointed by the time generalize runs. Resolving the pointer then
    /// gives the representative that collectFree actually reports.
    field_access_vars: std.AutoHashMap(*Type, void),
    module_loader: ?*module_loader_mod.ModuleLoader = null,
    imported_inferers: std.ArrayList(*Inferer),
    diagnostics: ?*DiagnosticList = null,
    enabled_warnings: diagnostics_mod.WarningSet = .{},
    used_names: std.StringHashMap(void),
    bound_names: std.StringHashMap(parser.Loc),
    param_arity: std.StringHashMap(u32), // function parameter name → arity (for function-typed params)
    var_type_tags: std.StringHashMap(i64), // variable name → type_tag (for closure capture decref)

    pub const DiagnosticList = @import("diagnostics.zig").DiagnosticList;
    const diagnostics_mod = @import("diagnostics.zig");

    pub fn init(allocator: std.mem.Allocator) Inferer {
        var inferer = Inferer{
            .allocator = allocator,
            .next_id = 0,
            .global = Env.init(allocator, null),
            .ctors = std.StringHashMap(CtorInfo).init(allocator),
            .types = std.StringHashMap(TypeDefInfo).init(allocator),
            .type_names = std.StringHashMap(usize).init(allocator),
            .type_ids = std.StringHashMap(usize).init(allocator),
            .next_type_id = 2, // Start at 2: Bool=0, Result=1 (matches codegen)
            .current_module = null,
            .last_error = null,
            .doc_comments = std.StringHashMap([]const []const u8).init(allocator),
            .expr_type_tags = std.AutoHashMap(*const parser.Expr, i64).init(allocator),
            .expr_elem_tags = std.AutoHashMap(*const parser.Expr, i64).init(allocator),
            .expr_types = std.AutoHashMap(*const parser.Expr, *Type).init(allocator),
            .concrete_elem_tags = std.StringHashMap(i64).init(allocator),
            .interp_sites = std.AutoHashMap(*const parser.Expr, parser.Loc).init(allocator),
            .field_access_vars = std.AutoHashMap(*Type, void).init(allocator),
            .module_loader = null,
            .imported_inferers = .empty,
            .enabled_warnings = .{},
            .used_names = std.StringHashMap(void).init(allocator),
            .bound_names = std.StringHashMap(parser.Loc).init(allocator),
            .param_arity = std.StringHashMap(u32).init(allocator),
            .var_type_tags = std.StringHashMap(i64).init(allocator),
        };
        // Pre-register built-in type IDs to match codegen's type_ids
        inferer.type_ids.put("Bool", 0) catch {};
        inferer.type_ids.put("Result", 1) catch {};
        // Also register type parameter counts so pattern inference works
        inferer.type_names.put("Bool", 0) catch {};
        inferer.type_names.put("Result", 2) catch {};

        // Pre-register True/False as built-in Bool constructors
        inferer.ctors.put("True", .{ .type_name = "Bool", .arity = 0, .tag = 1 }) catch {};
        inferer.ctors.put("False", .{ .type_name = "Bool", .arity = 0, .tag = 0 }) catch {};
        const bool_ty = inferer.newType(.bool) catch unreachable;
        inferer.global.set("True", .{ .quantified = &.{}, .body = bool_ty }) catch {};
        inferer.global.set("False", .{ .quantified = &.{}, .body = bool_ty }) catch {};

        inferer.registerPrelude() catch {};
        inferer.registerIoBuiltins() catch {};

        return inferer;
    }

    /// Build `t0 -> t1 -> ... -> ret` from a slice of parameter types.
    fn arrowOf(self: *Inferer, params: []const *Type, ret: *Type) Error!*Type {
        var out = ret;
        var i = params.len;
        while (i > 0) : (i -= 1) {
            const node = try self.allocator.create(Type);
            node.* = .{ .arrow = .{ .from = params[i - 1], .to = out } };
            out = node;
        }
        return out;
    }

    /// `Array a` is a builtin con with one parameter. Every signature below is
    /// polymorphic in the element type, so each is generalized over the
    /// variables it introduces.
    ///
    /// `push` returns the array rather than Unit, unlike DESIGN-data-structures
    /// §3: elements live inline after the header, so growing an array moves it
    /// and no handle into it can stay valid. `set` mutates in place and does
    /// return Unit, since it never reallocates.
    fn registerArrayBuiltins(self: *Inferer) Error!void {
        try self.type_names.put("Array", 1);

        const Sig = struct { name: []const u8, kind: enum { new, make, get, set, push, pop, length, is_empty } };
        for ([_]Sig{
            .{ .name = "Array.new", .kind = .new },
            .{ .name = "Array.make", .kind = .make },
            .{ .name = "Array.get", .kind = .get },
            .{ .name = "Array.set", .kind = .set },
            .{ .name = "Array.push", .kind = .push },
            .{ .name = "Array.pop", .kind = .pop },
            .{ .name = "Array.length", .kind = .length },
            .{ .name = "Array.isEmpty", .kind = .is_empty },
        }) |sig| {
            const a = try self.newVarType("a");
            const arr_args = try self.allocator.alloc(*Type, 1);
            arr_args[0] = a;
            const arr = try self.newType(.{ .con = .{ .name = "Array", .args = arr_args } });
            const int_ty = try self.newType(.int);

            const ty = switch (sig.kind) {
                .new => try self.arrowOf(&.{int_ty}, arr),
                .make => try self.arrowOf(&.{ int_ty, a }, arr),
                .get => try self.arrowOf(&.{ arr, int_ty }, a),
                .set => try self.arrowOf(&.{ arr, int_ty, a }, try self.newType(.unit)),
                .push => try self.arrowOf(&.{ arr, a }, arr),
                .pop => blk: {
                    const m_args = try self.allocator.alloc(*Type, 1);
                    m_args[0] = a;
                    break :blk try self.arrowOf(&.{arr}, try self.newType(.{ .con = .{ .name = "Maybe", .args = m_args } }));
                },
                .length => try self.arrowOf(&.{arr}, int_ty),
                .is_empty => try self.arrowOf(&.{arr}, try self.newType(.bool)),
            };
            const q = try self.allocator.alloc(usize, 1);
            q[0] = a.variable.id;
            try self.global.set(sig.name, .{ .quantified = q, .body = ty });
        }

        // Higher-order operations, which introduce a second element type.
        const Sig2 = struct { name: []const u8, kind: enum { map, filter, foldl, foldr, reverse } };
        for ([_]Sig2{
            .{ .name = "Array.map", .kind = .map },
            .{ .name = "Array.filter", .kind = .filter },
            .{ .name = "Array.foldl", .kind = .foldl },
            .{ .name = "Array.foldr", .kind = .foldr },
            .{ .name = "Array.reverse", .kind = .reverse },
        }) |sig| {
            const a = try self.newVarType("a");
            const b = try self.newVarType("b");
            const arr_a_args = try self.allocator.alloc(*Type, 1);
            arr_a_args[0] = a;
            const arr_a = try self.newType(.{ .con = .{ .name = "Array", .args = arr_a_args } });
            const arr_b_args = try self.allocator.alloc(*Type, 1);
            arr_b_args[0] = b;
            const arr_b = try self.newType(.{ .con = .{ .name = "Array", .args = arr_b_args } });

            const ty = switch (sig.kind) {
                .map => try self.arrowOf(&.{ try self.arrowOf(&.{a}, b), arr_a }, arr_b),
                .filter => try self.arrowOf(&.{ try self.arrowOf(&.{a}, try self.newType(.bool)), arr_a }, arr_a),
                .foldl => try self.arrowOf(&.{ try self.arrowOf(&.{ b, a }, b), b, arr_a }, b),
                .foldr => try self.arrowOf(&.{ try self.arrowOf(&.{ a, b }, b), b, arr_a }, b),
                .reverse => try self.arrowOf(&.{arr_a}, arr_a),
            };
            const q = try self.allocator.alloc(usize, 2);
            q[0] = a.variable.id;
            q[1] = b.variable.id;
            try self.global.set(sig.name, .{ .quantified = q, .body = ty });
        }

        // Array.sortWith : (a -> a -> Int) -> Array a -> Array a
        {
            const a = try self.newVarType("a");
            const arr_args = try self.allocator.alloc(*Type, 1);
            arr_args[0] = a;
            const arr = try self.newType(.{ .con = .{ .name = "Array", .args = arr_args } });
            const cmp = try self.arrowOf(&.{ a, a }, try self.newType(.int));
            const q = try self.allocator.alloc(usize, 1);
            q[0] = a.variable.id;
            try self.global.set("Array.sortWith", .{ .quantified = q, .body = try self.arrowOf(&.{ cmp, arr }, arr) });
        }

        // Array.sort : Array Int -> Array Int — deliberately monomorphic. It
        // orders the raw i64 payload, which is the value for an Int but a bit
        // pattern for a Float and an address for a String. Sorting those needs
        // Array.sortWith, and there are no typeclasses to pick an ordering.
        {
            const arr_args = try self.allocator.alloc(*Type, 1);
            arr_args[0] = try self.newType(.int);
            const arr_int = try self.newType(.{ .con = .{ .name = "Array", .args = arr_args } });
            try self.global.set("Array.sort", .{ .quantified = &.{}, .body = try self.arrowOf(&.{arr_int}, arr_int) });
        }
    }

    /// `Map k v` is a builtin con with two parameters.
    ///
    /// `set` returns the map rather than Unit, unlike DESIGN-data-structures
    /// §4, for the same reason `Array.push` does: buckets live inline, so a
    /// resize moves the table. `delete` returns Unit, since it only tombstones.
    ///
    /// `keys`/`values`/`entries` return `Array`, not the doc's `List`, because
    /// there is no builtin `List` to return — see the Stage 2 note.
    fn registerMapBuiltins(self: *Inferer) Error!void {
        try self.type_names.put("Map", 2);

        const Sig = struct { name: []const u8, kind: enum { new, get, set, delete, contains, length, is_empty, keys, values, entries } };
        for ([_]Sig{
            .{ .name = "Map.new", .kind = .new },
            .{ .name = "Map.get", .kind = .get },
            .{ .name = "Map.set", .kind = .set },
            .{ .name = "Map.delete", .kind = .delete },
            .{ .name = "Map.containsKey", .kind = .contains },
            .{ .name = "Map.length", .kind = .length },
            .{ .name = "Map.isEmpty", .kind = .is_empty },
            .{ .name = "Map.keys", .kind = .keys },
            .{ .name = "Map.values", .kind = .values },
            .{ .name = "Map.entries", .kind = .entries },
        }) |sig| {
            const k = try self.newVarType("k");
            const v = try self.newVarType("v");
            const map_args = try self.allocator.alloc(*Type, 2);
            map_args[0] = k;
            map_args[1] = v;
            const map = try self.newType(.{ .con = .{ .name = "Map", .args = map_args } });

            const ty = switch (sig.kind) {
                .new => try self.arrowOf(&.{try self.newType(.unit)}, map),
                .get => blk: {
                    const m_args = try self.allocator.alloc(*Type, 1);
                    m_args[0] = v;
                    break :blk try self.arrowOf(&.{ map, k }, try self.newType(.{ .con = .{ .name = "Maybe", .args = m_args } }));
                },
                .set => try self.arrowOf(&.{ map, k, v }, map),
                .delete => try self.arrowOf(&.{ map, k }, try self.newType(.unit)),
                .contains => try self.arrowOf(&.{ map, k }, try self.newType(.bool)),
                .length => try self.arrowOf(&.{map}, try self.newType(.int)),
                .is_empty => try self.arrowOf(&.{map}, try self.newType(.bool)),
                .keys => blk: {
                    const a_args = try self.allocator.alloc(*Type, 1);
                    a_args[0] = k;
                    break :blk try self.arrowOf(&.{map}, try self.newType(.{ .con = .{ .name = "Array", .args = a_args } }));
                },
                .values => blk: {
                    const a_args = try self.allocator.alloc(*Type, 1);
                    a_args[0] = v;
                    break :blk try self.arrowOf(&.{map}, try self.newType(.{ .con = .{ .name = "Array", .args = a_args } }));
                },
                .entries => blk: {
                    const pair_elems = try self.allocator.alloc(*Type, 2);
                    pair_elems[0] = k;
                    pair_elems[1] = v;
                    const a_args = try self.allocator.alloc(*Type, 1);
                    a_args[0] = try self.newType(.{ .tuple = pair_elems });
                    break :blk try self.arrowOf(&.{map}, try self.newType(.{ .con = .{ .name = "Array", .args = a_args } }));
                },
            };
            const q = try self.allocator.alloc(usize, 2);
            q[0] = k.variable.id;
            q[1] = v.variable.id;
            try self.global.set(sig.name, .{ .quantified = q, .body = ty });
        }

        // Map.fromArray : Array (k, v) -> Map k v
        {
            const k = try self.newVarType("k");
            const v = try self.newVarType("v");
            const pair_elems = try self.allocator.alloc(*Type, 2);
            pair_elems[0] = k;
            pair_elems[1] = v;
            const arr_args = try self.allocator.alloc(*Type, 1);
            arr_args[0] = try self.newType(.{ .tuple = pair_elems });
            const arr = try self.newType(.{ .con = .{ .name = "Array", .args = arr_args } });
            const map_args = try self.allocator.alloc(*Type, 2);
            map_args[0] = k;
            map_args[1] = v;
            const map = try self.newType(.{ .con = .{ .name = "Map", .args = map_args } });
            const q = try self.allocator.alloc(usize, 2);
            q[0] = k.variable.id;
            q[1] = v.variable.id;
            try self.global.set("Map.fromArray", .{ .quantified = q, .body = try self.arrowOf(&.{arr}, map) });
        }

        // Map.foldl : (b -> k -> v -> b) -> b -> Map k v -> b
        {
            const k = try self.newVarType("k");
            const v = try self.newVarType("v");
            const b = try self.newVarType("b");
            const map_args = try self.allocator.alloc(*Type, 2);
            map_args[0] = k;
            map_args[1] = v;
            const map = try self.newType(.{ .con = .{ .name = "Map", .args = map_args } });
            const step = try self.arrowOf(&.{ b, k, v }, b);
            const q = try self.allocator.alloc(usize, 3);
            q[0] = k.variable.id;
            q[1] = v.variable.id;
            q[2] = b.variable.id;
            try self.global.set("Map.foldl", .{ .quantified = q, .body = try self.arrowOf(&.{ step, b, map }, b) });
        }

        // Set operations: Map k v -> Map k v -> Map k v
        for ([_][]const u8{ "Map.union", "Map.intersection", "Map.difference" }) |name| {
            const k = try self.newVarType("k");
            const v = try self.newVarType("v");
            const map_args = try self.allocator.alloc(*Type, 2);
            map_args[0] = k;
            map_args[1] = v;
            const map = try self.newType(.{ .con = .{ .name = "Map", .args = map_args } });
            const q = try self.allocator.alloc(usize, 2);
            q[0] = k.variable.id;
            q[1] = v.variable.id;
            try self.global.set(name, .{ .quantified = q, .body = try self.arrowOf(&.{ map, map }, map) });
        }
    }

    /// `Maybe` and `Result` are declared here rather than in a `.ko` prelude
    /// because there is no prelude loader; every other built-in type is also
    /// hand-registered. Constructor tags must match `lir_lower.zig`'s
    /// `registerBuiltinCtors` and `codegen.zig`'s `constructor_tags`.
    fn registerPrelude(self: *Inferer) Error!void {
        const a = parser.TypeExpr{ .ident = "a" };
        const e = parser.TypeExpr{ .ident = "e" };

        try self.registerTypeDef(.{
            .name = "Maybe",
            .type_params = &.{"a"},
            .body = .{ .sum = &.{
                .{ .name = "Just", .params = &.{a} },
                .{ .name = "Nothing", .params = &.{} },
            } },
            .is_pub = true,
        });

        // Result's type_id is pinned at 1 above, so registerTypeDef will not
        // renumber it; this call only adds the Ok/Err constructors.
        try self.registerTypeDef(.{
            .name = "Result",
            .type_params = &.{ "e", "a" },
            .body = .{ .sum = &.{
                .{ .name = "Ok", .params = &.{a} },
                .{ .name = "Err", .params = &.{e} },
            } },
            .is_pub = true,
        });

        // The Error type used by the IO builtins. Constructor tags are pinned
        // positionally (0..4) and must match lir_lower.zig's registerBuiltins.
        const str = parser.TypeExpr{ .ident = "String" };
        try self.registerTypeDef(.{
            .name = "Error",
            .type_params = &.{},
            .body = .{ .sum = &.{
                .{ .name = "FileNotFound", .params = &.{} },
                .{ .name = "PermissionDenied", .params = &.{} },
                .{ .name = "InvalidPath", .params = &.{} },
                .{ .name = "IOError", .params = &.{str} },
                .{ .name = "EncodingError", .params = &.{str} },
            } },
            .is_pub = true,
        });
    }

    /// Build `Result Error T` for a success value type `inner`.
    fn resultError(self: *Inferer, inner: *Type) Error!*Type {
        const args = try self.allocator.alloc(*Type, 2);
        const err_args = try self.allocator.alloc(*Type, 0);
        args[0] = try self.newType(.{ .con = .{ .name = "Error", .args = err_args } });
        args[1] = inner;
        return self.newType(.{ .con = .{ .name = "Result", .args = args } });
    }

    /// Build `Maybe T`.
    fn maybeOf(self: *Inferer, inner: *Type) Error!*Type {
        const args = try self.allocator.alloc(*Type, 1);
        args[0] = inner;
        return self.newType(.{ .con = .{ .name = "Maybe", .args = args } });
    }

    /// Signatures for the IO builtins (Stage 5). The backing functions are
    /// native Zig host functions in stdlib.zig; these entries only give the
    /// typechecker their types.
    fn registerIoBuiltins(self: *Inferer) Error!void {
        const str = try self.newType(.string);
        const unit = try self.newType(.unit);
        const bool_ty = try self.newType(.bool);

        const arr_args = try self.allocator.alloc(*Type, 1);
        arr_args[0] = str;
        const arr_str = try self.newType(.{ .con = .{ .name = "Array", .args = arr_args } });

        const res_str = try self.resultError(str);
        const res_unit = try self.resultError(unit);
        const res_int = try self.resultError(try self.newType(.int));
        const res_arr_str = try self.resultError(arr_str);
        const maybe_str = try self.maybeOf(str);

        const Sig = struct { name: []const u8, params: []const *Type, ret: *Type };
        for ([_]Sig{
            .{ .name = "IO.readFile", .params = &.{str}, .ret = res_str },
            .{ .name = "IO.writeFile", .params = &.{ str, str }, .ret = res_unit },
            .{ .name = "IO.appendFile", .params = &.{ str, str }, .ret = res_unit },
            .{ .name = "IO.fileExists", .params = &.{str}, .ret = bool_ty },
            .{ .name = "IO.fileSize", .params = &.{str}, .ret = res_int },
            .{ .name = "IO.mkdir", .params = &.{str}, .ret = res_unit },
            .{ .name = "IO.rm", .params = &.{str}, .ret = res_unit },
            .{ .name = "IO.cp", .params = &.{ str, str }, .ret = res_unit },
            .{ .name = "IO.mv", .params = &.{ str, str }, .ret = res_unit },
            .{ .name = "IO.readdir", .params = &.{str}, .ret = res_arr_str },
            .{ .name = "IO.readLine", .params = &.{str}, .ret = str },
            .{ .name = "IO.eprintln", .params = &.{str}, .ret = unit },
            .{ .name = "IO.eprint", .params = &.{str}, .ret = unit },
            .{ .name = "IO.getEnv", .params = &.{str}, .ret = maybe_str },
        }) |sig| {
            try self.global.set(sig.name, .{ .quantified = &.{}, .body = try self.arrowOf(sig.params, sig.ret) });
        }
    }

    pub fn deinit(self: *Inferer) void {
        self.global.deinit();
        self.ctors.deinit();
        self.types.deinit();
        self.type_names.deinit();
        self.type_ids.deinit();
        self.doc_comments.deinit();
        self.expr_type_tags.deinit();
        self.expr_elem_tags.deinit();
        self.expr_types.deinit();
        self.concrete_elem_tags.deinit();
        self.interp_sites.deinit();
        self.field_access_vars.deinit();
        for (self.imported_inferers.items) |imp| imp.deinit();
        self.imported_inferers.deinit(self.allocator);
        self.used_names.deinit();
        self.bound_names.deinit();
        self.param_arity.deinit();
        self.var_type_tags.deinit();
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

    fn markNameUsed(self: *Inferer, name: []const u8) void {
        self.used_names.put(name, {}) catch {};
    }

    fn bindName(self: *Inferer, name: []const u8, loc: parser.Loc) void {
        self.bound_names.put(name, loc) catch {};
    }

    fn checkUnusedBindings(self: *Inferer) void {
        if (self.diagnostics == null) return;
        if (!self.enabled_warnings.contains(.unused_variable)) return;

        var iter = self.bound_names.iterator();
        while (iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const loc = entry.value_ptr.*;
            if (!self.used_names.contains(name)) {
                // Skip underscore-prefixed names (intentionally unused)
                if (name.len > 0 and name[0] == '_') continue;
                self.diagnostics.?.addWarning(
                    std.fmt.allocPrint(self.allocator, "unused variable '{s}'", .{name}) catch "unused variable",
                    loc,
                ) catch {};
            }
        }
    }

    fn resetUsageTracking(self: *Inferer) void {
        self.used_names.clearRetainingCapacity();
        self.bound_names.clearRetainingCapacity();
    }

    pub fn newType(self: *Inferer, ty: Type) Error!*Type {
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
                    // Follow the chain ALL the way to a non-variable type.
                    // After unify(?arg0, ?b) and unify(?b, String), resolve(?arg0)
                    // must return String, not ?b.
                    const resolved = self.resolve(inst);
                    v.instance = resolved;
                    break :blk resolved;
                }
                break :blk ty;
            },
            else => ty,
        };
    }

    pub fn typeToTag(self: *Inferer, ty: *Type) i64 {
        const resolved = self.resolve(ty);
        return switch (resolved.*) {
            .int => 0,
            .float => 1,
            .bool => 2,
            .char => 3,
            .string => 4,
            .unit => 5,
            .con => 6,
            .record => 7,
            .arrow => 8,
            .tuple => 9,
            .variable, .@"ref" => 100,
        };
    }

    fn recordExprType(self: *Inferer, expr: *const parser.Expr, ty: *Type) void {
        self.expr_type_tags.put(expr, self.typeToTag(ty)) catch {};
        const resolved = self.resolve(ty);
        if (resolved.* == .con and resolved.con.args.len > 0) {
            const inner = self.resolve(resolved.con.args[0]);
            const elem_tag = self.typeToTag(inner);
            self.expr_elem_tags.put(expr, elem_tag) catch {};
        }
        self.expr_types.put(expr, ty) catch {};
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
                if (self.occurs(v, b)) {
                    const a_str = typeToString(self.allocator, a.*) catch null;
                    const b_str = typeToString(self.allocator, b.*) catch null;
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "infinite type: {s} would contain {s}", .{
                            a_str orelse "?",
                            b_str orelse "?",
                        }) catch null,
                        .loc = self.current_loc,
                        .note = "occurs check failed: this type variable appears inside the type it would be unified with",
                    };
                    return error.OccursCheck;
                }
                v.instance = b;
                return;
            },
            else => {},
        }

        switch (b.*) {
            .variable => |v| {
                if (self.occurs(v, a)) {
                    const a_str = typeToString(self.allocator, a.*) catch null;
                    const b_str = typeToString(self.allocator, b.*) catch null;
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "infinite type: {s} would contain {s}", .{
                            b_str orelse "?",
                            a_str orelse "?",
                        }) catch null,
                        .loc = self.current_loc,
                        .note = "occurs check failed: this type variable appears inside the type it would be unified with",
                    };
                    return error.OccursCheck;
                }
                v.instance = a;
                return;
            },
            else => {},
        }

        const mismatch = struct {
            fn f(self_inner: *Inferer, l: *Type, r: *Type) Error!void {
                const exp_str = typeToString(self_inner.allocator, l.*) catch null;
                const act_str = typeToString(self_inner.allocator, r.*) catch null;
                var note_msg: ?[]const u8 = null;
                if (exp_str != null and act_str != null) {
                    note_msg = std.fmt.allocPrint(self_inner.allocator, "these types are not compatible", .{}) catch null;
                }
                self_inner.last_error = .{
                    .message = std.fmt.allocPrint(self_inner.allocator, "type mismatch: expected {s}, got {s}", .{
                        exp_str orelse "?",
                        act_str orelse "?",
                    }) catch null,
                    .expected = exp_str,
                    .actual = act_str,
                    .loc = self_inner.current_loc,
                    .note = note_msg,
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

        // Re-resolve the pinned field-access objects: unify may have linked them
        // to other variables since, and collectFree reports the representative.
        var pinned = std.AutoHashMap(usize, void).init(self.allocator);
        defer pinned.deinit();
        var pin_it = self.field_access_vars.keyIterator();
        while (pin_it.next()) |key| {
            const r = self.resolve(key.*);
            if (r.* == .variable) try pinned.put(r.variable.id, {});
        }

        var quantified = std.ArrayList(usize).empty;
        defer quantified.deinit(self.allocator);
        var it = free_ty.iterator();
        while (it.next()) |entry| {
            // A variable we took a field of stays monomorphic. Ko has no row
            // polymorphism, so the record's layout can only come from the call
            // site; quantifying here would hand the body a fresh variable and
            // leave codegen with no layout to emit a GEP against.
            if (pinned.contains(entry.key_ptr.*)) continue;
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
            .variable => |v| blk: {
                if (map.get(v.id)) |rep| break :blk rep;
                // A variable that is not quantified is free in the scheme, and
                // free variables are shared between instantiations rather than
                // renamed — that sharing is how a call site's argument type
                // reaches the function body. Freshening here would silently
                // undo the monomorphic pinning generalize() does for field
                // accesses, leaving the body's object type unbound at codegen.
                break :blk resolved;
            },
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
                if (self.types.get(name)) |info| {
                    if (info.record_type) |rec| return rec;
                    return try self.newType(.{ .con = .{ .name = name, .args = &.{} } });
                }
                return try self.newVarType(try self.freshName(name));
            },
            .constructor => |name| {
                // A record type name annotates as the declared record itself, so it
                // unifies with record literals of that type.
                if (self.types.get(name)) |info| {
                    if (info.record_type) |rec| return rec;
                }
                if (std.mem.eql(u8, name, "Int")) return try self.newType(.int);
                if (std.mem.eql(u8, name, "Float")) return try self.newType(.float);
                if (std.mem.eql(u8, name, "Bool")) return try self.newType(.bool);
                if (std.mem.eql(u8, name, "String")) return try self.newType(.string);
                if (std.mem.eql(u8, name, "Char")) return try self.newType(.char);
                if (std.mem.eql(u8, name, "Unit")) return try self.newType(.unit);
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
            // `Maybe Float`, `Result Error Int` — a type constructor applied to
            // arguments, which is con(name, args). Treating it as a *value*
            // application and unifying the head with an arrow (as this used to)
            // fails, because typeExprToType already returns con("Maybe", [?a])
            // for the head, and a con never unifies with an arrow.
            .application => |app| {
                var spine: std.ArrayList(*const parser.TypeExpr) = .empty;
                defer spine.deinit(self.allocator);
                try spine.append(self.allocator, app.arg);
                var head: *const parser.TypeExpr = app.func;
                while (head.* == .application) {
                    try spine.append(self.allocator, head.application.arg);
                    head = head.application.func;
                }
                const name = switch (head.*) {
                    .constructor, .ident => |n| n,
                    else => return try self.newVarType(try self.freshName("t")),
                };
                const args = try self.allocator.alloc(*Type, spine.items.len);
                for (args, 0..) |*slot, i| {
                    slot.* = try self.typeExprToType(spine.items[spine.items.len - 1 - i].*);
                }
                return try self.newType(.{ .con = .{ .name = name, .args = args } });
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
        // Process imports: load, typecheck, and register imported definitions
        if (self.module_loader) |loader| {
            for (program.imports) |imp| {
                const mod = loader.loadModule(imp.path) catch |err| {
                    std.log.err("Failed to load module: {}", .{err});
                    continue;
                } orelse {
                    std.log.err("Module not found: {s}", .{std.mem.join(self.allocator, "/", imp.path) catch "unknown"});
                    continue;
                };
                const module_name = imp.alias orelse imp.path[imp.path.len - 1];

                // Create a fresh inferer for the imported module
                var imp_inferer = try self.allocator.create(Inferer);
                imp_inferer.* = Inferer.init(self.allocator);
                imp_inferer.module_loader = loader;
                try self.imported_inferers.append(self.allocator, imp_inferer);

                // Typecheck the imported module
                imp_inferer.inferProgram(&mod.program) catch |err| {
                    std.log.err("Failed to typecheck imported module '{s}': {}", .{ module_name, err });
                    continue;
                };

                // Register imported type definitions with qualified names
                for (mod.program.definitions) |def| {
                    if (def == .type_def) {
                        const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, def.type_def.name });
                        var td = def.type_def;
                        td.name = prefixed;
                        try self.registerTypeDef(td);
                        // Also register unqualified type name so that lookups
                        // in typeExprToType, ctorParamType, and inferPatternBindings
                        // find the type by its short name (e.g., "List" not "List.List").
                        if (!self.type_names.contains(def.type_def.name)) {
                            try self.type_names.put(def.type_def.name, def.type_def.type_params.len);
                        }
                        if (!self.type_ids.contains(def.type_def.name)) {
                            try self.type_ids.put(def.type_def.name, self.type_ids.get(prefixed) orelse self.next_type_id - 1);
                        }
                        // For record types, also register in the types map with unqualified name
                        switch (def.type_def.body) {
                            .record => {
                                if (self.types.get(prefixed)) |info| {
                                    try self.types.put(def.type_def.name, info);
                                }
                            },
                            else => {},
                        }
                        // Also register constructor types with both qualified and unqualified names
                        // using the imported inferer's scheme (which has unqualified type names)
                        switch (def.type_def.body) {
                            .sum => |ctors| {
                                for (ctors) |ctor| {
                                    if (imp_inferer.global.getScheme(ctor.name)) |scheme| {
                                        // Qualified constructor name (e.g., List.Cons)
                                        const qualified_ctor = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, ctor.name });
                                        try self.global.set(qualified_ctor, scheme);
                                        // Unqualified constructor name (e.g., Cons)
                                        try self.global.set(ctor.name, scheme);
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }

                // Register imported function signatures with qualified names
                for (mod.program.definitions) |def| {
                    if (def == .fn_def) {
                        const fn_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, def.fn_def.name });
                        // Look up the function's type from the imported inferer
                        if (imp_inferer.global.getScheme(def.fn_def.name)) |scheme| {
                            try self.global.set(fn_name, scheme);
                            // For full imports: also register unqualified name
                            // For selective imports: only register selected names
                            const should_register_unqualified = if (imp.selective) |sel| blk: {
                                for (sel) |s| {
                                    if (std.mem.eql(u8, s, def.fn_def.name)) break :blk true;
                                }
                                break :blk false;
                            } else true;
                            if (should_register_unqualified) {
                                try self.global.set(def.fn_def.name, scheme);
                            }
                        }
                    }
                }

                // Register imported constructors with qualified and unqualified names
                for (mod.program.definitions) |def| {
                    if (def == .type_def) {
                        switch (def.type_def.body) {
                            .sum => |ctors| {
                                for (ctors, 0..) |ctor, tag_idx| {
                                    // Qualified: List.Cons
                                    const prefixed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, ctor.name });
                                    try self.ctors.put(prefixed, .{
                                        .type_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ module_name, def.type_def.name }),
                                        .arity = ctor.params.len,
                                        .tag = @intCast(tag_idx),
                                    });
                                    // Unqualified: Cons (with unqualified type name)
                                    try self.ctors.put(ctor.name, .{
                                        .type_name = try std.fmt.allocPrint(self.allocator, "{s}", .{def.type_def.name}),
                                        .arity = ctor.params.len,
                                        .tag = @intCast(tag_idx),
                                    });
                                }
                            },
                            else => {},
                        }
                    }
                }
            }
        }

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

        // Predeclare built-in functions. println/print print and return Unit;
        // inspect prints and returns the value.
        const println_from = try self.newVarType("a");
        const println_ty = try self.allocator.create(Type);
        println_ty.* = .{ .arrow = .{ .from = println_from, .to = try self.newType(.unit) } };
        const println_var_id = println_from.variable.id;
        const println_quantified = try self.allocator.alloc(usize, 1);
        println_quantified[0] = println_var_id;
        try self.global.set("println", .{ .quantified = println_quantified, .body = println_ty });

        const print_from = try self.newVarType("b");
        const print_ty = try self.allocator.create(Type);
        print_ty.* = .{ .arrow = .{ .from = print_from, .to = try self.newType(.unit) } };
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

        // panic : forall a. String -> a (never returns)
        const panic_param = try self.newType(.string);
        const panic_result = try self.newVarType("a");
        const panic_ty = try self.allocator.create(Type);
        panic_ty.* = .{ .arrow = .{ .from = panic_param, .to = panic_result } };
        const panic_var_id = panic_result.variable.id;
        const panic_quantified = try self.allocator.alloc(usize, 1);
        panic_quantified[0] = panic_var_id;
        try self.global.set("panic", .{ .quantified = panic_quantified, .body = panic_ty });

        // assert : Bool -> () (panics if False)
        {
            const bool_ty = try self.newType(.bool);
            const unit_ty = try self.newType(.unit);
            const assert_ty = try self.allocator.create(Type);
            assert_ty.* = .{ .arrow = .{ .from = bool_ty, .to = unit_ty } };
            try self.global.set("assert", .{ .quantified = &.{}, .body = assert_ty });
        }
        // assert_eq : forall a. a -> a -> () (panics if not equal)
        {
            const ra = try self.newVarType("a");
            const ra_to_ra_to_unit = try self.allocator.create(Type);
            const ra_to_unit = try self.allocator.create(Type);
            ra_to_unit.* = .{ .arrow = .{ .from = ra, .to = try self.newType(.unit) } };
            ra_to_ra_to_unit.* = .{ .arrow = .{ .from = ra, .to = ra_to_unit } };
            const qa = ra.variable.id;
            const q = try self.allocator.alloc(usize, 1);
            q[0] = qa;
            try self.global.set("assert_eq", .{ .quantified = q, .body = ra_to_ra_to_unit });
        }

        // String module builtins
        const string_ty = try self.newType(.string);
        const string_to_int = try self.allocator.create(Type);
        string_to_int.* = .{ .arrow = .{ .from = string_ty, .to = try self.newType(.int) } };
        try self.global.set("String.length", .{ .quantified = &.{}, .body = string_to_int });

        try self.registerArrayBuiltins();
        try self.registerMapBuiltins();

        // String.from : a -> String — what `${e}` desugars to. It accepts any
        // type here so inference never fails on it; validateInterpolations()
        // rejects the types that have no text form once they are resolved, and
        // lowering picks the concrete conversion from the static type.
        {
            const a = try self.newVarType("a");
            const from_ty = try self.allocator.create(Type);
            from_ty.* = .{ .arrow = .{ .from = a, .to = try self.newType(.string) } };
            const q = try self.allocator.alloc(usize, 1);
            q[0] = a.variable.id;
            try self.global.set("String.from", .{ .quantified = q, .body = from_ty });
        }

        // String.fromInt / fromFloat, and the Char builtins.
        {
            const int_to_str = try self.allocator.create(Type);
            int_to_str.* = .{ .arrow = .{ .from = try self.newType(.int), .to = try self.newType(.string) } };
            try self.global.set("String.fromInt", .{ .quantified = &.{}, .body = int_to_str });

            const float_to_str = try self.allocator.create(Type);
            float_to_str.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.string) } };
            try self.global.set("String.fromFloat", .{ .quantified = &.{}, .body = float_to_str });

            // String.toInt : String -> Maybe Int, String.toFloat : String -> Maybe Float
            for ([_]struct { name: []const u8, elem: Type }{
                .{ .name = "String.toInt", .elem = .{ .int = {} } },
                .{ .name = "String.toFloat", .elem = .{ .float = {} } },
            }) |spec| {
                const args = try self.allocator.alloc(*Type, 1);
                args[0] = try self.newType(spec.elem);
                const maybe = try self.newType(.{ .con = .{ .name = "Maybe", .args = args } });
                const ft = try self.allocator.create(Type);
                ft.* = .{ .arrow = .{ .from = try self.newType(.string), .to = maybe } };
                try self.global.set(spec.name, .{ .quantified = &.{}, .body = ft });
            }

            const char_to_int = try self.allocator.create(Type);
            char_to_int.* = .{ .arrow = .{ .from = try self.newType(.char), .to = try self.newType(.int) } };
            try self.global.set("ord", .{ .quantified = &.{}, .body = char_to_int });
            try self.global.set("Char.toInt", .{ .quantified = &.{}, .body = char_to_int });

            const int_to_char = try self.allocator.create(Type);
            int_to_char.* = .{ .arrow = .{ .from = try self.newType(.int), .to = try self.newType(.char) } };
            try self.global.set("chr", .{ .quantified = &.{}, .body = int_to_char });
            try self.global.set("Char.fromInt", .{ .quantified = &.{}, .body = int_to_char });

            for ([_][]const u8{ "Char.isAlpha", "Char.isDigit", "Char.isAlnum", "Char.isSpace", "Char.isUpper", "Char.isLower" }) |name| {
                const pred = try self.allocator.create(Type);
                pred.* = .{ .arrow = .{ .from = try self.newType(.char), .to = try self.newType(.bool) } };
                try self.global.set(name, .{ .quantified = &.{}, .body = pred });
            }
            for ([_][]const u8{ "Char.toUpper", "Char.toLower" }) |name| {
                const conv = try self.allocator.create(Type);
                conv.* = .{ .arrow = .{ .from = try self.newType(.char), .to = try self.newType(.char) } };
                try self.global.set(name, .{ .quantified = &.{}, .body = conv });
            }
        }

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

        // String.split : String -> String -> List String
        const string_split_to = try self.allocator.create(Type);
        {
            const sa = try self.newType(.string);
            const sb = try self.newType(.string);
            const list_sb = try self.allocator.create(Type);
            list_sb.* = .{ .con = .{ .name = "List", .args = try self.allocator.dupe(*Type, &.{sb}) } };
            const inner = try self.allocator.create(Type);
            inner.* = .{ .arrow = .{ .from = sb, .to = list_sb } };
            string_split_to.* = .{ .arrow = .{ .from = sa, .to = inner } };
        }
        try self.global.set("String.split", .{ .quantified = &.{}, .body = string_split_to });

        // String.startsWith : String -> String -> Bool
        // String.endsWith : String -> String -> Bool
        {
            const sa = try self.newType(.string);
            const sb = try self.newType(.string);
            const ret = try self.newType(.bool);
            const inner_arrow_sa = try self.allocator.create(Type);
            inner_arrow_sa.* = .{ .arrow = .{ .from = sb, .to = ret } };
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = sa, .to = inner_arrow_sa } };
            try self.global.set("String.startsWith", .{ .quantified = &.{}, .body = ft });
        }
        {
            const sa = try self.newType(.string);
            const sb = try self.newType(.string);
            const ret = try self.newType(.bool);
            const inner_arrow_sb = try self.allocator.create(Type);
            inner_arrow_sb.* = .{ .arrow = .{ .from = sb, .to = ret } };
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = sa, .to = inner_arrow_sb } };
            try self.global.set("String.endsWith", .{ .quantified = &.{}, .body = ft });
        }

        // String.substring : String -> Int -> Int -> String
        {
            const sa = try self.newType(.string);
            const si = try self.newType(.int);
            const sj = try self.newType(.int);
            const ret = try self.newType(.string);
            const inner2 = try self.allocator.create(Type);
            inner2.* = .{ .arrow = .{ .from = sj, .to = ret } };
            const inner1 = try self.allocator.create(Type);
            inner1.* = .{ .arrow = .{ .from = si, .to = inner2 } };
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = sa, .to = inner1 } };
            try self.global.set("String.substring", .{ .quantified = &.{}, .body = ft });
        }

        // String.indexOf : String -> String -> Int
        {
            const sa = try self.newType(.string);
            const sb = try self.newType(.string);
            const ret = try self.newType(.int);
            const inner_arrow_si = try self.allocator.create(Type);
            inner_arrow_si.* = .{ .arrow = .{ .from = sb, .to = ret } };
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = sa, .to = inner_arrow_si } };
            try self.global.set("String.indexOf", .{ .quantified = &.{}, .body = ft });
        }

        // Int module builtins
        const int_ty = try self.newType(.int);
        const int_to_int = try self.allocator.create(Type);
        int_to_int.* = .{ .arrow = .{ .from = int_ty, .to = int_ty } };
        try self.global.set("Int.factorial", .{ .quantified = &.{}, .body = int_to_int });
        try self.global.set("Int.isqrt", .{ .quantified = &.{}, .body = int_to_int });
        try self.global.set("Int.abs", .{ .quantified = &.{}, .body = int_to_int });

        const int_int_to_int = try self.allocator.create(Type);
        const int_param_a = try self.newType(.int);
        const int_param_b = try self.newType(.int);
        const int_result = try self.newType(.int);
        const int_inner = try self.allocator.create(Type);
        int_inner.* = .{ .arrow = .{ .from = int_param_b, .to = int_result } };
        int_int_to_int.* = .{ .arrow = .{ .from = int_param_a, .to = int_inner } };
        try self.global.set("Int.pow", .{ .quantified = &.{}, .body = int_int_to_int });
        try self.global.set("Int.gcd", .{ .quantified = &.{}, .body = int_int_to_int });
        try self.global.set("Int.lcm", .{ .quantified = &.{}, .body = int_int_to_int });
        try self.global.set("Int.min", .{ .quantified = &.{}, .body = int_int_to_int });
        try self.global.set("Int.max", .{ .quantified = &.{}, .body = int_int_to_int });

        const int_to_string = try self.allocator.create(Type);
        int_to_string.* = .{ .arrow = .{ .from = int_ty, .to = try self.newType(.string) } };
        try self.global.set("Int.toString", .{ .quantified = &.{}, .body = int_to_string });

        // Float module builtins — each gets its own type node to avoid shared mutation
        const float_ty = try self.newType(.float);

        // Float -> Float functions (each needs its own node)
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.sqrt", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.sin", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.cos", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.tan", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.log", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.log2", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.log10", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.exp", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.floor", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.ceil", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.float) } };
            try self.global.set("Float.abs", .{ .quantified = &.{}, .body = ft });
        }

        // Int -> Float
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.int), .to = try self.newType(.float) } };
            try self.global.set("Float.ofInt", .{ .quantified = &.{}, .body = ft });
        }

        // Float -> Int (toInt and sign each get their own node)
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.int) } };
            try self.global.set("Float.toInt", .{ .quantified = &.{}, .body = ft });
        }

        // Float -> Float -> Float
        {
            const fa = try self.newType(.float);
            const fb = try self.newType(.float);
            const fr = try self.newType(.float);
            const inner = try self.allocator.create(Type);
            inner.* = .{ .arrow = .{ .from = fb, .to = fr } };
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = fa, .to = inner } };
            try self.global.set("Float.pow", .{ .quantified = &.{}, .body = ft });
        }

        // Float constants (value type — resolved by codegen as global constants)
        try self.global.set("Float.pi", .{ .quantified = &.{}, .body = float_ty });
        try self.global.set("Float.e", .{ .quantified = &.{}, .body = float_ty });
        try self.global.set("Float.infinity", .{ .quantified = &.{}, .body = float_ty });
        try self.global.set("Float.nan", .{ .quantified = &.{}, .body = float_ty });
        try self.global.set("Float.maxValue", .{ .quantified = &.{}, .body = float_ty });
        try self.global.set("Float.minValue", .{ .quantified = &.{}, .body = float_ty });
        try self.global.set("Float.epsilon", .{ .quantified = &.{}, .body = float_ty });

        // Float predicates: Float -> Bool (each gets its own node)
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.bool) } };
            try self.global.set("Float.isNaN", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.bool) } };
            try self.global.set("Float.isInfinite", .{ .quantified = &.{}, .body = ft });
        }
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.bool) } };
            try self.global.set("Float.isFinite", .{ .quantified = &.{}, .body = ft });
        }

        // Float.sign: Float -> Int (own node, not shared with Float.toInt)
        {
            const ft = try self.allocator.create(Type);
            ft.* = .{ .arrow = .{ .from = try self.newType(.float), .to = try self.newType(.int) } };
            try self.global.set("Float.sign", .{ .quantified = &.{}, .body = ft });
        }

        // Int.fromString : String -> Result Overflow Int
        // (Uses a simple Result type for now)
        {
            const str_ty = try self.newType(.string);
            const ra = try self.newVarType("a");
            const rb = try self.newVarType("b");
            const result_a_b = try self.allocator.create(Type);
            const args_a_b = try self.allocator.alloc(*Type, 2);
            args_a_b[0] = ra;
            args_a_b[1] = rb;
            result_a_b.* = .{ .con = .{ .name = "Result", .args = args_a_b } };
            const str_to_result = try self.allocator.create(Type);
            str_to_result.* = .{ .arrow = .{ .from = str_ty, .to = result_a_b } };
            const qa = ra.variable.id;
            const qb = rb.variable.id;
            const q = try self.allocator.alloc(usize, 2);
            q[0] = qa;
            q[1] = qb;
            try self.global.set("Int.fromString", .{ .quantified = q, .body = str_to_result });
        }

        // Checked arithmetic: Int -> Int -> Result Int Overflow
        {
            const overflow_ty = try self.allocator.create(Type);
            overflow_ty.* = .{ .con = .{ .name = "Overflow", .args = &.{} } };
            const int_ty2 = try self.newType(.int);
            const result_int_overflow = try self.allocator.create(Type);
            const result_args = try self.allocator.alloc(*Type, 2);
            result_args[0] = int_ty2;
            result_args[1] = overflow_ty;
            result_int_overflow.* = .{ .con = .{ .name = "Result", .args = result_args } };
            const int_to_result = try self.allocator.create(Type);
            int_to_result.* = .{ .arrow = .{ .from = try self.newType(.int), .to = result_int_overflow } };
            const int_int_to_result = try self.allocator.create(Type);
            int_int_to_result.* = .{ .arrow = .{ .from = try self.newType(.int), .to = int_to_result } };
            try self.global.set("Int.addChecked", .{ .quantified = &.{}, .body = int_int_to_result });
            try self.global.set("Int.subChecked", .{ .quantified = &.{}, .body = int_int_to_result });
            try self.global.set("Int.mulChecked", .{ .quantified = &.{}, .body = int_int_to_result });
        }

        // Checked division: Int -> Int -> Result Int DivisionByZero
        {
            const divbyzero_ty = try self.allocator.create(Type);
            divbyzero_ty.* = .{ .con = .{ .name = "DivisionByZero", .args = &.{} } };
            const int_ty2 = try self.newType(.int);
            const result_int_divbyzero = try self.allocator.create(Type);
            const result_args = try self.allocator.alloc(*Type, 2);
            result_args[0] = int_ty2;
            result_args[1] = divbyzero_ty;
            result_int_divbyzero.* = .{ .con = .{ .name = "Result", .args = result_args } };
            const int_to_result = try self.allocator.create(Type);
            int_to_result.* = .{ .arrow = .{ .from = try self.newType(.int), .to = result_int_divbyzero } };
            const int_int_to_result = try self.allocator.create(Type);
            int_int_to_result.* = .{ .arrow = .{ .from = try self.newType(.int), .to = int_to_result } };
            try self.global.set("Int.divChecked", .{ .quantified = &.{}, .body = int_int_to_result });
            try self.global.set("Int.modChecked", .{ .quantified = &.{}, .body = int_int_to_result });
        }

        // Int.negChecked : Int -> Result Int Overflow
        {
            const overflow_ty = try self.allocator.create(Type);
            overflow_ty.* = .{ .con = .{ .name = "Overflow", .args = &.{} } };
            const int_ty2 = try self.newType(.int);
            const result_int_overflow = try self.allocator.create(Type);
            const result_args = try self.allocator.alloc(*Type, 2);
            result_args[0] = int_ty2;
            result_args[1] = overflow_ty;
            result_int_overflow.* = .{ .con = .{ .name = "Result", .args = result_args } };
            const int_to_result = try self.allocator.create(Type);
            int_to_result.* = .{ .arrow = .{ .from = try self.newType(.int), .to = result_int_overflow } };
            try self.global.set("Int.negChecked", .{ .quantified = &.{}, .body = int_to_result });
        }

        // Int.divOr : Int -> Int -> Int -> Int (safe division with default)
        {
            const int_int_int_to_int = try self.allocator.create(Type);
            const inner2 = try self.allocator.create(Type);
            inner2.* = .{ .arrow = .{ .from = try self.newType(.int), .to = try self.newType(.int) } };
            const inner1 = try self.allocator.create(Type);
            inner1.* = .{ .arrow = .{ .from = try self.newType(.int), .to = inner2 } };
            int_int_int_to_int.* = .{ .arrow = .{ .from = try self.newType(.int), .to = inner1 } };
            try self.global.set("Int.divOr", .{ .quantified = &.{}, .body = int_int_int_to_int });
        }

        // Result operations (built-in)
        // Result.is_ok : forall a b. Result a b -> Int
        {
            const ra = try self.newVarType("a");
            const rb = try self.newVarType("b");
            const result_a_b = try self.allocator.create(Type);
            const args_a_b = try self.allocator.alloc(*Type, 2);
            args_a_b[0] = ra;
            args_a_b[1] = rb;
            result_a_b.* = .{ .con = .{ .name = "Result", .args = args_a_b } };
            const result_to_int = try self.allocator.create(Type);
            result_to_int.* = .{ .arrow = .{ .from = result_a_b, .to = try self.newType(.int) } };
            const qa = ra.variable.id;
            const qb = rb.variable.id;
            const q = try self.allocator.alloc(usize, 2);
            q[0] = qa;
            q[1] = qb;
            try self.global.set("Result.is_ok", .{ .quantified = q, .body = result_to_int });
        }
        // Result.is_err : forall a b. Result a b -> Int
        {
            const ra = try self.newVarType("a");
            const rb = try self.newVarType("b");
            const result_a_b = try self.allocator.create(Type);
            const args_a_b = try self.allocator.alloc(*Type, 2);
            args_a_b[0] = ra;
            args_a_b[1] = rb;
            result_a_b.* = .{ .con = .{ .name = "Result", .args = args_a_b } };
            const result_to_int = try self.allocator.create(Type);
            result_to_int.* = .{ .arrow = .{ .from = result_a_b, .to = try self.newType(.int) } };
            const qa = ra.variable.id;
            const qb = rb.variable.id;
            const q = try self.allocator.alloc(usize, 2);
            q[0] = qa;
            q[1] = qb;
            try self.global.set("Result.is_err", .{ .quantified = q, .body = result_to_int });
        }
        // Result.unwrap : forall a b. Result a b -> a (panicking version)
        {
            const ra = try self.newVarType("a");
            const rb = try self.newVarType("b");
            const result_a_b = try self.allocator.create(Type);
            const args_a_b = try self.allocator.alloc(*Type, 2);
            args_a_b[0] = ra;
            args_a_b[1] = rb;
            result_a_b.* = .{ .con = .{ .name = "Result", .args = args_a_b } };
            const result_to_a = try self.allocator.create(Type);
            result_to_a.* = .{ .arrow = .{ .from = result_a_b, .to = ra } };
            const qa = ra.variable.id;
            const qb = rb.variable.id;
            const q = try self.allocator.alloc(usize, 2);
            q[0] = qa;
            q[1] = qb;
            try self.global.set("Result.unwrap", .{ .quantified = q, .body = result_to_a });
        }
        // Result.unwrapOr : forall a b. a -> Result a b -> a (non-panicking version)
        {
            const ra = try self.newVarType("a");
            const rb = try self.newVarType("b");
            const result_a_b = try self.allocator.create(Type);
            const args_a_b = try self.allocator.alloc(*Type, 2);
            args_a_b[0] = ra;
            args_a_b[1] = rb;
            result_a_b.* = .{ .con = .{ .name = "Result", .args = args_a_b } };
            const result_to_a = try self.allocator.create(Type);
            result_to_a.* = .{ .arrow = .{ .from = result_a_b, .to = ra } };
            const a_to_result_to_a = try self.allocator.create(Type);
            a_to_result_to_a.* = .{ .arrow = .{ .from = ra, .to = result_to_a } };
            const qa = ra.variable.id;
            const qb = rb.variable.id;
            const q = try self.allocator.alloc(usize, 2);
            q[0] = qa;
            q[1] = qb;
            try self.global.set("Result.unwrapOr", .{ .quantified = q, .body = a_to_result_to_a });
        }
        // Result.map : forall a b c. (a -> b) -> Result a c -> Result b c
        {
            const ra = try self.newVarType("a");
            const rb = try self.newVarType("b");
            const rc = try self.newVarType("c");
            const a_to_b = try self.allocator.create(Type);
            a_to_b.* = .{ .arrow = .{ .from = ra, .to = rb } };
            const result_a_c = try self.allocator.create(Type);
            const args_ac = try self.allocator.alloc(*Type, 2);
            args_ac[0] = ra;
            args_ac[1] = rc;
            result_a_c.* = .{ .con = .{ .name = "Result", .args = args_ac } };
            const result_b_c = try self.allocator.create(Type);
            const args_bc = try self.allocator.alloc(*Type, 2);
            args_bc[0] = rb;
            args_bc[1] = rc;
            result_b_c.* = .{ .con = .{ .name = "Result", .args = args_bc } };
            const result_b_c_ret = try self.allocator.create(Type);
            result_b_c_ret.* = .{ .arrow = .{ .from = result_a_c, .to = result_b_c } };
            const fn_to_result = try self.allocator.create(Type);
            fn_to_result.* = .{ .arrow = .{ .from = a_to_b, .to = result_b_c_ret } };
            const q = try self.allocator.alloc(usize, 3);
            q[0] = ra.variable.id;
            q[1] = rb.variable.id;
            q[2] = rc.variable.id;
            try self.global.set("Result.map", .{ .quantified = q, .body = fn_to_result });
        }
        // Result.fold : forall a b c. (a -> c) -> (b -> c) -> Result a b -> c
        {
            const ra = try self.newVarType("a");
            const rb = try self.newVarType("b");
            const rc = try self.newVarType("c");
            const a_to_c = try self.allocator.create(Type);
            a_to_c.* = .{ .arrow = .{ .from = ra, .to = rc } };
            const b_to_c = try self.allocator.create(Type);
            b_to_c.* = .{ .arrow = .{ .from = rb, .to = rc } };
            const result_a_b = try self.allocator.create(Type);
            const args_ab = try self.allocator.alloc(*Type, 2);
            args_ab[0] = ra;
            args_ab[1] = rb;
            result_a_b.* = .{ .con = .{ .name = "Result", .args = args_ab } };
            const result_to_c = try self.allocator.create(Type);
            result_to_c.* = .{ .arrow = .{ .from = result_a_b, .to = rc } };
            const b_to_c_to_result = try self.allocator.create(Type);
            b_to_c_to_result.* = .{ .arrow = .{ .from = b_to_c, .to = result_to_c } };
            const full = try self.allocator.create(Type);
            full.* = .{ .arrow = .{ .from = a_to_c, .to = b_to_c_to_result } };
            const q = try self.allocator.alloc(usize, 3);
            q[0] = ra.variable.id;
            q[1] = rb.variable.id;
            q[2] = rc.variable.id;
            try self.global.set("Result.fold", .{ .quantified = q, .body = full });
        }
        // Result.and_then : forall a b c. (a -> Result b c) -> Result a c -> Result b c
        {
            const ra = try self.newVarType("a");
            const rb = try self.newVarType("b");
            const rc = try self.newVarType("c");
            const result_b_c = try self.allocator.create(Type);
            const args_bc = try self.allocator.alloc(*Type, 2);
            args_bc[0] = rb;
            args_bc[1] = rc;
            result_b_c.* = .{ .con = .{ .name = "Result", .args = args_bc } };
            const a_to_result_b_c = try self.allocator.create(Type);
            a_to_result_b_c.* = .{ .arrow = .{ .from = ra, .to = result_b_c } };
            const result_a_c = try self.allocator.create(Type);
            const args_ac = try self.allocator.alloc(*Type, 2);
            args_ac[0] = ra;
            args_ac[1] = rc;
            result_a_c.* = .{ .con = .{ .name = "Result", .args = args_ac } };
            const result_a_c_to_result_b_c = try self.allocator.create(Type);
            result_a_c_to_result_b_c.* = .{ .arrow = .{ .from = result_a_c, .to = result_b_c } };
            const full = try self.allocator.create(Type);
            full.* = .{ .arrow = .{ .from = a_to_result_b_c, .to = result_a_c_to_result_b_c } };
            const q = try self.allocator.alloc(usize, 3);
            q[0] = ra.variable.id;
            q[1] = rb.variable.id;
            q[2] = rc.variable.id;
            try self.global.set("Result.and_then", .{ .quantified = q, .body = full });
        }

        // Predeclare functions for recursion.
        for (program.definitions) |def| {
            try self.predeclareDefinition(def, "");
        }

        // Infer top-level definitions in order.
        for (program.definitions) |def| {
            if (self.diagnostics) |diags| {
                self.inferDefinition(def, "") catch |err| {
                    // Add the error to diagnostics and continue
                    if (self.last_error) |ec| {
                        try diags.addErrorCtx(
                            ec.message orelse @errorName(err),
                            ec.loc,
                            ec.note,
                            ec.help,
                        );
                    } else {
                        try diags.addError(@errorName(err), null);
                    }
                    // Register a dummy type for the failed definition so
                    // subsequent definitions don't also fail with "undefined name"
                    self.registerDummyForFailedDef(def);
                };
            } else {
                try self.inferDefinition(def, "");
            }
        }

        self.finalizeElemTags();
        self.validateInterpolations();
        self.validateMapKeys();
    }

    /// Reject `Map k v` where `k` has no structural hash and equality.
    ///
    /// `ko_hash` handles the scalars and hashes String by content; everything
    /// else would fall back to the payload bits, which for a tuple or a
    /// constructor is its address. Two structurally equal keys would then land
    /// in different buckets and lookups would quietly miss, so the accepted set
    /// here must match what ko_hash and ko_key_eq actually implement.
    fn validateMapKeys(self: *Inferer) void {
        const diags = self.diagnostics orelse return;
        var reported = std.AutoHashMap(*const parser.Expr, void).init(self.allocator);
        defer reported.deinit();

        var it = self.expr_types.iterator();
        while (it.next()) |entry| {
            const r = self.resolve(entry.value_ptr.*);
            if (r.* != .con or !std.mem.eql(u8, r.con.name, "Map") or r.con.args.len != 2) continue;
            switch (self.resolve(r.con.args[0]).*) {
                .int, .float, .bool, .char, .string, .unit, .variable => continue,
                else => {},
            }
            if (reported.contains(entry.key_ptr.*)) continue;
            reported.put(entry.key_ptr.*, {}) catch {};
            const name = typeToString(self.allocator, self.resolve(r.con.args[0]).*) catch null;
            const msg = std.fmt.allocPrint(
                self.allocator,
                "{s} cannot be a Map key",
                .{name orelse "this type"},
            ) catch "this type cannot be a Map key";
            diags.addErrorCtx(
                msg,
                entry.key_ptr.*.getLoc(),
                "keys are hashed and compared structurally, and only Int, Float, Bool, Char, String and Unit are",
                "key by one of those instead — for a compound key, derive a String",
            ) catch {};
        }
    }

    /// Reject `${e}` where `e` has no text form. This runs after inference
    /// because the argument's type is usually still an unbound variable at the
    /// point the call is seen. Types that pass here are exactly the ones
    /// lowerStringFrom knows how to convert; the two lists must stay in step.
    fn validateInterpolations(self: *Inferer) void {
        const diags = self.diagnostics orelse return;
        var it = self.interp_sites.iterator();
        while (it.next()) |entry| {
            const ty = self.expr_types.get(entry.key_ptr.*) orelse continue;
            const r = self.resolve(ty);
            switch (r.*) {
                .string, .int, .float, .bool, .char => continue,
                // A variable here means the value is polymorphic at this point,
                // typically a generic function's parameter. The conversion is
                // chosen from the static type, so there is nothing to choose;
                // defaulting to Int would print a Float's raw bits.
                .variable => {
                    diags.addErrorCtx(
                        "cannot interpolate a value whose type is not known here",
                        entry.value_ptr.*,
                        "the conversion is picked from the static type, and this one is still polymorphic",
                        "annotate the parameter, or call String.fromInt / fromFloat explicitly",
                    ) catch {};
                    continue;
                },
                else => {},
            }
            const name = typeToString(self.allocator, r.*) catch null;
            const msg = std.fmt.allocPrint(
                self.allocator,
                "cannot interpolate a value of type {s}",
                .{name orelse "?"},
            ) catch "cannot interpolate this value";
            diags.addErrorCtx(
                msg,
                entry.value_ptr.*,
                "only Int, Float, Bool, Char and String have a text form",
                "convert it explicitly before interpolating",
            ) catch {};
        }
    }

    /// Element type tags must be computed once inference has finished: at the time
    /// an expression is recorded its element type is often still an unbound var,
    /// which would pin the tag to 100 (unknown) and lose list-element formatting.
    fn finalizeElemTags(self: *Inferer) void {
        var it = self.expr_types.iterator();
        while (it.next()) |entry| {
            // Skip entries that already have a correct elem_tag from recordExprType
            if (self.expr_elem_tags.get(entry.key_ptr.*)) |existing| {
                if (existing != 100) continue;
            }
            const resolved = self.resolve(entry.value_ptr.*);
            if (resolved.* == .con and resolved.con.args.len > 0) {
                var elem_tag = self.typeToTag(self.resolve(resolved.con.args[0]));
                if (elem_tag == 100) {
                    const e_ptr = entry.key_ptr.*;
                    if (e_ptr.* == .identifier) {
                        const n = e_ptr.identifier.name;
                        if (self.concrete_elem_tags.get(n)) |concrete| {
                            if (concrete != 100) elem_tag = concrete;
                        }
                    }
                }
                self.expr_elem_tags.put(entry.key_ptr.*, elem_tag) catch {};
            }
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
                // Record type tag for the variable (used for closure capture decref)
                self.var_type_tags.put(prefixed_name, self.typeToTag(t)) catch {};
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

    fn registerDummyForFailedDef(self: *Inferer, def: parser.Definition) void {
        // Register a dummy type for a failed definition so subsequent
        // definitions don't fail with "undefined name"
        switch (def) {
            .fn_def => |f| {
                // Already registered by predeclareDefinition, just leave it
                _ = f;
            },
            .let_binding => |l| {
                // Register as a type variable (unknown type)
                const t = self.newVarType("err") catch return;
                const scheme = self.generalize(&self.global, t) catch return;
                self.global.set(l.name, scheme) catch {};
            },
            else => {},
        }
    }

    fn registerTypeDef(self: *Inferer, t: parser.TypeDef) Error!void {
        // Only assign type_id on first registration (registerTypeDef is called from multiple passes)
        const is_first = !self.type_ids.contains(t.name);
        if (is_first) {
            try self.type_names.put(t.name, t.type_params.len);
            const type_id = self.next_type_id;
            self.next_type_id += 1;
            try self.type_ids.put(t.name, type_id);
        }
        switch (t.body) {
            .sum => |ctors| {
                const type_param_vars = try self.allocator.alloc(*Type, t.type_params.len);
                for (type_param_vars, 0..) |*slot, i| {
                    slot.* = try self.newVarType(try self.freshName(t.type_params[i]));
                }

                // Build a map from type param names to their variables, so that
                // typeExprToType for constructor params uses the SAME variables
                // as the result type.
                var type_param_map = std.StringHashMap(*Type).init(self.allocator);
                defer type_param_map.deinit();
                for (t.type_params, type_param_vars) |name, v| {
                    try type_param_map.put(name, v);
                }

                for (ctors, 0..) |ctor, tag_idx| {
                    const arity = ctor.params.len;
                    // Collect value arg types for pretty-printing (with unresolved type vars)
                    var value_arg_types: ?[]const *Type = null;
                    if (arity > 0) {
                        const typesSlice = try self.allocator.alloc(*Type, arity);
                        for (typesSlice, 0..) |*slot, i| {
                            slot.* = try self.ctorParamType(ctor.params[arity - 1 - i], &type_param_map);
                        }
                        value_arg_types = typesSlice;
                    }
                    try self.ctors.put(ctor.name, .{ .type_name = t.name, .arity = arity, .tag = @intCast(tag_idx), .value_arg_types = value_arg_types });

                    const result = try self.newType(.{ .con = .{ .name = t.name, .args = type_param_vars } });
                    var fn_type = result;
                    var idx = arity;
                    while (idx > 0) : (idx -= 1) {
                        // Use the actual param type from the constructor definition,
                        // substituting type param names with the shared variables.
                        const param_ty = try self.ctorParamType(ctor.params[idx - 1], &type_param_map);
                        fn_type = try self.newType(.{ .arrow = .{ .from = param_ty, .to = fn_type } });
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
                const field_types = try self.allocator.alloc(RecordFieldType, fields.len);
                for (fields, 0..) |field, i| {
                    field_types[i] = .{ .name = field.name, .ty = try self.typeExprToType(field.type_expr) };
                }
                const rec_ty = try self.newType(.{ .record = .{ .name = t.name, .fields = field_types } });
                try self.types.put(t.name, .{
                    .field_names = try self.allocator.dupe([]const u8, names.items),
                    .record_type = rec_ty,
                });
            },
        }
    }

    /// Convert a constructor parameter TypeExpr to a Type, substituting type param
    /// names with the shared variables from the type definition.
    fn ctorParamType(self: *Inferer, te: parser.TypeExpr, type_param_map: *std.StringHashMap(*Type)) Error!*Type {
        return switch (te) {
            .ident => |name| {
                // If this is a type param name, use the shared variable
                if (type_param_map.get(name)) |v| return v;
                // Otherwise, check if it's a known type or create a fresh var
                if (self.types.get(name)) |info| {
                    if (info.record_type) |rec| return rec;
                    return try self.newType(.{ .con = .{ .name = name, .args = &.{} } });
                }
                return try self.newVarType(try self.freshName(name));
            },
            .constructor => |name| {
                if (self.types.get(name)) |info| {
                    if (info.record_type) |rec| return rec;
                }
                if (std.mem.eql(u8, name, "Int")) return try self.newType(.int);
                if (std.mem.eql(u8, name, "Float")) return try self.newType(.float);
                if (std.mem.eql(u8, name, "Bool")) return try self.newType(.bool);
                if (std.mem.eql(u8, name, "String")) return try self.newType(.string);
                if (std.mem.eql(u8, name, "Char")) return try self.newType(.char);
                if (std.mem.eql(u8, name, "Unit")) return try self.newType(.unit);
                if (self.type_names.get(name)) |num_params| {
                    const args = try self.allocator.alloc(*Type, num_params);
                    for (args) |*slot| {
                        slot.* = try self.newVarType(try self.freshName(name));
                    }
                    return try self.newType(.{ .con = .{ .name = name, .args = args } });
                }
                return try self.newType(.{ .con = .{ .name = name, .args = &.{} } });
            },
            .arrow => |a| try self.newType(.{ .arrow = .{ .from = try self.ctorParamType(a.from.*, type_param_map), .to = try self.ctorParamType(a.to.*, type_param_map) } }),
            .group => |inner| try self.ctorParamType(inner.*, type_param_map),
            // `Cons a (List a)` — the recursive occurrence must come out as
            // con("List", [a]) sharing the definition's type variable. Falling
            // through to a fresh variable leaves the constructor's scheme with
            // a free variable that no call site can bind independently.
            .application => |app| blk: {
                var spine: std.ArrayList(*const parser.TypeExpr) = .empty;
                defer spine.deinit(self.allocator);
                try spine.append(self.allocator, app.arg);
                var head: *const parser.TypeExpr = app.func;
                while (head.* == .application) {
                    try spine.append(self.allocator, head.application.arg);
                    head = head.application.func;
                }
                const name = switch (head.*) {
                    .constructor, .ident => |n| n,
                    else => break :blk try self.newVarType(try self.freshName("param")),
                };
                if (type_param_map.get(name) != null) break :blk try self.newVarType(try self.freshName("param"));
                const args = try self.allocator.alloc(*Type, spine.items.len);
                // The spine was collected outermost-first; arguments read left to right.
                for (args, 0..) |*slot, i| {
                    slot.* = try self.ctorParamType(spine.items[spine.items.len - 1 - i].*, type_param_map);
                }
                break :blk try self.newType(.{ .con = .{ .name = name, .args = args } });
            },
            else => try self.newVarType(try self.freshName("param")),
        };
    }

    fn inferFn(self: *Inferer, f: parser.FnDef) Error!void {
        const scheme = self.global.getScheme(f.name) orelse return error.UndefinedName;
        const fn_type = scheme.body;
        var local = Env.init(self.allocator, &self.global);
        defer local.deinit();

        // Reset usage tracking for this function
        self.resetUsageTracking();

        // ── Bidirectional: walk the function type arrow-by-arrow,
        //    using annotations to constrain parameter types. ──
        var cur = fn_type;
        for (f.params) |param| {
            switch (cur.*) {
                .arrow => |a| {
                    // If the parameter has a type annotation, unify it with the
                    // arrow's domain. This lets the signature drive inference.
                    if (param.type_ann) |ann| {
                        const ann_ty = try self.typeExprToType(ann);
                        try self.unify(a.from, ann_ty);
                    }
                    switch (param.pattern) {
                        .identifier => |name| {
                            try local.set(name, .{ .quantified = &.{}, .body = a.from });
                            self.bindName(name, f.loc);
                            // Record type tag for the parameter (used for closure capture decref)
                            self.var_type_tags.put(name, self.typeToTag(a.from)) catch {};
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

        // ── Bidirectional: check the body against the return type. ──
        // If the function has a return type annotation, check the body against it.
        // Otherwise, infer the body and unify with the arrow's codomain.
        if (f.return_type) |ann| {
            const ann_ty = try self.typeExprToType(ann);
            try self.checkExpr(&local, f.body, ann_ty);
            try self.unify(cur, ann_ty);
        } else {
            const body_ty = try self.inferExpr(&local, f.body);
            try self.unify(cur, body_ty);
        }

        // Now that type variables are resolved, compute arities for function-typed parameters.
        // Walk fn_type to find parameter names and their resolved types.
        {
            var walk_type = fn_type;
            for (f.params) |param| {
                switch (walk_type.*) {
                    .arrow => |a| {
                        if (param.pattern == .identifier) {
                            // Resolve type variables to get the actual type
                            var resolved = a.from;
                            while (resolved.* == .variable) {
                                if (resolved.variable.instance) |inst| {
                                    resolved = inst;
                                } else break;
                            }
                            // Count arrows to determine arity
                            var arity: u32 = 0;
                            var w = resolved;
                            while (w.* == .arrow) {
                                arity += 1;
                                w = w.arrow.to;
                            }
                            if (arity > 0) {
                                self.param_arity.put(param.pattern.identifier, arity) catch {};
                            }
                        }
                        walk_type = a.to;
                    },
                    else => break,
                }
            }
        }

        // Check for unused bindings
        self.checkUnusedBindings();

        // Remove the function's own predeclared binding before generalizing,
        // otherwise collectEnvFree picks up free vars from the function's own type
        // (which has empty quantified), preventing them from being quantified.
        const removed = self.global.bindings.fetchRemove(f.name);
        const generalized = try self.generalize(&self.global, fn_type);
        if (removed) |old| {
            // Restore nothing — we're about to overwrite with the proper scheme
            _ = old;
        }
        try self.global.set(f.name, generalized);
    }

    fn inferExpr(self: *Inferer, env: *Env, expr: *const parser.Expr) Error!*Type {
        self.current_loc = expr.getLoc();
        const ty = try switch (expr.*) {
            .int_literal => self.newType(.int),
            .float_literal => self.newType(.float),
            .string_literal => self.newType(.string),
            .char_literal => self.newType(.char),
            .bool_literal => self.newType(.bool),
            .identifier => |id| blk: {
                const scheme = self.resolveName(env, id.name) orelse {
                    var help_msg: ?[]const u8 = null;
                    if (findSimilarName(id.name, env)) |suggestion| {
                        help_msg = std.fmt.allocPrint(self.allocator, "did you mean '{s}'?", .{suggestion}) catch null;
                    }
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "undefined name '{s}'", .{id.name}) catch null,
                        .loc = self.current_loc,
                        .help = help_msg,
                    };
                    return error.UndefinedName;
                };
                self.markNameUsed(id.name);
                break :blk try self.instantiate(scheme);
            },
            .constructor => |c| blk: {
                const scheme = self.resolveName(env, c.name) orelse {
                    var help_msg: ?[]const u8 = null;
                    if (findSimilarName(c.name, env)) |suggestion| {
                        help_msg = std.fmt.allocPrint(self.allocator, "did you mean '{s}'?", .{suggestion}) catch null;
                    }
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "undefined constructor '{s}'", .{c.name}) catch null,
                        .loc = self.current_loc,
                        .help = help_msg,
                    };
                    return error.UndefinedName;
                };
                break :blk try self.instantiate(scheme);
            },
            .tuple => |t| blk: {
                // `()` parses as a zero-element tuple but *is* the unit value.
                // Leaving it as `tuple []` gives a type that prints as "()" yet
                // never unifies with `unit` — "expected (), got ()".
                if (t.items.len == 0) break :blk try self.newType(.unit);
                const tys = try self.allocator.alloc(*Type, t.items.len);
                for (t.items, 0..) |item, i| tys[i] = try self.inferExpr(env, item);
                break :blk try self.newType(.{ .tuple = tys });
            },
            .record_literal => |rec| try self.inferRecordLiteral(env, rec.name, rec.fields),
            .field_access => |fa| try self.inferFieldAccess(env, fa.object, fa.field),
            .fn_call => |call| blk: {
                // Remember `String.from` arguments so their types can be checked
                // once inference has finished — see validateInterpolations().
                if (call.args.len == 1 and call.func.* == .field_access) {
                    const fa = call.func.field_access;
                    if (fa.object.* == .constructor and
                        std.mem.eql(u8, fa.object.constructor.name, "String") and
                        std.mem.eql(u8, fa.field, "from"))
                    {
                        self.interp_sites.put(call.args[0], call.loc) catch {};
                    }
                }
                break :blk try self.inferCall(env, call.func, call.args, call.named_args);
            },
            .lambda => |lam| try self.inferLambda(env, lam.params, lam.body),
            .unary_op => |u| try self.inferUnary(env, u.op, u.expr),
            .binary_op => |b| try self.inferBinary(env, b.op, b.left, b.right),
            .let_expr => |l| try self.inferLetExpr(env, l.name, l.value, l.body, l.type_ann, l.pattern),
            .if_expr => |i| try self.inferIf(env, i.condition, i.then_branch, i.else_branch),
            .block => |b| try self.inferBlock(env, b.items),
            .match_expr => |m| try self.inferMatch(env, m.value, m.arms),
            .comptime_expr => |inner| try self.inferExpr(env, inner),
            .pat_record => try self.newType(.unit),
            .ref_expr => |inner| try self.inferUnary(env, .ref, inner),
            .assign_expr => |a| blk: {
                _ = try self.inferExpr(env, a.target);
                _ = try self.inferExpr(env, a.value);
                break :blk try self.newType(.unit);
            },
        };
        self.recordExprType(expr, ty);
        return ty;
    }

    fn inferBlock(self: *Inferer, env: *Env, items: []const *parser.Expr) Error!*Type {
        var last = try self.newType(.unit);
        for (items) |item| last = try self.inferExpr(env, item);
        return last;
    }

    /// ML's value restriction: only a syntactic value may be generalized.
    ///
    /// `let m = Map.new ()` is an application, and generalizing it hands every
    /// use a fresh copy of the key and value variables while the *binding's*
    /// own copy stays unbound. Codegen then has no key type to pick a hash
    /// from, and the map silently keys on tag 100. The same reasoning covers
    /// `Array.new` and any other allocator whose element type comes from later
    /// unification.
    fn isSyntacticValue(expr: *const parser.Expr) bool {
        return switch (expr.*) {
            .int_literal, .float_literal, .string_literal, .char_literal, .bool_literal => true,
            .identifier, .constructor, .lambda => true,
            .tuple => |t| blk: {
                for (t.items) |item| if (!isSyntacticValue(item)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    fn inferLetExpr(self: *Inferer, env: *Env, name: []const u8, value: *parser.Expr, body: *parser.Expr, type_ann: ?parser.TypeExpr, pattern: ?parser.Pattern) Error!*Type {
        // Bidirectional: if annotation present, check value against it
        const val_ty = if (type_ann) |ann| blk: {
            const ann_ty = try self.typeExprToType(ann);
            try self.checkExpr(env, value, ann_ty);
            break :blk ann_ty;
        } else try self.inferExpr(env, value);

        // Record type tag for the variable (used for closure capture decref)
        self.var_type_tags.put(name, self.typeToTag(val_ty)) catch {};

        // Record concrete elem_tag for the variable name (used by finalizeElemTags
        // to fix up elem_tags that are still 100 due to fresh variables from
        // instantiate of polymorphic types).
        {
            const resolved_val = self.resolve(val_ty);
            if (resolved_val.* == .con and resolved_val.con.args.len > 0) {
                const elem_tag = self.typeToTag(self.resolve(resolved_val.con.args[0]));
                self.concrete_elem_tags.put(name, elem_tag) catch {};
            }
        }

        var local = Env.init(self.allocator, env);
        defer local.deinit();
        if (pattern) |pat| {
            try self.inferPattern(&local, pat, val_ty);
        } else {
            const scheme = if (isSyntacticValue(value))
                try self.generalize(env, val_ty)
            else
                Scheme{ .quantified = &.{}, .body = val_ty };
            try local.set(name, scheme);
            self.bindName(name, value.getLoc());
        }
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

    // ── Bidirectional checking mode ──────────────────────────────────
    // checkExpr verifies that `expr` has type `expected`.
    // For expressions with known shapes (lambdas, ifs, matches, lets),
    // we push the expected type inward (checking mode).
    // For expressions that don't consume expected types, we fall through
    // to inferExpr and unify the result (synthesis mode).

    fn checkExpr(self: *Inferer, env: *Env, expr: *const parser.Expr, expected: *Type) Error!void {
        self.current_loc = expr.getLoc();
        switch (expr.*) {
            // ── Literals: unify with expected ──
            .int_literal => try self.unify(expected, try self.newType(.int)),
            .float_literal => try self.unify(expected, try self.newType(.float)),
            .string_literal => try self.unify(expected, try self.newType(.string)),
            .char_literal => try self.unify(expected, try self.newType(.char)),
            .bool_literal => try self.unify(expected, try self.newType(.bool)),

            // ── Variables / constructors: instantiate and unify ──
            .identifier => |id| {
                const scheme = self.resolveName(env, id.name) orelse {
                    var help_msg: ?[]const u8 = null;
                    if (findSimilarName(id.name, env)) |suggestion| {
                        help_msg = std.fmt.allocPrint(self.allocator, "did you mean '{s}'?", .{suggestion}) catch null;
                    }
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "undefined name '{s}'", .{id.name}) catch null,
                        .loc = self.current_loc,
                        .help = help_msg,
                    };
                    return error.UndefinedName;
                };
                self.markNameUsed(id.name);
                const inst = try self.instantiate(scheme);
                try self.unify(inst, expected);
                self.recordExprType(expr, expected);
            },
            .constructor => |c| {
                const scheme = self.resolveName(env, c.name) orelse {
                    var help_msg: ?[]const u8 = null;
                    if (findSimilarName(c.name, env)) |suggestion| {
                        help_msg = std.fmt.allocPrint(self.allocator, "did you mean '{s}'?", .{suggestion}) catch null;
                    }
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "undefined constructor '{s}'", .{c.name}) catch null,
                        .loc = self.current_loc,
                        .help = help_msg,
                    };
                    return error.UndefinedName;
                };
                const inst = try self.instantiate(scheme);
                try self.unify(inst, expected);
                self.recordExprType(expr, expected);
            },

            // ── Tuples: check each element against expected element type ──
            .tuple => |t| {
                const resolved = self.resolve(expected);
                switch (resolved.*) {
                    .tuple => |expected_elems| {
                        if (t.items.len != expected_elems.len) {
                            self.last_error = .{
                                .message = std.fmt.allocPrint(self.allocator, "tuple has {d} elements, expected {d}", .{ t.items.len, expected_elems.len }) catch null,
                                .loc = self.current_loc,
                            };
                            return error.TypeMismatch;
                        }
                        for (t.items, expected_elems) |item, exp_ty| {
                            try self.checkExpr(env, item, exp_ty);
                        }
                    },
                    else => {
                        // Can't push expected into tuple; infer and unify
                        const inferred = try self.inferExpr(env, expr);
                        try self.unify(inferred, expected);
                    },
                }
                self.recordExprType(expr, expected);
            },

            // ── Records: check each field against expected field type ──
            .record_literal => |rec| {
                const resolved = self.resolve(expected);
                switch (resolved.*) {
                    .record => |expected_rec| {
                        for (expected_rec.fields) |expected_field| {
                            var found: ?*parser.Expr = null;
                            for (rec.fields) |field| {
                                if (std.mem.eql(u8, field.name, expected_field.name)) {
                                    found = field.value;
                                    break;
                                }
                            }
                            const field_expr = found orelse {
                                self.last_error = .{
                                    .message = std.fmt.allocPrint(self.allocator, "missing field '{s}' in record", .{expected_field.name}) catch null,
                                    .loc = self.current_loc,
                                };
                                return error.UnknownType;
                            };
                            try self.checkExpr(env, field_expr, expected_field.ty);
                        }
                    },
                    else => {
                        const inferred = try self.inferExpr(env, expr);
                        try self.unify(inferred, expected);
                    },
                }
                self.recordExprType(expr, expected);
            },

            // ── If: check condition is Bool, check branches against expected ──
            .if_expr => |i| {
                const cond_ty = try self.inferExpr(env, i.condition);
                try self.unify(cond_ty, try self.newType(.bool));
                try self.checkExpr(env, i.then_branch, expected);
                if (i.else_branch) |else_expr| {
                    try self.checkExpr(env, else_expr, expected);
                }
                self.recordExprType(expr, expected);
            },

            // ── Match: check scrutinee, check all arm bodies against expected ──
            .match_expr => |m| {
                _ = try self.inferExpr(env, m.value);
                for (m.arms) |arm| {
                    var arm_env = Env.init(self.allocator, env);
                    defer arm_env.deinit();
                    const scrut_ty = try self.inferExpr(env, m.value);
                    try self.inferPattern(&arm_env, arm.pattern, scrut_ty);
                    try self.checkExpr(&arm_env, arm.body, expected);
                }
                self.recordExprType(expr, expected);
            },

            // ── Lambda: check against expected arrow type ──
            .lambda => |lam| {
                const resolved = self.resolve(expected);
                switch (resolved.*) {
                    .arrow => |arr| {
                        if (lam.params.len != 1) {
                            // Multi-param lambda vs single arrow: fall through to infer
                            const inferred = try self.inferLambda(env, lam.params, lam.body);
                            try self.unify(inferred, expected);
                        } else {
                            var local = Env.init(self.allocator, env);
                            defer local.deinit();
                            switch (lam.params[0]) {
                                .identifier => |name| {
                                    try local.set(name, .{ .quantified = &.{}, .body = arr.from });
                                },
                                else => {
                                    try self.inferPattern(&local, lam.params[0], arr.from);
                                },
                            }
                            try self.checkExpr(&local, lam.body, arr.to);
                        }
                    },
                    else => {
                        // Expected type is not an arrow: fall back to infer
                        const inferred = try self.inferLambda(env, lam.params, lam.body);
                        try self.unify(inferred, expected);
                    },
                }
                self.recordExprType(expr, expected);
            },

            // ── Let: check body against expected ──
            .let_expr => |l| {
                try self.checkLetExpr(env, l.name, l.value, l.body, l.type_ann, l.pattern, expected);
                self.recordExprType(expr, expected);
            },

            // ── Block: check last item against expected ──
            .block => |b| {
                try self.checkBlock(env, b.items, expected);
                self.recordExprType(expr, expected);
            },

            // ── Comptime: forward to inner ──
            .comptime_expr => |inner| {
                try self.checkExpr(env, inner, expected);
                self.recordExprType(expr, expected);
            },

            // ── Ref: infer inner, unify ref T with expected ──
            .ref_expr => |inner| {
                const inner_ty = try self.inferExpr(env, inner);
                try self.unify(expected, try self.newType(.{ .@"ref" = inner_ty }));
                self.recordExprType(expr, expected);
            },

            // ── Assign: infer target and value, result is unit ──
            .assign_expr => |a| {
                _ = try self.inferExpr(env, a.target);
                _ = try self.inferExpr(env, a.value);
                try self.unify(expected, try self.newType(.unit));
                self.recordExprType(expr, expected);
            },

            // ── Fallthrough: synthesize and unify ──
            else => {
                const inferred = try self.inferExpr(env, expr);
                try self.unify(inferred, expected);
            },
        }
    }

    fn checkBlock(self: *Inferer, env: *Env, items: []const *parser.Expr, expected: *Type) Error!void {
        if (items.len == 0) {
            try self.unify(expected, try self.newType(.unit));
            return;
        }
        // Check all but the last item in synthesis mode (their values are discarded)
        for (items[0 .. items.len - 1]) |item| {
            _ = try self.inferExpr(env, item);
        }
        // Check the last item against the expected type
        try self.checkExpr(env, items[items.len - 1], expected);
    }

    fn checkLetExpr(self: *Inferer, env: *Env, name: []const u8, value: *parser.Expr, body: *parser.Expr, type_ann: ?parser.TypeExpr, pattern: ?parser.Pattern, expected: *Type) Error!void {
        const val_ty = if (type_ann) |ann| blk: {
            const ann_ty = try self.typeExprToType(ann);
            try self.checkExpr(env, value, ann_ty);
            break :blk ann_ty;
        } else try self.inferExpr(env, value);

        var local = Env.init(self.allocator, env);
        defer local.deinit();
        if (pattern) |pat| {
            try self.inferPattern(&local, pat, val_ty);
        } else {
            const scheme = if (isSyntacticValue(value))
                try self.generalize(env, val_ty)
            else
                Scheme{ .quantified = &.{}, .body = val_ty };
            try local.set(name, scheme);
            self.bindName(name, value.getLoc());
        }
        try self.checkExpr(&local, body, expected);
    }

    fn inferUnary(self: *Inferer, env: *Env, op: parser.UnaryOp, inner: *parser.Expr) Error!*Type {
        const ty = try self.inferExpr(env, inner);
        return switch (op) {
            .neg => blk: {
                // Negation is Int-or-Float, mirroring .sub/.mul/.div in inferBinary.
                if (self.resolve(ty).* == .float) {
                    try self.unify(ty, try self.newType(.float));
                    break :blk try self.newType(.float);
                }
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
                const args = try self.allocator.dupe(*Type, &.{ ok_ty, result_ty });
                try self.unify(ty, try self.newType(.{ .con = .{ .name = "Result", .args = args } }));
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
                if (lt.* == .float or rt.* == .float) {
                    try self.unify(lt, try self.newType(.float));
                    try self.unify(rt, try self.newType(.float));
                    break :blk try self.newType(.float);
                }
                try self.unify(lt, try self.newType(.int));
                try self.unify(rt, try self.newType(.int));
                break :blk try self.newType(.int);
            },
            .sub, .mul, .div, .mod => blk: {
                if (lt.* == .float or rt.* == .float) {
                    try self.unify(lt, try self.newType(.float));
                    try self.unify(rt, try self.newType(.float));
                    break :blk try self.newType(.float);
                }
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
            // Float operators (dot-suffixed) — force Float operands
            .add_dot, .sub_dot, .mul_dot, .div_dot => blk: {
                try self.unify(lt, try self.newType(.float));
                try self.unify(rt, try self.newType(.float));
                break :blk try self.newType(.float);
            },
            .lte_dot, .gte_dot => blk: {
                try self.unify(lt, try self.newType(.float));
                try self.unify(rt, try self.newType(.float));
                break :blk try self.newType(.bool);
            },
            .pipe => blk: {
                break :blk rt;
            },
            .cons => blk: {
                // desugar: left :: right  →  Cons left right
                const ctor_scheme = self.resolveName(env, "Cons") orelse return error.UndefinedName;
                const ctor_ty = try self.instantiate(ctor_scheme);
                // Get the type name from the constructor's registered type
                const ctor_info = self.ctors.get("Cons") orelse return error.UndefinedName;
                const elem_ty = try self.newVarType(try self.freshName("elem"));
                const list_ty = try self.newType(.{ .con = .{ .name = ctor_info.type_name, .args = try self.allocator.dupe(*Type, &.{elem_ty}) } });
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
        // Re-record elem_tags after unification — inferExpr records them with
        // instantiated types (fresh variables), but unify may resolve them to
        // concrete types (e.g., List a → List String). Without this, elem_tag
        // stays 100 and inspect can't print list elements correctly.
        for (args, 0..) |arg, idx| {
            self.recordExprType(arg, arg_tys[idx]);
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
                self.last_error = .{
                    .message = std.fmt.allocPrint(self.allocator, "type String has no field '{s}'", .{field}) catch null,
                    .loc = self.current_loc,
                };
                return error.UnknownType;
            },
            .record => |rec| {
                for (rec.fields) |f| {
                    if (std.mem.eql(u8, f.name, field)) return f.ty;
                }
                self.last_error = .{
                    .message = std.fmt.allocPrint(self.allocator, "record '{s}' has no field '{s}'", .{ rec.name, field }) catch null,
                    .loc = self.current_loc,
                };
                return error.UnknownType;
            },
            .tuple => |elems| {
                const idx = std.fmt.parseInt(usize, field, 10) catch {
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "tuple has no field '{s}' — use a numeric index like '.0'", .{field}) catch null,
                        .loc = self.current_loc,
                    };
                    return error.UnknownType;
                };
                if (idx >= elems.len) {
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "tuple index {d} out of range for a {d}-element tuple", .{ idx, elems.len }) catch null,
                        .loc = self.current_loc,
                    };
                    return error.UnknownType;
                }
                return elems[idx];
            },
            .variable => {
                if (std.mem.eql(u8, field, "length")) {
                    try self.unify(obj_ty, try self.newType(.string));
                    return try self.newType(.int);
                }
                // Pin this variable monomorphically so the call site's record type
                // reaches the body — see generalize().
                self.field_access_vars.put(resolved, {}) catch {};
                return try self.newVarType(try self.freshName("field"));
            },
            else => {
                self.last_error = .{
                    .message = "cannot access fields on this type",
                    .loc = self.current_loc,
                };
                return error.UnknownType;
            },
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
                const expr = found orelse {
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "missing field '{s}' in record", .{wanted}) catch null,
                        .loc = self.current_loc,
                    };
                    return error.UnknownType;
                };
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
                const info = ctor_info orelse {
                    self.last_error = .{
                        .message = std.fmt.allocPrint(self.allocator, "unknown constructor '{s}'", .{ctor.name}) catch null,
                        .loc = self.current_loc,
                    };
                    return error.UnknownConstructor;
                };
                const num_type_params = self.type_names.get(info.type_name) orelse 0;
                const type_args = try self.allocator.alloc(*Type, num_type_params);
                for (type_args) |*slot| {
                    slot.* = try self.newVarType(try self.freshName(info.type_name));
                }
                const arg_types = try self.allocator.alloc(*Type, info.arity);
                for (arg_types) |*slot| {
                    slot.* = try self.newVarType(try self.freshName(ctor.name));
                }
                // Take the scrutinee type from the constructor's own scheme rather than
                // rebuilding con(type_name): the built-in True/False are registered under
                // type_name "Bool" but carry the primitive `bool` type, so reconstructing
                // con("Bool") would fail to unify. A user-defined `type Bool = True | False`
                // overwrites that scheme, so it still unifies as con("Bool").
                //
                // The field types come from that same instantiation. Leaving them as the
                // fresh variables above would disconnect them from the scrutinee: matching
                // `Maybe Float` on `Just v` would leave `v` unbound, and every use of `v`
                // would fall back to the integer representation.
                const con_ty = try self.newType(.{ .con = .{ .name = info.type_name, .args = type_args } });
                const scrutinee_ty = blk: {
                    const scheme = self.global.getScheme(ctor.name) orelse break :blk con_ty;
                    var result = self.resolve(try self.instantiate(scheme));
                    var idx: usize = 0;
                    while (idx < info.arity) : (idx += 1) {
                        if (result.* != .arrow) break :blk con_ty;
                        arg_types[idx] = result.arrow.from;
                        result = self.resolve(result.arrow.to);
                    }
                    break :blk result;
                };
                try self.unify(expected, scrutinee_ty);
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
