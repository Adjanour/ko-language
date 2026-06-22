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
