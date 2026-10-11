const std = @import("std");

const pin_file = @embedFile("yaml-suite-revision.txt");
const default_timeout_secs: f64 = 10;

const Params = struct {
    bin: []const u8,
    corpus: []const u8,
    timeout_secs: f64,
};

const Outcome = union(enum) {
    exited: u8,
    signaled: u32,
    timed_out,
};

const Class = union(enum) {
    accept,
    reject,
    timeout,
    crash_exit: u8,
    crash_signal: u32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    const bin = args.next() orelse {
        std.debug.print("usage: test_yaml_suite <test_yaml_one-binary> [corpus-dir]\n", .{});
        std.debug.print("  corpus-dir may also be supplied with TIN_YAML_CORPUS_DIR\n", .{});
        std.process.exit(1);
    };

    var corpus_owned: ?[]u8 = null;
    defer if (corpus_owned) |c| allocator.free(c);
    const corpus: []const u8 = args.next() orelse blk: {
        corpus_owned = std.process.getEnvVarOwned(allocator, "TIN_YAML_CORPUS_DIR") catch break :blk "";
        break :blk corpus_owned.?;
    };

    if (corpus.len == 0) {
        std.debug.print("SKIP: no official YAML corpus provided (pass a corpus-dir or set TIN_YAML_CORPUS_DIR)\n", .{});
        return;
    }

    const code = try runSuite(allocator, .{
        .bin = bin,
        .corpus = corpus,
        .timeout_secs = readTimeout(allocator),
    });
    std.process.exit(code);
}

fn readTimeout(allocator: std.mem.Allocator) f64 {
    const raw = std.process.getEnvVarOwned(allocator, "TIN_YAML_TIMEOUT") catch return default_timeout_secs;
    defer allocator.free(raw);
    const value = std.fmt.parseFloat(f64, std.mem.trim(u8, raw, " \t\r\n")) catch return default_timeout_secs;
    if (value <= 0) return default_timeout_secs;
    return value;
}

fn parsePin(content: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "revision=")) {
            return std.mem.trim(u8, line["revision=".len..], " \t\r");
        }
    }
    return null;
}

fn isExecutable(path: []const u8) bool {
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

fn hasGitComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".git")) return true;
    }
    return false;
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn exists(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ dir, name }) catch return false;
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn relativeId(corpus: []const u8, case_dir: []const u8) []const u8 {
    if (case_dir.len > corpus.len) {
        const rest = case_dir[corpus.len..];
        if (rest.len > 0 and rest[0] == '/') return rest[1..];
        return rest;
    }
    return ".";
}

fn gitRevision(allocator: std.mem.Allocator, corpus: []const u8) ?[]u8 {
    const dotgit = std.fs.path.join(allocator, &.{ corpus, ".git" }) catch return null;
    defer allocator.free(dotgit);
    std.fs.cwd().access(dotgit, .{}) catch return null;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", corpus, "rev-parse", "HEAD" },
        .max_output_bytes = 256,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n")) catch null;
}

