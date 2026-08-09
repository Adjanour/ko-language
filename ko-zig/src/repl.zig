const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ln = @import("linenoise");
const llvm = @import("llvm");
const llvm_engine = llvm.engine;
const types = llvm.types;
const engine = llvm.engine;
const core = llvm.core;
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const codegen_mod = @import("codegen.zig");
const codegen_lir = @import("codegen_lir.zig");
const monomorphize_mod = @import("monomorphize.zig");
const hir_lower = @import("hir_lower.zig");
const prettyprint = @import("prettyprint.zig");
const hir_beta = @import("hir_beta.zig");
const hir_let_simpl = @import("hir_let_simpl.zig");
const hir_known_match = @import("hir_known_match.zig");
const hir_fold = @import("hir_fold.zig");
const hir_dce = @import("hir_dce.zig");
const lir_lower = @import("lir_lower.zig");
const stdlib = @import("stdlib.zig");

extern "c" fn fflush(?*anyopaque) c_int;
extern "c" fn setjmp([*]c_int) c_int;
extern "c" fn longjmp([*]c_int, c_int) noreturn;

fn flushStdout() void {
    _ = fflush(null);
}

var g_repl_jmp_buf: [256]c_int = undefined;
var g_repl_allocator: std.mem.Allocator = undefined;
var g_repl_accumulated: *std.ArrayList(u8) = undefined;

fn sigHandler(sig: std.posix.SIG) callconv(.c) void {
    const msg = switch (sig) {
        .INT => "\nInterrupted.\n",
        .ABRT => "\nRuntime panic (abort).\n",
        .SEGV => "\nRuntime panic (segmentation fault).\n",
        else => "\nSignal received.\n",
    };
    _ = linux.write(2, msg.ptr, msg.len);
    flushStdout();
    longjmp(&g_repl_jmp_buf, 1);
}

fn installSignalHandlers() void {
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &sa, null);
    std.posix.sigaction(.ABRT, &sa, null);
    std.posix.sigaction(.SEGV, &sa, null);
}

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const rc = linux.write(fd, data[pos..].ptr, data.len - pos);
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

fn printTo(fd: posix.fd_t, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(msg);
    try writeAll(fd, msg);
}

const ko_keywords = [_][]const u8{
    "fn", "let", "if", "then", "else", "match", "type", "import", "package",
    "pub", "module", "ref", "comptime", "not", "and", "or", "true", "false",
};

const ko_builtins = [_][]const u8{
    "println", "print", "inspect", "panic", "assert", "assert_eq",
    "String.length", "String.append", "String.contains", "String.charAt",
    "String.toUpperCase", "String.toLowerCase", "String.trim", "String.replace", "String.split",
    "String.startsWith", "String.endsWith", "String.substring", "String.indexOf",
    "Int.toString", "Int.abs", "Int.min", "Int.max", "Int.pow", "Int.gcd", "Int.lcm",
    "Int.factorial", "Int.isqrt", "Int.addChecked", "Int.subChecked", "Int.mulChecked", "Int.divChecked", "Int.modChecked", "Int.negChecked", "Int.divOr",
    "Float.ofInt", "Float.toInt", "Float.sqrt", "Float.pow",
    "Float.sin", "Float.cos", "Float.tan", "Float.log", "Float.floor", "Float.ceil", "Float.abs",
    "Result.is_ok", "Result.is_err", "Result.unwrap", "Result.unwrapOr",
    "Result.map", "Result.fold", "Result.and_then",
    "head", "tail", "length", "append", "reverse", "map", "filter",
    "foldl", "foldr", "zip", "concat", "sum", "product",
};

