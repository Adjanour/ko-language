const std = @import("std");
const Io = std.Io;
const llvm = @import("llvm");
const core = llvm.core;
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const codegen_mod = @import("codegen.zig");

pub fn main(init: std.process.Init) !void {
    var threaded: Io.Threaded = .init(init.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    var mode: enum { ir, run, obj, exe, emit_ir } = .ir;
    var filename: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--run")) {
            mode = .run;
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

    const fname = filename orelse {
        const stderr = Io.File.stderr();
        var buffer: [4096]u8 = undefined;
        var writer = stderr.writer(io, &buffer);
        try writer.interface.print("Usage: ko [--run | --emit-obj <out.o> | --emit-exe <out> | --emit-ir <out.ll>] <file.ko>\n", .{});
        try writer.interface.flush();
        std.process.exit(1);
    };

    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(io, fname, .{});
    defer file.close(io);

    var file_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    const source = try reader.interface.allocRemainingAlignedSentinel(
        init.arena.allocator(),
        .unlimited,
        @enumFromInt(0),
        0,
    );

    const stdout = Io.File.stdout();
    var out_buffer: [4096]u8 = undefined;
    var writer = stdout.writer(io, &out_buffer);

    // Parse
    var p = try parser.Parser.init(init.arena.allocator(), source);
    defer p.deinit();
    const prog = try p.parse_program();
    try writer.interface.print("Parsed: {d} definitions\n", .{prog.definitions.len});
    try writer.interface.flush();

    // Typecheck
    var inferer = typecheck.Inferer.init(init.arena.allocator());
    defer inferer.deinit();
    inferer.inferProgram(&prog) catch |err| {
        const stderr = Io.File.stderr();
        var err_buf: [4096]u8 = undefined;
        var err_writer = stderr.writer(io, &err_buf);
        if (inferer.last_error) |ec| {
            if (ec.loc) |loc| {
                if (ec.message) |msg| {
                    try err_writer.interface.print("type error at line {d}, col {d}: {s}\n", .{ loc.line, loc.col, msg });
                } else {
                    try err_writer.interface.print("type error at line {d}, col {d}: {s}\n", .{ loc.line, loc.col, @errorName(err) });
                }
            } else if (ec.message) |msg| {
                try err_writer.interface.print("type error: {s}\n", .{msg});
            } else {
                try err_writer.interface.print("type error: {s}\n", .{@errorName(err)});
            }
        } else {
            try err_writer.interface.print("type error: {s}\n", .{@errorName(err)});
        }
        try err_writer.interface.flush();
        std.process.exit(1);
    };
    try writer.interface.print("Typechecked OK\n", .{});
    try writer.interface.flush();

    // Codegen
    var cg = codegen_mod.Codegen.init(init.arena.allocator(), "ko_module");
    defer cg.deinit();
    try cg.codegenProgram(prog);

    switch (mode) {
        .ir => {
            try writer.interface.print("Generated LLVM IR:\n", .{});
            try writer.interface.flush();
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
            try writer.interface.print("Emitted LLVM IR to: {s}\n", .{out_name});
            try writer.interface.flush();
        },
        .run => {
            cg.module_owned_by_jit = true;
            var jit = try codegen_mod.Jit.init(cg.module, 0);
            defer jit.deinit();
            cg.mapBuiltinsToNative(jit.engine);
            const result = try jit.runMain();
            try writer.interface.print("{d}\n", .{result});
            try writer.interface.flush();
        },
        .obj => {
            const out_name_z = try init.arena.allocator().dupeZ(u8, output orelse "output.o");
            var aot = try codegen_mod.Aot.init();
            defer aot.deinit();
            try aot.emitObjectFile(cg.module, out_name_z);
            try writer.interface.print("Emitted object file: {s}\n", .{out_name_z});
            try writer.interface.flush();
        },
        .exe => {
            const out_name = try init.arena.allocator().dupeZ(u8, output orelse "output");
            const obj_name_slice = try std.fmt.allocPrint(init.arena.allocator(), "{s}.o", .{out_name});
            const obj_name = try init.arena.allocator().dupeZ(u8, obj_name_slice);

            // Emit object file
            cg.module_owned_by_jit = true; // prevent double-free
            var aot = try codegen_mod.Aot.init();
            defer aot.deinit();
            try aot.emitObjectFile(cg.module, obj_name);
            try writer.interface.print("Emitted object file: {s}\n", .{obj_name});
            try writer.interface.flush();

            // Link with cc
            // Compile C runtime using gcc with PATH set
            const runtime_obj = init.arena.allocator().dupeZ(u8, "ko_runtime.o") catch unreachable;
            const cc_argv = [_][]const u8{ "/usr/bin/gcc", "-c", "/home/bernard/Learning/weird/ko-zig/src/ko_runtime.c", "-o", runtime_obj };
            const cc_result = std.process.run(init.arena.allocator(), io, .{
                .argv = &cc_argv,
                .stderr_limit = .unlimited,
                .stdout_limit = .unlimited,
            }) catch |err| {
                try writer.interface.print("Failed to compile runtime: {}\n", .{err});
                try writer.interface.flush();
                std.process.exit(1);
            };
            defer {
                init.arena.allocator().free(cc_result.stdout);
                init.arena.allocator().free(cc_result.stderr);
            }
            if (cc_result.term != .exited or cc_result.term.exited != 0) {
                const code: u8 = if (cc_result.term == .exited) cc_result.term.exited else 1;
                try writer.interface.print("Runtime compilation failed (exit code {d}):\n{s}\n{s}\n", .{ code, cc_result.stdout, cc_result.stderr });
                try writer.interface.flush();
                std.process.exit(1);
            }

            // Link with ld (using crt files for proper startup)
            const ld_argv = [_][]const u8{
                "ld", "/usr/lib/crt1.o", "/usr/lib/crti.o",
                obj_name,         runtime_obj, "-o", out_name,
                "-lc", "-lm", "/usr/lib/crtn.o",
                "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2",
            };
            const result = std.process.run(init.arena.allocator(), io, .{
                .argv = &ld_argv,
                .stderr_limit = .unlimited,
                .stdout_limit = .unlimited,
            }) catch |err| {
                try writer.interface.print("Failed to run linker: {}\n", .{err});
                try writer.interface.flush();
                std.process.exit(1);
            };
            defer {
                init.arena.allocator().free(result.stdout);
                init.arena.allocator().free(result.stderr);
            }
            if (result.term != .exited or result.term.exited != 0) {
                const code: u8 = if (result.term == .exited) result.term.exited else 1;
                try writer.interface.print("Linker failed (exit code {d}):\n{s}\n", .{ code, result.stderr });
                try writer.interface.flush();
                std.process.exit(1);
            }

            try writer.interface.print("Emitted executable: {s}\n", .{out_name});
            try writer.interface.flush();
        },
    }
}

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("typecheck.zig");
    _ = @import("codegen.zig");
}
