const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const llvm = @import("llvm");
const core = llvm.core;
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const codegen_mod = @import("codegen.zig");
const repl_mod = @import("repl.zig");
const module_loader_mod = @import("module_loader.zig");

const VERSION = "0.2.0-alpha";

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn printHelp(io: Io) void {
    const stderr = Io.File.stderr();
    var buffer: [4096]u8 = undefined;
    var w = stderr.writer(io, &buffer);
    w.interface.print(
        \\
        \\Kō v{s}
        \\
        \\Usage:
        \\  ko <file.ko>                Run program
        \\  ko --repl                   Start interactive REPL
        \\  ko --dump-ir <file.ko>      Show generated LLVM IR
        \\  ko --emit-ir <out> <file>   Write LLVM IR to file
        \\  ko --emit-obj <out> <file>  Compile to object file
        \\  ko --emit-exe <out> <file>  Compile to executable
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -v, --version    Show version
        \\
    , .{VERSION}) catch {};
    w.interface.flush() catch {};
}

fn printVersion(io: Io) void {
    const stderr = Io.File.stderr();
    var buffer: [4096]u8 = undefined;
    var w = stderr.writer(io, &buffer);
    w.interface.print("ko {s}\n", .{VERSION}) catch {};
    w.interface.flush() catch {};
}

fn reportError(io: Io, filename: []const u8, loc: ?parser.Loc, comptime fmt: []const u8, args: anytype) void {
    const stderr = Io.File.stderr();
    var buffer: [4096]u8 = undefined;
    var w = stderr.writer(io, &buffer);

    if (loc) |l| {
        w.interface.print("error", .{}) catch {};
        w.interface.print(" at {s}:{d}:{d}", .{ filename, l.line, l.col }) catch {};
        w.interface.print(": ", .{}) catch {};
    } else {
        w.interface.print("error: ", .{}) catch {};
    }
    w.interface.print(fmt, args) catch {};
    w.interface.print("\n", .{}) catch {};
    w.interface.flush() catch {};
}

