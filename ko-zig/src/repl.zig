const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const llvm = @import("llvm");
const llvm_engine = llvm.engine;
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const codegen_mod = @import("codegen.zig");

fn rawRead(fd: posix.fd_t, buf: []u8) !usize {
    return posix.read(fd, buf) catch |err| switch (err) {
        error.InputOutput => return error.ReadFailed,
        error.SystemResources => return error.ReadFailed,
        else => return error.ReadFailed,
    };
}

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const rc = if (comptime @import("builtin").os.tag == .linux)
            linux.write(fd, data[pos..].ptr, data.len - pos)
        else
            std.c.write(fd, data[pos..].ptr, data.len - pos);
        if (rc < 0) {
            const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
            switch (e) {
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
        pos += @intCast(rc);
    }
}

fn printStr(fd: posix.fd_t, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(msg);
    try writeAll(fd, msg);
}

fn readLine(fd: posix.fd_t, line_buf: []u8) ![]const u8 {
    var line_len: usize = 0;
    while (line_len < line_buf.len) {
        const n = rawRead(fd, line_buf[line_len .. line_len + 1]) catch |err| {
            if (err == error.EndOfStream) {
                if (line_len > 0) return line_buf[0..line_len];
                return error.ConnectionClosed;
            }
            return err;
        };
        if (n == 0) {
            if (line_len > 0) return line_buf[0..line_len];
            return error.ConnectionClosed;
        }
        if (line_buf[line_len] == '\n') {
            line_len += 1;
            break;
        }
        line_len += 1;
    }
    // Strip trailing \r\n
    while (line_len > 0) {
        const last_ch = line_buf[line_len - 1];
        if (last_ch == '\n' or last_ch == '\r') {
            line_len -= 1;
        } else {
            break;
        }
    }
    return line_buf[0..line_len];
}

