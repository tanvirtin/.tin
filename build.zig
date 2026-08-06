const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const yaml_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/yaml.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "tin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("yaml", yaml_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_yaml_exe = b.addExecutable(.{
        .name = "test_yaml_one",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_yaml_one.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_yaml_exe.root_module.addImport("yaml", yaml_mod);
    b.installArtifact(test_yaml_exe);

    const run_step = b.step("run", "Run tin");
    run_step.dependOn(&run_cmd.step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_exe.root_module.addImport("yaml", yaml_mod);

    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_run.step);

    const unit_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_test.root_module.addImport("yaml", yaml_mod);

    const flow_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_flow_parse.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    flow_test.root_module.addImport("yaml", yaml_mod);

    const suite_exe = b.addExecutable(.{
        .name = "suite_manager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite_manager.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const suite_run = b.addRunArtifact(suite_exe);
    suite_run.addArtifactArg(exe);
    suite_run.addArtifactArg(test_yaml_exe);
    suite_run.addArtifactArg(bench_exe);
    suite_run.addArtifactArg(unit_test);
    suite_run.addArtifactArg(flow_test);

    const test_step = b.step("test", "Run unit, integration, YAML spec, and performance tests");
    test_step.dependOn(&suite_run.step);
}
