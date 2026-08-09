const std = @import("std");
const typecheck = @import("typecheck.zig");
const Type = typecheck.Type;
const CtorInfo = typecheck.CtorInfo;

pub fn inspectValue(
    alloc: std.mem.Allocator,
    val: i64,
    ty: *const Type,
    ctor_tag_names: ?*const std.StringHashMap(std.AutoHashMap(u8, []const u8)),
    ctors: ?*const std.StringHashMap(CtorInfo),
) ![]const u8 {
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
                const s = try inspectValue(alloc, ptr[i], elem_ty, ctor_tag_names, ctors);
                defer alloc.free(s);
                try parts.appendSlice(alloc, s);
            }
            try parts.append(alloc, ')');
            return try parts.toOwnedSlice(alloc);
        },
        .con => |c| {
            // Determine if this is a zero-arg constructor (value is tag) or multi-arg (value is pointer)
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
            const raw_tag = ptr[0];
            if (raw_tag > 255) {
                return try alloc.dupe(u8, "<fn>");
            }
            // Resolve display name from tag
            var display_name = c.name;
            if (ctor_tag_names != null) {
                const tag: u8 = @intCast(raw_tag);
                if (ctor_tag_names.?.get(c.name)) |inner| {
                    if (inner.get(tag)) |name| {
                        display_name = name;
                    }
                }
            }
            // Get constructor arity from ctors map (use display_name which is the ctor name)
            var arity: usize = 0;
            if (ctors != null) {
                if (ctors.?.get(display_name)) |info| {
                    arity = info.arity;
                }
            }
            // Fallback: if no arity found, use type args count (old behavior)
            if (arity == 0) arity = c.args.len;
            var parts = std.ArrayList(u8).empty;
            try parts.appendSlice(alloc, display_name);
            // Print each value arg
            for (0..arity) |i| {
                try parts.append(alloc, ' ');
                // Strategy:
                // - If type has args (e.g. List Int), use c.args for all positions (resolved concrete types)
                // - If type has no args (e.g. Point), use value_arg_types (e.g. P Int Int -> [Int, Int])
                // - Fallback to ty (parent type) for recursive positions
                var arg_ty: *const Type = ty;
                if (c.args.len > 0) {
                    // Type has args — use them (handles non-recursive positions correctly)
                    // For recursive positions beyond args count, use ty (parent type)
                    arg_ty = if (i < c.args.len) c.args[i] else ty;
                } else if (ctors != null) {
                    // Type has no args — try value_arg_types for concrete types
                    if (ctors.?.get(display_name)) |info| {
                        if (info.value_arg_types) |vat| {
                            if (i < vat.len) arg_ty = vat[i];
                        }
                    }
                }
                const s = try inspectValue(alloc, ptr[i + 1], arg_ty, ctor_tag_names, ctors);
                defer alloc.free(s);
                const needs_parens = switch (arg_ty.*) {
                    .con => |ac| blk: {
                        // Check if this is a multi-arg constructor that needs parens
                        // Use display_name (constructor name) not ac.name (type name)
                        if (ctors != null) {
                            // Try to find the constructor by checking the rendered value
                            // If s is a known zero-arg constructor name, no parens needed
                            var is_zero_arg = false;
                            var ctor_it = ctors.?.iterator();
                            while (ctor_it.next()) |entry| {
                                if (entry.value_ptr.arity == 0 and std.mem.eql(u8, s, entry.key_ptr.*)) {
                                    is_zero_arg = true;
                                    break;
                                }
                            }
                            if (is_zero_arg) break :blk false;
                            // For other con types with args, add parens
                            break :blk ac.args.len > 0;
                        }
                        break :blk ac.args.len > 0;
                    },
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
                const s = try inspectValue(alloc, ptr[i], field.ty, ctor_tag_names, ctors);
                defer alloc.free(s);
                try parts.appendSlice(alloc, s);
            }
            try parts.appendSlice(alloc, " }}");
            return try parts.toOwnedSlice(alloc);
        },
    };
}
