const std = @import("std");
const lir = @import("lir.zig");
const lir_lower = @import("lir_lower.zig");

pub fn dumpLir(allocator: std.mem.Allocator, lower: *const lir_lower.LirLower, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(allocator, "=== LIR Program ===\n\n");

    // Dump functions
    try buf.print(allocator, "--- Functions ({d}) ---\n", .{lower.fns.items.len});
    for (lower.fns.items) |*func| {
        try dumpFn(func, buf, allocator);
        try buf.appendSlice(allocator, "\n\n");
    }

    // Dump globals
    if (lower.globals.count() > 0) {
        try buf.print(allocator, "--- Globals ({d}) ---\n", .{lower.globals.count()});
        var iter = lower.globals.iterator();
        while (iter.next()) |entry| {
            try buf.print(allocator, "  {s}: {s}\n", .{ entry.key_ptr.*, @tagName(entry.value_ptr.*.kind) });
        }
    }

    // Dump constructors
    if (lower.ctors.count() > 0) {
        try buf.print(allocator, "\n--- Constructors ({d}) ---\n", .{lower.ctors.count()});
        var iter = lower.ctors.iterator();
        while (iter.next()) |entry| {
            try buf.print(allocator, "  {s} (tag={d}, arity={d})\n", .{
                entry.key_ptr.*,
                entry.value_ptr.*.tag,
                entry.value_ptr.*.arity,
            });
        }
    }

    // Dump function signatures
    if (lower.fn_sigs.count() > 0) {
        try buf.print(allocator, "\n--- Function Signatures ({d}) ---\n", .{lower.fn_sigs.count()});
        var iter = lower.fn_sigs.iterator();
        while (iter.next()) |entry| {
            try buf.print(allocator, "  {s}: ", .{entry.key_ptr.*});
            try dumpFnType(entry.value_ptr.*, buf, allocator);
            try buf.append(allocator, '\n');
        }
    }
}

fn dumpFn(func: *const lir.LirFn, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.print(allocator, "fn {s}(", .{func.name});
    for (func.params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.print(allocator, "%{d}", .{p});
    }
    try buf.appendSlice(allocator, ") -> ");
    try dumpType(func.return_type, buf, allocator);
    try buf.appendSlice(allocator, " {\n");

    // Dump locals
    if (func.locals.len > 0) {
        try buf.appendSlice(allocator, "  ; locals: ");
        for (func.locals, 0..) |local, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try dumpType(local, buf, allocator);
        }
        try buf.append(allocator, '\n');
    }

    // Dump blocks
    for (func.blocks) |block| {
        try buf.print(allocator, "  block{d}(", .{block.id});
        for (block.params, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.print(allocator, "%{d}", .{p});
        }
        try buf.appendSlice(allocator, ") {\n");

        // Dump statements
        for (block.body) |stmt| {
            try buf.appendSlice(allocator, "    ");
            try dumpStmt(stmt, buf, allocator);
            try buf.append(allocator, '\n');
        }

        // Dump terminator
        try buf.appendSlice(allocator, "    ");
        try dumpTerminator(block.terminator, buf, allocator);
        try buf.append(allocator, '\n');

        try buf.appendSlice(allocator, "  }\n");
    }

    try buf.append(allocator, '}');
}

fn dumpStmt(stmt: lir.LirStmt, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (stmt) {
        .assign => |a| {
            try buf.print(allocator, "%{d} = ", .{a.dest});
            try dumpValue(a.value, buf, allocator);
        },
        .store => |s| {
            try buf.print(allocator, "store %{} -> %{}", .{ s.value, s.dest });
        },
        .effect => |v| {
            try buf.appendSlice(allocator, "effect ");
            try dumpValue(v, buf, allocator);
        },
    }
}

