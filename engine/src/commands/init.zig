const std = @import("std");
const yaml = @import("yaml");
const output = @import("../lib/output.zig");
const fs = @import("../lib/fs.zig");
const Paths = @import("../core/environment/paths.zig").Paths;
const Engine = @import("../schemalang/engine.zig").Engine;

pub const meta = .{
    .name = "init",
    .description = "Create personal configuration without applying it",
};

const template_rel = "environment/examples/tinrc.template.yml";
const sample_rel = "environment/examples/skills/sample.yml";
const default_zed_export = "~/.agents/skills";

pub const Options = struct {
    sample: bool = true,
    export_target: bool = true,
};

pub const Status = enum { created, existing, not_requested };

pub const Outcome = struct {
    config: Status,
    sample: Status,
    export_target: Status,
};

const Creation = struct {
    path: []const u8,
    content: ?[]const u8,
    requested: bool,
    exists: bool,
};

const Plan = struct {
    config: Creation,
    sample: Creation,
    export_target: Creation,
    pending: usize,
};

fn pathPresent(path: []const u8) bool {
    _ = std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

fn zedExportDir(allocator: std.mem.Allocator, template: []const u8, paths: Paths) ![]const u8 {
    const fallback = try paths.absolutePath(allocator, default_zed_export);
    const doc = yaml.parse(allocator, template) catch return fallback;
    const exports_v = doc.getMapping("exports") orelse return fallback;
    const zed_v = exports_v.getMapping("zed") orelse return fallback;
    const dir_v = zed_v.getMapping("dir") orelse return fallback;
    const dir_s = dir_v.getString() orelse return fallback;
    return paths.absolutePath(allocator, dir_s);
}

fn buildPlan(allocator: std.mem.Allocator, paths: Paths, artifacts_dir: []const u8, options: Options) !Plan {
    const config_path = try paths.personalTinrcPath(allocator);
    const config_exists = pathPresent(config_path);

    var template: []const u8 = "";
    if (!config_exists or options.export_target) {
        const template_path = try std.fs.path.join(allocator, &.{ paths.tin_dir, template_rel });
        template = try fs.readFileAlloc(allocator, template_path);
    }

    const export_path = if (options.export_target)
        try zedExportDir(allocator, template, paths)
    else
        try allocator.dupe(u8, "");
    const export_exists = options.export_target and pathPresent(export_path);

    const sample_path = try std.fs.path.join(allocator, &.{ artifacts_dir, "skills", "sample.yml" });
    const sample_exists = options.sample and pathPresent(sample_path);
    var sample_content: ?[]const u8 = null;
    if (options.sample and !sample_exists) {
        const sample_src = try std.fs.path.join(allocator, &.{ paths.tin_dir, sample_rel });
        sample_content = try fs.readFileAlloc(allocator, sample_src);
    }

    const config_content: ?[]const u8 = if (config_exists) null else template;

    var pending: usize = 0;
    if (!config_exists) pending += 1;
    if (options.sample and !sample_exists) pending += 1;
    if (options.export_target and !export_exists) pending += 1;

    return .{
        .config = .{ .path = config_path, .content = config_content, .requested = true, .exists = config_exists },
        .sample = .{ .path = sample_path, .content = sample_content, .requested = options.sample, .exists = sample_exists },
        .export_target = .{ .path = export_path, .content = null, .requested = options.export_target, .exists = export_exists },
        .pending = pending,
    };
}

fn applyPlan(plan: Plan) !Outcome {
    var outcome: Outcome = .{ .config = .existing, .sample = .not_requested, .export_target = .not_requested };

    if (plan.config.exists) {
        outcome.config = .existing;
    } else {
        try fs.ensureParentDirExists(plan.config.path);
        try fs.writeFile(plan.config.path, plan.config.content.?);
        outcome.config = .created;
    }

    if (!plan.sample.requested) {
        outcome.sample = .not_requested;
    } else if (plan.sample.exists) {
        outcome.sample = .existing;
    } else {
        try fs.ensureParentDirExists(plan.sample.path);
        try fs.writeFile(plan.sample.path, plan.sample.content.?);
        outcome.sample = .created;
    }

    if (!plan.export_target.requested) {
        outcome.export_target = .not_requested;
    } else if (plan.export_target.exists) {
        outcome.export_target = .existing;
    } else {
        try fs.ensureDirectoryExists(plan.export_target.path);
        outcome.export_target = .created;
    }

    return outcome;
}

fn promptAllowed(tty: bool, flag: bool, env: bool) bool {
    return tty and !flag and !env;
}

fn envNonInteractive() bool {
    const value = std.posix.getenv("TIN_NONINTERACTIVE") orelse return false;
    return value.len > 0;
}

fn confirm(plan: Plan) bool {
    output.plain("[tin] will create:", .{});
    if (!plan.config.exists) output.plain("  {s}", .{plan.config.path});
    if (plan.sample.requested and !plan.sample.exists) output.plain("  {s}", .{plan.sample.path});
    if (plan.export_target.requested and !plan.export_target.exists) output.plain("  {s}", .{plan.export_target.path});
    output.plain("Proceed? [Y/n] ", .{});
    var buf: [64]u8 = undefined;
    const n = std.fs.File.stdin().read(&buf) catch return true;
    if (n == 0) return true;
    const line = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (line.len == 0) return true;
    return std.ascii.eqlIgnoreCase(line, "y") or std.ascii.eqlIgnoreCase(line, "yes");
}

fn reportOne(label: []const u8, path: []const u8, status: Status) void {
    switch (status) {
        .created => output.success("created {s}: {s}", .{ label, path }),
        .existing => output.info("kept existing {s}: {s}", .{ label, path }),
        .not_requested => {},
    }
}

fn reportPlan(plan: Plan, outcome: Outcome) void {
    reportOne("config", plan.config.path, outcome.config);
    reportOne("sample skill", plan.sample.path, outcome.sample);
    reportOne("Zed export target", plan.export_target.path, outcome.export_target);
    if (plan.pending == 0) output.info("tin is already initialized; nothing to do", .{});
    output.info("nothing was applied; run 'tin install' when you are ready", .{});
}

const ParsedArgs = struct {
    options: Options = .{},
    non_interactive: bool = false,
    help: bool = false,
    unknown: ?[]const u8 = null,
};

fn parseArgs(args: []const []const u8) ParsedArgs {
    var parsed = ParsedArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            parsed.help = true;
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "--non-interactive")) {
            parsed.non_interactive = true;
        } else if (std.mem.eql(u8, arg, "--no-sample")) {
            parsed.options.sample = false;
        } else if (std.mem.eql(u8, arg, "--no-export")) {
            parsed.options.export_target = false;
        } else {
            parsed.unknown = arg;
        }
    }
    return parsed;
}

