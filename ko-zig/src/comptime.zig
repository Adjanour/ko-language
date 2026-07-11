const std = @import("std");
const parser = @import("parser.zig");

pub const ComptimeValue = union(enum) {
    int: i64,
    float: f64,
    bool_val: bool,
    char: u8,
    string: []const u8,
    unit: void,
    list: []const ComptimeValue,
    tuple: []const ComptimeValue,
    constructor: struct { tag: u8, args: []const ComptimeValue },

    pub fn equal(self: ComptimeValue, other: ComptimeValue) bool {
        return switch (self) {
            .int => |a| switch (other) {
                .int => |b| a == b,
                else => false,
            },
            .float => |a| switch (other) {
                .float => |b| a == b,
                else => false,
            },
            .bool_val => |a| switch (other) {
                .bool_val => |b| a == b,
                else => false,
            },
            .char => |a| switch (other) {
                .char => |b| a == b,
                else => false,
            },
            .string => |a| switch (other) {
                .string => |b| std.mem.eql(u8, a, b),
                else => false,
            },
            .unit => switch (other) {
                .unit => true,
                else => false,
            },
            .list => |a| switch (other) {
                .list => |b| {
                    if (a.len != b.len) return false;
                    for (a, b) |ai, bi| {
                        if (!ai.equal(bi)) return false;
                    }
                    return true;
                },
                else => false,
            },
            .tuple => |a| switch (other) {
                .tuple => |b| {
                    if (a.len != b.len) return false;
                    for (a, b) |ai, bi| {
                        if (!ai.equal(bi)) return false;
                    }
                    return true;
                },
                else => false,
            },
            .constructor => |a| switch (other) {
                .constructor => |b| {
                    if (a.tag != b.tag) return false;
                    if (a.args.len != b.args.len) return false;
                    for (a.args, b.args) |ai, bi| {
                        if (!ai.equal(bi)) return false;
                    }
                    return true;
                },
                else => false,
            },
        };
    }

    pub fn format(self: ComptimeValue) void {
        switch (self) {
            .int => |v| std.debug.print("{d}", .{v}),
            .float => |v| std.debug.print("{d}", .{v}),
            .bool_val => |v| std.debug.print("{}", .{v}),
            .char => |v| std.debug.print("'{c}'", .{v}),
            .string => |v| std.debug.print("\"{s}\"", .{v}),
            .unit => std.debug.print("()", .{}),
            .list => |v| {
                std.debug.print("[", .{});
                for (v, 0..) |item, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    item.format();
                }
                std.debug.print("]", .{});
            },
            .tuple => |v| {
                std.debug.print("(", .{});
                for (v, 0..) |item, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    item.format();
                }
                std.debug.print(")", .{});
            },
            .constructor => |v| {
                std.debug.print("Ctor({d})", .{v.tag});
                if (v.args.len > 0) {
                    std.debug.print("(", .{});
                    for (v.args, 0..) |arg, i| {
                        if (i > 0) std.debug.print(", ", .{});
                        arg.format();
                    }
                    std.debug.print(")", .{});
                }
            },
        }
    }
};

pub const ConstructorInfo = struct {
    type_name: []const u8,
    tag: u8,
    arity: u8,
};

const EvalError = error{NotComptime};

