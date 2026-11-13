const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const hir_dump = @import("hir_dump.zig");
const repl_mod = @import("repl.zig");
const diagnostics_mod = @import("diagnostics.zig");
const compiler_pipelines = @import("compiler_pipelines.zig");
const compiler_cache = @import("compiler_cache.zig");
const comptime_boundary = @import("comptime_boundary.zig");
const build_options = @import("build_options");
const compiler_frontend = @import("compiler_frontend.zig");

const VERSION = "0.3.2";

const Mode = compiler_pipelines.Mode;

const CliOptions = struct {
    mode: Mode = .run,
    filename: ?[]const u8 = null,
    output: ?[]const u8 = null,
    use_lir: bool = true,
    skip_linearity: bool = false,
    enabled_warnings: diagnostics_mod.WarningSet = .{},
    warnings_as_errors: bool = false,
    target_triple: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
};

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn parseCliOptions(io: Io, args: *std.process.Args.Iterator) CliOptions {
    var options = CliOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp(io);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            printVersion(io);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--repl")) {
            options.mode = .repl;
        } else if (std.mem.eql(u8, arg, "--dump-ir")) {
            options.mode = .ir;
        } else if (std.mem.eql(u8, arg, "--dump-hir")) {
            options.mode = .dump_hir;
        } else if (std.mem.eql(u8, arg, "--dump-lir")) {
            options.mode = .dump_lir;
        } else if (std.mem.eql(u8, arg, "--emit-obj")) {
            options.mode = .obj;
            options.output = args.next();
        } else if (std.mem.eql(u8, arg, "--emit-exe")) {
            options.mode = .exe;
            options.output = args.next();
        } else if (std.mem.eql(u8, arg, "--use-lir")) {
            options.use_lir = true;
        } else if (std.mem.eql(u8, arg, "--use-legacy")) {
            options.use_lir = false;
        } else if (std.mem.eql(u8, arg, "--skip-linearity")) {
            options.skip_linearity = true;
        } else if (std.mem.eql(u8, arg, "--emit-ir")) {
            options.mode = .emit_ir;
            options.output = args.next();
        } else if (std.mem.eql(u8, arg, "--check")) {
            options.mode = .check;
        } else if (std.mem.eql(u8, arg, "--warn")) {
            if (args.next()) |warning_name| {
                if (diagnostics_mod.WarningSet.fromName(warning_name)) |warning_set| {
                    options.enabled_warnings = warning_set;
                } else {
                    reportError(io, "(cli)", null, "unknown warning '{s}'", .{warning_name});
                    std.process.exit(1);
                }
            }
        } else if (std.mem.eql(u8, arg, "-Werror")) {
            options.warnings_as_errors = true;
        } else if (std.mem.eql(u8, arg, "--target")) {
            options.target_triple = args.next();
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            options.cache_dir = args.next();
        } else if (options.filename == null) {
            options.filename = arg;
        }
    }
    return options;
}

fn readSource(io: Io, allocator: std.mem.Allocator, filename: []const u8) ![:0]const u8 {
    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(io, filename, .{});
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    return try reader.interface.allocRemainingAlignedSentinel(
        allocator,
        .unlimited,
        @fromBackingInt(@intCast(0)),
        0,
    );
}

fn parseSource(allocator: std.mem.Allocator, source: [:0]const u8, diags: *diagnostics_mod.DiagnosticList) !parser.Program {
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    p.diagnostics = diags;
    return p.parse_program() catch |err| {
        if (p.last_error) |ec| {
            try diags.addError(ec.message, ec.loc);
        } else {
            try diags.addError(@errorName(err), null);
        }
        return .{ .imports = &.{}, .definitions = &.{}, .package = null };
    };
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
        \\  ko --check <file.ko>        Type-check only (no codegen)
        \\  ko --repl                   Start interactive REPL
        \\  ko --dump-ir <file.ko>      Show generated LLVM IR
        \\  ko --dump-hir <file.ko>     Show HIR (High-level IR)
        \\  ko --dump-lir <file.ko>     Show LIR (Low-level IR)
        \\  ko --emit-ir <out> <file>   Write LLVM IR to file
        \\  ko --emit-obj <out> <file>  Compile to object file
        \\  ko --emit-exe <out> <file>  Compile to executable
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -v, --version    Show version
        \\  --target <triple>  Cross-compile for target (e.g. aarch64-macos, x86_64-windows-gnu)
        \\  --use-legacy     Use legacy AST→LLVM pipeline (frozen, for unsupported features)
        \\  --warn <kind>    Enable warnings (unused, shadow, all)
        \\  -Werror          Treat warnings as errors
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

    if (loc) |l| {
        printSourceLine(io, &w, filename, l);
    }

    w.interface.flush() catch {};
}

fn reportNote(io: Io, filename: []const u8, loc: ?parser.Loc, comptime fmt: []const u8, args: anytype) void {
    const stderr = Io.File.stderr();
    var buffer: [4096]u8 = undefined;
    var w = stderr.writer(io, &buffer);

    if (loc) |l| {
        w.interface.print("  note at {s}:{d}:{d}: ", .{ filename, l.line, l.col }) catch {};
    } else {
        w.interface.print("  note: ", .{}) catch {};
    }
    w.interface.print(fmt, args) catch {};
    w.interface.print("\n", .{}) catch {};
    w.interface.flush() catch {};
}

