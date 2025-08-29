const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const metal_air = b.addSystemCommand(&.{
        "xcrun","-sdk","macosx","metal",
        "-mmacosx-version-min=13.0",
        "-o","shader.air",
        "-c","metal/shader.metal",
    });

    const metallib = b.addSystemCommand(&.{
        "xcrun","-sdk","macosx","metallib",
        "-o","gvfs.metallib",
        "shader.air",
    });

    metallib.step.dependOn(&metal_air.step);

    const exe = b.addExecutable(.{
        .name = "vfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.addIncludePath(b.path("src"));
    exe.addCSourceFile(.{
        .file = b.path("src/gvfs_metal.m"),
        .flags = &.{ "-fobjc-arc" },
    });

    exe.linkFramework("Metal");
    exe.linkFramework("Foundation");
    exe.step.dependOn(&metallib.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
