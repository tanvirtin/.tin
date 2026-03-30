const std = @import("std");

pub const ProcessError = error{
    CommandFailed,
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