fn koCompletionCallback(buf: [*:0]const u8, completions: *ln.Completions) callconv(.c) void {
    const prefix = std.mem.sliceTo(buf, 0);
    if (prefix.len == 0) return;
    for (ko_keywords) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) {
            ln.addCompletion(completions, @ptrCast(kw.ptr));
        }
    }
    for (ko_builtins) |b| {
        if (std.mem.startsWith(u8, b, prefix)) {
            ln.addCompletion(completions, @ptrCast(b.ptr));
        }
    }
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
        g_repl_allocator = self.allocator;
        g_repl_accumulated = &self.accumulated_source;

        installSignalHandlers();

        ln.setMultiLine(1);
        ln.setCompletionCallback(koCompletionCallback);
        _ = ln.historySetMaxLen(1000);

        const home_ptr = std.c.getenv("HOME");
        const home = if (home_ptr) |ptr| std.mem.sliceTo(ptr, 0) else "/tmp";
        const history_path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/.ko_history", .{home}, 0);
        defer self.allocator.free(history_path);
        _ = ln.historyLoad(history_path.ptr);

        const stdout_fd: posix.fd_t = posix.STDOUT_FILENO;
        try writeAll(stdout_fd, "Ko REPL v0.3.2 (LIR pipeline + Linenoise)\n");
        try writeAll(stdout_fd, "Type expressions to evaluate, definitions to bind.\n");
        try writeAll(stdout_fd, "Commands: :quit, :type <expr>, :env, :reset, :help\n");
        try writeAll(stdout_fd, "Line editing: Ctrl-A/E, Ctrl-K/U/W, Tab, Up/Down\n\n");

        while (true) {
            const jmp_ret = setjmp(&g_repl_jmp_buf);
            if (jmp_ret != 0) {
                try writeAll(stdout_fd, "\n");
            }

            const line_ptr = ln.linenoise("ko> ") orelse {
                try writeAll(stdout_fd, "\nBye!\n");
                break;
            };
            defer ln.linenoiseFree(line_ptr);

            const line = std.mem.sliceTo(line_ptr, 0);
            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, ":")) {
                self.handleCommand(line, stdout_fd) catch |err| {
                    try printTo(stdout_fd, "Error: {}\n", .{err});
                };
                continue;
            }

            const input = try self.readMultiLine(line);
            defer self.allocator.free(input);

            if (input.len == 0) continue;

            _ = ln.historyAdd(line_ptr);
            _ = ln.historySave(history_path.ptr);

            self.addToHistory(input) catch {};

            self.evalInput(input, stdout_fd) catch |err| {
                try printTo(stdout_fd, "Error: {}\n", .{err});
            };
        }
    }

    fn readMultiLine(self: *Repl, first_line: []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, first_line);

        var bracket_depth: i32 = 0;
        var needs_body = false;

        while (true) {
            // Count brackets in current buffer
            bracket_depth = 0;
            for (buf.items) |ch| {
                if (ch == '(' or ch == '{' or ch == '[') bracket_depth += 1;
                if (ch == ')' or ch == '}' or ch == ']') bracket_depth -= 1;
            }

            // Check if line needs a body (ends with = or then without else)
            const trimmed = std.mem.trimEnd(u8, buf.items, " \t");
            needs_body = false;
            if (trimmed.len > 0) {
                const last_ch = trimmed[trimmed.len - 1];
                if (last_ch == '=') {
                    needs_body = true;
                } else if (std.mem.endsWith(u8, trimmed, "then")) {
                    // Check if there's an else after then
                    const then_pos = std.mem.lastIndexOf(u8, trimmed, "then") orelse 0;
                    const after_then = trimmed[then_pos + 4 ..];
                    if (std.mem.indexOf(u8, after_then, "else") == null) {
                        needs_body = true;
                    }
                }
            }

            // If brackets are balanced and no body needed, try parsing
            if (bracket_depth <= 0 and !needs_body) {
                const source_z = try self.allocator.dupeZ(u8, buf.items);
                defer self.allocator.free(source_z);

                if (parser.Parser.init(self.allocator, source_z)) |p| {
                    var parser_inst = p;
                    defer parser_inst.deinit();
                    if (parser_inst.parse_program()) |_| {
                        // Parse succeeded — input is complete
                        break;
                    } else |_| {
                        // Parse error — might be incomplete input
                    }
                } else |_| {
                    // Parser init failed — likely incomplete input
                }
            }

            // Need more input
            try buf.append(self.allocator, '\n');
            const cont_ptr = ln.linenoise("... ") orelse break;
            defer ln.linenoiseFree(cont_ptr);
            const cont = std.mem.sliceTo(cont_ptr, 0);
            if (cont.len == 0) break; // Empty line terminates multi-line
            try buf.appendSlice(self.allocator, cont);
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    fn addToHistory(self: *Repl, input: []const u8) !void {
        if (isDefinition(input)) {
            if (self.accumulated_source.items.len > 0) {
                try self.accumulated_source.append(self.allocator, '\n');
            }
            try self.accumulated_source.appendSlice(self.allocator, input);
            try self.accumulated_source.append(self.allocator, '\n');
        }
    }

    fn evalInput(self: *Repl, input: []const u8, stdout_fd: posix.fd_t) !void {
        if (isDefinition(input)) {
            try writeAll(stdout_fd, "Defined.\n");
            return;
        }

        const eval_name_raw = try std.fmt.allocPrint(self.allocator, "__repl_eval_{d}", .{self.eval_counter});
        defer self.allocator.free(eval_name_raw);
        const eval_name = try self.allocator.dupeZ(u8, eval_name_raw);
        defer self.allocator.free(eval_name);
        self.eval_counter += 1;

        var source = std.ArrayList(u8).empty;
        defer source.deinit(self.allocator);

        var fn_defs = std.ArrayList(u8).empty;
        defer fn_defs.deinit(self.allocator);
        var let_bindings = std.ArrayList(u8).empty;
        defer let_bindings.deinit(self.allocator);

        if (self.accumulated_source.items.len > 0) {
            var lines = std.mem.splitScalar(u8, self.accumulated_source.items, '\n');
            var in_fn_body = false;
            while (lines.next()) |line| {
                const trimmed_line = std.mem.trimStart(u8, line, " \t");
                if (trimmed_line.len == 0) {
                    in_fn_body = false;
                    continue;
                }
                if (std.mem.startsWith(u8, trimmed_line, "fn ") or
                    std.mem.startsWith(u8, trimmed_line, "type "))
                {
                    try fn_defs.appendSlice(self.allocator, line);
                    try fn_defs.append(self.allocator, '\n');
                    const trimmed_end = std.mem.trimEnd(u8, trimmed_line, " \t");
                    in_fn_body = trimmed_end.len > 0 and trimmed_end[trimmed_end.len - 1] == '=';
                } else if (in_fn_body) {
                    try fn_defs.appendSlice(self.allocator, line);
                    try fn_defs.append(self.allocator, '\n');
                    if (line.len > 0 and line[0] != ' ' and line[0] != '\t') {
                        in_fn_body = false;
                    }
                } else {
                    try let_bindings.appendSlice(self.allocator, "  ");
                    try let_bindings.appendSlice(self.allocator, line);
                    try let_bindings.append(self.allocator, '\n');
                }
            }
        }

        try source.appendSlice(self.allocator, fn_defs.items);
        try source.appendSlice(self.allocator, "fn ");
        try source.appendSlice(self.allocator, eval_name);
        try source.appendSlice(self.allocator, " =\n");
        try source.appendSlice(self.allocator, let_bindings.items);
        try source.appendSlice(self.allocator, "  ");
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

        var hl = hir_lower.HirLower.init(self.allocator, &inferer);
        defer hl.deinit();
        try hl.lowerProgram(&prog);

        var beta = hir_beta.HirBeta.init(self.allocator, &hl.expressions);
        beta.run();
        var let_simpl = hir_let_simpl.HirLetSimpl.init(self.allocator, &hl.expressions);
        let_simpl.run();
        var known = hir_known_match.HirKnownMatch.init(self.allocator, &hl.expressions);
        known.run();
        var fold = hir_fold.HirFold.init(self.allocator, &hl.expressions);
        fold.run();
        var dce = hir_dce.HirDce.init(self.allocator, &hl.expressions);
        dce.run(hl.roots.items);

        var ll = lir_lower.LirLower.init(self.allocator, hl.expressions.items, hl.defs.items, &inferer);
        defer ll.deinit();
        const lir_fns = try ll.lowerProgram();

        var lcg = codegen_lir.CodegenLir.init(self.allocator, "ko_repl");
        defer lcg.deinit();
        lcg.declareRuntime();
        try lcg.codegenProgram(lir_fns);

        lcg.module_owned_by_jit = true;
        var jit = try codegen_mod.Jit.init(lcg.module, 0);
        defer jit.deinit();
        mapLirJitFns(lcg.module, jit.engine);

        const fn_addr = llvm_engine.LLVMGetFunctionAddress(jit.engine, eval_name.ptr);
        if (fn_addr == 0) {
            try writeAll(stdout_fd, "Error: could not find evaluation function\n");
            return;
        }

        const eval_fn: *const fn () callconv(.c) i64 = @ptrFromInt(fn_addr);

        const trimmed_input = std.mem.trimStart(u8, input, " \t");
        const is_side_effect = blk: {
            if (std.mem.startsWith(u8, trimmed_input, "println")) break :blk true;
            if (std.mem.startsWith(u8, trimmed_input, "print ")) break :blk true;
            if (std.mem.startsWith(u8, trimmed_input, "inspect")) break :blk true;
            if (std.mem.startsWith(u8, trimmed_input, "panic")) break :blk true;
            if (std.mem.startsWith(u8, trimmed_input, "assert")) break :blk true;
            for (trimmed_input, 0..) |ch, i| {
                if (ch == ':' and i + 1 < trimmed_input.len and trimmed_input[i + 1] == '=') break :blk true;
            }
            break :blk false;
        };

        const result = eval_fn();
        flushStdout();

        if (!is_side_effect) {
            // Pretty-print the result using inspectValue
            const result_str = blk: {
                // Get the eval function's body type
                const last_def = prog.definitions[prog.definitions.len - 1];
                const fd = last_def.fn_def;
                // Walk down blocks to find the innermost expression
                var inner = fd.body;
                while (true) {
                    switch (inner.*) {
                        .block => |blk| {
                            if (blk.items.len > 0) {
                                inner = blk.items[blk.items.len - 1];
                                continue;
                            }
                        },
                        else => {},
                    }
                    break;
                }
                const raw_ty = inferer.expr_types.get(inner) orelse
                    inferer.expr_types.get(fd.body);
                // Resolve type variables to their concrete types
                const result_ty = if (raw_ty) |ty| resolve: {
                    var cur = ty;
                    while (cur.* == .variable) {
                        if (cur.variable.instance) |inst| {
                            cur = inst;
                        } else break;
                    }
                    break :resolve cur;
                } else null;
                if (result_ty) |ty| {
                    // Build ctor_tag_names from inferer.ctors
                    var ctor_tag_names = std.StringHashMap(std.AutoHashMap(u8, []const u8)).init(self.allocator);
                    defer {
                        var it = ctor_tag_names.iterator();
                        while (it.next()) |entry| {
                            entry.value_ptr.deinit();
                        }
                        ctor_tag_names.deinit();
                    }
                    var ctors_it = inferer.ctors.iterator();
                    while (ctors_it.next()) |entry| {
                        const type_name = entry.value_ptr.type_name;
                        const tag = entry.value_ptr.tag;
                        var inner_map = ctor_tag_names.get(type_name) orelse std.AutoHashMap(u8, []const u8).init(self.allocator);
                        try inner_map.put(tag, entry.key_ptr.*);
                        try ctor_tag_names.put(type_name, inner_map);
                    }
                    break :blk prettyprint.inspectValue(self.allocator, result, ty, &ctor_tag_names, &inferer.ctors) catch
                        try std.fmt.allocPrint(self.allocator, "{d}", .{result});
                }
                break :blk try std.fmt.allocPrint(self.allocator, "{d}", .{result});
            };
            defer self.allocator.free(result_str);
            try printTo(stdout_fd, "= {s}\n", .{result_str});
        }
    }

    fn mapLirJitFns(mod: types.LLVMModuleRef, jit_engine: types.LLVMExecutionEngineRef) void {
        const result_names = [_][*:0]const u8{
            "ko_result_is_ok", "ko_result_is_err", "ko_result_unwrap", "ko_result_unwrap_or",
            "ko_result_map", "ko_result_fold", "ko_result_and_then",
            "ko_panic", "ko_panic_str", "ko_assert", "ko_assert_eq",
        };
        const result_ptrs = [_]*const anyopaque{
            @ptrCast(&stdlib.ko_result_is_ok),
            @ptrCast(&stdlib.ko_result_is_err),
            @ptrCast(&stdlib.ko_result_unwrap_panic),
            @ptrCast(&stdlib.ko_result_unwrap_or),
            @ptrCast(&stdlib.ko_result_map),
            @ptrCast(&stdlib.ko_result_fold),
            @ptrCast(&stdlib.ko_result_and_then),
            @ptrCast(&stdlib.ko_panic),
            @ptrCast(&stdlib.ko_panic_str),
            @ptrCast(&stdlib.ko_assert),
            @ptrCast(&stdlib.ko_assert_eq),
        };
        for (result_names, result_ptrs) |name, impl| {
            if (core.LLVMGetNamedFunction(mod, name)) |fn_val| {
                engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(impl));
            }
        }
    }

    fn handleCommand(self: *Repl, cmd: []const u8, stdout_fd: posix.fd_t) !void {
        if (std.mem.eql(u8, cmd, ":quit") or std.mem.eql(u8, cmd, ":q") or std.mem.eql(u8, cmd, ":exit")) {
            try writeAll(stdout_fd, "Bye!\n");
            std.process.exit(0);
        } else if (std.mem.eql(u8, cmd, ":help") or std.mem.eql(u8, cmd, ":h")) {
            try writeAll(stdout_fd, "Commands:\n");
            try writeAll(stdout_fd, "  :quit, :q, :exit  Exit the REPL\n");
            try writeAll(stdout_fd, "  :type <expr>      Show the type of an expression\n");
            try writeAll(stdout_fd, "  :env              Show accumulated definitions\n");
            try writeAll(stdout_fd, "  :reset            Clear accumulated source\n");
            try writeAll(stdout_fd, "  :help, :h         Show this help\n");
            try writeAll(stdout_fd, "\nLine editing (Linenoise):\n");
            try writeAll(stdout_fd, "  Ctrl-A/E          Move to start/end of line\n");
            try writeAll(stdout_fd, "  Ctrl-K            Kill from cursor to end of line\n");
            try writeAll(stdout_fd, "  Ctrl-U            Kill from cursor to start of line\n");
            try writeAll(stdout_fd, "  Ctrl-W            Delete word before cursor\n");
            try writeAll(stdout_fd, "  Ctrl-Y            Yank (paste) last killed text\n");
            try writeAll(stdout_fd, "  Tab               Autocomplete keywords and builtins\n");
            try writeAll(stdout_fd, "  Up/Down           Navigate command history\n");
        } else if (std.mem.eql(u8, cmd, ":env")) {
            if (self.accumulated_source.items.len == 0) {
                try writeAll(stdout_fd, "(empty)\n");
            } else {
                try printTo(stdout_fd, "{s}\n", .{self.accumulated_source.items});
            }
        } else if (std.mem.eql(u8, cmd, ":reset")) {
            self.accumulated_source.clearRetainingCapacity();
            self.eval_counter = 0;
            try writeAll(stdout_fd, "Reset.\n");
        } else if (std.mem.startsWith(u8, cmd, ":type ")) {
            const expr = cmd[6..];
            if (expr.len == 0) {
                try writeAll(stdout_fd, "Usage: :type <expression>\n");
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
                try printTo(stdout_fd, "Error: {}\n", .{err});
                return;
            };

            if (inferer.global.getScheme(type_fn_name)) |scheme| {
                const type_str = try typecheck.typeToString(self.allocator, scheme.body.*);
                defer self.allocator.free(type_str);
                try printTo(stdout_fd, "{s} : {s}\n", .{ expr, type_str });
            } else {
                try writeAll(stdout_fd, "Error: could not infer type\n");
            }
        } else {
            try printTo(stdout_fd, "Unknown command: {s}\n", .{cmd});
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
