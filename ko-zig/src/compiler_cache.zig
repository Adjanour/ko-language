//! Content-addressed compiler artifact cache.
//!
//! Entries are immutable, self-validating blobs. This module does not decide
//! whether an artifact is eligible; callers must reject opaque compile-time
//! work before calling `put`.

const std = @import("std");
const Io = std.Io;
const boundary = @import("comptime_boundary.zig");

const magic = "KOCACHE1";

pub const Cache = struct {
    allocator: std.mem.Allocator,
    root: []const u8,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) Cache {
        return .{ .allocator = allocator, .root = root };
    }

    pub fn put(self: Cache, io: Io, dir: Io.Dir, stage: boundary.CacheStage, key: u64, payload: []const u8) !void {
        const artifact_path = try self.path(stage, key);
        defer self.allocator.free(artifact_path);
        const directory = std.fs.path.dirname(artifact_path) orelse return error.InvalidCachePath;
        try dir.createDirPath(io, directory);

        const temporary = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{artifact_path});
        defer self.allocator.free(temporary);
        var file = try dir.createFile(io, temporary, .{ .truncate = true });
        defer file.close(io);
        var header = Header{ .payload_hash = boundary.fingerprint(&.{payload}), .payload_len = payload.len };
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(std.mem.asBytes(&header));
        try writer.interface.writeAll(payload);
        try writer.interface.flush();
        try dir.rename(temporary, dir, artifact_path, io);
    }

    pub fn get(self: Cache, io: Io, dir: Io.Dir, stage: boundary.CacheStage, key: u64) !?[]u8 {
        const artifact_path = try self.path(stage, key);
        defer self.allocator.free(artifact_path);
        var file = dir.openFile(io, artifact_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        const size = (try file.stat(io)).size;
        if (size > 256 * 1024 * 1024) return error.CorruptArtifact;
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        errdefer self.allocator.free(bytes);
        try reader.interface.readSliceAll(bytes);
        if (bytes.len < @sizeOf(Header)) return error.CorruptArtifact;
        const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        const payload = bytes[@sizeOf(Header)..];
        if (!std.mem.eql(u8, &header.magic_bytes, magic) or header.payload_len != payload.len or header.payload_hash != boundary.fingerprint(&.{payload})) return error.CorruptArtifact;
        const result = try self.allocator.dupe(u8, payload);
        self.allocator.free(bytes);
        return result;
    }

    fn path(self: Cache, stage: boundary.CacheStage, key: u64) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{x}.artifact", .{ self.root, @tagName(stage), key });
    }
};

const Header = extern struct {
    magic_bytes: [8]u8 = magic.*,
    payload_hash: u64,
    payload_len: usize,
};

test "cache header has a stable magic marker" {
    const header = Header{ .payload_hash = 0, .payload_len = 0 };
    try std.testing.expectEqualStrings("KOCACHE1", &header.magic_bytes);
}
