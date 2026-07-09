const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Kō compiler executable
    const ko_exe = b.addExecutable(.{
        .name = "ko",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    ko_exe.root_module.addImport("llvm", b.createModule(.{
        .root_source_file = b.path("src/llvm/llvm-bindings.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    ko_exe.root_module.linkSystemLibrary("LLVM-22", .{});
    ko_exe.root_module.linkSystemLibrary("z", .{});

    b.installArtifact(ko_exe);

    // REPL step
    const repl_cmd = b.addRunArtifact(ko_exe);
    repl_cmd.step.dependOn(b.getInstallStep());
    repl_cmd.addArgs(&.{"--repl"});
    const repl_step = b.step("repl", "Run the Kō REPL");
    repl_step.dependOn(&repl_cmd.step);

    // Kō LSP server (no LLVM dependency)
    const ko_lsp = b.addExecutable(.{
        .name = "ko-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(ko_lsp);

    const run_lsp = b.addRunArtifact(ko_lsp);
    run_lsp.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_lsp.addArgs(args);
    }
    const lsp_step = b.step("lsp", "Run the Kō LSP server");
    lsp_step.dependOn(&run_lsp.step);

    // Run command
    const run_cmd = b.addRunArtifact(ko_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Kō compiler");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("llvm", b.createModule(.{
        .root_source_file = b.path("src/llvm/llvm-bindings.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    unit_tests.root_module.linkSystemLibrary("LLVM-22", .{});
    unit_tests.root_module.linkSystemLibrary("z", .{});
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
