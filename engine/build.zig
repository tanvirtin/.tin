const std = @import("std");

const TestWiringCheck = struct {
    step: std.Build.Step,

    fn create(b: *std.Build) *TestWiringCheck {
        const self = b.allocator.create(TestWiringCheck) catch @panic("out of memory");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "check test wiring",
                .owner = b,
                .makeFn = make,
            }),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const arena = step.owner.allocator;
        var src = try step.owner.build_root.handle.openDir("src", .{ .iterate = true });
        defer src.close();

        var reachable = std.StringHashMapUnmanaged(void){};
        var queue = std.ArrayListUnmanaged([]const u8){};
        for ([_][]const u8{ "main.zig", "lib/yaml.zig" }) |root| {
            try reachable.put(arena, root, {});
            try queue.append(arena, root);
        }
        while (queue.pop()) |file| {
            const content = try src.readFileAlloc(arena, file, 1 << 22);
            var rest = content;
            while (std.mem.indexOf(u8, rest, "@import(\"")) |i| {
                rest = rest[i + "@import(\"".len ..];
                const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
                const target = rest[0..end];
                if (!std.mem.endsWith(u8, target, ".zig")) continue;
                const resolved = try std.fs.path.resolve(arena, &.{ "/", std.fs.path.dirname(file) orelse "", target });
                const path = resolved[1..];
                if (!reachable.contains(path)) {
                    try reachable.put(arena, path, {});
                    try queue.append(arena, path);
                }
            }
        }

        var walker = try src.walk(arena);
        defer walker.deinit();
        var unwired: usize = 0;
        while (try walker.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const content = try src.readFileAlloc(arena, entry.path, 1 << 22);
            if (std.mem.indexOf(u8, content, "test \"") == null) continue;
            if (reachable.contains(entry.path)) continue;
            std.debug.print("src/{s} contains tests but is not imported from src/main.zig\n", .{entry.path});
            unwired += 1;
        }
        if (unwired > 0) return step.fail("{d} test file(s) not wired into a test root", .{unwired});
    }
};

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
    const install_tin_step = b.step("install-tin", "Install only Tin to the selected prefix");
    install_tin_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

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

    const test_runner_exe = b.addExecutable(.{
        .name = "test_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const expression_suite_exe = b.addExecutable(.{
        .name = "expression_suite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/expression_suite_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    expression_suite_exe.root_module.addImport("yaml", yaml_mod);

    const test_run = b.addRunArtifact(test_runner_exe);
    test_run.addArtifactArg(exe);
    test_run.addArtifactArg(test_yaml_exe);
    test_run.addArtifactArg(bench_exe);
    test_run.addArtifactArg(unit_test);
    test_run.addArtifactArg(flow_test);
    test_run.addArtifactArg(expression_suite_exe);
    test_run.addFileArg(b.path("tests/expression_suite.yml"));

    const test_step = b.step("test", "Run the full suite: unit, integration, YAML spec, flow, benchmarks, and expressions");
    test_step.dependOn(&test_run.step);
    test_step.dependOn(&TestWiringCheck.create(b).step);
}
