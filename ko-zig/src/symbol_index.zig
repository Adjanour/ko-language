//! Canonical compiler symbol index. Typechecking environments are temporary
//! views; this index owns stable declaration identity and mutation metadata.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const symbol_identity = @import("symbol_identity.zig");

pub const SymbolId = symbol_identity.SymbolId;
pub const Namespace = enum { value, type_name, constructor };
pub const DeclarationKind = enum { function, value, type_definition, constructor };
pub const Visibility = enum { private, public };
pub const Origin = union(enum) {
    source: ast.Loc,
    generated: struct { action_id: []const u8, source: ast.Loc },
};

pub const Symbol = struct {
    id: SymbolId,
    name: []const u8,
    module_id: []const u8,
    namespace: Namespace,
    kind: DeclarationKind,
    visibility: Visibility,
    origin: Origin,
    type: ?*const typecheck.Type = null,
    scheme: ?typecheck.Scheme = null,
    constructor_arity: ?usize = null,
    invalidation_generation: u64 = 0,
};

pub const Dependency = struct { from: SymbolId, to: SymbolId };

pub const Index = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayList(Symbol) = .empty,
    by_key: std.StringHashMap(SymbolId),
    dependencies: std.ArrayList(Dependency) = .empty,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator, .by_key = std.StringHashMap(SymbolId).init(allocator) };
    }

    pub fn deinit(self: *Index) void {
        var keys = self.by_key.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.by_key.deinit();
        self.symbols.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
    }

    pub fn add(self: *Index, module_id: []const u8, name: []const u8, namespace: Namespace, kind: DeclarationKind, visibility: Visibility, origin: Origin, ty: ?*const typecheck.Type, arity: ?usize, scheme: ?typecheck.Scheme) !SymbolId {
        const namespace_name = @tagName(namespace);
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}\x00{s}", .{ module_id, namespace_name, name });
        if (self.by_key.get(key)) |existing| {
            self.allocator.free(key);
            return existing;
        }
        const id = symbol_identity.stableId(module_id, name, @tagName(kind));
        var indexed_scheme = scheme;
        if (indexed_scheme) |*value| value.symbol_id = id;
        try self.by_key.put(key, id);
        try self.symbols.append(self.allocator, .{ .id = id, .name = name, .module_id = module_id, .namespace = namespace, .kind = kind, .visibility = visibility, .origin = origin, .type = ty, .constructor_arity = arity, .scheme = indexed_scheme });
        return id;
    }

    pub fn lookupScheme(self: *Index, name: []const u8) ?typecheck.Scheme {
        for (self.symbols.items) |symbol| {
            if (symbol.namespace == .value and std.mem.eql(u8, symbol.name, name)) return symbol.scheme;
        }
        return null;
    }

    pub fn invalidate(self: *Index, id: SymbolId) void {
        var pending = std.ArrayList(SymbolId).empty;
        defer pending.deinit(self.allocator);
        pending.append(self.allocator, id) catch return;
        var seen = std.AutoHashMap(SymbolId, void).init(self.allocator);
        defer seen.deinit();
        while (pending.items.len > 0) {
            const changed = pending.pop() orelse unreachable;
            if (seen.contains(changed)) continue;
            seen.put(changed, {}) catch return;
            for (self.symbols.items) |*symbol| {
                if (symbol.id == changed) symbol.invalidation_generation += 1;
            }
            for (self.dependencies.items) |edge| {
                if (edge.to == changed) pending.append(self.allocator, edge.from) catch return;
            }
        }
    }

    pub fn addDependency(self: *Index, from: SymbolId, to: SymbolId) !void {
        try self.dependencies.append(self.allocator, .{ .from = from, .to = to });
    }
};

pub fn buildForProgram(allocator: std.mem.Allocator, module_id: []const u8, program: *const parser.Program, inferer: *typecheck.Inferer) !Index {
    var index = Index.init(allocator);
    errdefer index.deinit();
    try addProgram(&index, module_id, program, inferer, false);
    var visited = std.AutoHashMap(*typecheck.Inferer, void).init(allocator);
    defer visited.deinit();
    try addImported(&index, inferer, &visited);
    return index;
}

fn addProgram(index: *Index, module_id: []const u8, program: *const parser.Program, inferer: *typecheck.Inferer, public_only: bool) !void {
    for (program.definitions) |definition| switch (definition) {
        .fn_def => |fd| {
            if (public_only and !fd.is_pub) continue;
            const scheme = inferer.global.getScheme(fd.name);
            _ = try index.add(module_id, fd.name, .value, .function, if (fd.is_pub) .public else .private, .{ .source = fd.loc }, if (scheme) |s| s.body else null, null, scheme);
        },
        .let_binding => |lb| {
            if (public_only and !lb.is_pub) continue;
            const scheme = inferer.global.getScheme(lb.name);
            _ = try index.add(module_id, lb.name, .value, .value, if (lb.is_pub) .public else .private, .{ .source = lb.loc }, if (scheme) |s| s.body else null, null, scheme);
        },
        .type_def => |td| {
            if (public_only and !td.is_pub) continue;
            _ = try index.add(module_id, td.name, .type_name, .type_definition, if (td.is_pub) .public else .private, .{ .source = td.loc }, null, null, null);
            if (td.body == .sum) for (td.body.sum) |ctor| {
                _ = try index.add(module_id, ctor.name, .constructor, .constructor, if (td.is_pub) .public else .private, .{ .source = .{} }, null, ctor.params.len, null);
            };
        },
        else => {},
    };
}

fn addImported(index: *Index, inferer: *typecheck.Inferer, visited: *std.AutoHashMap(*typecheck.Inferer, void)) !void {
    if (visited.contains(inferer)) return;
    try visited.put(inferer, {});
    for (inferer.imported_modules.items) |imported| {
        const module_id = imported.module.file_path;
        const before = index.symbols.items.len;
        try addProgram(index, module_id, &imported.module.program, imported.inferer, true);
        const imported_ids = index.symbols.items[before..];
        for (index.symbols.items[0..before]) |owner| {
            for (imported_ids) |dependency| try index.addDependency(owner.id, dependency.id);
        }
        try addImported(index, imported.inferer, visited);
    }
}

pub fn resolveScheme(context: *anyopaque, name: []const u8) ?typecheck.Scheme {
    const index: *Index = @ptrCast(@alignCast(context));
    return index.lookupScheme(name);
}

test "symbol IDs are stable for the same declaration" {
    var first = Index.init(std.testing.allocator);
    defer first.deinit();
    var second = Index.init(std.testing.allocator);
    defer second.deinit();
    const origin: Origin = .{ .source = .{} };
    const a = try first.add("pkg:main", "run", .value, .function, .public, origin, null, null, null);
    const b = try second.add("pkg:main", "run", .value, .function, .public, origin, null, null, null);
    try std.testing.expectEqual(a, b);
}

test "invalidation propagates from dependencies to dependents" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();
    const origin: Origin = .{ .source = .{} };
    const dependent = try index.add("pkg:main", "run", .value, .function, .public, origin, null, null, null);
    const dependency = try index.add("pkg:lib", "value", .value, .value, .public, origin, null, null, null);
    try index.addDependency(dependent, dependency);

    index.invalidate(dependency);

    try std.testing.expectEqual(@as(u64, 1), index.symbols.items[0].invalidation_generation);
    try std.testing.expectEqual(@as(u64, 1), index.symbols.items[1].invalidation_generation);
}
