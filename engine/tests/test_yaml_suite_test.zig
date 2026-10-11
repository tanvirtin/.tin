const std = @import("std");
const build_options = @import("build_options");

const suite_exe = build_options.suite_exe;
const fixture_exe = build_options.fixture_exe;

const Run = struct {
    code: u8,
    output: []const u8,
};

fn parsePin(content: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "revision=")) {
            return std.mem.trim(u8, line["revision=".len..], " \t\r");
        }
    }
    return null;
}

fn baseOut(allocator: std.mem.Allocator) ![]const u8 {
    const raw = std.process.getEnvVarOwned(allocator, "PATH") catch return "/usr/bin:/bin";
    defer allocator.free(raw);
    if (raw.len == 0) return "/usr/bin:/bin";
    return allocator.dupe(u8, raw);
}

fn makeEnv(allocator: std.mem.Allocator, extras: []const [2][]const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(allocator);
    const path = try baseOut(allocator);
    defer allocator.free(path);
    try env.put("PATH", path);
    for (extras) |kv| try env.put(kv[0], kv[1]);
    return env;
}

fn runSuite(allocator: std.mem.Allocator, args: []const []const u8, extras: []const [2][]const u8) !Run {
    var env = try makeEnv(allocator, extras);
    defer env.deinit();

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    try argv.append(allocator, suite_exe);
    for (args) |a| try argv.append(allocator, a);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .env_map = &env,
        .max_output_bytes = 1 << 20,
    });
    const merged = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr });
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    const code: u8 = switch (result.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .output = merged };
}

fn expectCode(expected: u8, run: Run) !void {
    try std.testing.expectEqual(expected, run.code);
}

fn expectContains(needle: []const u8, run: Run) !void {
    if (std.mem.indexOf(u8, run.output, needle) == null) {
        std.debug.print("output did not contain {s}. output:\n{s}\n", .{ needle, run.output });
        return error.MissingOutput;
    }
}

fn expectNotContains(needle: []const u8, run: Run) !void {
    if (std.mem.indexOf(u8, run.output, needle) != null) {
        std.debug.print("output unexpectedly contained {s}. output:\n{s}\n", .{ needle, run.output });
        return error.UnexpectedOutput;
    }
}

fn mkCase(allocator: std.mem.Allocator, root: std.fs.Dir, rel: []const u8, reject: bool) !void {
    try root.makePath(rel);
    const in_yaml = try std.fs.path.join(allocator, &.{ rel, "in.yaml" });
    defer allocator.free(in_yaml);
    try root.writeFile(.{ .sub_path = in_yaml, .data = "a: 1\n" });
    if (reject) {
        const err_path = try std.fs.path.join(allocator, &.{ rel, "error" });
        defer allocator.free(err_path);
        try root.writeFile(.{ .sub_path = err_path, .data = "" });
    }
}

fn tmpRoot(allocator: std.mem.Allocator) !struct { tmp: std.testing.TmpDir, base: []const u8 } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    return .{ .tmp = tmp, .base = base };
}

fn pinnedRevision(allocator: std.mem.Allocator) ![]const u8 {
    const raw = try std.fs.cwd().readFileAlloc(allocator, "tests/yaml-suite-revision.txt", 4096);
    defer allocator.free(raw);
    return allocator.dupe(u8, parsePin(raw) orelse "unpinned");
}

test "passing corpus is discovered and counted" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try mkCase(allocator, root.tmp.dir, "ok/ok-case", false);
    try mkCase(allocator, root.tmp.dir, "ok/err-case", true);
    try mkCase(allocator, root.tmp.dir, "ok/nested/00-ok", false);
    try mkCase(allocator, root.tmp.dir, "ok/nested/01-err", true);

    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{});
    defer allocator.free(run.output);
    try expectCode(0, run);
    try expectContains("Total: 4/4", run);
    try expectNotContains("FAIL", run);
    const pin = try pinnedRevision(allocator);
    defer allocator.free(pin);
    try expectContains(pin, run);
}