pub const CompileTimeWorld = struct {
    allocator: std.mem.Allocator,
    functions: std.StringHashMap(parser.FnDef),
    constructors: std.StringHashMap(ConstructorInfo),
    values: std.StringHashMap(ComptimeValue),
    eval_depth: u32,
    max_eval_depth: u32,

    pub fn init(allocator: std.mem.Allocator) CompileTimeWorld {
        return .{
            .allocator = allocator,
            .functions = std.StringHashMap(parser.FnDef).init(allocator),
            .constructors = std.StringHashMap(ConstructorInfo).init(allocator),
            .values = std.StringHashMap(ComptimeValue).init(allocator),
            .eval_depth = 0,
            .max_eval_depth = 10000,
        };
    }

    pub fn deinit(self: *CompileTimeWorld) void {
        self.functions.deinit();
        self.constructors.deinit();
        self.values.deinit();
    }

    pub fn evaluate(self: *CompileTimeWorld, expr: *const parser.Expr) ?ComptimeValue {
        if (self.eval_depth >= self.max_eval_depth) return null;
        self.eval_depth += 1;
        defer self.eval_depth -= 1;

        return switch (expr.*) {
            .int_literal => |v| .{ .int = v },
            .float_literal => |v| .{ .float = v },
            .bool_literal => |v| .{ .bool_val = v },
            .char_literal => |v| blk: {
                const inner = if (v.len >= 2 and v[0] == '\'' and v[v.len - 1] == '\'')
                    v[1 .. v.len - 1]
                else
                    v;
                if (inner.len == 0) break :blk .{ .char = 0 };
                break :blk .{ .char = inner[0] };
            },
            .string_literal => |v| blk: {
                const inner = if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"')
                    v[1 .. v.len - 1]
                else
                    v;
                break :blk .{ .string = inner };
            },
            .unary_op => |op| blk: {
                const operand = self.evaluate(op.expr) orelse break :blk null;
                break :blk switch (op.op) {
                    .neg => switch (operand) {
                        .int => |v| .{ .int = -v },
                        .float => |v| .{ .float = -v },
                        else => null,
                    },
                    .not => switch (operand) {
                        .bool_val => |v| .{ .bool_val = !v },
                        else => null,
                    },
                    else => null,
                };
            },
            .binary_op => |op| blk: {
                const left = self.evaluate(op.left) orelse break :blk null;
                const right = self.evaluate(op.right) orelse break :blk null;
                break :blk self.evalBinaryOp(op.op, left, right);
            },
            .if_expr => |if_e| blk: {
                const cond = self.evaluate(if_e.condition) orelse break :blk null;
                const cond_bool = switch (cond) {
                    .bool_val => |b| b,
                    .int => |v| v != 0,
                    else => break :blk null,
                };
                if (cond_bool) {
                    break :blk self.evaluate(if_e.then_branch);
                } else {
                    if (if_e.else_branch) |eb| {
                        break :blk self.evaluate(eb);
                    }
                    break :blk .{ .unit = {} };
                }
            },
            .let_expr => |let_e| blk: {
                const val = self.evaluate(let_e.value) orelse break :blk null;
                // Store in values for the body evaluation
                const old = self.values.get(let_e.name);
                self.values.put(let_e.name, val) catch break :blk null;
                const result = self.evaluate(let_e.body);
                // Restore old value
                if (old) |v| {
                    self.values.put(let_e.name, v) catch {};
                } else {
                    _ = self.values.remove(let_e.name);
                }
                break :blk result;
            },
            .block => |b| blk: {
                if (b.items.len == 0) break :blk .{ .unit = {} };
                // Evaluate all but last, return last
                for (b.items[0 .. b.items.len - 1]) |item| {
                    _ = self.evaluate(item) orelse break :blk null;
                }
                break :blk self.evaluate(b.items[b.items.len - 1]);
            },
            .identifier => |id| blk: {
                // Look up in local values
                if (self.values.get(id.name)) |v| break :blk v;
                // Check if it's a zero-param comptime function — evaluate it
                if (self.functions.get(id.name)) |fn_def| {
                    if (fn_def.is_comptime and fn_def.params.len == 0) {
                        break :blk self.callComptimeFn(fn_def, &.{});
                    }
                }
                break :blk null;
            },
            .constructor => |ctor| blk: {
                const tag_info = self.constructors.get(ctor.name) orelse break :blk null;
                break :blk .{ .constructor = .{
                    .tag = tag_info.tag,
                    .args = &.{},
                } };
            },
            .tuple => |tup| blk: {
                var items: [16]ComptimeValue = undefined;
                for (tup.items, 0..) |item, i| {
                    items[i] = self.evaluate(item) orelse break :blk null;
                }
                break :blk .{ .tuple = self.allocator.dupe(ComptimeValue, items[0..tup.items.len]) catch break :blk null };
            },
            .fn_call => |call| blk: {
                // Resolve the function name — support both identifier and field_access (e.g., String.length)
                const name = switch (call.func.*) {
                    .identifier => |id| id.name,
                    .field_access => |fa| blk2: {
                        // Combine as "Module.name" for qualified lookup
                        const obj_name = switch (fa.object.*) {
                            .identifier => |id| id.name,
                            .constructor => |c| c.name,
                            else => break :blk null,
                        };
                        break :blk2 std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ obj_name, fa.field }) catch break :blk null;
                    },
                    else => break :blk null,
                };

                // Check if it's a comptime function
                const fn_def = self.functions.get(name) orelse {
                    // Check if it's a constructor used as a function (e.g., Cons 1 Nil)
                    if (self.constructors.get(name)) |ctor_info| {
                        if (call.args.len != ctor_info.arity) break :blk null;
                        var ctor_args: [32]ComptimeValue = undefined;
                        for (call.args, 0..) |arg, i| {
                            ctor_args[i] = self.evaluate(arg) orelse break :blk null;
                        }
                        break :blk .{ .constructor = .{
                            .tag = ctor_info.tag,
                            .args = self.allocator.dupe(ComptimeValue, ctor_args[0..call.args.len]) catch break :blk null,
                        } };
                    }
                    // Check builtins
                    break :blk self.evalBuiltinFn(name, call.args);
                };
                if (!fn_def.is_comptime) break :blk null;

                // Check arity
                if (call.args.len != fn_def.params.len) break :blk null;

                // Evaluate all arguments
                var args: [32]ComptimeValue = undefined;
                for (call.args, 0..) |arg, i| {
                    args[i] = self.evaluate(arg) orelse break :blk null;
                }

                // Call the comptime function
                break :blk self.callComptimeFn(fn_def, args[0..call.args.len]);
            },
            .match_expr => |m| blk: {
                const val = self.evaluate(m.value) orelse break :blk null;
                for (m.arms) |arm| {
                    var bindings = std.StringHashMap(ComptimeValue).init(self.allocator);
                    defer bindings.deinit();
                    if (self.matchPattern(arm.pattern, val, &bindings)) {
                        // Add pattern bindings
                        var it = bindings.iterator();
                        while (it.next()) |entry| {
                            const old = self.values.get(entry.key_ptr.*);
                            self.values.put(entry.key_ptr.*, entry.value_ptr.*) catch break :blk null;
                            // Save for restoration
                            _ = old;
                        }
                        const result = self.evaluate(arm.body);
                        // Restore bindings
                        var it2 = bindings.iterator();
                        while (it2.next()) |entry| {
                            _ = self.values.remove(entry.key_ptr.*);
                        }
                        break :blk result;
                    }
                }
                break :blk null;
            },
            .comptime_expr => |inner| self.evaluate(inner),
            else => null,
        };
    }

    fn evalBinaryOp(self: *CompileTimeWorld, op: parser.BinaryOp, left: ComptimeValue, right: ComptimeValue) ?ComptimeValue {
        return switch (op) {
            .add => switch (left) {
                .int => |a| switch (right) {
                    .int => |b| .{ .int = a +% b },
                    .float => |b| .{ .float = @as(f64, @floatFromInt(a)) + b },
                    else => null,
                },
                .float => |a| switch (right) {
                    .int => |b| .{ .float = a + @as(f64, @floatFromInt(b)) },
                    .float => |b| .{ .float = a + b },
                    else => null,
                },
                else => null,
            },
            .sub => switch (left) {
                .int => |a| switch (right) {
                    .int => |b| .{ .int = a -% b },
                    .float => |b| .{ .float = @as(f64, @floatFromInt(a)) - b },
                    else => null,
                },
                .float => |a| switch (right) {
                    .int => |b| .{ .float = a - @as(f64, @floatFromInt(b)) },
                    .float => |b| .{ .float = a - b },
                    else => null,
                },
                else => null,
            },
            .mul => switch (left) {
                .int => |a| switch (right) {
                    .int => |b| .{ .int = a *% b },
                    .float => |b| .{ .float = @as(f64, @floatFromInt(a)) * b },
                    else => null,
                },
                .float => |a| switch (right) {
                    .int => |b| .{ .float = a * @as(f64, @floatFromInt(b)) },
                    .float => |b| .{ .float = a * b },
                    else => null,
                },
                else => null,
            },
            .div => switch (left) {
                .int => |a| switch (right) {
                    .int => |b| if (b == 0) null else .{ .int = @divTrunc(a, b) },
                    .float => |b| if (b == 0.0) null else .{ .float = @as(f64, @floatFromInt(a)) / b },
                    else => null,
                },
                .float => |a| switch (right) {
                    .int => |b| if (b == 0) null else .{ .float = a / @as(f64, @floatFromInt(b)) },
                    .float => |b| if (b == 0.0) null else .{ .float = a / b },
                    else => null,
                },
                else => null,
            },
            .mod => switch (left) {
                .int => |a| switch (right) {
                    .int => |b| if (b == 0) null else .{ .int = @rem(a, b) },
                    else => null,
                },
                else => null,
            },
            .eq => .{ .bool_val = left.equal(right) },
            .neq => .{ .bool_val = !left.equal(right) },
            .lt => switch (left) {
                .int => |a| switch (right) {
                    .int => |b| .{ .bool_val = a < b },
                    .float => |b| .{ .bool_val = @as(f64, @floatFromInt(a)) < b },
                    else => null,
                },
                .float => |a| switch (right) {
                    .int => |b| .{ .bool_val = a < @as(f64, @floatFromInt(b)) },
                    .float => |b| .{ .bool_val = a < b },
                    else => null,
                },
                .char => |a| switch (right) {
                    .char => |b| .{ .bool_val = a < b },
                    else => null,
                },
                else => null,
            },
            .lte => switch (left) {
                .int => |a| switch (right) {
                    .int => |b| .{ .bool_val = a <= b },
                    .float => |b| .{ .bool_val = @as(f64, @floatFromInt(a)) <= b },
                    else => null,
                },
                .float => |a| switch (right) {
                    .int => |b| .{ .bool_val = a <= @as(f64, @floatFromInt(b)) },
                    .float => |b| .{ .bool_val = a <= b },
                    else => null,
                },
                .char => |a| switch (right) {
                    .char => |b| .{ .bool_val = a <= b },
                    else => null,
                },
                else => null,
            },
            .gt => switch (left) {
                .int => |a| switch (right) {
                    .int => |b| .{ .bool_val = a > b },
                    .float => |b| .{ .bool_val = @as(f64, @floatFromInt(a)) > b },
                    else => null,
                },
                .float => |a| switch (right) {
                    .int => |b| .{ .bool_val = a > @as(f64, @floatFromInt(b)) },
                    .float => |b| .{ .bool_val = a > b },
                    else => null,
                },
                .char => |a| switch (right) {
                    .char => |b| .{ .bool_val = a > b },
                    else => null,
                },
                else => null,
            },
            .gte => switch (left) {
                .int => |a| switch (right) {
                    .int => |b| .{ .bool_val = a >= b },
                    .float => |b| .{ .bool_val = @as(f64, @floatFromInt(a)) >= b },
                    else => null,
                },
                .float => |a| switch (right) {
                    .int => |b| .{ .bool_val = a >= @as(f64, @floatFromInt(b)) },
                    .float => |b| .{ .bool_val = a >= b },
                    else => null,
                },
                .char => |a| switch (right) {
                    .char => |b| .{ .bool_val = a >= b },
                    else => null,
                },
                else => null,
            },
            .and_op => switch (left) {
                .bool_val => |a| switch (right) {
                    .bool_val => |b| .{ .bool_val = a and b },
                    else => null,
                },
                else => null,
            },
            .or_op => switch (left) {
                .bool_val => |a| switch (right) {
                    .bool_val => |b| .{ .bool_val = a or b },
                    else => null,
                },
                else => null,
            },
            .cons => blk: {
                var new_list: std.ArrayList(ComptimeValue) = .empty;
                new_list.append(self.allocator, left) catch break :blk null;
                switch (right) {
                    .list => |v| new_list.appendSlice(self.allocator, v) catch break :blk null,
                    else => {},
                }
                break :blk .{ .list = new_list.toOwnedSlice(self.allocator) catch break :blk null };
            },
            else => null,
        };
    }

    fn matchPattern(self: *CompileTimeWorld, pattern: parser.Pattern, value: ComptimeValue, bindings: *std.StringHashMap(ComptimeValue)) bool {
        return switch (pattern) {
            .wildcard => true,
            .identifier => |name| blk: {
                bindings.put(name, value) catch return false;
                break :blk true;
            },
            .literal => |lit| blk: {
                const pat_val = switch (lit) {
                    .int => |v| ComptimeValue{ .int = v },
                    .float => |v| ComptimeValue{ .float = v },
                    .bool => |v| ComptimeValue{ .bool_val = v },
                    .string => |v| blk2: {
                        const inner = if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"')
                            v[1 .. v.len - 1]
                        else
                            v;
                        break :blk2 ComptimeValue{ .string = inner };
                    },
                    .char => |v| blk2: {
                        const inner = if (v.len >= 2 and v[0] == '\'' and v[v.len - 1] == '\'')
                            v[1 .. v.len - 1]
                        else
                            v;
                        break :blk2 ComptimeValue{ .char = if (inner.len > 0) inner[0] else 0 };
                    },
                };
                break :blk value.equal(pat_val);
            },
            .constructor => |ctor| blk: {
                switch (value) {
                    .constructor => |val_ctor| {
                        const tag_info = self.constructors.get(ctor.name) orelse break :blk false;
                        if (val_ctor.tag != tag_info.tag) break :blk false;
                        if (ctor.args.len != val_ctor.args.len) break :blk false;
                        for (ctor.args, val_ctor.args) |pat_arg, val_arg| {
                            if (!self.matchPattern(pat_arg, val_arg, bindings)) break :blk false;
                        }
                        break :blk true;
                    },
                    else => break :blk false,
                }
            },
            else => false,
        };
    }

    fn evalBuiltinFn(self: *CompileTimeWorld, name: []const u8, args: []const *parser.Expr) ?ComptimeValue {
        if (args.len == 0) return null;

        // String builtins (1 arg: string)
        if (std.mem.eql(u8, name, "String.length")) {
            const s = self.evaluate(args[0]) orelse return null;
            return switch (s) {
                .string => |v| .{ .int = @intCast(v.len) },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "String.append")) {
            if (args.len != 2) return null;
            const a = self.evaluate(args[0]) orelse return null;
            const b = self.evaluate(args[1]) orelse return null;
            return switch (a) {
                .string => |sa| switch (b) {
                    .string => |sb| blk: {
                        const result = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ sa, sb }) catch return null;
                        break :blk .{ .string = result };
                    },
                    else => null,
                },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "String.charAt")) {
            if (args.len != 2) return null;
            const s = self.evaluate(args[0]) orelse return null;
            const idx = self.evaluate(args[1]) orelse return null;
            return switch (s) {
                .string => |str| switch (idx) {
                    .int => |i| {
                        if (i < 0 or i >= str.len) return null;
                        return .{ .char = str[@intCast(i)] };
                    },
                    else => null,
                },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "String.substring")) {
            if (args.len != 3) return null;
            const s = self.evaluate(args[0]) orelse return null;
            const start = self.evaluate(args[1]) orelse return null;
            const len = self.evaluate(args[2]) orelse return null;
            return switch (s) {
                .string => |str| switch (start) {
                    .int => |si| switch (len) {
                        .int => |li| {
                            const s_usize: usize = @intCast(if (si < 0) 0 else si);
                            const l_usize: usize = @intCast(if (li < 0) 0 else li);
                            const end = @min(s_usize + l_usize, str.len);
                            if (s_usize > str.len) return null;
                            return .{ .string = str[s_usize..end] };
                        },
                        else => null,
                    },
                    else => null,
                },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "String.startsWith")) {
            if (args.len != 2) return null;
            const s = self.evaluate(args[0]) orelse return null;
            const prefix = self.evaluate(args[1]) orelse return null;
            return switch (s) {
                .string => |str| switch (prefix) {
                    .string => |pfx| .{ .bool_val = std.mem.startsWith(u8, str, pfx) },
                    else => null,
                },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "String.endsWith")) {
            if (args.len != 2) return null;
            const s = self.evaluate(args[0]) orelse return null;
            const suffix = self.evaluate(args[1]) orelse return null;
            return switch (s) {
                .string => |str| switch (suffix) {
                    .string => |sfx| .{ .bool_val = std.mem.endsWith(u8, str, sfx) },
                    else => null,
                },
                else => null,
            };
        }

        // List builtins
        if (std.mem.eql(u8, name, "List.length")) {
            const lst = self.evaluate(args[0]) orelse return null;
            return switch (lst) {
                .list => |v| .{ .int = @intCast(v.len) },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "List.head")) {
            const lst = self.evaluate(args[0]) orelse return null;
            return switch (lst) {
                .list => |v| {
                    if (v.len == 0) return null;
                    return v[0];
                },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "List.tail")) {
            const lst = self.evaluate(args[0]) orelse return null;
            return switch (lst) {
                .list => |v| {
                    if (v.len == 0) return null;
                    return .{ .list = v[1..] };
                },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "List.cons")) {
            if (args.len != 2) return null;
            const elem = self.evaluate(args[0]) orelse return null;
            const lst = self.evaluate(args[1]) orelse return null;
            return switch (lst) {
                .list => |v| blk: {
                    var new_list: std.ArrayList(ComptimeValue) = .empty;
                    new_list.append(self.allocator, elem) catch return null;
                    new_list.appendSlice(self.allocator, v) catch return null;
                    break :blk .{ .list = new_list.toOwnedSlice(self.allocator) catch return null };
                },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "List.reverse")) {
            const lst = self.evaluate(args[0]) orelse return null;
            return switch (lst) {
                .list => |v| blk: {
                    var reversed: std.ArrayList(ComptimeValue) = .empty;
                    var i: usize = v.len;
                    while (i > 0) {
                        i -= 1;
                        reversed.append(self.allocator, v[i]) catch return null;
                    }
                    break :blk .{ .list = reversed.toOwnedSlice(self.allocator) catch return null };
                },
                else => null,
            };
        }
        if (std.mem.eql(u8, name, "List.append")) {
            if (args.len != 2) return null;
            const elem = self.evaluate(args[0]) orelse return null;
            const lst = self.evaluate(args[1]) orelse return null;
            return switch (lst) {
                .list => |v| blk: {
                    var new_list: std.ArrayList(ComptimeValue) = .empty;
                    new_list.appendSlice(self.allocator, v) catch return null;
                    new_list.append(self.allocator, elem) catch return null;
                    break :blk .{ .list = new_list.toOwnedSlice(self.allocator) catch return null };
                },
                else => null,
            };
        }

        // Int builtins
        if (std.mem.eql(u8, name, "Int.toString")) {
            const v = self.evaluate(args[0]) orelse return null;
            return switch (v) {
                .int => |i| blk: {
                    const result = std.fmt.allocPrint(self.allocator, "{d}", .{i}) catch return null;
                    break :blk .{ .string = result };
                },
                else => null,
            };
        }

        // Constructor registration: if name matches a known constructor, create value
        if (self.constructors.get(name)) |ctor_info| {
            if (args.len == ctor_info.arity) {
                var ctor_args: [32]ComptimeValue = undefined;
                for (args, 0..) |arg, i| {
                    ctor_args[i] = self.evaluate(arg) orelse return null;
                }
                return .{ .constructor = .{
                    .tag = ctor_info.tag,
                    .args = self.allocator.dupe(ComptimeValue, ctor_args[0..args.len]) catch return null,
                } };
            }
        }

        return null;
    }

    pub fn callComptimeFn(self: *CompileTimeWorld, fn_def: parser.FnDef, args: []const ComptimeValue) ?ComptimeValue {
        if (fn_def.params.len != args.len) return null;

        // Save current values
        var saved: [32]?ComptimeValue = undefined;
        for (fn_def.params, 0..) |param, i| {
            const name = switch (param.pattern) {
                .identifier => |n| n,
                else => return null,
            };
            saved[i] = self.values.get(name);
            self.values.put(name, args[i]) catch return null;
        }

        const result = self.evaluate(fn_def.body);

        // Restore values
        for (fn_def.params, 0..) |param, i| {
            const name = switch (param.pattern) {
                .identifier => |n| n,
                else => unreachable,
            };
            if (saved[i]) |v| {
                self.values.put(name, v) catch {};
            } else {
                _ = self.values.remove(name);
            }
        }

        return result;
    }
};