pub const Repl = struct {
    allocator: std.mem.Allocator,
    accumulated_source: std.ArrayList(u8),
    eval_counter: usize,

    pub fn init(allocator: std.mem.Allocator) Repl {
        return .{
            .allocator = allocator,
            .accumulated_source = std.ArrayList(u8).empty,
            .eval_counter = 0,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.accumulated_source.deinit(self.allocator);
    }

    pub fn run(self: *Repl) !void {
        const stdout_fd: posix.fd_t = posix.STDOUT_FILENO;
        const stdin_fd: posix.fd_t = posix.STDIN_FILENO;

        try printStr(stdout_fd, "Kō REPL v0.3.0\n", .{});
        try printStr(stdout_fd, "Type expressions to evaluate, definitions to bind.\n", .{});
        try printStr(stdout_fd, "Commands: :quit, :type <expr>, :env, :reset, :help\n\n", .{});

        var line_buf: [4096]u8 = undefined;
        while (true) {
            try printStr(stdout_fd, "ko> ", .{});
            const line = readLine(stdin_fd, &line_buf) catch |err| {
                if (err == error.ConnectionClosed) {
                    try printStr(stdout_fd, "\nBye!\n", .{});
                    break;
                }
                try printStr(stdout_fd, "Error: {}\n", .{err});
                continue;
            };

            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, ":")) {
                self.handleCommand(line, stdout_fd) catch |err| {
                    try printStr(stdout_fd, "Error: {}\n", .{err});
                };
                continue;
            }

            self.evalInput(line, stdout_fd) catch |err| {
                try printStr(stdout_fd, "Error: {}\n", .{err});
            };
        }
    }

    fn evalInput(self: *Repl, input: []const u8, stdout_fd: posix.fd_t) !void {
        const is_def = isDefinition(input);

        if (is_def) {
            var source = std.ArrayList(u8).empty;
            defer source.deinit(self.allocator);

            if (self.accumulated_source.items.len > 0) {
                try source.appendSlice(self.allocator, self.accumulated_source.items);
                try source.append(self.allocator, '\n');
            }
            try source.appendSlice(self.allocator, input);
            try source.append(self.allocator, '\n');

            const source_z = try self.allocator.dupeZ(u8, source.items);
            defer self.allocator.free(source_z);
            var p = try parser.Parser.init(self.allocator, source_z);
            defer p.deinit();
            const prog = try p.parse_program();

            var inferer = typecheck.Inferer.init(self.allocator);
            defer inferer.deinit();
            try inferer.inferProgram(&prog);

            if (self.accumulated_source.items.len > 0) {
                try self.accumulated_source.append(self.allocator, '\n');
            }
            try self.accumulated_source.appendSlice(self.allocator, input);
            try self.accumulated_source.append(self.allocator, '\n');

            try printStr(stdout_fd, "Defined.\n", .{});
        } else {
            const eval_name_raw = try std.fmt.allocPrint(self.allocator, "__repl_eval_{d}", .{self.eval_counter});
            defer self.allocator.free(eval_name_raw);
            const eval_name = try self.allocator.dupeZ(u8, eval_name_raw);
            defer self.allocator.free(eval_name);
            self.eval_counter += 1;

            var source = std.ArrayList(u8).empty;
            defer source.deinit(self.allocator);

            if (self.accumulated_source.items.len > 0) {
                try source.appendSlice(self.allocator, self.accumulated_source.items);
                try source.append(self.allocator, '\n');
            }
            try source.appendSlice(self.allocator, "fn ");
            try source.appendSlice(self.allocator, eval_name);
            try source.appendSlice(self.allocator, " =\n  ");
            try source.appendSlice(self.allocator, input);
            try source.append(self.allocator, '\n');

            const source_z = try self.allocator.dupeZ(u8, source.items);
            defer self.allocator.free(source_z);
            var p = try parser.Parser.init(self.allocator, source_z);
            defer p.deinit();
            const prog = try p.parse_program();

            var inferer = typecheck.Inferer.init(self.allocator);
            defer inferer.deinit();
            try inferer.inferProgram(&prog);

            var cg = codegen_mod.Codegen.init(self.allocator, "ko_repl");
            defer cg.deinit();
            cg.module_owned_by_jit = true;
            cg.quiet = true;
            cg.expr_type_tags = &inferer.expr_type_tags;
            try cg.codegenProgram(prog);

            var jit = try codegen_mod.Jit.init(cg.module, 0);
            defer jit.deinit();
            cg.mapBuiltinsToNative(jit.engine);

            const fn_addr = llvm_engine.LLVMGetFunctionAddress(jit.engine, eval_name.ptr);
            if (fn_addr == 0) {
                try printStr(stdout_fd, "Error: could not find evaluation function\n", .{});
                return;
            }

            const eval_fn: *const fn () callconv(.c) i64 = @ptrFromInt(fn_addr);
            const result = eval_fn();

            try printStr(stdout_fd, "= {d}\n", .{result});
        }
    }

    fn handleCommand(self: *Repl, cmd: []const u8, stdout_fd: posix.fd_t) !void {
        if (std.mem.eql(u8, cmd, ":quit") or std.mem.eql(u8, cmd, ":q")) {
            try printStr(stdout_fd, "Bye!\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, cmd, ":help") or std.mem.eql(u8, cmd, ":h")) {
            try printStr(stdout_fd, "Commands:\n", .{});
            try printStr(stdout_fd, "  :quit, :q       Exit the REPL\n", .{});
            try printStr(stdout_fd, "  :type <expr>    Show the type of an expression\n", .{});
            try printStr(stdout_fd, "  :env            Show accumulated definitions\n", .{});
            try printStr(stdout_fd, "  :reset          Clear accumulated source\n", .{});
            try printStr(stdout_fd, "  :help, :h       Show this help\n", .{});
        } else if (std.mem.eql(u8, cmd, ":env")) {
            if (self.accumulated_source.items.len == 0) {
                try printStr(stdout_fd, "(empty)\n", .{});
            } else {
                try printStr(stdout_fd, "{s}\n", .{self.accumulated_source.items});
            }
        } else if (std.mem.eql(u8, cmd, ":reset")) {
            self.accumulated_source.clearRetainingCapacity();
            self.eval_counter = 0;
            try printStr(stdout_fd, "Reset.\n", .{});
        } else if (std.mem.startsWith(u8, cmd, ":type ")) {
            const expr = cmd[6..];
            if (expr.len == 0) {
                try printStr(stdout_fd, "Usage: :type <expression>\n", .{});
                return;
            }

            var source = std.ArrayList(u8).empty;
            defer source.deinit(self.allocator);

            if (self.accumulated_source.items.len > 0) {
                try source.appendSlice(self.allocator, self.accumulated_source.items);
                try source.append(self.allocator, '\n');
            }
            const type_fn_name = try std.fmt.allocPrint(self.allocator, "__type_query_{d}", .{self.eval_counter});
            defer self.allocator.free(type_fn_name);
            try source.appendSlice(self.allocator, "fn ");
            try source.appendSlice(self.allocator, type_fn_name);
            try source.appendSlice(self.allocator, " =\n  ");
            try source.appendSlice(self.allocator, expr);
            try source.append(self.allocator, '\n');

            const source_z = try self.allocator.dupeZ(u8, source.items);
            defer self.allocator.free(source_z);
            var p = try parser.Parser.init(self.allocator, source_z);
            defer p.deinit();
            const prog = try p.parse_program();

            var inferer = typecheck.Inferer.init(self.allocator);
            defer inferer.deinit();
            inferer.inferProgram(&prog) catch |err| {
                try printStr(stdout_fd, "Error: {}\n", .{err});
                return;
            };

            if (inferer.global.getScheme(type_fn_name)) |scheme| {
                const type_str = try typecheck.typeToString(self.allocator, scheme.body.*);
                defer self.allocator.free(type_str);
                try printStr(stdout_fd, "{s} : {s}\n", .{ expr, type_str });
            } else {
                try printStr(stdout_fd, "Error: could not infer type\n", .{});
            }
        } else {
            try printStr(stdout_fd, "Unknown command: {s}\n", .{cmd});
        }
    }
};

fn isDefinition(input: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, input, " \t");
    if (std.mem.startsWith(u8, trimmed, "fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "type ")) return true;
    if (std.mem.startsWith(u8, trimmed, "let ")) return true;
    if (std.mem.startsWith(u8, trimmed, "module ")) return true;
    if (std.mem.startsWith(u8, trimmed, "pub ")) return true;
    if (std.mem.startsWith(u8, trimmed, "import ")) return true;
    if (std.mem.startsWith(u8, trimmed, "package ")) return true;
    for (trimmed, 0..) |ch, i| {
        if (ch == '(' or ch == ')' or ch == '{' or ch == '}' or ch == '[' or ch == ']') return false;
        if (ch == '=' and i > 0 and trimmed[i - 1] != '!' and trimmed[i - 1] != '<' and trimmed[i - 1] != '>' and trimmed[i - 1] != '=') return true;
    }
    return false;
}
