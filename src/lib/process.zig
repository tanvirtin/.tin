const std = @import("std");

pub const ProcessError = error{
    CommandFailed,
};

pub const Capture = struct {
    code: u32,
    stdout: []const u8,
};

/// Run a command, collecting its stdout and exit code (no shell). Pass an
/// optional `cwd` to set the working directory. The caller owns the returned
/// stdout slice (use an arena for simplicity).
pub fn captureExitCwd(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !Capture {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    }) catch |e| return e;
    const code: u32 = switch (result.term) {
        .Exited => |c| @intCast(c),
        else => 1,
    };
    return .{ .code = code, .stdout = result.stdout };
}

pub fn captureExit(allocator: std.mem.Allocator, argv: []const []const u8) !Capture {
    return captureExitCwd(allocator, argv, null);
}

/// Run a command in a given working directory, inheriting stdio.
pub fn runCwd(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    }) catch |e| return e;
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return ProcessError.CommandFailed;
        },
        else => return ProcessError.CommandFailed,
    }
}

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return ProcessError.CommandFailed;
        },
        else => return ProcessError.CommandFailed,
    }
}

pub fn runShell(allocator: std.mem.Allocator, cmd: []const u8) !void {
    try run(allocator, &.{ "sh", "-c", cmd });
}

test "runShell succeeds for true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runShell(arena.allocator(), "true");
}

test "runShell fails for false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ProcessError.CommandFailed, runShell(arena.allocator(), "false"));
}