pub fn main(init: std.process.Init) !void {
    var threaded: Io.Threaded = .init(init.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var mode: enum { run, ir, obj, exe, emit_ir, repl } = .run;
    var filename: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp(io);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            printVersion(io);
            return;
        } else if (std.mem.eql(u8, arg, "--repl")) {
            mode = .repl;
        } else if (std.mem.eql(u8, arg, "--dump-ir")) {
            mode = .ir;
        } else if (std.mem.eql(u8, arg, "--emit-obj")) {
            mode = .obj;
            output = args.next();
        } else if (std.mem.eql(u8, arg, "--emit-exe")) {
            mode = .exe;
            output = args.next();
        } else if (std.mem.eql(u8, arg, "--emit-ir")) {
            mode = .emit_ir;
            output = args.next();
        } else if (filename == null) {
            filename = arg;
        }
    }

    if (mode == .repl) {
        var r = repl_mod.Repl.init(init.arena.allocator());
        defer r.deinit();
        try r.run();
        return;
    }

    const fname = filename orelse {
        printHelp(io);
        std.process.exit(1);
    };

    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, fname, .{}) catch {
        reportError(io, fname, null, "cannot open file '{s}'", .{fname});
        std.process.exit(1);
    };
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    const source = reader.interface.allocRemainingAlignedSentinel(
        init.arena.allocator(),
        .unlimited,
        @enumFromInt(0),
        0,
    ) catch {
        reportError(io, fname, null, "cannot read file '{s}'", .{fname});
        std.process.exit(1);
    };

    const stdout = Io.File.stdout();
    var out_buffer: [4096]u8 = undefined;
    var writer = stdout.writer(io, &out_buffer);

    const timer = nowNs();

    // Parse
    var p = try parser.Parser.init(init.arena.allocator(), source);
    defer p.deinit();
    const prog = p.parse_program() catch |err| {
        if (p.last_error) |ec| {
            reportError(io, fname, ec.loc, "{s}", .{ec.message});
        } else {
            reportError(io, fname, null, "parse error: {s}", .{@errorName(err)});
        }
        std.process.exit(1);
    };
    const parse_time = nowNs() - timer;

    // Typecheck
    // Extract base directory from filename for module resolution
    const base_dir = std.fs.path.dirname(fname) orelse ".";
    // Resolve real executable directory (follows symlinks) for stdlib lookup
    const exe_dir = std.process.executableDirPathAlloc(io, init.arena.allocator()) catch ".";
    var loader = module_loader_mod.ModuleLoader.init(init.arena.allocator(), base_dir, null, exe_dir);
    defer loader.deinit();

    var inferer = typecheck.Inferer.init(init.arena.allocator());
    defer inferer.deinit();
    inferer.module_loader = &loader;
    inferer.inferProgram(&prog) catch |err| {
        if (inferer.last_error) |ec| {
            reportError(io, fname, ec.loc, "{s}", .{ec.message orelse @errorName(err)});
        } else {
            reportError(io, fname, null, "type error: {s}", .{@errorName(err)});
        }
        std.process.exit(1);
    };
    const typecheck_time = nowNs() - timer - parse_time;

    // Codegen
    var cg = codegen_mod.Codegen.init(init.arena.allocator(), "ko_module");
    defer cg.deinit();
    cg.expr_type_tags = &inferer.expr_type_tags;
    cg.module_loader = &loader;
    cg.codegenProgram(prog) catch |err| {
        reportError(io, fname, null, "codegen error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const codegen_time = nowNs() - timer - parse_time - typecheck_time;

    if (mode != .run) {
        const total_ms = @as(f64, @floatFromInt(parse_time + typecheck_time + codegen_time)) / std.time.ns_per_ms;
        const parse_ms = @as(f64, @floatFromInt(parse_time)) / std.time.ns_per_ms;
        const tc_ms = @as(f64, @floatFromInt(typecheck_time)) / std.time.ns_per_ms;
        const cg_ms = @as(f64, @floatFromInt(codegen_time)) / std.time.ns_per_ms;
        try writer.interface.print("compiled {d} defs in {d:.1}ms  parse {d:.1}ms | typecheck {d:.1}ms | codegen {d:.1}ms\n", .{
            prog.definitions.len, total_ms, parse_ms, tc_ms, cg_ms,
        });
        try writer.interface.flush();
    }

    switch (mode) {
        .ir => {
            cg.dumpModule();
        },
        .emit_ir => {
            const ir_str = cg.printModuleToString();
            defer if (ir_str) |r| core.LLVMDisposeMessage(@constCast(r));
            const out_name = output orelse "output.ll";
            const out_file = try cwd.createFile(io, out_name, .{});
            defer out_file.close(io);
            var out_buf: [4096]u8 = undefined;
            var out_writer = out_file.writer(io, &out_buf);
            if (ir_str) |r| {
                try out_writer.interface.writeAll(std.mem.sliceTo(r, 0));
                try out_writer.interface.flush();
            }
            try writer.interface.print("wrote {s}\n", .{out_name});
            try writer.interface.flush();
        },
        .run => {
            cg.module_owned_by_jit = true;
            var jit = try codegen_mod.Jit.init(cg.module, 0);
            defer jit.deinit();
            cg.mapBuiltinsToNative(jit.engine);
            _ = try jit.runMain();
        },
        .obj => {
            const out_name = output orelse "output.o";
            var aot = try codegen_mod.Aot.init();
            defer aot.deinit();
            const emit_result = try aot.emitObjectFile(cg.module, init.arena.allocator());
            const out_file = try cwd.createFile(io, out_name, .{});
            defer out_file.close(io);
            var out_buf: [4096]u8 = undefined;
            var out_writer = out_file.writer(io, &out_buf);
            try out_writer.interface.writeAll(emit_result.data);
            try out_writer.interface.flush();
            try writer.interface.print("wrote {s}\n", .{out_name});
            try writer.interface.flush();
        },
        .exe => {
            const out_name = try init.arena.allocator().dupeZ(u8, output orelse "output");
            const obj_name_slice = try std.fmt.allocPrint(init.arena.allocator(), "{s}.o", .{out_name});
            const obj_name = try init.arena.allocator().dupeZ(u8, obj_name_slice);

            // Emit object file to memory buffer, then write to disk
            cg.module_owned_by_jit = true; // prevent double-free
            var aot = try codegen_mod.Aot.init();
            defer aot.deinit();
            const emit_result = try aot.emitObjectFile(cg.module, init.arena.allocator());
            {
                const obj_file = try cwd.createFile(io, obj_name_slice, .{});
                defer obj_file.close(io);
                var obj_buf: [4096]u8 = undefined;
                var obj_writer = obj_file.writer(io, &obj_buf);
                try obj_writer.interface.writeAll(emit_result.data);
                try obj_writer.interface.flush();
            }

            // Link with platform-appropriate linker
            const os_tag = @import("builtin").os.tag;
            const ld_argv = if (os_tag == .macos) [_][]const u8{
                "ld", "-o", out_name,
                obj_name,
                "-lc", "-lm", "-L/usr/lib", "-L/opt/homebrew/lib",
                "-syslibroot", "`xcrun --show-sdk-path`",
            } else if (os_tag == .linux) [_][]const u8{
                "ld", "/usr/lib/crt1.o", "/usr/lib/crti.o",
                obj_name, "-o", out_name,
                "-lc", "-lm", "/usr/lib/crtn.o",
                "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2",
            } else [_][]const u8{
                "cc", obj_name, "-o", out_name,
                "-lc", "-lm",
            };
            const result = std.process.run(init.arena.allocator(), io, .{
                .argv = &ld_argv,
                .stderr_limit = .unlimited,
                .stdout_limit = .unlimited,
            }) catch |err| {
                reportError(io, fname, null, "failed to link: {}", .{err});
                std.process.exit(1);
            };
            defer {
                init.arena.allocator().free(result.stdout);
                init.arena.allocator().free(result.stderr);
            }
            if (result.term != .exited or result.term.exited != 0) {
                const code: u8 = if (result.term == .exited) result.term.exited else 1;
                reportError(io, fname, null, "linker failed (exit {d})", .{code});
                if (result.stderr.len > 0) {
                    const errw = Io.File.stderr();
                    var ebuf: [4096]u8 = undefined;
                    var ew = errw.writer(io, &ebuf);
                    try ew.interface.writeAll(result.stderr);
                    try ew.interface.flush();
                }
                std.process.exit(1);
            }

            try writer.interface.print("wrote {s}\n", .{out_name});
            try writer.interface.flush();
        },
        .repl => unreachable, // handled earlier
    }
}

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("typecheck.zig");
    _ = @import("codegen.zig");
}
