const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const llvm = @import("llvm");
const core = llvm.core;
const types = llvm.types;
const engine = llvm.engine;
const stdlib = @import("stdlib.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const codegen_mod = @import("codegen.zig");
const hir_lower = @import("hir_lower.zig");
const hir_fold = @import("hir_fold.zig");
const hir_dce = @import("hir_dce.zig");
const hir_check = @import("hir_check.zig");
const hir_beta = @import("hir_beta.zig");
const hir_let_simpl = @import("hir_let_simpl.zig");
const hir_known_match = @import("hir_known_match.zig");
const lir_lower = @import("lir_lower.zig");
const codegen_lir = @import("codegen_lir.zig");
const hir_dump = @import("hir_dump.zig");
const lir_dump = @import("lir_dump.zig");
const linearity_mod = @import("linearity.zig");
const repl_mod = @import("repl.zig");
const module_loader_mod = @import("module_loader.zig");
const diagnostics_mod = @import("diagnostics.zig");
const monomorphize_mod = @import("monomorphize.zig");

const VERSION = "0.3.0-alpha";

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn hasWarnings(diags: *const diagnostics_mod.DiagnosticList) bool {
    for (diags.items.items) |d| {
        if (d.severity == .warning) return true;
    }
    return false;
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
        \\  ko --dump-lir <file.ko>     Show LIR (Low-level IR) [requires --use-lir]
        \\  ko --emit-ir <out> <file>   Write LLVM IR to file
        \\  ko --emit-obj <out> <file>  Compile to object file
        \\  ko --emit-exe <out> <file>  Compile to executable
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -v, --version    Show version
        \\  --use-lir        Use experimental HIR→LIR→LLVM pipeline
        \\                   (run/--dump-ir/--emit-ir only)
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

fn mapLirJitResultFns(mod: types.LLVMModuleRef, jit_engine: types.LLVMExecutionEngineRef) void {
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

fn printSourceLine(io: Io, w: anytype, filename: []const u8, loc: parser.Loc) void {
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, filename, .{}) catch return;
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    const source = reader.interface.allocRemainingAlignedSentinel(
        std.heap.page_allocator,
        .unlimited,
        @enumFromInt(0),
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
    var threaded: Io.Threaded = .init(init.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var mode: enum { run, ir, obj, exe, emit_ir, repl, check, dump_hir, dump_lir } = .run;
    var filename: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    var use_lir = false;
    var skip_linearity = false;
    var enabled_warnings = diagnostics_mod.WarningSet{};
    var warnings_as_errors = false;
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
        } else if (std.mem.eql(u8, arg, "--dump-hir")) {
            mode = .dump_hir;
        } else if (std.mem.eql(u8, arg, "--dump-lir")) {
            mode = .dump_lir;
        } else if (std.mem.eql(u8, arg, "--emit-obj")) {
            mode = .obj;
            output = args.next();
        } else if (std.mem.eql(u8, arg, "--emit-exe")) {
            mode = .exe;
            output = args.next();
        } else if (std.mem.eql(u8, arg, "--use-lir")) {
            use_lir = true;
        } else if (std.mem.eql(u8, arg, "--skip-linearity")) {
            skip_linearity = true;
        } else if (std.mem.eql(u8, arg, "--emit-ir")) {
            mode = .emit_ir;
            output = args.next();
        } else if (std.mem.eql(u8, arg, "--check")) {
            mode = .check;
        } else if (std.mem.eql(u8, arg, "--warn")) {
            if (args.next()) |w| {
                if (diagnostics_mod.WarningSet.fromName(w)) |ws| {
                    enabled_warnings = ws;
                } else {
                    reportError(io, "(cli)", null, "unknown warning '{s}'", .{w});
                    std.process.exit(1);
                }
            }
        } else if (std.mem.eql(u8, arg, "-Werror")) {
            warnings_as_errors = true;
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

    // Create diagnostic list for error accumulation
    var diags = diagnostics_mod.DiagnosticList.init(init.arena.allocator());
    defer diags.deinit();

    // Parse (with error recovery when diagnostics available)
    var p = try parser.Parser.init(init.arena.allocator(), source);
    defer p.deinit();
    p.diagnostics = &diags;
    var prog = p.parse_program() catch |err| blk: {
        if (p.last_error) |ec| {
            try diags.addError(ec.message, ec.loc);
        } else {
            try diags.addError(@errorName(err), null);
        }
        // Return a dummy program so we can emit diagnostics below
        break :blk parser.Program{
            .imports = &.{},
            .definitions = &.{},
            .package = null,
        };
    };
    const parse_time = nowNs() - timer;

    // If we have parse errors, emit them and exit
    if (diags.has_errors) {
        diags.emitAll(io, fname, source);
        std.process.exit(1);
    }

    // Monomorphization: instantiate polymorphic functions to concrete types
    // Per frozen pipeline: parse → monomorphize → bidirectional-typecheck → linearity-check → codegen
    var mono = monomorphize_mod.Monomorphizer.init(init.arena.allocator());
    defer mono.deinit();
    const mono_result = mono.run(prog) catch |err| {
        std.log.err("Monomorphization error: {}", .{err});
        return err;
    };

    // Replace program definitions with monomorphized versions
    // and append specialized function definitions
    const combined = try init.arena.allocator().alloc(parser.Definition, mono_result.definitions.len + mono_result.specialized_fns.len);
    for (mono_result.definitions, 0..) |def, i| {
        combined[i] = def;
    }
    for (mono_result.specialized_fns, 0..) |spec_fn, i| {
        combined[mono_result.definitions.len + i] = .{ .fn_def = spec_fn };
    }
    prog.definitions = combined;

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
    inferer.diagnostics = &diags;
    inferer.enabled_warnings = enabled_warnings;
    inferer.inferProgram(&prog) catch |err| {
        if (inferer.last_error) |ec| {
            try diags.addErrorCtx(
                ec.message orelse @errorName(err),
                ec.loc,
                ec.note,
                ec.help,
            );
        } else {
            try diags.addError(@errorName(err), null);
        }
    };
    const typecheck_time = nowNs() - timer - parse_time;

    // If we have errors, emit them and exit
    if (diags.has_errors) {
        diags.emitAll(io, fname, source);
        std.process.exit(1);
    }

    // HIR lowering (needed for both --dump-hir and --use-lir paths)
    var hl = hir_lower.HirLower.init(init.arena.allocator(), &inferer);
    defer hl.deinit();
    hl.lowerProgram(&prog) catch |err| {
        reportError(io, fname, null, "HIR lowering error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // Linearity check: verify linear variables are used exactly once
    // Must run BEFORE optimization passes (let_simpl, fold, etc.) which may
    // create duplicate bindings that shadow originals, causing false positives.
    if (!skip_linearity) {
        var linearity = linearity_mod.LinearityChecker.init(init.arena.allocator(), &hl.expressions, &diags);
        defer linearity.deinit();
        linearity.run(hl.roots.items, hl.defs.items);
        if (diags.has_errors) {
            diags.emitAll(io, fname, source);
            std.process.exit(1);
        }
    }

    // HIR optimization passes
    var beta = hir_beta.HirBeta.init(init.arena.allocator(), &hl.expressions);
    beta.run();
    // Check for compile-time errors (e.g., division by zero with literal operands)
    // Must run BEFORE let_simpl which propagates constants
    var check = hir_check.HirCheck.init(init.arena.allocator(), &hl.expressions, &diags);
    check.run();
    // Emit any compile-time errors found by HIR check
    if (diags.has_errors) {
        diags.emitAll(io, fname, source);
        std.process.exit(1);
    }
    // Emit warnings from HIR check (e.g., redundant conditions, integer overflow)
    if (hasWarnings(&diags)) {
        diags.emitAll(io, fname, source);
    }
    // Check if warnings should be treated as errors
    if (warnings_as_errors and hasWarnings(&diags)) {
        std.process.exit(1);
    }
    var let_simpl = hir_let_simpl.HirLetSimpl.init(init.arena.allocator(), &hl.expressions);
    let_simpl.run();
    var known = hir_known_match.HirKnownMatch.init(init.arena.allocator(), &hl.expressions);
    known.run();
    var fold = hir_fold.HirFold.init(init.arena.allocator(), &hl.expressions);
    fold.run();
    var dce = hir_dce.HirDce.init(init.arena.allocator(), &hl.expressions);
    dce.run(hl.roots.items);

    // Dump HIR if requested
    if (mode == .dump_hir) {
        var hir_dump_buf = std.ArrayList(u8).empty;
        defer hir_dump_buf.deinit(init.arena.allocator());
        try hir_dump.dumpHir(init.arena.allocator(), &hl, &hir_dump_buf);
        try writer.interface.writeAll(hir_dump_buf.items);
        try writer.interface.flush();
        return;
    }

    // --check mode: type-check + linearity-check only, no codegen
    if (mode == .check) {
        return;
    }

    // Experimental HIR → LIR → LLVM pipeline (--use-lir)
    if (use_lir) {
        var ll = lir_lower.LirLower.init(init.arena.allocator(), hl.expressions.items, hl.defs.items, &inferer);
        defer ll.deinit();
        const lir_fns = ll.lowerProgram() catch |err| {
            reportError(io, fname, null, "LIR lowering error: {s}", .{@errorName(err)});
            std.process.exit(1);
        };

        // Dump LIR if requested
        if (mode == .dump_lir) {
            var lir_dump_buf = std.ArrayList(u8).empty;
            defer lir_dump_buf.deinit(init.arena.allocator());
            try lir_dump.dumpLir(init.arena.allocator(), &ll, &lir_dump_buf);
            try writer.interface.writeAll(lir_dump_buf.items);
            try writer.interface.flush();
            return;
        }

        var lcg = codegen_lir.CodegenLir.init(init.arena.allocator(), "ko_module");
        defer lcg.deinit();
        lcg.declareRuntime();
        lcg.codegenProgram(lir_fns) catch |err| {
            reportError(io, fname, null, "LIR codegen error: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        switch (mode) {
            .ir => core.LLVMDumpModule(lcg.module),
            .emit_ir => {
                const ir_str = try lcg.printToString();
                const out_name = output orelse "output.ll";
                const out_file = try cwd.createFile(io, out_name, .{});
                defer out_file.close(io);
                var out_buf: [4096]u8 = undefined;
                var out_writer = out_file.writer(io, &out_buf);
                try out_writer.interface.writeAll(ir_str);
                try out_writer.interface.flush();
                try writer.interface.print("wrote {s}\n", .{out_name});
                try writer.interface.flush();
            },
            .run => {
                lcg.module_owned_by_jit = true;
                var jit = try codegen_mod.Jit.init(lcg.module, 0);
                defer jit.deinit();
                // Map Result native functions for JIT
                mapLirJitResultFns(lcg.module, jit.engine);
                _ = try jit.runMain();
            },
            .obj, .exe => {
                reportError(io, fname, null, "--use-lir does not support AOT modes yet", .{});
                std.process.exit(1);
            },
            .check, .repl, .dump_hir, .dump_lir => unreachable,
        }
        return;
    }

    // Codegen (legacy AST→LLVM path)
    var cg = codegen_mod.Codegen.init(init.arena.allocator(), "ko_module");
    defer cg.deinit();
    cg.expr_type_tags = &inferer.expr_type_tags;
    cg.expr_elem_tags = &inferer.expr_elem_tags;
    cg.param_arity = &inferer.param_arity;
    cg.var_type_tags = &inferer.var_type_tags;
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
        .repl, .check, .dump_hir, .dump_lir => unreachable, // handled earlier
    }
}

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("typecheck.zig");
    _ = @import("codegen.zig");
}
