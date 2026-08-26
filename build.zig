const std = @import("std");

pub fn build(b: *std.Build) void {
    const installStep = b.getInstallStep();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const isRelease = optimize == .fast or optimize == .small;

    const exe = b.addExecutable(.{
        .name = "ssync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,

            .single_threaded = true,
            .strip = isRelease,
            .stack_check = !isRelease,
            .omit_frame_pointer = isRelease,
            .unwind_tables = if (isRelease) .none else null,
        }),
    });

    const checkStep = b.step("check", "Check without emiting binary");
    checkStep.dependOn(&exe.step);

    const testStep = b.step("test", "Test");

    const testExe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const runTest = b.addRunArtifact(testExe);
    runTest.has_side_effects = true;

    testStep.dependOn(&runTest.step);
    installStep.dependOn(testStep);

    b.installArtifact(exe);
}
