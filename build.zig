const std = @import("std");

fn linkDependencies(compile: *std.Build.Step.Compile) void {
    compile.linkSystemLibrary("systemd");
    compile.linkSystemLibrary("rocksdb");
    compile.linkSystemLibrary("protobuf-c");
    compile.linkSystemLibrary("nghttp2");

    // Add include path for generated proto headers
    compile.addIncludePath(.{ .cwd_relative = "src/cri/proto" });

    // Add protobuf-c generated C source
    compile.addCSourceFile(.{
        .file = .{ .cwd_relative = "src/cri/proto/api.pb-c.c" },
        .flags = &.{"-std=c11"},
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Executable
    const exe = b.addExecutable(.{
        .name = "systemd-cri",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    linkDependencies(exe);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    linkDependencies(exe_unit_tests);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    linkDependencies(lib_unit_tests);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "lib", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }) },
            },
        }),
    });
    linkDependencies(integration_tests);

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    const integration_step = b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&run_integration_tests.step);

    // Full integration tests (requires root and systemd)
    const full_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/full_integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "lib", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }) },
            },
        }),
    });
    linkDependencies(full_integration_tests);

    const run_full_integration_tests = b.addRunArtifact(full_integration_tests);

    const full_integration_step = b.step("test-full", "Run full integration tests (requires root)");
    full_integration_step.dependOn(&run_full_integration_tests.step);

    // critest runner tool
    const critest_runner = b.addExecutable(.{
        .name = "critest-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/critest_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(critest_runner);

    const run_critest = b.addRunArtifact(critest_runner);
    run_critest.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_critest.addArgs(args);
    }

    const critest_step = b.step("critest", "Run cri-tools tests against systemd-cri");
    critest_step.dependOn(&run_critest.step);
}
