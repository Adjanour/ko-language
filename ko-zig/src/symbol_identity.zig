//! Dependency-free symbol identity shared by typechecking and the canonical
//! symbol index.

const boundary = @import("comptime_boundary.zig");

pub const SymbolId = u64;

pub fn stableId(module_id: []const u8, name: []const u8, declaration_kind: []const u8) SymbolId {
    return boundary.fingerprint(&.{ module_id, name, declaration_kind });
}