fn dumpValue(value: lir.LirValue, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (value) {
        .int => |v| try buf.print(allocator, "{d}", .{v}),
        .float => |v| try buf.print(allocator, "{d}", .{v}),
        .bool => |v| try buf.appendSlice(allocator, if (v) "true" else "false"),
        .char => |v| try buf.print(allocator, "'{c}'", .{v}),
        .string => |v| try buf.print(allocator, "\"{s}\"", .{v.ptr[0..v.len]}),
        .local => |v| try buf.print(allocator, "%{d}", .{v}),
        .fn_ref => |v| try buf.print(allocator, "@{s}", .{v}),
        .alloc => |av| {
            try buf.appendSlice(allocator, "alloc ");
            try dumpType(av.ty, buf, allocator);
            try buf.print(allocator, " type_tag={d}", .{av.type_tag});
        },
        .load => |v| try buf.print(allocator, "load %{}", .{v}),
        .alloc_stack => |v| {
            try buf.appendSlice(allocator, "alloc_stack ");
            try dumpType(v, buf, allocator);
        },
        .incref => |v| try buf.print(allocator, "incref %{}", .{v}),
        .decref => |v| try buf.print(allocator, "decref %{}", .{v}),
        .is_unique => |v| try buf.print(allocator, "is_unique %{}", .{v}),
        .call => |v| {
            try buf.print(allocator, "call %{}(", .{v.func});
            for (v.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "%{}", .{a});
            }
            try buf.append(allocator, ')');
        },
        .make_closure => |v| {
            try buf.print(allocator, "closure({s}, captures=[", .{v.fn_name});
            for (v.captures, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "%{}", .{c});
            }
            try buf.appendSlice(allocator, "])");
        },
        .extract_value => |v| {
            try buf.print(allocator, "extract %{}[{}]", .{ v.aggregate, v.index });
        },
        .insert_value => |v| {
            try buf.print(allocator, "insert %{}[{}] = %{}", .{ v.aggregate, v.index, v.value });
        },
        .get_element_ptr => |v| {
            try buf.print(allocator, "gep %{}[", .{v.ptr});
            for (v.indices, 0..) |idx, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "%{}", .{idx});
            }
            try buf.append(allocator, ']');
        },
        .ptrtoint => |v| try buf.print(allocator, "ptrtoint %{}", .{v}),
        .inttoptr => |v| {
            try buf.print(allocator, "inttoptr %{}", .{v.val});
        },
        .zext => |v| {
            try buf.print(allocator, "zext %{} to ", .{v.val});
            try dumpType(v.ty, buf, allocator);
        },
        .trunc => |v| {
            try buf.print(allocator, "trunc %{} to ", .{v.val});
            try dumpType(v.ty, buf, allocator);
        },
        .bitcast => |v| {
            try buf.print(allocator, "bitcast %{} to ", .{v.val});
            try dumpType(v.ty, buf, allocator);
        },
        .primop => |v| {
            try buf.print(allocator, "{s}(", .{@tagName(v.op)});
            for (v.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "%{}", .{a});
            }
            try buf.append(allocator, ')');
        },
    }
}

fn dumpTerminator(term: lir.LirTerminator, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (term) {
        .br => |v| {
            try buf.print(allocator, "br -> block{}", .{v.target});
            if (v.args.len > 0) {
                try buf.append(allocator, '(');
                for (v.args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.print(allocator, "%{}", .{a});
                }
                try buf.append(allocator, ')');
            }
        },
        .cond_br => |v| {
            try buf.print(allocator, "cond_br %{}, then -> block{}", .{ v.cond, v.then.target });
            if (v.then.args.len > 0) {
                try buf.append(allocator, '(');
                for (v.then.args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.print(allocator, "%{}", .{a});
                }
                try buf.append(allocator, ')');
            }
            try buf.print(allocator, ", else -> block{}", .{v.else_.target});
            if (v.else_.args.len > 0) {
                try buf.append(allocator, '(');
                for (v.else_.args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.print(allocator, "%{}", .{a});
                }
                try buf.append(allocator, ')');
            }
        },
        .switch_ => |v| {
            try buf.print(allocator, "switch %{} {{\n", .{v.val});
            for (v.cases) |c| {
                try buf.print(allocator, "      case {d} -> block{}", .{ c.tag, c.target.target });
                if (c.target.args.len > 0) {
                    try buf.append(allocator, '(');
                    for (c.target.args, 0..) |a, i| {
                        if (i > 0) try buf.appendSlice(allocator, ", ");
                        try buf.print(allocator, "%{}", .{a});
                    }
                    try buf.append(allocator, ')');
                }
                try buf.append(allocator, '\n');
            }
            try buf.print(allocator, "      default -> block{}", .{v.default.target});
            if (v.default.args.len > 0) {
                try buf.append(allocator, '(');
                for (v.default.args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.print(allocator, "%{}", .{a});
                }
                try buf.append(allocator, ')');
            }
            try buf.appendSlice(allocator, "\n    }");
        },
        .ret => |v| try buf.print(allocator, "ret %{}", .{v}),
        .unreachable_ => try buf.appendSlice(allocator, "unreachable"),
        .tail_call => |v| {
            try buf.print(allocator, "tail_call %{}(", .{v.func});
            for (v.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "%{}", .{a});
            }
            try buf.append(allocator, ')');
        },
    }
}

fn dumpType(ty: lir.LirType, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (ty) {
        .int => try buf.appendSlice(allocator, "i64"),
        .float => try buf.appendSlice(allocator, "f64"),
        .bool => try buf.appendSlice(allocator, "bool"),
        .char => try buf.appendSlice(allocator, "char"),
        .string => try buf.appendSlice(allocator, "string"),
        .unit => try buf.appendSlice(allocator, "unit"),
        .ptr => |p| {
            try buf.append(allocator, '*');
            try dumpType(p.*, buf, allocator);
        },
        .struct_ => |fields| {
            try buf.append(allocator, '{');
            for (fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try dumpType(f, buf, allocator);
            }
            try buf.append(allocator, '}');
        },
        .array => |a| {
            try buf.append(allocator, '[');
            try dumpType(a.elem.*, buf, allocator);
            try buf.print(allocator, "; {}]", .{a.len});
        },
        .function => |f| {
            try buf.append(allocator, '(');
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try dumpType(p, buf, allocator);
            }
            try buf.appendSlice(allocator, ") -> ");
            try dumpType(f.returns, buf, allocator);
        },
        .opaque_type => try buf.appendSlice(allocator, "opaque"),
    }
}

fn dumpFnType(ty: lir.LirFnType, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '(');
    for (ty.params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try dumpType(p, buf, allocator);
    }
    try buf.appendSlice(allocator, ") -> ");
    try dumpType(ty.returns, buf, allocator);
}
