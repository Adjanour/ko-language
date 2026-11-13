//! Stable representation contracts shared by compiler stages and the runtime.
//!
//! These numeric values are part of the generated-program ABI. Keep them
//! explicit here; do not duplicate their literal values in lowering or runtime
//! code.

const std = @import("std");

/// Static type classification passed to `print`, `println`, and `inspect`.
/// These tags describe the source-level shape of a value, not its heap layout.
pub const InspectTypeTag = enum(i64) {
    int = 0,
    float = 1,
    bool = 2,
    char = 3,
    string = 4,
    unit = 5,
    constructor = 6,
    record = 7,
    function = 8,
    tuple = 9,
    unknown = 100,
};

/// Heap layout classification written into the allocation header.
///
/// `raw` has no recursively-owned fields. Constructors, tuples, and records
/// use the generic field bitmap. The remaining layouts have dedicated runtime
/// handling.
pub const HeapTag = enum(i64) {
    raw = 0,
    constructor = 1,
    tuple = 2,
    record = 3,
    closure = 10,
    array_scalar = 11,
    array_heap = 12,
    map = 13,
};

pub fn tagValue(tag: anytype) i64 {
    return @backingInt(tag);
}

pub const inspect = struct {
    pub const int = tagValue(InspectTypeTag.int);
    pub const float = tagValue(InspectTypeTag.float);
    pub const @"bool" = tagValue(InspectTypeTag.bool);
    pub const char = tagValue(InspectTypeTag.char);
    pub const string = tagValue(InspectTypeTag.string);
    pub const unit = tagValue(InspectTypeTag.unit);
    pub const constructor = tagValue(InspectTypeTag.constructor);
    pub const record = tagValue(InspectTypeTag.record);
    pub const function = tagValue(InspectTypeTag.function);
    pub const tuple = tagValue(InspectTypeTag.tuple);
    pub const unknown = tagValue(InspectTypeTag.unknown);
};

pub const heap = struct {
    pub const raw = tagValue(HeapTag.raw);
    pub const constructor = tagValue(HeapTag.constructor);
    pub const tuple = tagValue(HeapTag.tuple);
    pub const record = tagValue(HeapTag.record);
    pub const closure = tagValue(HeapTag.closure);
    pub const array_scalar = tagValue(HeapTag.array_scalar);
    pub const array_heap = tagValue(HeapTag.array_heap);
    pub const map = tagValue(HeapTag.map);
};

test "representation tags retain the runtime ABI" {
    try std.testing.expectEqual(@as(i64, 0), tagValue(InspectTypeTag.int));
    try std.testing.expectEqual(@as(i64, 100), tagValue(InspectTypeTag.unknown));
    try std.testing.expectEqual(@as(i64, 1), tagValue(HeapTag.constructor));
    try std.testing.expectEqual(@as(i64, 10), tagValue(HeapTag.closure));
    try std.testing.expectEqual(@as(i64, 13), tagValue(HeapTag.map));
}
