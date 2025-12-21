const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Library linkage (dynamic or static)",
    ) orelse .dynamic;

    // Export the library module for Zig consumers
    const nvshader_mod = b.addModule("nvshader", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C API shared/static library
    const lib = b.addLibrary(.{
        .linkage = linkage,
        .name = "nvshader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Install the library
    b.installArtifact(lib);

    // Install C header
    b.installFile("include/nvshader.h", "include/nvshader.h");

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "nvshader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nvshader", .module = nvshader_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run nvshader CLI");
    run_step.dependOn(&run_cmd.step);

    // Tests for library module
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Tests for C API
    const c_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const run_c_api_tests = b.addRunArtifact(c_api_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_c_api_tests.step);

    // Check step for quick compile verification
    const check_step = b.step("check", "Check if code compiles");
    check_step.dependOn(&lib.step);
    check_step.dependOn(&exe.step);
}
