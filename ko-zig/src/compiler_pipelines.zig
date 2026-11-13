const std = @import("std");
const Io = std.Io;
const compat = @import("compat.zig");
const llvm = @import("llvm");
const core = llvm.core;
const types = llvm.types;
const engine = llvm.engine;
const stdlib = @import("stdlib.zig");
const codegen_mod = @import("codegen.zig");
const parser = @import("parser.zig");
const hir_lower = @import("hir_lower.zig");
const typecheck = @import("typecheck.zig");
const lir_lower = @import("lir_lower.zig");
const lir_liveness = @import("lir_liveness.zig");
const codegen_lir = @import("codegen_lir.zig");
const hir_dump = @import("hir_dump.zig");
const lir_dump = @import("lir_dump.zig");
const module_loader_mod = @import("module_loader.zig");
const compiler_cache = @import("compiler_cache.zig");
const comptime_boundary = @import("comptime_boundary.zig");

pub const Mode = enum { run, ir, obj, exe, emit_ir, repl, check, dump_hir, dump_lir };

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
pub fn runLirPipeline(
    io: Io,
    cwd: Io.Dir,
    allocator: std.mem.Allocator,
    mode: Mode,
    output: ?[]const u8,
    target_triple: ?[]const u8,
    filename: []const u8,
    report_error: anytype,
    hir: *hir_lower.HirLower,
    inferer: *typecheck.Inferer,
    cache: ?*compiler_cache.Cache,
    configuration: comptime_boundary.BuildConfiguration,
    source_hash: u64,
    interface_hash: u64,
    dependency_hash: u64,
    comptime_context: *comptime_boundary.Context,
    cacheable: bool,
) !bool {
    var l = lir_lower.LirLower.init(allocator, hir.expressions.items, hir.defs.items, inferer);
    defer l.deinit();
    const lir_fns = l.lowerProgram() catch |err| {
        if (err == error.Unsupported) {
            report_error(io, filename, null, "LIR: unsupported feature, falling back to legacy codegen", .{});
            return false;
        }
        report_error(io, filename, null, "LIR lowering error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    try lir_liveness.run(allocator, lir_fns);

    var stdout = Io.File.stdout();
    var output_buffer: [4096]u8 = undefined;
    var writer = stdout.writer(io, &output_buffer);

    if (mode == .dump_lir) {
        var dump = std.ArrayList(u8).empty;
        defer dump.deinit(allocator);
        try lir_dump.dumpLir(allocator, &l, &dump);
        try writer.interface.writeAll(dump.items);
        try writer.interface.flush();
        return true;
    }

    const object_key = comptime_boundary.cacheKey(.object, .{
        .compiler_build = configuration.compiler_build,
        .language_version = configuration.language_version,
        .target = configuration.target,
        .flags = configuration.flags,
        .module_id = filename,
        .source_hash = source_hash,
        .interface_hash = interface_hash,
        .dependency_hash = dependency_hash,
        .stdlib_hash = 0,
        .comptime_input_hash = 0,
        .representation_version = configuration.representation_version,
        .llvm_version = configuration.llvm_version,
    });
    if (mode == .obj) {
        if (!cacheable) {
            if (cache != null) try comptime_context.cacheMiss("object", object_key, "opaque_comptime");
        } else if (cache) |store| {
            const cached_result = store.get(io, cwd, .object, object_key) catch |err| blk: switch (err) {
                error.CorruptArtifact => {
                    try comptime_context.cacheMiss("object", object_key, "corrupt_artifact");
                    break :blk null;
                },
                else => return err,
            };
            if (cached_result) |cached| {
                defer allocator.free(cached);
                try comptime_context.cacheHit("object", object_key);
                const output_name = output orelse "output.o";
                const file = try cwd.createFile(io, output_name, .{});
                defer file.close(io);
                var file_buffer: [4096]u8 = undefined;
                var file_writer = file.writer(io, &file_buffer);
                try file_writer.interface.writeAll(cached);
                try file_writer.interface.flush();
                return true;
            }
            try comptime_context.cacheMiss("object", object_key, "source_changed");
        }
    }

    var codegen = codegen_lir.CodegenLir.init(allocator, "ko_module");
    defer codegen.deinit();
    if (target_triple) |triple| codegen.setTargetTriple(triple);
    codegen.declareRuntime();
    codegen.codegenProgram(lir_fns) catch |err| {
        report_error(io, filename, null, "LIR codegen error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    switch (mode) {
        .ir => core.LLVMDumpModule(codegen.module),
        .emit_ir => {
            const ir = try codegen.printToString();
            const output_name = output orelse "output.ll";
            const file = try cwd.createFile(io, output_name, .{});
            defer file.close(io);
            var file_buffer: [4096]u8 = undefined;
            var file_writer = file.writer(io, &file_buffer);
            try file_writer.interface.writeAll(ir);
            try file_writer.interface.flush();
            try writer.interface.print("wrote {s}\n", .{output_name});
            try writer.interface.flush();
        },
        .run => {
            codegen.module_owned_by_jit = true;
            var jit = try codegen_mod.Jit.init(codegen.module, 0);
            defer jit.deinit();
            mapLirJitResultFns(codegen.module, jit.engine);
            _ = try jit.runMain();
        },
        .obj => {
            const output_name = output orelse "output.o";
            const object = try codegen_lir.emitObjectFile(codegen.module, allocator);
            const file = try cwd.createFile(io, output_name, .{});
            defer file.close(io);
            var file_buffer: [4096]u8 = undefined;
            var file_writer = file.writer(io, &file_buffer);
            try file_writer.interface.writeAll(object);
            try file_writer.interface.flush();
            if (cacheable) {
                if (cache) |store| {
                    try store.put(io, cwd, .object, object_key, object);
                    try comptime_context.artifactProduced("object", object);
                }
            }
            try writer.interface.print("wrote {s}\n", .{output_name});
            try writer.interface.flush();
        },
        .exe => {
            const output_name = try compat.dupeZ(allocator, output orelse "output");
            const object_name = try std.fmt.allocPrint(allocator, "{s}.o", .{output_name});
            const object = try codegen_lir.emitObjectFile(codegen.module, allocator);
            {
                const file = try cwd.createFile(io, object_name, .{});
                defer file.close(io);
                var file_buffer: [4096]u8 = undefined;
                var file_writer = file.writer(io, &file_buffer);
                try file_writer.interface.writeAll(object);
                try file_writer.interface.flush();
            }

            const linker_args: []const []const u8 = if (target_triple) |triple|
                &.{ "zig", "cc", "-target", triple, object_name, "-o", output_name, "-lc", "-lm" }
            else
                &.{ "zig", "cc", object_name, "-o", output_name, "-lc", "-lm" };
            const result = std.process.run(allocator, io, .{
                .argv = linker_args,
                .stderr_limit = .unlimited,
                .stdout_limit = .unlimited,
            }) catch |err| {
                report_error(io, filename, null, "failed to link: {}", .{err});
                std.process.exit(1);
            };
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
            if (result.term != .exited or result.term.exited != 0) {
                const code: u8 = if (result.term == .exited) result.term.exited else 1;
                report_error(io, filename, null, "linker failed (exit {d})", .{code});
                if (result.stderr.len > 0) {
                    var error_buffer: [4096]u8 = undefined;
                    var error_writer = Io.File.stderr().writer(io, &error_buffer);
                    try error_writer.interface.writeAll(result.stderr);
                    try error_writer.interface.flush();
                }
                std.process.exit(1);
            }
            try writer.interface.print("wrote {s}\n", .{output_name});
            try writer.interface.flush();
        },
        .check, .repl, .dump_hir, .dump_lir => unreachable,
    }
    return true;
}

/// Runs the frozen AST → LLVM backend. This remains available only as a
/// compatibility fallback while LIR gains support for the remaining features.
pub fn runLegacyPipeline(
    io: Io,
    cwd: Io.Dir,
    allocator: std.mem.Allocator,
    writer: anytype,
    mode: Mode,
    output: ?[]const u8,
    target_triple: ?[]const u8,
    filename: []const u8,
    report_error: anytype,
    source_definitions: usize,
    timer: u64,
    parse_time: u64,
    typecheck_time: u64,
    program: parser.Program,
    inferer: *typecheck.Inferer,
    loader: *module_loader_mod.ModuleLoader,
) !void {
    var codegen = codegen_mod.Codegen.init(allocator, "ko_module");
    defer codegen.deinit();
    codegen.expr_type_tags = &inferer.expr_type_tags;
    codegen.expr_elem_tags = &inferer.expr_elem_tags;
    codegen.param_arity = &inferer.param_arity;
    codegen.var_type_tags = &inferer.var_type_tags;
    codegen.module_loader = loader;
    codegen.codegenProgram(program) catch |err| {
        report_error(io, filename, null, "codegen error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const codegen_time = nowNs() - timer - parse_time - typecheck_time;

    if (mode != .run) {
        const total_ms = @as(f64, @floatFromInt(parse_time + typecheck_time + codegen_time)) / std.time.ns_per_ms;
        const parse_ms = @as(f64, @floatFromInt(parse_time)) / std.time.ns_per_ms;
        const typecheck_ms = @as(f64, @floatFromInt(typecheck_time)) / std.time.ns_per_ms;
        const codegen_ms = @as(f64, @floatFromInt(codegen_time)) / std.time.ns_per_ms;
        try writer.interface.print("compiled {d} defs in {d:.1}ms  parse {d:.1}ms | typecheck {d:.1}ms | codegen {d:.1}ms\n", .{
            source_definitions, total_ms, parse_ms, typecheck_ms, codegen_ms,
        });
        try writer.interface.flush();
    }

    switch (mode) {
        .ir => codegen.dumpModule(),
        .emit_ir => {
            const ir = codegen.printModuleToString();
            defer if (ir) |value| core.LLVMDisposeMessage(@constCast(value));
            const output_name = output orelse "output.ll";
            const file = try cwd.createFile(io, output_name, .{});
            defer file.close(io);
            var file_buffer: [4096]u8 = undefined;
            var file_writer = file.writer(io, &file_buffer);
            if (ir) |value| {
                try file_writer.interface.writeAll(std.mem.sliceTo(value, 0));
                try file_writer.interface.flush();
            }
            try writer.interface.print("wrote {s}\n", .{output_name});
            try writer.interface.flush();
        },
        .run => {
            codegen.module_owned_by_jit = true;
            var jit = try codegen_mod.Jit.init(codegen.module, 0);
            defer jit.deinit();
            codegen.mapBuiltinsToNative(jit.engine);
            _ = try jit.runMain();
        },
        .obj => {
            const output_name = output orelse "output.o";
            var aot = try codegen_mod.Aot.init();
            defer aot.deinit();
            const object = try aot.emitObjectFile(codegen.module, allocator);
            const file = try cwd.createFile(io, output_name, .{});
            defer file.close(io);
            var file_buffer: [4096]u8 = undefined;
            var file_writer = file.writer(io, &file_buffer);
            try file_writer.interface.writeAll(object.data);
            try file_writer.interface.flush();
            try writer.interface.print("wrote {s}\n", .{output_name});
            try writer.interface.flush();
        },
        .exe => {
            const output_name = try compat.dupeZ(allocator, output orelse "output");
            const object_name = try std.fmt.allocPrint(allocator, "{s}.o", .{output_name});

            if (target_triple != null) {
                report_error(io, filename, null, "--target requires the LIR pipeline (remove --use-legacy)", .{});
                std.process.exit(1);
            }

            codegen.module_owned_by_jit = true;
            var aot = try codegen_mod.Aot.init();
            defer aot.deinit();
            const object = try aot.emitObjectFile(codegen.module, allocator);
            {
                const file = try cwd.createFile(io, object_name, .{});
                defer file.close(io);
                var file_buffer: [4096]u8 = undefined;
                var file_writer = file.writer(io, &file_buffer);
                try file_writer.interface.writeAll(object.data);
                try file_writer.interface.flush();
            }

            const linker_args: []const []const u8 = &.{ "zig", "cc", object_name, "-o", output_name, "-lc", "-lm" };
            const result = std.process.run(allocator, io, .{
                .argv = linker_args,
                .stderr_limit = .unlimited,
                .stdout_limit = .unlimited,
            }) catch |err| {
                report_error(io, filename, null, "failed to link: {}", .{err});
                std.process.exit(1);
            };
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
            if (result.term != .exited or result.term.exited != 0) {
                const code: u8 = if (result.term == .exited) result.term.exited else 1;
                report_error(io, filename, null, "linker failed (exit {d})", .{code});
                if (result.stderr.len > 0) {
                    var error_buffer: [4096]u8 = undefined;
                    var error_writer = Io.File.stderr().writer(io, &error_buffer);
                    try error_writer.interface.writeAll(result.stderr);
                    try error_writer.interface.flush();
                }
                std.process.exit(1);
            }
            try writer.interface.print("wrote {s}\n", .{output_name});
            try writer.interface.flush();
        },
        .repl, .check, .dump_hir, .dump_lir => unreachable,
    }
}

fn mapLirJitResultFns(mod: types.LLVMModuleRef, jit_engine: types.LLVMExecutionEngineRef) void {
    const result_names = [_][*:0]const u8{
        "ko_result_is_ok", "ko_result_is_err", "ko_result_unwrap",   "ko_result_unwrap_or",
        "ko_result_map",   "ko_result_fold",   "ko_result_and_then", "ko_panic",
        "ko_panic_str",    "ko_assert",        "ko_assert_eq",
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
    const io_names = [_][*:0]const u8{
        "ko_io_read_file",   "ko_io_write_file", "ko_io_append_file",
        "ko_io_file_exists", "ko_io_file_size",  "ko_io_mkdir",
        "ko_io_rm",          "ko_io_cp",         "ko_io_mv",
        "ko_io_readdir",     "ko_io_read_line",  "ko_io_eprintln",
        "ko_io_eprint",      "ko_io_get_env",
    };
    const io_ptrs = [_]*const anyopaque{
        @ptrCast(&stdlib.ko_io_read_file),
        @ptrCast(&stdlib.ko_io_write_file),
        @ptrCast(&stdlib.ko_io_append_file),
        @ptrCast(&stdlib.ko_io_file_exists),
        @ptrCast(&stdlib.ko_io_file_size),
        @ptrCast(&stdlib.ko_io_mkdir),
        @ptrCast(&stdlib.ko_io_rm),
        @ptrCast(&stdlib.ko_io_cp),
        @ptrCast(&stdlib.ko_io_mv),
        @ptrCast(&stdlib.ko_io_readdir),
        @ptrCast(&stdlib.ko_io_read_line),
        @ptrCast(&stdlib.ko_io_eprintln),
        @ptrCast(&stdlib.ko_io_eprint),
        @ptrCast(&stdlib.ko_io_get_env),
    };
    for (io_names, io_ptrs) |name, impl| {
        if (core.LLVMGetNamedFunction(mod, name)) |fn_val| {
            engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(impl));
        }
    }
}
