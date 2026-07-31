const std = @import("std");
const hir = @import("hir.zig");
const hir_lower = @import("hir_lower.zig");

pub fn dumpHir(allocator: std.mem.Allocator, lower: *const hir_lower.HirLower, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator, "=== HIR Program ===\n\n");

    // Dump definitions
    try buf.print(allocator, "--- Definitions ({d}) ---\n", .{lower.defs.items.len});
    for (lower.defs.items, 0..) |def, i| {
        try buf.print(allocator, "[{d}] ", .{i});
        switch (def) {
            .fn_def => |fd| try buf.print(allocator, "fn {s} (arity={d}, root={d})", .{ fd.name, fd.arity, fd.root }),
            .let_binding => |lb| try buf.print(allocator, "let {s} (root={d})", .{ lb.name, lb.root }),
            .type_def => |td| {
                try buf.print(allocator, "type {s} = ", .{td.name});
                for (td.ctors, 0..) |ctor, j| {
                    if (j > 0) try buf.appendSlice(allocator, " | ");
                    try buf.print(allocator, "{s}/{d}", .{ ctor.name, ctor.arity });
                }
            },
        }
        try buf.append(allocator, '\n');
    }

    // Dump expressions
    try buf.print(allocator, "\n--- Expressions ({d}) ---\n", .{lower.expressions.items.len});
    for (lower.expressions.items, 0..) |*expr, i| {
        try buf.print(allocator, "[{d}] ", .{i});
        try dumpExpr(lower, expr, buf, allocator);
        try buf.append(allocator, '\n');
    }
}

fn dumpExpr(lower: *const hir_lower.HirLower, expr: *const hir.HirExpr, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    _ = lower;
    switch (expr.kind) {
        .int => |v| try buf.print(allocator, "int({d})", .{v}),
        .float => |v| try buf.print(allocator, "float({d})", .{v}),
        .bool => |v| try buf.print(allocator, "bool({s})", .{if (v) "true" else "false"}),
        .char => |v| try buf.print(allocator, "char('{c}')", .{v}),
        .string => |v| try buf.print(allocator, "string(\"{s}\")", .{v}),
        .local => |v| try buf.print(allocator, "local({d})", .{v}),
        .global => |v| try buf.print(allocator, "global({s})", .{v}),
        .lambda => |v| {
            try buf.appendSlice(allocator, "lambda(params=[");
            for (v.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "{d}", .{p});
            }
            try buf.print(allocator, "], body={d}, captures=[", .{v.body});
            for (v.captures, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "{d}", .{c});
            }
            try buf.appendSlice(allocator, "])");
        },
        .apply => |v| try buf.print(allocator, "apply(func={d}, arg={d})", .{ v.func, v.arg }),
        .let => |v| try buf.print(allocator, "let(name={d}, value={d}, body={d})", .{ v.name, v.value, v.body }),
        .let_rec => |v| {
            try buf.appendSlice(allocator, "let_rec(bindings=[");
            for (v.bindings, 0..) |b, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "({d}={d})", .{ b.name, b.value });
            }
            try buf.print(allocator, "], body={d})", .{v.body});
        },
        .if_ => |v| try buf.print(allocator, "if(cond={d}, then={d}, else={d})", .{ v.cond, v.then, v.else_ }),
        .match => |v| {
            try buf.print(allocator, "match(scrutinee={d}, arms=[", .{v.scrutinee});
            for (v.arms, 0..) |arm, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try dumpPattern(arm.pattern, buf, allocator);
                if (arm.guard) |g| try buf.print(allocator, " when {d}", .{g});
                try buf.print(allocator, " => {d}", .{arm.body});
            }
            try buf.appendSlice(allocator, "])");
        },
        .record => |v| {
            try buf.appendSlice(allocator, "record(fields=[");
            for (v.fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "{s}={d}", .{ f.name, f.value });
            }
            try buf.appendSlice(allocator, "])");
        },
        .record_access => |v| try buf.print(allocator, "record_access(record={d}, field=\"{s}\")", .{ v.record, v.field }),
        .tuple => |v| {
            try buf.appendSlice(allocator, "tuple(elements=[");
            for (v.elements, 0..) |e, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "{d}", .{e});
            }
            try buf.appendSlice(allocator, "])");
        },
        .constructor => |v| {
            try buf.print(allocator, "constructor(type=\"{s}\", ctor=\"{s}\", args=[", .{ v.type_name, v.ctor_name });
            for (v.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "{d}", .{a});
            }
            try buf.appendSlice(allocator, "])");
        },
        .ref => |v| try buf.print(allocator, "ref({d})", .{v}),
        .deref => |v| try buf.print(allocator, "deref({d})", .{v}),
        .assign => |v| try buf.print(allocator, "assign(target={d}, value={d})", .{ v.target, v.value }),
        .comptime_expr => |v| try buf.print(allocator, "comptime({d})", .{v}),
        .primop => |v| {
            try buf.print(allocator, "primop({s}, args=[", .{@tagName(v.op)});
            for (v.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "{d}", .{a});
            }
            try buf.appendSlice(allocator, "])");
        },
    }
}

fn dumpPattern(pattern: hir.Pattern, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (pattern) {
        .wildcard => try buf.append(allocator, '_'),
        .bind => |v| try buf.print(allocator, "bind({d})", .{v}),
        .literal => |v| switch (v) {
            .int => |i| try buf.print(allocator, "{d}", .{i}),
            .float => |f| try buf.print(allocator, "{d}", .{f}),
            .string => |s| try buf.print(allocator, "\"{s}\"", .{s}),
            .char => |c| try buf.print(allocator, "'{s}'", .{c}),
            .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        },
        .constructor => |v| {
            try buf.print(allocator, "{s}.{s}(", .{ v.type_name, v.ctor_name });
            for (v.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try dumpPattern(a, buf, allocator);
            }
            try buf.append(allocator, ')');
        },
        .record => |v| {
            try buf.append(allocator, '{');
            for (v.fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "{s}=", .{f.name});
                try dumpPattern(f.p, buf, allocator);
            }
            if (v.rest) try buf.appendSlice(allocator, ", ..");
            try buf.append(allocator, '}');
        },
        .tuple => |v| {
            try buf.append(allocator, '(');
            for (v, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try dumpPattern(p, buf, allocator);
            }
            try buf.append(allocator, ')');
        },
    }
}