test "crash on any case fails the run" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try mkCase(allocator, root.tmp.dir, "crash/valid/case-crash", false);
    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("expected accept, got crash (exit 3)", run);
}

test "crash is never counted as expected rejection" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try mkCase(allocator, root.tmp.dir, "crash/err-crash", true);
    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("expected reject, got crash (exit 3)", run);
}

test "timeout on a valid case fails the run" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try mkCase(allocator, root.tmp.dir, "timeout/valid/case-hang", false);
    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{.{ "TIN_YAML_TIMEOUT", "1" }});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("expected accept, got timeout", run);
}

test "timeout is never counted as expected rejection" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try mkCase(allocator, root.tmp.dir, "timeout/err-hang", true);
    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{.{ "TIN_YAML_TIMEOUT", "1" }});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("expected reject, got timeout", run);
}

test "accepting invalid yaml fails the run" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try mkCase(allocator, root.tmp.dir, "misaccept/err-misaccept", true);
    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("expected reject, got accept", run);
}

test "rejecting valid yaml fails the run" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try mkCase(allocator, root.tmp.dir, "misreject/case-misreject", false);
    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("expected accept, got reject", run);
}

test "empty corpus is rejected" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try root.tmp.dir.makePath("empty");
    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("no in.yaml cases", run);
}

test "wrong-layout corpus is rejected" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try root.tmp.dir.makePath("wrong/src");
    try root.tmp.dir.writeFile(.{ .sub_path = "wrong/src/229Q.yaml", .data = "a: 1\n" });
    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("no in.yaml cases", run);
}

test "missing corpus directory is rejected" {
    const allocator = std.testing.allocator;
    const gone = try std.fs.path.join(allocator, &.{ "/tmp", "tin-missing-corpus-does-not-exist" });
    defer allocator.free(gone);
    const run = try runSuite(allocator, &.{ fixture_exe, gone }, &.{});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("corpus directory not found", run);
}

test "missing binary is rejected" {
    const allocator = std.testing.allocator;
    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try mkCase(allocator, root.tmp.dir, "ok/ok-case", false);
    const gone_bin = try std.fs.path.join(allocator, &.{ root.base, "no-such-binary" });
    defer allocator.free(gone_bin);
    const run = try runSuite(allocator, &.{ gone_bin, root.base }, &.{});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("binary not found", run);
}

test "no corpus is skipped locally" {
    const allocator = std.testing.allocator;
    const run = try runSuite(allocator, &.{fixture_exe}, &.{});
    defer allocator.free(run.output);
    try expectCode(0, run);
    try expectContains("SKIP", run);
}

test "corpus revision mismatch is rejected" {
    const allocator = std.testing.allocator;
    if (!gitAvailable(allocator)) return;

    var root = try tmpRoot(allocator);
    defer {
        root.tmp.cleanup();
        allocator.free(root.base);
    }
    try mkCase(allocator, root.tmp.dir, "git/ok-case", false);

    var env = try makeEnv(allocator, &.{
        .{ "GIT_CONFIG_GLOBAL", "/dev/null" },
        .{ "GIT_CONFIG_SYSTEM", "/dev/null" },
    });
    defer env.deinit();

    const init_args = [_][]const u8{ "-C", root.base, "init", "-q" };
    try runGit(allocator, &env, &init_args);
    const add_args = [_][]const u8{ "-C", root.base, "add", "-A" };
    try runGit(allocator, &env, &add_args);
    const commit_args = [_][]const u8{ "-C", root.base, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init" };
    try runGit(allocator, &env, &commit_args);

    const run = try runSuite(allocator, &.{ fixture_exe, root.base }, &.{});
    defer allocator.free(run.output);
    try expectCode(1, run);
    try expectContains("does not match pinned", run);
}

fn gitAvailable(allocator: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "--version" },
        .max_output_bytes = 4096,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |c| return c == 0,
        else => return false,
    }
}

fn runGit(allocator: std.mem.Allocator, env: *const std.process.EnvMap, args: []const []const u8) !void {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args) |a| try argv.append(allocator, a);
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .env_map = env,
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |c| if (c != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}