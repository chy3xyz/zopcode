const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const framework_dep = b.dependency("framework", .{
        .target = target,
        .optimize = optimize,
    });
    const framework_mod = framework_dep.module("zaibase");

    const lib_mod = b.addModule("zig_opencode", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("framework", framework_mod);

    const exe = b.addExecutable(.{
        .name = "zig-opencode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zig_opencode", lib_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zig-opencode executable");
    run_step.dependOn(&run_cmd.step);

    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    root_tests.root_module.addImport("framework", framework_mod);
    root_tests.root_module.addImport("zig_opencode", lib_mod);

    const run_root_tests = b.addRunArtifact(root_tests);
    if (b.args) |args| {
        run_root_tests.addArgs(args);
    }
    const test_step = b.step("test", "Run zig-opencode unit tests");
    test_step.dependOn(&run_root_tests.step);
}
