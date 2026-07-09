const std = @import("std");
const parser = @import("parser.zig");

pub const ComptimeValue = union(enum) {
    int: i64,
    float: f64,
    bool_val: bool,
    char: u8,
    string: []const u8,
    unit: void,

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
        };
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
            .max_eval_depth = 1000,
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
            .fn_call => |call| blk: {
                // Only handle calls to identifiers (not arbitrary expressions)
                if (call.func.* != .identifier) break :blk null;
                const name = call.func.identifier.name;

                // Check if it's a comptime function
                const fn_def = self.functions.get(name) orelse break :blk null;
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
            .comptime_expr => |inner| self.evaluate(inner),
            else => null,
        };
    }

    fn evalBinaryOp(self: *CompileTimeWorld, op: parser.BinaryOp, left: ComptimeValue, right: ComptimeValue) ?ComptimeValue {
        _ = self;
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
            else => null,
        };
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
