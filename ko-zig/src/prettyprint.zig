const std = @import("std");
const typecheck = @import("typecheck.zig");
const Type = typecheck.Type;

pub fn inspectValue(alloc: std.mem.Allocator, val: i64, ty: *const Type, ctor_tag_names: ?*const std.StringHashMap(std.AutoHashMap(u8, []const u8))) ![]const u8 {
    return switch (ty.*) {
        .int => try std.fmt.allocPrint(alloc, "{d}", .{val}),
        .float => {
            const f: f64 = @bitCast(val);
            return try std.fmt.allocPrint(alloc, "{d}", .{f});
        },
        .bool => if (val == 0) try alloc.dupe(u8, "False") else try alloc.dupe(u8, "True"),
        .char => {
            const ch: u8 = @intCast(val);
            return try std.fmt.allocPrint(alloc, "'{c}'", .{ch});
        },
        .string => {
            const ptr: [*]const u8 = @ptrFromInt(@as(usize, @bitCast(val)));
            var len: usize = 0;
            while (ptr[len] != 0) : (len += 1) {}
            return try std.fmt.allocPrint(alloc, "\"{s}\"", .{ptr[0..len]});
        },
        .unit => try alloc.dupe(u8, "()"),
        .arrow => try alloc.dupe(u8, "<fn>"),
        .variable, .@"ref" => try std.fmt.allocPrint(alloc, "{d}", .{val}),
        .tuple => |elem_types| {
            if (elem_types.len == 0) return try alloc.dupe(u8, "()");
            const ptr: [*]const i64 = @ptrFromInt(@as(usize, @bitCast(val)));
            var parts = std.ArrayList(u8).empty;
            try parts.append(alloc, '(');
            for (elem_types, 0..) |elem_ty, i| {
                if (i > 0) try parts.appendSlice(alloc, ", ");
                const s = try inspectValue(alloc, ptr[i], elem_ty, ctor_tag_names);
                defer alloc.free(s);
                try parts.appendSlice(alloc, s);
            }
            try parts.append(alloc, ')');
            return try parts.toOwnedSlice(alloc);
        },
        .con => |c| {
            // Determine if this is a zero-arg constructor (value is tag) or multi-arg (value is pointer)
            // For zero-arg constructors, the value is a small tag number
            // For multi-arg constructors, the value is a heap pointer
            // Heuristic: small values (< 4096) are tags, larger aligned values are heap pointers
            const is_likely_pointer = val > 4096 and @rem(val, 8) == 0;
            if (!is_likely_pointer) {
                // Value is a tag — zero-arg constructor
                var display_name = c.name;
                if (ctor_tag_names != null and val >= 0 and val <= 255) {
                    const tag: u8 = @intCast(val);
                    if (ctor_tag_names.?.get(c.name)) |inner| {
                        if (inner.get(tag)) |name| {
                            display_name = name;
                        }
                    }
                }
                return try alloc.dupe(u8, display_name);
            }
            // Value is a heap pointer — multi-arg constructor
            const ptr: [*]const i64 = @ptrFromInt(@as(usize, @bitCast(val)));
            // Safety: read tag, check bounds
            const raw_tag = ptr[0];
            if (raw_tag > 255) {
                // Not a valid tag — likely a function pointer or garbage
                return try alloc.dupe(u8, "<fn>");
            }
            var display_name = c.name;
            if (ctor_tag_names != null) {
                const tag: u8 = @intCast(raw_tag);
                if (ctor_tag_names.?.get(c.name)) |inner| {
                    if (inner.get(tag)) |name| {
                        display_name = name;
                    }
                }
            }
            var parts = std.ArrayList(u8).empty;
            try parts.appendSlice(alloc, display_name);
            // Only show value args (not type params from the ADT definition)
            // The type's args are type params, but the runtime struct has value fields
            // For now, show the type's args as value args (works for current representation)
            for (c.args, 0..) |arg_ty, i| {
                try parts.append(alloc, ' ');
                const s = try inspectValue(alloc, ptr[i + 1], arg_ty, ctor_tag_names);
                defer alloc.free(s);
                const needs_parens = switch (arg_ty.*) {
                    .con => |ac| ac.args.len > 0,
                    .tuple => true,
                    else => false,
                };
                if (needs_parens) try parts.append(alloc, '(');
                try parts.appendSlice(alloc, s);
                if (needs_parens) try parts.append(alloc, ')');
            }
            return try parts.toOwnedSlice(alloc);
        },
        .record => |r| {
            const ptr: [*]const i64 = @ptrFromInt(@as(usize, @bitCast(val)));
            var parts = std.ArrayList(u8).empty;
            const header = try std.fmt.allocPrint(alloc, "{s} {{ ", .{r.name});
            defer alloc.free(header);
            try parts.appendSlice(alloc, header);
            for (r.fields, 0..) |field, i| {
                if (i > 0) try parts.appendSlice(alloc, ", ");
                const field_header = try std.fmt.allocPrint(alloc, "{s} = ", .{field.name});
                defer alloc.free(field_header);
                try parts.appendSlice(alloc, field_header);
                const s = try inspectValue(alloc, ptr[i], field.ty, ctor_tag_names);
                defer alloc.free(s);
                try parts.appendSlice(alloc, s);
            }
            try parts.appendSlice(alloc, " }}");
            return try parts.toOwnedSlice(alloc);
        },
    };
}
