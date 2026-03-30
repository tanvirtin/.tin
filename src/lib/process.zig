const std = @import("std");

pub const ProcessError = error{
    CommandFailed,
    CommandNotFound,
};

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

pub fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout: std.ArrayList(u8) = .{};
    var stderr: std.ArrayList(u8) = .{};
    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) return ProcessError.CommandFailed;
        },
        else => return ProcessError.CommandFailed,
    }

    return stdout.items;
}

pub fn runShell(allocator: std.mem.Allocator, cmd: []const u8) !void {
    try run(allocator, &.{ "sh", "-c", cmd });
}

test "run type compiles" {
    _ = run;
}

test "runCapture type compiles" {
    _ = runCapture;
}

test "runShell type compiles" {
    _ = runShell;
}