fn runCase(bin: []const u8, file: []const u8, timeout_ns: u64) !Outcome {
    var child = std.process.Child.init(&.{ bin, file }, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var timer = try std.time.Timer.start();
    while (true) {
        const res = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (res.pid != 0) {
            if (std.posix.W.IFEXITED(res.status)) return .{ .exited = std.posix.W.EXITSTATUS(res.status) };
            if (std.posix.W.IFSIGNALED(res.status)) return .{ .signaled = std.posix.W.TERMSIG(res.status) };
            return .{ .exited = 255 };
        }
        if (timer.read() >= timeout_ns) {
            std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            _ = std.posix.waitpid(child.id, 0);
            return .timed_out;
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
}

fn classify(outcome: Outcome) Class {
    return switch (outcome) {
        .timed_out => .timeout,
        .exited => |code| switch (code) {
            0 => .accept,
            2 => .reject,
            else => .{ .crash_exit = code },
        },
        .signaled => |sig| .{ .crash_signal = sig },
    };
}

fn classLabel(class: Class, buf: *[64]u8) []const u8 {
    return switch (class) {
        .accept => "accept",
        .reject => "reject",
        .timeout => "timeout",
        .crash_exit => |code| std.fmt.bufPrint(buf, "crash (exit {d})", .{code}) catch "crash",
        .crash_signal => |sig| std.fmt.bufPrint(buf, "crash (signal {d})", .{sig}) catch "crash",
    };
}

fn reportFail(id: []const u8, expected: []const u8, class: Class) void {
    var buf: [64]u8 = undefined;
    std.debug.print("FAIL {s}: expected {s}, got {s}\n", .{ id, expected, classLabel(class, &buf) });
}

fn runSuite(allocator: std.mem.Allocator, params: Params) !u8 {
    const bin = params.bin;
    const corpus = params.corpus;
    const pin = parsePin(pin_file);

    if (!isExecutable(bin)) {
        std.debug.print("ERROR: binary not found or not executable: {s}\n", .{bin});
        return 1;
    }

    var dir = std.fs.cwd().openDir(corpus, .{ .iterate = true }) catch {
        std.debug.print("ERROR: corpus directory not found: {s}\n", .{corpus});
        return 1;
    };
    defer dir.close();

    const actual_owned = gitRevision(allocator, corpus);
    defer if (actual_owned) |a| allocator.free(a);
    const actual: []const u8 = actual_owned orelse "unverified";

    if (pin) |p| {
        if (!std.mem.eql(u8, actual, "unverified") and !std.mem.eql(u8, actual, p)) {
            std.debug.print("ERROR: corpus revision {s} does not match pinned {s}\n", .{ actual, p });
            return 1;
        }
    }

    var cases = std.ArrayListUnmanaged([]u8){};
    defer {
        for (cases.items) |c| allocator.free(c);
        cases.deinit(allocator);
    }

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "in.yaml")) continue;
        if (hasGitComponent(entry.path)) continue;
        const abs = std.fs.path.join(allocator, &.{ corpus, entry.path }) catch continue;
        try cases.append(allocator, abs);
    }

    std.mem.sort([]u8, cases.items, {}, lessThan);

    const count = cases.items.len;
    if (count == 0) {
        std.debug.print("ERROR: no in.yaml cases found in corpus (empty or wrong layout): {s}\n", .{corpus});
        return 1;
    }

    std.debug.print("YAML suite corpus: {s}\n", .{corpus});
    std.debug.print("YAML suite revision: {s} (corpus: {s})\n", .{ pin orelse "unpinned", actual });
    std.debug.print("Cases: {d}\n", .{count});

    const timeout_ns: u64 = @intFromFloat(params.timeout_secs * @as(f64, @floatFromInt(std.time.ns_per_s)));

    var accept_total: usize = 0;
    var accept_pass: usize = 0;
    var reject_total: usize = 0;
    var reject_pass: usize = 0;
    var failed: usize = 0;

    for (cases.items) |file| {
        const case_dir = std.fs.path.dirname(file) orelse corpus;
        const is_reject = exists(allocator, case_dir, "error");
        const outcome = try runCase(bin, file, timeout_ns);
        const class = classify(outcome);
        const id = relativeId(corpus, case_dir);
        if (is_reject) {
            reject_total += 1;
            switch (class) {
                .reject => reject_pass += 1,
                else => {
                    failed += 1;
                    reportFail(id, "reject", class);
                },
            }
        } else {
            accept_total += 1;
            switch (class) {
                .accept => accept_pass += 1,
                else => {
                    failed += 1;
                    reportFail(id, "accept", class);
                },
            }
        }
    }

    const passed = accept_pass + reject_pass;
    std.debug.print("Accept: {d}/{d}  Reject: {d}/{d}  Total: {d}/{d}\n", .{ accept_pass, accept_total, reject_pass, reject_total, passed, count });

    if (failed > 0) {
        std.debug.print("Failing: {d}\n", .{failed});
        return 1;
    }
    return 0;
}