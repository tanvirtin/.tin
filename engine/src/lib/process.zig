const std = @import("std");

pub const ProcessError = error{
    CommandFailed,
};

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const code = try runCode(allocator, argv);
    if (code != 0) return ProcessError.CommandFailed;
}

pub fn runCode(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| code,
        else => 255,
    };
}

pub const Capture = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    pub fn deinit(self: Capture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn capture(allocator: std.mem.Allocator, argv: []const []const u8) !Capture {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 512 * 1024,
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = switch (result.term) {
            .Exited => |code| code,
            else => 255,
        },
    };
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

test "runCode returns the child exit code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u8, 0), try runCode(arena.allocator(), &.{"true"}));
    try std.testing.expectEqual(@as(u8, 1), try runCode(arena.allocator(), &.{"false"}));
}

test "capture returns stdout and a zero exit code" {
    const result = try capture(std.testing.allocator, &.{ "sh", "-c", "printf hello" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings("hello", result.stdout);
}

test "capture reports a non-zero exit code" {
    const result = try capture(std.testing.allocator, &.{ "sh", "-c", "exit 3" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 3), result.code);
}
