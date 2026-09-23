const std = @import("std");

/// Zig 0.17 removed `Allocator.dupeZ`. This helper preserves the old
/// single-expression call shape (`compat.dupeZ(allocator, s)`) at the
/// ~40 call sites that relied on it.
pub fn dupeZ(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    return allocator.dupeSentinel(u8, s, 0);
}

/// Zig 0.17 removed `std.fmt.bufPrintZ`. Format into a stack buffer and
/// return it as a sentinel slice; on overflow return `fallback`.
pub fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype, fallback: [:0]const u8) [:0]const u8 {
    const slice = std.fmt.bufPrint(buf, fmt, args) catch return fallback;
    buf[slice.len] = 0;
    return buf[0..slice.len :0];
}