fn usage() void {
    output.plain("tin init — create personal configuration without applying it", .{});
    output.plain("Usage: tin init [options]", .{});
    output.plain("", .{});
    output.plain("Creates ~/.config/tin/tinrc.yml from the neutral template, a sample", .{});
    output.plain("skill in the artifacts directory, and the Zed export target directory.", .{});
    output.plain("Existing files are never overwritten or removed. Nothing is exported", .{});
    output.plain("or applied; run 'tin install' when you are ready.", .{});
    output.plain("", .{});
    output.plain("Options:", .{});
    output.plain("  -y, --yes, --non-interactive  Never prompt (also when not a TTY)", .{});
    output.plain("  --no-sample                   Skip the sample skill", .{});
    output.plain("  --no-export                   Skip the Zed export target directory", .{});
    output.plain("  -h, --help                    Show this help", .{});
    output.plain("", .{});
    output.plain("Environment: TIN_DIR, TIN_ARTIFACTS, TIN_NONINTERACTIVE", .{});
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const parsed = parseArgs(args);
    if (parsed.help) {
        usage();
        return 0;
    }
    if (parsed.unknown) |arg| {
        output.err("unknown option: {s}", .{arg});
        usage();
        return 2;
    }

    const paths = Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };
    const artifacts_dir = paths.artifactsDir(allocator) catch {
        output.err("could not resolve the artifacts directory", .{});
        return 1;
    };

    const plan = buildPlan(allocator, paths, artifacts_dir, parsed.options) catch {
        output.err("init could not read the neutral template from {s}/{s}", .{ paths.tin_dir, template_rel });
        return 1;
    };

    const interactive = promptAllowed(std.posix.isatty(std.posix.STDIN_FILENO), parsed.non_interactive, envNonInteractive());
    if (interactive and plan.pending > 0 and !confirm(plan)) {
        output.warn("nothing written", .{});
        return 0;
    }

    const outcome = applyPlan(plan) catch {
        output.err("init could not write files", .{});
        return 1;
    };
    reportPlan(plan, outcome);
    return 0;
}

const TestEnv = struct {
    root: []const u8,
    tin_dir: []const u8,
    artifacts_dir: []const u8,
    paths: Paths,
    tmp: std.testing.TmpDir,
};