fn reportHelp(io: Io, filename: []const u8, loc: ?parser.Loc, comptime fmt: []const u8, args: anytype) void {
    const stderr = Io.File.stderr();
    var buffer: [4096]u8 = undefined;
    var w = stderr.writer(io, &buffer);

    if (loc) |l| {
        w.interface.print("  help at {s}:{d}:{d}: ", .{ filename, l.line, l.col }) catch {};
    } else {
        w.interface.print("  help: ", .{}) catch {};
    }
    w.interface.print(fmt, args) catch {};
    w.interface.print("\n", .{}) catch {};
    w.interface.flush() catch {};
}

fn printSourceLine(io: Io, w: anytype, filename: []const u8, loc: parser.Loc) void {
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, filename, .{}) catch return;
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    const source = reader.interface.allocRemainingAlignedSentinel(
        std.heap.page_allocator,
        .unlimited,
        @fromBackingInt(@intCast(0)),
        0,
    ) catch return;
    defer std.heap.page_allocator.free(source);

    var line_num: usize = 1;
    var line_start: usize = 0;
    for (source, 0..) |ch, i| {
        if (ch == '\n') {
            if (line_num == loc.line) {
                const line_end = i;
                const line_content = source[line_start..line_end];
                w.interface.print("  {d} | ", .{loc.line}) catch {};
                w.interface.print("{s}\n", .{line_content}) catch {};

                w.interface.print("  ", .{}) catch {};
                var j: usize = 0;
                while (j < std.fmt.count("{d}", .{loc.line}) + 4) : (j += 1) {
                    w.interface.print(" ", .{}) catch {};
                }
                var col: usize = 1;
                while (col < loc.col) : (col += 1) {
                    w.interface.print(" ", .{}) catch {};
                }
                w.interface.print("^\n", .{}) catch {};
                return;
            }
            line_num += 1;
            line_start = i + 1;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var threaded: Io.Threaded = .init(init.gpa, .{ .environ = init.minimal.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    const options = parseCliOptions(io, &args);
    const mode = options.mode;
    const filename = options.filename;
    const output = options.output;
    const use_lir = options.use_lir;
    const skip_linearity = options.skip_linearity;
    const enabled_warnings = options.enabled_warnings;
    const warnings_as_errors = options.warnings_as_errors;
    const target_triple = options.target_triple;
    var cache = if (options.cache_dir) |directory| compiler_cache.Cache.init(init.arena.allocator(), directory) else null;
    const configuration = comptime_boundary.BuildConfiguration{
        .compiler_build = VERSION,
        .language_version = "1",
        .target = target_triple orelse "native",
        .flags = "debug",
        .representation_version = "repr-1",
        .llvm_version = build_options.llvm_version,
    };

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

    const source = readSource(io, init.arena.allocator(), fname) catch {
        reportError(io, fname, null, "cannot open file '{s}'", .{fname});
        std.process.exit(1);
    };
    const cwd = Io.Dir.cwd();

    const stdout = Io.File.stdout();
    var out_buffer: [4096]u8 = undefined;
    var writer = stdout.writer(io, &out_buffer);

    const timer = nowNs();

    // Create diagnostic list for error accumulation
    var diags = diagnostics_mod.DiagnosticList.init(init.arena.allocator());
    defer diags.deinit();

    // Parse (with error recovery when diagnostics available)
    const prog = try parseSource(init.arena.allocator(), source, &diags);
    const parse_time = nowNs() - timer;

    // If we have parse errors, emit them and exit
    if (diags.has_errors) {
        diags.emitAll(io, fname, source);
        std.process.exit(1);
    }

    var prepared = try compiler_frontend.prepare(
        io,
        init.arena.allocator(),
        fname,
        source,
        prog,
        parse_time,
        timer,
        &diags,
        enabled_warnings,
        skip_linearity,
        warnings_as_errors,
        if (cache) |*value| value else null,
        configuration,
        reportError,
    );
    defer prepared.deinit();
    const typecheck_time = prepared.typecheck_time;

    // Dump HIR if requested
    if (mode == .dump_hir) {
        var hir_dump_buf = std.ArrayList(u8).empty;
        defer hir_dump_buf.deinit(init.arena.allocator());
        try hir_dump.dumpHir(init.arena.allocator(), prepared.hir, &hir_dump_buf);
        try writer.interface.writeAll(hir_dump_buf.items);
        try writer.interface.flush();
        return;
    }

    // --check mode: type-check + linearity-check only, no codegen
    if (mode == .check) {
        return;
    }

    // HIR → LIR → LLVM pipeline (default, with legacy fallback for unsupported features)
    if (use_lir and try compiler_pipelines.runLirPipeline(
        io,
        cwd,
        init.arena.allocator(),
        mode,
        output,
        target_triple,
        fname,
        reportError,
        prepared.hir,
        prepared.inferer,
        if (cache) |*value| value else null,
        configuration,
        comptime_boundary.fingerprint(&.{source}),
        prepared.interface_hash,
        prepared.dependency_hash,
        prepared.comptime_context,
        prepared.comptime_context.cacheable,
    )) return;

    try compiler_pipelines.runLegacyPipeline(
        io,
        cwd,
        init.arena.allocator(),
        &writer,
        mode,
        output,
        target_triple,
        fname,
        reportError,
        prepared.program.definitions.len,
        timer,
        parse_time,
        typecheck_time,
        prepared.program,
        prepared.inferer,
        prepared.loader,
    );
}

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("typecheck.zig");
}
