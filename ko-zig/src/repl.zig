const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Io = std.Io;
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
            if (comptime @import("builtin").os.tag == .linux) {
                const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
                switch (e) {
                    .INTR => continue,
                    else => return error.WriteFailed,
                }
            } else {
                const e = std.c.getErrno(-% @as(isize, @intCast(rc)));
                switch (e) {
                    .INTR => continue,
                    else => return error.WriteFailed,
                }
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

const ko_keywords = [_][]const u8{
    "fn", "let", "if", "then", "else", "match", "type", "import", "package",
    "pub", "module", "ref", "comptime", "not", "and", "or", "true", "false",
};

const ko_builtins = [_][]const u8{
    "println", "print", "inspect", "panic", "assert", "assert_eq",
    "String.length", "String.append", "String.contains", "String.charAt",
    "String.toUpperCase", "String.toLowerCase", "String.trim", "String.replace", "String.split",
    "Int.toString", "Int.abs", "Int.min", "Int.max", "Int.pow", "Int.gcd", "Int.lcm",
    "Int.factorial", "Int.isqrt",
    "Float.ofInt", "Float.toInt", "Float.sqrt", "Float.pow",
    "Float.sin", "Float.cos", "Float.tan", "Float.log", "Float.floor", "Float.ceil", "Float.abs",
    "Result.is_ok", "Result.is_err", "Result.unwrap", "Result.unwrapOr",
    "Result.map", "Result.fold", "Result.and_then",
    "head", "tail", "length", "append", "reverse", "map", "filter",
    "foldl", "foldr", "zip", "concat", "sum", "product",
};

pub const Repl = struct {
    allocator: std.mem.Allocator,
    accumulated_source: std.ArrayList(u8),
    eval_counter: usize,
    history: std.ArrayList([]const u8),
    history_index: ?usize = null,
    history_file_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) Repl {
        const history_path = std.fmt.allocPrint(allocator, "/tmp/.ko_history_{d}", .{@as(u32, @intCast(std.c.getuid()))}) catch "/tmp/.ko_history";
        var r = Repl{
            .allocator = allocator,
            .accumulated_source = std.ArrayList(u8).empty,
            .eval_counter = 0,
            .history = std.ArrayList([]const u8).empty,
            .history_file_path = history_path,
        };
        r.loadHistory() catch {};
        return r;
    }

    pub fn deinit(self: *Repl) void {
        self.saveHistory() catch {};
        self.accumulated_source.deinit(self.allocator);
        for (self.history.items) |h| self.allocator.free(h);
        self.history.deinit(self.allocator);
        self.allocator.free(self.history_file_path);
    }

    fn loadHistory(self: *Repl) !void {
        // Use Io for file operations
        var threaded: Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = Io.Dir.cwd();
        const file = cwd.openFile(io, self.history_file_path, .{}) catch return;
        defer file.close(io);

        var file_buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &file_buffer);
        const content = try reader.interface.allocRemainingAlignedSentinel(
            self.allocator,
            .unlimited,
            @enumFromInt(0),
            0,
        );
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                const owned = try self.allocator.dupe(u8, line);
                try self.history.append(self.allocator, owned);
            }
        }
    }

    fn saveHistory(self: *Repl) !void {
        var threaded: Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = Io.Dir.cwd();
        const file = try cwd.createFile(io, self.history_file_path, .{});
        defer file.close(io);

        var file_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &file_buffer);
        for (self.history.items) |h| {
            try writer.interface.print("{s}\n", .{h});
        }
        try writer.interface.flush();
    }

    fn addToHistory(self: *Repl, line: []const u8) !void {
        // Don't add duplicate of last entry
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }
        const owned = try self.allocator.dupe(u8, line);
        try self.history.append(self.allocator, owned);
        // Reset history navigation index
        self.history_index = null;
    }

    pub fn run(self: *Repl) !void {
        const stdout_fd: posix.fd_t = posix.STDOUT_FILENO;
        const stdin_fd: posix.fd_t = posix.STDIN_FILENO;

        try printStr(stdout_fd, "Kō REPL v0.3.0\n", .{});
        try printStr(stdout_fd, "Type expressions to evaluate, definitions to bind.\n", .{});
        try printStr(stdout_fd, "Commands: :quit, :type <expr>, :env, :reset, :history, :help\n\n", .{});

        var line_buf: [4096]u8 = undefined;
        while (true) {
            try printStr(stdout_fd, "ko> ", .{});
            const line = self.readLineWithCompletion(stdin_fd, &line_buf, stdout_fd) catch |err| {
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

            self.addToHistory(line) catch {};
            self.evalInput(line, stdout_fd) catch |err| {
                try printStr(stdout_fd, "Error: {}\n", .{err});
            };
        }
    }

    fn readLineWithCompletion(self: *Repl, fd: posix.fd_t, line_buf: []u8, stdout_fd: posix.fd_t) ![]const u8 {
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
            const ch = line_buf[line_len];

            // Handle tab completion
            if (ch == '\t') {
                // Find the current word being typed
                var word_start = line_len;
                while (word_start > 0) {
                    const prev = line_buf[word_start - 1];
                    if (prev == ' ' or prev == '\t' or prev == '(' or prev == ')' or prev == ',' or prev == '\n') break;
                    word_start -= 1;
                }
                const prefix = line_buf[word_start..line_len];

                if (prefix.len > 0) {
                    // Find completions and pick the longest common prefix
                    var first_match: ?[]const u8 = null;
                    var match_count: usize = 0;
                    var all_same = true;

                    // Check keywords
                    for (ko_keywords) |kw| {
                        if (std.mem.startsWith(u8, kw, prefix)) {
                            if (first_match == null) {
                                first_match = kw;
                            } else if (all_same and !std.mem.eql(u8, first_match.?, kw)) {
                                all_same = false;
                            }
                            match_count += 1;
                        }
                    }

                    // Check builtins
                    for (ko_builtins) |b| {
                        if (std.mem.startsWith(u8, b, prefix)) {
                            if (first_match == null) {
                                first_match = b;
                            } else if (all_same and !std.mem.eql(u8, first_match.?, b)) {
                                all_same = false;
                            }
                            match_count += 1;
                        }
                    }

                    // Check user-defined names from accumulated source
                    var lines = std.mem.splitScalar(u8, self.accumulated_source.items, '\n');
                    while (lines.next()) |line| {
                        var name: ?[]const u8 = null;
                        // Look for "fn name" patterns
                        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "fn ")) {
                            const trimmed = std.mem.trimStart(u8, line, " \t");
                            const after_fn = trimmed[3..];
                            var name_end: usize = 0;
                            while (name_end < after_fn.len and after_fn[name_end] != ' ' and after_fn[name_end] != '=') : (name_end += 1) {}
                            if (name_end > 0) name = after_fn[0..name_end];
                        }
                        // Look for "let name" patterns
                        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "let ")) {
                            const trimmed = std.mem.trimStart(u8, line, " \t");
                            const after_let = trimmed[4..];
                            var name_end: usize = 0;
                            while (name_end < after_let.len and after_let[name_end] != ' ' and after_let[name_end] != '=' and after_let[name_end] != ':' and after_let[name_end] != '\t') : (name_end += 1) {}
                            if (name_end > 0) name = after_let[0..name_end];
                        }
                        if (name) |nm| {
                            if (std.mem.startsWith(u8, nm, prefix) and nm.len > 0) {
                                // Check for duplicates
                                var is_dup = false;
                                if (first_match) |fm| {
                                    if (std.mem.eql(u8, fm, nm)) is_dup = true;
                                }
                                if (!is_dup) {
                                    if (first_match == null) {
                                        first_match = nm;
                                    } else if (all_same and !std.mem.eql(u8, first_match.?, nm)) {
                                        all_same = false;
                                    }
                                    match_count += 1;
                                }
                            }
                        }
                    }

                    if (match_count == 1 and first_match != null) {
                        // Single match - complete it
                        const completion = first_match.?;
                        const suffix = completion[prefix.len..];
                        if (line_len + suffix.len <= line_buf.len) {
                            // Move existing content after cursor
                            var i: usize = line_len;
                            while (i > word_start) : (i -= 1) {
                                line_buf[i + suffix.len - 1] = line_buf[i - 1];
                            }
                            // Insert completion
                            for (suffix, 0..) |s, idx| {
                                line_buf[word_start + idx] = s;
                            }
                            line_len += suffix.len;
                            // Clear and redraw line
                            try printStr(stdout_fd, "\r\x1b[K", .{});
                            try printStr(stdout_fd, "ko> ", .{});
                            try writeAll(stdout_fd, line_buf[0..line_len]);
                        }
                    } else if (match_count > 1) {
                        // Multiple matches - show them and re-prompt
                        try printStr(stdout_fd, "\n", .{});
                        // Print all matches (keywords + builtins + user defs)
                        var printed: usize = 0;
                        for (ko_keywords) |kw| {
                            if (std.mem.startsWith(u8, kw, prefix)) {
                                if (printed > 0) try printStr(stdout_fd, "  ", .{});
                                try printStr(stdout_fd, "{s}", .{kw});
                                printed += 1;
                            }
                        }
                        for (ko_builtins) |b| {
                            if (std.mem.startsWith(u8, b, prefix)) {
                                if (printed > 0) try printStr(stdout_fd, "  ", .{});
                                try printStr(stdout_fd, "{s}", .{b});
                                printed += 1;
                            }
                        }
                        var lines2 = std.mem.splitScalar(u8, self.accumulated_source.items, '\n');
                        while (lines2.next()) |line| {
                            var name: ?[]const u8 = null;
                            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "fn ")) {
                                const trimmed = std.mem.trimStart(u8, line, " \t");
                                const after_fn = trimmed[3..];
                                var name_end: usize = 0;
                                while (name_end < after_fn.len and after_fn[name_end] != ' ' and after_fn[name_end] != '=') : (name_end += 1) {}
                                if (name_end > 0) name = after_fn[0..name_end];
                            }
                            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "let ")) {
                                const trimmed = std.mem.trimStart(u8, line, " \t");
                                const after_let = trimmed[4..];
                                var name_end: usize = 0;
                                while (name_end < after_let.len and after_let[name_end] != ' ' and after_let[name_end] != '=' and after_let[name_end] != ':' and after_let[name_end] != '\t') : (name_end += 1) {}
                                if (name_end > 0) name = after_let[0..name_end];
                            }
                            if (name) |nm| {
                                if (std.mem.startsWith(u8, nm, prefix) and nm.len > 0) {
                                    // Skip duplicates
                                    var is_dup = false;
                                    for (ko_keywords) |kw| {
                                        if (std.mem.eql(u8, kw, nm)) is_dup = true;
                                    }
                                    for (ko_builtins) |b| {
                                        if (std.mem.eql(u8, b, nm)) is_dup = true;
                                    }
                                    if (!is_dup) {
                                        if (printed > 0) try printStr(stdout_fd, "  ", .{});
                                        try printStr(stdout_fd, "{s}", .{nm});
                                        printed += 1;
                                    }
                                }
                            }
                        }
                        try printStr(stdout_fd, "\nko> ", .{});
                        try writeAll(stdout_fd, line_buf[0..line_len]);
                    }
                }
                continue;
            }

            // Handle escape sequences (arrow keys, etc.)
            if (ch == '\x1b') {
                // Read next char (should be '[')
                var seq_buf: [2]u8 = undefined;
                const seq_n = rawRead(fd, &seq_buf) catch 0;
                if (seq_n == 2 and seq_buf[0] == '[') {
                    const key = seq_buf[1];
                    if (key == 'A') {
                        // Up arrow - previous history
                        if (self.history.items.len > 0) {
                            const new_idx = if (self.history_index) |idx|
                                if (idx > 0) idx - 1 else 0
                            else
                                self.history.items.len - 1;

                            self.history_index = new_idx;
                            const hist_item = self.history.items[new_idx];

                            // Clear current line and replace with history
                            line_len = 0;
                            if (hist_item.len <= line_buf.len) {
                                for (hist_item, 0..) |c, i| {
                                    line_buf[i] = c;
                                }
                                line_len = hist_item.len;
                            }

                            // Clear and redraw line
                            try printStr(stdout_fd, "\r\x1b[K", .{});
                            try printStr(stdout_fd, "ko> ", .{});
                            try writeAll(stdout_fd, line_buf[0..line_len]);
                        }
                    } else if (key == 'B') {
                        // Down arrow - next history
                        if (self.history_index) |idx| {
                            if (idx < self.history.items.len - 1) {
                                const new_idx = idx + 1;
                                self.history_index = new_idx;
                                const hist_item = self.history.items[new_idx];

                                line_len = 0;
                                if (hist_item.len <= line_buf.len) {
                                    for (hist_item, 0..) |c, i| {
                                        line_buf[i] = c;
                                    }
                                    line_len = hist_item.len;
                                }
                            } else {
                                // At end of history, clear line
                                self.history_index = null;
                                line_len = 0;
                            }

                            // Clear and redraw line
                            try printStr(stdout_fd, "\r\x1b[K", .{});
                            try printStr(stdout_fd, "ko> ", .{});
                            try writeAll(stdout_fd, line_buf[0..line_len]);
                        }
                    }
                }
                continue;
            }

            if (ch == '\n') {
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
            try printStr(stdout_fd, "  :history        Show input history\n", .{});
            try printStr(stdout_fd, "  :load <file>    Load a .ko file into the session\n", .{});
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
        } else if (std.mem.eql(u8, cmd, ":history")) {
            if (self.history.items.len == 0) {
                try printStr(stdout_fd, "(no history)\n", .{});
            } else {
                for (self.history.items, 0..) |h, i| {
                    try printStr(stdout_fd, "  {d}: {s}\n", .{ i + 1, h });
                }
            }
        } else if (std.mem.startsWith(u8, cmd, ":load ")) {
            const filename = cmd[6..];
            if (filename.len == 0) {
                try printStr(stdout_fd, "Usage: :load <file.ko>\n", .{});
                return;
            }
            // Read file using raw Linux syscalls
            const fd: i32 = @intCast(linux.open(@ptrCast(filename.ptr), .{}, 0));
            if (fd < 0) {
                try printStr(stdout_fd, "Error opening file\n", .{});
                return;
            }
            defer _ = linux.close(fd);
            var file_buf: [65536]u8 = undefined;
            const buf_ptr: [*]u8 = @ptrCast(&file_buf);
            const n: i32 = @intCast(linux.read(fd, buf_ptr, file_buf.len));
            if (n < 0) {
                try printStr(stdout_fd, "Error reading file\n", .{});
                return;
            }
            const content = file_buf[0..@intCast(n)];

            // Add to accumulated source
            if (self.accumulated_source.items.len > 0) {
                try self.accumulated_source.append(self.allocator, '\n');
            }
            try self.accumulated_source.appendSlice(self.allocator, content);
            try printStr(stdout_fd, "Loaded {s} ({d} bytes)\n", .{ filename, n });
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