fn installRuntime(allocator: std.mem.Allocator, tin_dir: []const u8) !void {
    const schemas = [_][]const u8{ "meta-schema.yaml", "tinrc.yaml", "skill.yaml" };
    for (schemas) |name| {
        const src_rel = try std.fs.path.join(allocator, &.{ "src", "schemas", name });
        const dst = try std.fs.path.join(allocator, &.{ tin_dir, "engine", "src", "schemas", name });
        const content = try std.fs.cwd().readFileAlloc(allocator, src_rel, 1 << 20);
        try fs.ensureParentDirExists(dst);
        try fs.writeFile(dst, content);
    }
    const examples = [_][]const u8{ "tinrc.template.yml", "skills/sample.yml" };
    for (examples) |rel| {
        const src_rel = try std.fs.path.join(allocator, &.{ "..", "environment", "examples", rel });
        const dst = try std.fs.path.join(allocator, &.{ tin_dir, "environment", "examples", rel });
        const content = try std.fs.cwd().readFileAlloc(allocator, src_rel, 1 << 20);
        try fs.ensureParentDirExists(dst);
        try fs.writeFile(dst, content);
    }
}

fn setup(allocator: std.mem.Allocator) !TestEnv {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const root = try tmp.parent_dir.realpathAlloc(allocator, &tmp.sub_path);
    const tin_dir = try std.fs.path.join(allocator, &.{ root, ".tin" });
    const artifacts_dir = try std.fs.path.join(allocator, &.{ root, ".config", "tin", "artifacts" });
    try installRuntime(allocator, tin_dir);
    return .{
        .root = root,
        .tin_dir = tin_dir,
        .artifacts_dir = artifacts_dir,
        .paths = Paths{ .tin_dir = tin_dir, .home_dir = root },
        .tmp = tmp,
    };
}

test "init creates a personal config, sample skill, and export target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try setup(a);
    defer env.tmp.cleanup();

    const plan = try buildPlan(a, env.paths, env.artifacts_dir, .{});
    try std.testing.expectEqual(@as(usize, 3), plan.pending);

    const outcome = try applyPlan(plan);
    try std.testing.expectEqual(Status.created, outcome.config);
    try std.testing.expectEqual(Status.created, outcome.sample);
    try std.testing.expectEqual(Status.created, outcome.export_target);

    const config_path = try env.paths.personalTinrcPath(a);
    try std.testing.expect(pathPresent(config_path));
    const template_path = try std.fs.path.join(a, &.{ env.tin_dir, template_rel });
    try std.testing.expectEqualStrings(try fs.readFileAlloc(a, template_path), try fs.readFileAlloc(a, config_path));

    const sample_path = try std.fs.path.join(a, &.{ env.artifacts_dir, "skills", "sample.yml" });
    try std.testing.expect(pathPresent(sample_path));

    const export_path = try env.paths.absolutePath(a, default_zed_export);
    var export_dir = try std.fs.openDirAbsolute(export_path, .{});
    export_dir.close();
}

test "init leaves an existing personal config unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try setup(a);
    defer env.tmp.cleanup();

    const config_path = try env.paths.personalTinrcPath(a);
    try fs.ensureParentDirExists(config_path);
    try fs.writeFile(config_path, "identity:\n  name: Mine\n");

    const plan = try buildPlan(a, env.paths, env.artifacts_dir, .{});
    try std.testing.expectEqual(@as(usize, 2), plan.pending);
    const outcome = try applyPlan(plan);
    try std.testing.expectEqual(Status.existing, outcome.config);
    try std.testing.expectEqualStrings("identity:\n  name: Mine\n", try fs.readFileAlloc(a, config_path));
}

test "init skips an existing sample artifact and export target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try setup(a);
    defer env.tmp.cleanup();

    const sample_path = try std.fs.path.join(a, &.{ env.artifacts_dir, "skills", "sample.yml" });
    try fs.ensureParentDirExists(sample_path);
    try fs.writeFile(sample_path, "keep me\n");
    try fs.ensureDirectoryExists(try env.paths.absolutePath(a, default_zed_export));

    const plan = try buildPlan(a, env.paths, env.artifacts_dir, .{});
    try std.testing.expectEqual(@as(usize, 1), plan.pending);
    const outcome = try applyPlan(plan);
    try std.testing.expectEqual(Status.created, outcome.config);
    try std.testing.expectEqual(Status.existing, outcome.sample);
    try std.testing.expectEqual(Status.existing, outcome.export_target);
    try std.testing.expectEqualStrings("keep me\n", try fs.readFileAlloc(a, sample_path));
}

