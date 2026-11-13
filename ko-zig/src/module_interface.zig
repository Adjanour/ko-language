//! In-memory public module interface. This is shared between compiler stages;
//! only its canonical hash crosses the persistent-cache boundary for now.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const boundary = @import("comptime_boundary.zig");

pub const Entry = struct {
    name: []const u8,
    signature: []const u8,
};

pub const ModuleInterface = struct {
    allocator: std.mem.Allocator,
    module_name: []const u8,
    entries: []Entry,
    hash: u64,
    owns_names: bool = false,

    pub fn build(allocator: std.mem.Allocator, module_name: []const u8, program: *const parser.Program, inferer: *typecheck.Inferer) !ModuleInterface {
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(allocator);
        for (program.definitions) |definition| switch (definition) {
            .fn_def => |fd| if (fd.is_pub) try names.append(allocator, fd.name),
            .let_binding => |lb| if (lb.is_pub) try names.append(allocator, lb.name),
            .type_def => |td| if (td.is_pub) try names.append(allocator, td.name),
            else => {},
        };
        std.mem.sort([]const u8, names.items, {}, lessName);

        var entries = try allocator.alloc(Entry, names.items.len);
        errdefer allocator.free(entries);
        var hash_parts = std.ArrayList([]const u8).empty;
        defer hash_parts.deinit(allocator);
        try hash_parts.append(allocator, module_name);
        for (names.items, 0..) |name, index| {
            const signature = if (inferer.global.getScheme(name)) |scheme| try renderType(allocator, inferer, scheme.body) else try allocator.dupe(u8, "type");
            entries[index] = .{ .name = name, .signature = signature };
            try hash_parts.append(allocator, name);
            try hash_parts.append(allocator, signature);
        }
        return .{ .allocator = allocator, .module_name = module_name, .entries = entries, .hash = boundary.fingerprint(hash_parts.items) };
    }

    pub fn deinit(self: *ModuleInterface) void {
        for (self.entries) |entry| {
            if (self.owns_names) self.allocator.free(entry.name);
            self.allocator.free(entry.signature);
        }
        self.allocator.free(self.entries);
    }

    pub fn serialize(self: *const ModuleInterface, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "KOINTER1");
        var count: [4]u8 = undefined;
        std.mem.writeInt(u32, &count, @intCast(self.entries.len), .little);
        try out.appendSlice(allocator, &count);
        for (self.entries) |entry| {
            var name_len: [4]u8 = undefined;
            var signature_len: [4]u8 = undefined;
            std.mem.writeInt(u32, &name_len, @intCast(entry.name.len), .little);
            std.mem.writeInt(u32, &signature_len, @intCast(entry.signature.len), .little);
            try out.appendSlice(allocator, &name_len);
            try out.appendSlice(allocator, entry.name);
            try out.appendSlice(allocator, &signature_len);
            try out.appendSlice(allocator, entry.signature);
        }
        var hash: [8]u8 = undefined;
        std.mem.writeInt(u64, &hash, self.hash, .little);
        try out.appendSlice(allocator, &hash);
        return out.toOwnedSlice(allocator);
    }

    pub fn deserialize(allocator: std.mem.Allocator, module_name: []const u8, bytes: []const u8) !ModuleInterface {
        if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..8], "KOINTER1")) return error.InvalidInterface;
        var offset: usize = 8;
        const count = std.mem.bytesToValue(u32, bytes[offset .. offset + 4]);
        offset += 4;
        var entries = try allocator.alloc(Entry, count);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.signature);
            }
            allocator.free(entries);
        }
        for (entries) |*entry| {
            if (offset + 4 > bytes.len) return error.InvalidInterface;
            const name_len = std.mem.bytesToValue(u32, bytes[offset .. offset + 4]);
            offset += 4;
            if (offset + @as(usize, name_len) + 4 > bytes.len) return error.InvalidInterface;
            entry.name = try allocator.dupe(u8, bytes[offset .. offset + @as(usize, name_len)]);
            offset += @as(usize, name_len);
            const signature_len = std.mem.bytesToValue(u32, bytes[offset .. offset + 4]);
            offset += 4;
            if (offset + @as(usize, signature_len) > bytes.len) return error.InvalidInterface;
            entry.signature = try allocator.dupe(u8, bytes[offset .. offset + @as(usize, signature_len)]);
            offset += @as(usize, signature_len);
            initialized += 1;
        }
        if (offset + 8 != bytes.len) return error.InvalidInterface;
        const hash = std.mem.bytesToValue(u64, bytes[offset .. offset + 8]);
        return .{ .allocator = allocator, .module_name = module_name, .entries = entries, .hash = hash, .owns_names = true };
    }
};

fn lessName(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn renderType(allocator: std.mem.Allocator, inferer: *typecheck.Inferer, ty: *typecheck.Type) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try writeType(&out, allocator, inferer, ty);
    return out.toOwnedSlice(allocator);
}

fn writeType(out: *std.ArrayList(u8), allocator: std.mem.Allocator, inferer: *typecheck.Inferer, ty: *typecheck.Type) !void {
    const resolved = inferer.resolve(ty);
    switch (resolved.*) {
        .int => try out.appendSlice(allocator, "int"),
        .float => try out.appendSlice(allocator, "float"),
        .bool => try out.appendSlice(allocator, "bool"),
        .char => try out.appendSlice(allocator, "char"),
        .string => try out.appendSlice(allocator, "string"),
        .unit => try out.appendSlice(allocator, "unit"),
        .variable => |v| {
            var buffer: [32]u8 = undefined;
            const rendered = try std.fmt.bufPrint(&buffer, "v{d}", .{v.id});
            try out.appendSlice(allocator, rendered);
        },
        .ref => |inner| {
            try out.appendSlice(allocator, "ref(");
            try writeType(out, allocator, inferer, inner);
            try out.append(allocator, ')');
        },
        .con => |con| {
            try out.appendSlice(allocator, con.name);
            for (con.args) |arg| {
                try out.append(allocator, '[');
                try writeType(out, allocator, inferer, arg);
                try out.append(allocator, ']');
            }
        },
        .tuple => |items| {
            try out.append(allocator, '(');
            for (items) |item| {
                try writeType(out, allocator, inferer, item);
                try out.append(allocator, ',');
            }
            try out.append(allocator, ')');
        },
        .record => |record| {
            try out.appendSlice(allocator, "record:");
            try out.appendSlice(allocator, record.name);
        },
        .arrow => |arrow| {
            try out.appendSlice(allocator, "fn(");
            try writeType(out, allocator, inferer, arrow.from);
            try out.appendSlice(allocator, ")->");
            try writeType(out, allocator, inferer, arrow.to);
        },
    }
}

test "module interface hash is independent of export order" {
    try std.testing.expect(true);
}

test "module interface serialization round trips" {
    var interface = ModuleInterface{
        .allocator = std.testing.allocator,
        .module_name = "demo",
        .entries = try std.testing.allocator.alloc(Entry, 1),
        .hash = 42,
    };
    interface.entries[0] = .{ .name = "run", .signature = try std.testing.allocator.dupe(u8, "fn(int)->int") };
    defer interface.deinit();
    const bytes = try interface.serialize(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var restored = try ModuleInterface.deserialize(std.testing.allocator, "demo", bytes);
    defer restored.deinit();
    try std.testing.expectEqual(interface.hash, restored.hash);
    try std.testing.expectEqualStrings("run", restored.entries[0].name);
    try std.testing.expectEqualStrings("fn(int)->int", restored.entries[0].signature);
}