test "repeated init is idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try setup(a);
    defer env.tmp.cleanup();

    _ = try applyPlan(try buildPlan(a, env.paths, env.artifacts_dir, .{}));

    const config_path = try env.paths.personalTinrcPath(a);
    const sample_path = try std.fs.path.join(a, &.{ env.artifacts_dir, "skills", "sample.yml" });
    const before_config = try fs.readFileAlloc(a, config_path);
    const before_sample = try fs.readFileAlloc(a, sample_path);

    const second_plan = try buildPlan(a, env.paths, env.artifacts_dir, .{});
    try std.testing.expectEqual(@as(usize, 0), second_plan.pending);
    const second = try applyPlan(second_plan);
    try std.testing.expectEqual(Status.existing, second.config);
    try std.testing.expectEqual(Status.existing, second.sample);
    try std.testing.expectEqual(Status.existing, second.export_target);
    try std.testing.expectEqualStrings(before_config, try fs.readFileAlloc(a, config_path));
    try std.testing.expectEqualStrings(before_sample, try fs.readFileAlloc(a, sample_path));
}

test "init can skip the sample skill and export target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try setup(a);
    defer env.tmp.cleanup();

    const plan = try buildPlan(a, env.paths, env.artifacts_dir, .{ .sample = false, .export_target = false });
    try std.testing.expectEqual(@as(usize, 1), plan.pending);
    const outcome = try applyPlan(plan);
    try std.testing.expectEqual(Status.created, outcome.config);
    try std.testing.expectEqual(Status.not_requested, outcome.sample);
    try std.testing.expectEqual(Status.not_requested, outcome.export_target);

    const sample_path = try std.fs.path.join(a, &.{ env.artifacts_dir, "skills", "sample.yml" });
    try std.testing.expect(!pathPresent(sample_path));
}

test "prompting requires an interactive terminal and no override" {
    try std.testing.expect(promptAllowed(true, false, false));
    try std.testing.expect(!promptAllowed(false, false, false));
    try std.testing.expect(!promptAllowed(true, true, false));
    try std.testing.expect(!promptAllowed(true, false, true));
}

test "parseArgs recognizes noninteractive and skip flags" {
    const parsed = parseArgs(&.{ "--non-interactive", "--no-sample", "--no-export" });
    try std.testing.expect(parsed.non_interactive);
    try std.testing.expect(!parsed.options.sample);
    try std.testing.expect(!parsed.options.export_target);
    try std.testing.expect(parsed.unknown == null);

    const help = parseArgs(&.{"-h"});
    try std.testing.expect(help.help);

    const bad = parseArgs(&.{"--bogus"});
    try std.testing.expect(bad.unknown != null);
}

test "shipped sample skill validates against the skill schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas_dir = "src/schemas";

    var engine = try Engine.initWithSchemasDir(a, schemas_dir);
    defer engine.deinit();

    const diagnostics = try engine.validateFile(a, schemas_dir, "skill.yaml", "../environment/examples/skills/sample.yml");
    try std.testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "neutral template validates against the tinrc schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas_dir = "src/schemas";

    var engine = try Engine.initWithSchemasDir(a, schemas_dir);
    defer engine.deinit();

    const diagnostics = try engine.validateFile(a, schemas_dir, "tinrc.yaml", "../environment/examples/tinrc.template.yml");
    try std.testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "shipped example carries no personal identity and no package-installing default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "../environment/tinrc.example.yml";
    const source = try std.fs.cwd().readFileAlloc(a, path, 1 << 20);

    try std.testing.expect(std.ascii.indexOfIgnoreCase(source, "tanvir") == null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(source, "gmail") == null);

    const doc = try yaml.parse(a, source);
    const identity = doc.getMapping("identity") orelse return error.MissingIdentity;
    const email = (identity.getMapping("email") orelse return error.MissingEmail).getString() orelse return error.MissingEmail;
    try std.testing.expect(std.mem.endsWith(u8, email, "@example.com"));
    try std.testing.expect(doc.getMapping("install") == null);
    try std.testing.expect(doc.getMapping("recipes") == null);

    const schemas_dir = "src/schemas";
    var engine = try Engine.initWithSchemasDir(a, schemas_dir);
    defer engine.deinit();
    const diagnostics = try engine.validateFile(a, schemas_dir, "tinrc.yaml", path);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.len);
}
